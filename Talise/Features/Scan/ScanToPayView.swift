import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen Scan-to-Pay surface. The user lands here from the Home
/// top-right disc (the slot previously occupied by Contacts).
///
/// The live camera feed (`QRScannerView`) mounts behind the overlay; the
/// corner brackets + caption float on top. Camera permission is requested
/// in onboarding (`PermissionsScreen`) but we never assume it — we
/// re-check `AVCaptureDevice.authorizationStatus(for: .video)` on appear
/// and request if undetermined. Denied/restricted → an inline Settings
/// prompt. Simulator / no camera → an "unavailable" state.
///
/// A successful scan parses the QR (`ScanPayload`), resolves the recipient
/// to a display identity (reusing `/api/recipient/resolve` + the local
/// `SuiAddress` decode the Send flow uses), and presents a
/// `ConfirmPaymentSheet` over the scanner. The user reviews the recipient +
/// amount and slides to pay; execution reuses the existing gasless send
/// pipeline (`ZkLoginCoordinator.signAndSubmitSend`). After a successful
/// send the whole scan surface dismisses back to Home.
struct ScanToPayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var balance: BalancesDTO?
    @State private var flashOn = false

    /// Camera authorization gate. Drives which surface we paint.
    enum CameraState {
        case checking      // resolving authorizationStatus / requesting
        case scanning      // authorized + camera present → live preview
        case denied        // .denied / .restricted → Settings prompt
        case unavailable   // no capture device (simulator, no back camera)
    }
    @State private var cameraState: CameraState = .checking
    /// Whether the active device has a torch. Hides the flash toggle when
    /// false (front-only devices, simulator).
    @State private var hasTorch = false
    /// Brief "Not a Talise payment code" pill, auto-dismissed.
    @State private var showUnrecognized = false
    /// Latches once we've handed a valid scan to the confirm sheet so a
    /// second frame can't double-route.
    @State private var didRoute = false
    /// Bumped after an unrecognized scan to re-arm QRScannerView's
    /// debounce so the next code is read.
    @State private var resumeToken = 0
    /// True while we resolve the scanned recipient to a display identity
    /// before presenting the confirm sheet — drives the "Resolving…" overlay.
    @State private var resolving = false
    /// Brief "Scanned ✓" success interstitial between a locked scan and the
    /// confirm sheet. Without it the sheet snapped up the instant a code was
    /// read — too fast to register what happened.
    @State private var scanned = false
    /// The resolved payment, set once the scanned recipient resolves. Drives
    /// the `.sheet(item:)` that presents `ConfirmPaymentSheet`.
    @State private var pendingPayment: PendingPayment?

    // MARK: Mode + bank path

    /// Top toggle: scan with the camera vs. type a bank account by hand.
    enum Mode { case scan, manual }
    @State private var mode: Mode = .scan

    /// A detected/entered bank account ready to pay out. Drives the
    /// `.sheet(item:)` that presents `ScanBankPayoutSheet`.
    @State private var pendingBank: PendingBankPayout?

    /// OCR lock debounce. We require the SAME {bank, account} candidate on a
    /// few consecutive frames before routing, so a half-read placard doesn't
    /// fire a wrong account at the off-ramp.
    @State private var ocrCandidate: BankAccountExtractor.Candidate?
    @State private var ocrStreak = 0
    private let ocrLockThreshold = 2

    // Manual entry.
    @State private var manualBank: ScanBank?
    @State private var manualAccount: String = ""
    @State private var showBankPicker = false
    @FocusState private var manualAccountFocused: Bool

    private var manualReady: Bool {
        manualBank != nil && manualAccount.count == 10
    }

    /// Same formatter HomeView uses for the headline figure — keeps the
    /// pill consistent with the user's "Balance $X.XX" elsewhere in the
    /// app. Empty wallet renders as "$0.00".
    private var balanceFormatted: String {
        TaliseFormat.local2(balance?.usdsui ?? 0)
    }

    var body: some View {
        ZStack {
            // Black backdrop — always present so any letterboxing around
            // the aspect-fill preview reads as intentional black.
            Color.black.ignoresSafeArea()

            // Live camera feed sits behind the overlay so the corner
            // brackets + caption float on top of the frame.
            if cameraState == .scanning && mode == .scan {
                QRScannerView(
                    torchOn: flashOn,
                    resumeToken: resumeToken,
                    onCode: handleScan,
                    onText: handleOCR,
                    ocrEnabled: true,
                    onCameraAvailability: { available in
                        // The representable resolves availability after we
                        // optimistically entered .scanning; demote to the
                        // unavailable surface if there's no usable device.
                        if !available { cameraState = .unavailable }
                    },
                    onTorchAvailability: { hasTorch = $0 }
                )
                .ignoresSafeArea()
            }

            if mode == .manual {
                manualEntry
            } else {
                overlay
            }

            // Permission / availability surfaces sit above the overlay so
            // their copy isn't competing with the viewfinder caption. Only in
            // scan mode — manual entry needs no camera.
            if mode == .scan {
                switch cameraState {
                case .denied:       deniedState
                case .unavailable:  unavailableState
                case .checking, .scanning: EmptyView()
                }
            }

            // Brief resolving veil between a valid scan and the confirm
            // sheet — covers the SuiNS / address lookup so the viewfinder
            // doesn't keep flashing the success haptic underneath.
            if resolving {
                resolvingOverlay
            }
            if scanned {
                scannedOverlay
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .task { await loadBalance() }
        .onAppear(perform: resolveCameraAuthorization)
        .sheet(item: $pendingPayment, onDismiss: rearmAfterConfirm) { payment in
            ConfirmPaymentSheet(
                recipient: payment.recipient,
                scannedAmount: payment.amount,
                onPaid: {
                    // Send landed — dismiss the scanner, which tears down
                    // this nested confirm sheet with it, returning the user
                    // to Home in one motion.
                    dismiss()
                }
            )
            .presentationDetents([.height(560), .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(TaliseColor.bg)
        }
        .sheet(item: $pendingBank, onDismiss: rearmAfterBank) { payout in
            ScanBankPayoutSheet(
                bank: payout.bank,
                accountNumber: payout.accountNumber,
                onPaid: { dismiss() }
            )
            .presentationDetents([.height(580), .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(TaliseColor.bg)
        }
        .sheet(isPresented: $showBankPicker) {
            ScanBankPickerSheet(selected: manualBank) { manualBank = $0 }
        }
    }

    /// After the bank sheet is dismissed without paying out, re-arm the
    /// scanner + clear the OCR debounce so a fresh placard can lock.
    private func rearmAfterBank() {
        pendingBank = nil
        didRoute = false
        ocrCandidate = nil
        ocrStreak = 0
        resumeToken &+= 1
    }

    /// After the confirm sheet is dismissed WITHOUT a completed payment (the
    /// user tapped Cancel or swiped down), re-arm the scanner so they can
    /// scan again instead of staring at a latched viewfinder.
    private func rearmAfterConfirm() {
        pendingPayment = nil
        didRoute = false
        ocrCandidate = nil
        ocrStreak = 0
        resumeToken &+= 1
    }

    /// "Scanned successfully" beat — a mint check that pops in, holds, then
    /// hands off to the confirm sheet. ~0.9s total: long enough to register,
    /// short enough to keep the flow fast.
    private var scannedOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(TaliseColor.greenMint.opacity(0.16))
                        .frame(width: 64, height: 64)
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(TaliseColor.greenMint)
                }
                .scaleEffect(scannedPop ? 1 : 0.4)
                .opacity(scannedPop ? 1 : 0)
                Text("Scanned successfully")
                    .font(TaliseFont.body(13, weight: .regular))
                    .foregroundStyle(.white)
                    .opacity(scannedPop ? 1 : 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(TaliseColor.surface)
            )
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                scannedPop = true
            }
        }
        .onDisappear { scannedPop = false }
    }
    @State private var scannedPop = false

    /// Show the success beat, then run `andThen` (presenting whichever sheet
    /// the scan routed to). One place so the QR and bank-OCR paths feel
    /// identical.
    private func showScannedThen(_ andThen: @escaping () -> Void) {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        withAnimation(.easeIn(duration: 0.12)) { scanned = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.15)) { scanned = false }
            // Let the veil fade before the sheet slides — no overlap jank.
            try? await Task.sleep(nanoseconds: 150_000_000)
            andThen()
        }
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                TaliseLoadingRing(size: 44, lineWidth: 3)
                Text("Finding who to pay…")
                    .font(TaliseFont.body(13, weight: .regular))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(TaliseColor.surface)
            )
        }
        .transition(.opacity)
    }

    // MARK: - Overlay

    /// Side of the viewfinder window — also the cut-out for the dimming
    /// scrim and the radius the corner brackets trace.
    private let viewfinderSize: CGFloat = 268

    private var overlay: some View {
        ZStack {
            // Soft dimming scrim with the viewfinder window punched out, so
            // the live frame reads brightest inside the brackets (the inspo
            // focus-window feel). Only painted over the live preview.
            if cameraState == .scanning {
                scrim
            }

            // Center: viewfinder corner brackets, floated over the full-bleed
            // camera. Sits independently so it stays vertically centered
            // regardless of the top/bottom overlay chrome. Mint brackets + a
            // sweeping scan line make the window unmistakably Talise.
            ZStack {
                ScanFrame(
                    size: viewfinderSize,
                    cornerRadius: 28,
                    bracketLength: 34,
                    lineWidth: 3,
                    color: TaliseColor.greenMint
                )
                if cameraState == .scanning {
                    ScanSweep(size: viewfinderSize)
                }
            }
            .frame(width: viewfinderSize, height: viewfinderSize)

            // Top + bottom chrome float over the edge-to-edge camera. A
            // subtle dark gradient behind each keeps the white controls
            // legible over a bright viewfinder.
            VStack(spacing: 0) {
                topChrome
                    .background(topScrim)

                Spacer(minLength: 0)

                bottomChrome
                    .background(bottomScrim)
            }
        }
    }

    /// Top overlay block: close button + title + mode toggle, sitting in the
    /// top safe area over a dark gradient scrim. The balance deliberately does
    /// NOT live up here (that's every super-app's scanner) — it sits in a
    /// quiet chip above the caption instead.
    private var topChrome: some View {
        VStack(spacing: 0) {
            topStatusBar
                .padding(.horizontal, 24)
                .padding(.top, 8)

            // Title sits just below the status bar. Kerning ratio matches the
            // design language (-size × 0.03).
            Text("Point & pay")
                .font(TaliseFont.heading(20, weight: .semibold))
                .kerning(-20 * 0.03)
                .foregroundStyle(.white)
                .padding(.top, 26)

            Text("QR codes, account numbers — one camera.")
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 4)

            modeToggle
                .padding(.top, 16)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
    }

    /// Bottom overlay block: balance chip + instruction caption (or the
    /// "unrecognized" pill) over a dark gradient scrim, anchored above the
    /// home indicator.
    private var bottomChrome: some View {
        VStack(spacing: 14) {
            balanceChip

            if showUnrecognized {
                unrecognizedPill
                    .transition(.opacity)
            } else {
                Text("Frame a Talise code or a bank account number — Talise reads it and sets up the payment.")
                    .font(TaliseFont.body(13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 52)
            }
        }
        .padding(.top, 36)
        .padding(.bottom, 40)
    }

    /// Dark top→clear gradient behind the top chrome so white controls stay
    /// legible over a bright camera frame. Extends up under the status bar.
    private var topScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    /// Clear→dark gradient behind the bottom hint, extending below the home
    /// indicator.
    private var bottomScrim: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    /// Dimming scrim with a rounded-rect cut-out over the viewfinder window.
    /// `.blendMode(.destinationOut)` punches the window through the fill;
    /// the `.compositingGroup()` confines the blend to this layer so it
    /// doesn't erase the camera preview behind it.
    private var scrim: some View {
        Rectangle()
            .fill(Color.black.opacity(0.42))
            .ignoresSafeArea()
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .frame(width: viewfinderSize, height: viewfinderSize)
                    .blendMode(.destinationOut)
            )
            .compositingGroup()
            .allowsHitTesting(false)
    }

    /// Transient "not a Talise code" feedback. We keep scanning underneath
    /// — this just tells the user the last code wasn't routable.
    private var unrecognizedPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("Not a Talise payment code")
                .font(TaliseFont.body(13, weight: .regular))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(TaliseColor.surface))
    }

    // MARK: - Mode toggle

    /// "Camera / Type it in" segmented control, glassy over the dark scanner
    /// backdrop with the active segment in brand mint. Switching to manual
    /// stops feeding the camera (the scanner is unmounted in `body`) and
    /// reveals the bank form.
    private var modeToggle: some View {
        HStack(spacing: 4) {
            toggleSegment(title: "Camera", icon: "viewfinder", isOn: mode == .scan) { mode = .scan }
            toggleSegment(title: "Type it in", icon: "keyboard", isOn: mode == .manual) {
                flashOn = false
                mode = .manual
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private func toggleSegment(title: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(TaliseFont.heading(13, weight: .medium))
            }
            .foregroundStyle(isOn ? TaliseColor.bg : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isOn ? TaliseColor.greenMint : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// Quiet balance chip above the caption — what you can spend, where your
    /// eye already is, instead of the super-app top-corner figure.
    private var balanceChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TaliseColor.greenMint)
                .frame(width: 6, height: 6)
            Text("Balance")
                .font(TaliseFont.mono(10, weight: .regular))
                .kerning(1.1)
                .foregroundStyle(.white.opacity(0.65))
            Text(balanceFormatted)
                .font(TaliseFont.heading(14, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    // MARK: - Manual entry

    /// Type a bank + 10-digit account by hand. Mirrors the bank-form pattern
    /// from `BankWithdrawView` (searchable picker + 10-digit field). Sits on
    /// the dark scanner backdrop so the toggle stays in place.
    private var manualEntry: some View {
        VStack(spacing: 0) {
            topStatusBar
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Text("Pay a bank account")
                .font(TaliseFont.heading(20, weight: .semibold))
                .kerning(-20 * 0.03)
                .foregroundStyle(.white)
                .padding(.top, 26)

            Text("We confirm the account name before anything moves.")
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 4)

            modeToggle
                .padding(.top, 16)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    manualLabel("Bank")
                    Button { showBankPicker = true } label: {
                        HStack(spacing: 12) {
                            Text(manualBank?.name ?? "Select bank")
                                .font(TaliseFont.body(15))
                                .foregroundStyle(manualBank == nil ? .white.opacity(0.5) : .white)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                        .background(manualFieldShape.fill(Color.white.opacity(0.08)))
                        .overlay(manualFieldShape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    manualLabel("Account number")
                    TextField("", text: $manualAccount, prompt: Text("10-digit account number").foregroundColor(.white.opacity(0.4)))
                        .keyboardType(.numberPad)
                        .focused($manualAccountFocused)
                        .font(TaliseFont.body(16))
                        .foregroundStyle(.white)
                        .tint(TaliseColor.greenMint)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(manualFieldShape.fill(Color.white.opacity(0.08)))
                        .overlay(manualFieldShape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                        .onChange(of: manualAccount) { _, new in
                            let trimmed = String(new.filter { $0.isNumber }.prefix(10))
                            if trimmed != new { manualAccount = trimmed }
                        }
                }

                Button(action: routeManual) {
                    Text("Continue")
                        .font(TaliseFont.heading(16, weight: .medium))
                        .foregroundStyle(TaliseColor.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(manualReady ? TaliseColor.greenMint : Color.white.opacity(0.3))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!manualReady)
                .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { manualAccountFocused = false }
    }

    private var manualFieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private func manualLabel(_ s: String) -> some View {
        Text(s)
            .font(TaliseFont.mono(10, weight: .light))
            .kerning(1.3)
            .foregroundStyle(.white.opacity(0.6))
    }

    /// Route the manually-entered bank + account to the payout sheet.
    private func routeManual() {
        guard let bank = manualBank, manualAccount.count == 10 else { return }
        manualAccountFocused = false
        pendingBank = PendingBankPayout(bank: bank, accountNumber: manualAccount)
    }

    // MARK: - OCR routing

    /// Called per processed frame (throttled in the scanner) with the
    /// recognized strings. We extract a {bank, 10-digit account} candidate and
    /// debounce: the SAME candidate must appear on `ocrLockThreshold + 1`
    /// consecutive frames before we lock + present the payout sheet. This
    /// keeps a half-read placard from firing a wrong account.
    private func handleOCR(_ strings: [String]) {
        guard !didRoute, mode == .scan, pendingPayment == nil, pendingBank == nil else { return }
        guard let candidate = BankAccountExtractor.extract(from: strings) else {
            return
        }
        if candidate == ocrCandidate {
            ocrStreak += 1
        } else {
            ocrCandidate = candidate
            ocrStreak = 0
        }
        guard ocrStreak >= ocrLockThreshold else { return }

        // Locked — route to the off-ramp via the success beat. Latch so QR
        // frames + further OCR can't double-route.
        didRoute = true
        showScannedThen {
            pendingBank = PendingBankPayout(bank: candidate.bank, accountNumber: candidate.accountNumber)
        }
    }

    // MARK: - Top status bar

    /// Two-up row: a glass dismiss disc on the leading edge and the flash
    /// toggle on the trailing edge. The balance moved to the bottom chip
    /// (`balanceChip`) so the top stays uncluttered.
    private var topStatusBar: some View {
        HStack(alignment: .center, spacing: 12) {
            dismissButton
            Spacer()
            // Only paint the flash toggle when the active device actually
            // has a torch (hidden on the simulator + front-only devices).
            if hasTorch {
                flashToggle
            }
        }
    }

    private var dismissButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(TaliseColor.surface2))
        }
        .buttonStyle(.plain)
    }

    private var flashToggle: some View {
        Button(action: { flashOn.toggle() }) {
            // Drives AVCaptureDevice.torchMode via QRScannerView's
            // `torchOn` binding (applied in updateUIViewController →
            // setTorch). The icon swap mirrors the device state.
            Image(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(flashOn ? TaliseColor.greenMint : .white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(TaliseColor.surface2))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission states

    /// Shown for `.denied` / `.restricted`. The user already chose to deny
    /// (here or in onboarding) so a re-request would be a silent no-op —
    /// the only path forward is Settings.
    private var deniedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access needed to scan")
                .font(TaliseFont.heading(17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to scan a payment QR code.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
            Button(action: openSettings) {
                Text("Open Settings")
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(height: 48)
                    .padding(.horizontal, 28)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
    }

    /// Shown when there's no usable capture device — the iOS Simulator
    /// (no camera hardware) and devices without a back camera. Keeps the
    /// view testable instead of a frozen black screen.
    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera unavailable on this device")
                .font(TaliseFont.heading(17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Scan-to-Pay needs a camera. Try this on a physical iPhone.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .padding(24)
    }

    // MARK: - Authorization

    private func resolveCameraAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .scanning
        case .notDetermined:
            // Request inline — onboarding may have been skipped, or this
            // is the user's first camera touchpoint. Don't assume grant.
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    cameraState = granted ? .scanning : .denied
                }
            }
        case .denied, .restricted:
            cameraState = .denied
        @unknown default:
            cameraState = .denied
        }
    }

    private func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Scan routing

    /// Called once per detected QR (QRScannerView debounces). Valid codes
    /// resolve the recipient to a display identity and present the
    /// `ConfirmPaymentSheet`; unrecognized codes flash a pill and keep
    /// scanning.
    private func handleScan(_ raw: String) {
        guard !didRoute else { return }

        guard let parsed = ScanPayload.parse(raw) else {
            // Unrecognized code — flash the pill (auto-dismisses) and
            // re-arm the scanner so the next code is read. We deliberately
            // do NOT set `didRoute`. Bumping `resumeToken` clears
            // QRScannerView's `didEmit` latch via resumeDetection().
            withAnimation { showUnrecognized = true }
            resumeToken &+= 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation { showUnrecognized = false }
            }
            return
        }

        // Latch so a second frame can't double-route while we resolve.
        didRoute = true
        withAnimation { resolving = true }
        Task { await resolveAndPresent(parsed) }
    }

    /// Resolve the scanned recipient token to a display identity, then
    /// present the confirm sheet. Reuses the SAME resolution the Send flow
    /// uses: a bare 0x address decodes locally via `SuiAddress`; everything
    /// else (SuiNS names, Talise handles) goes through `/api/recipient/resolve`.
    /// A resolution miss re-arms the scanner with the "Not a Talise code"
    /// pill rather than presenting a confirm sheet for an unroutable target.
    private func resolveAndPresent(_ parsed: ScanPayload.Recipient) async {
        // 1. Local address decode — no network hop for a bare 0x scan.
        if let addr = SuiAddress(parsed.recipient) {
            let resolution = RecipientResolution(
                address: addr.raw,
                displayName: addr.short,
                display: nil,
                source: "address"
            )
            await present(resolution, amount: parsed.amount)
            return
        }

        // 2. SuiNS name / Talise handle → server resolver (same endpoint
        //    SendRecipientView's `scheduleResolve` hits).
        do {
            let encoded = parsed.recipient.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? parsed.recipient
            let resolution: RecipientResolution = try await APIClient.shared.get(
                "/api/recipient/resolve?q=\(encoded)"
            )
            await present(resolution, amount: parsed.amount)
        } catch {
            await failResolve()
        }
    }

    /// Hand a resolved recipient to the confirm sheet — via the success beat.
    private func present(_ resolution: RecipientResolution, amount: Double?) async {
        await MainActor.run {
            withAnimation { resolving = false }
            showScannedThen {
                pendingPayment = PendingPayment(recipient: resolution, amount: amount)
            }
        }
    }

    /// Resolution failed (no SuiNS / handle match, or network error). Drop
    /// the resolving veil, flash the unrecognized pill, and re-arm scanning.
    private func failResolve() async {
        await MainActor.run {
            withAnimation {
                resolving = false
                showUnrecognized = true
            }
            didRoute = false
            resumeToken &+= 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation { showUnrecognized = false }
            }
        }
    }

    // MARK: - Data

    private func loadBalance() async {
        do {
            let r: BalancesDTO = try await APIClient.shared.get("/api/balances")
            await MainActor.run { self.balance = r }
        } catch {
            // Silent — pill falls back to "$0.00" which is the design's
            // empty state anyway.
        }
    }
}

// MARK: - Pending payment

/// A resolved scan ready to confirm. `Identifiable` so it drives a
/// `.sheet(item:)`; the `id` is the recipient address since a given scan
/// resolves to exactly one payment target.
private struct PendingPayment: Identifiable {
    let recipient: RecipientResolution
    let amount: Double?
    var id: String { recipient.address }
}

/// A detected/entered bank account ready for off-ramp payout. Drives the
/// `.sheet(item:)` that presents `ScanBankPayoutSheet`.
private struct PendingBankPayout: Identifiable {
    let bank: ScanBank
    let accountNumber: String
    var id: String { "\(bank.code)-\(accountNumber)" }
}

// MARK: - Viewfinder frame

/// Four rounded corner brackets tracing a softly-rounded window. Each
/// bracket runs through the quarter-circle of the window's corner radius
/// and out along each edge, so the brackets visually belong to a rounded
/// rect rather than a hard square. Drawn with `Path` + `Canvas` so it
/// scales crisply at any DPI with round line caps.
private struct ScanFrame: View {
    /// Side of the (square) window the brackets enclose.
    let size: CGFloat
    /// Corner radius of the rounded window the brackets trace.
    let cornerRadius: CGFloat
    /// Length of each straight leg past the corner arc.
    let bracketLength: CGFloat
    /// Bracket stroke thickness.
    let lineWidth: CGFloat
    /// Bracket stroke colour — brand mint on the live scanner.
    var color: Color = .white

    var body: some View {
        Canvas { ctx, _ in
            let half = lineWidth / 2
            let minX = half
            let minY = half
            let maxX = size - half
            let maxY = size - half
            // Clamp the radius so the arc + both legs fit on each side.
            let r = min(cornerRadius, (size - lineWidth) / 2 - 1)
            let L = bracketLength

            // Top-left: straight down the left edge → corner arc → straight
            // along the top edge.
            var p = Path()
            p.move(to: CGPoint(x: minX, y: minY + r + L))
            p.addLine(to: CGPoint(x: minX, y: minY + r))
            p.addArc(
                center: CGPoint(x: minX + r, y: minY + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: minX + r + L, y: minY))
            ctx.stroke(p, with: .color(color), style: bracketStyle)

            // Top-right.
            p = Path()
            p.move(to: CGPoint(x: maxX - r - L, y: minY))
            p.addLine(to: CGPoint(x: maxX - r, y: minY))
            p.addArc(
                center: CGPoint(x: maxX - r, y: minY + r),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: maxX, y: minY + r + L))
            ctx.stroke(p, with: .color(color), style: bracketStyle)

            // Bottom-right.
            p = Path()
            p.move(to: CGPoint(x: maxX, y: maxY - r - L))
            p.addLine(to: CGPoint(x: maxX, y: maxY - r))
            p.addArc(
                center: CGPoint(x: maxX - r, y: maxY - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: maxX - r - L, y: maxY))
            ctx.stroke(p, with: .color(color), style: bracketStyle)

            // Bottom-left.
            p = Path()
            p.move(to: CGPoint(x: minX + r + L, y: maxY))
            p.addLine(to: CGPoint(x: minX + r, y: maxY))
            p.addArc(
                center: CGPoint(x: minX + r, y: maxY - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: minX, y: maxY - r - L))
            ctx.stroke(p, with: .color(color), style: bracketStyle)
        }
    }

    private var bracketStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}


// MARK: - Scan sweep

/// Animated mint sweep line gliding up and down inside the viewfinder —
/// signals "live and reading" and gives the window a Talise signature the
/// plain bracket frame lacked.
private struct ScanSweep: View {
    let size: CGFloat
    @State private var down = false

    var body: some View {
        LinearGradient(
            colors: [
                TaliseColor.greenMint.opacity(0),
                TaliseColor.greenMint.opacity(0.9),
                TaliseColor.greenMint.opacity(0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: size - 44, height: 2.5)
        .shadow(color: TaliseColor.greenMint.opacity(0.55), radius: 6)
        .offset(y: down ? size / 2 - 30 : -(size / 2 - 30))
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: down)
        .onAppear { down = true }
        .allowsHitTesting(false)
    }
}

#Preview {
    ScanToPayView()
}
