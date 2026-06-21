import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// "Confirm Payment" bottom sheet presented after a successful Scan-to-Pay
/// scan resolves a recipient. Premium, minimal, dark-glass — matches the
/// inspiration layout (recipient avatar + handle, "Amount to pay" big
/// figure + asset, "Available" line, green Slide to Pay, Cancel).
///
/// Execution REUSES the existing gasless send pipeline verbatim:
/// `ZkLoginCoordinator.signAndSubmitSend` (sponsor-prepare → sign →
/// broadcast/confirm), the same path `SendFlowView` runs. On slide-complete
/// we run that, then swap in the existing `SuccessfulTxView` celebration.
/// Nothing about the send rail is re-implemented here — only the surface.
///
/// Presentation: hosted as a `.sheet` from `ScanToPayView` (sheet-over-
/// sheet). The scanner stays alive underneath; dismissing this sheet returns
/// the user to the live viewfinder so a mistyped amount / wrong code isn't a
/// dead end. A successful send dismisses the whole scan surface back to Home.
struct ConfirmPaymentSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The resolved recipient — address + display identity. Resolved by the
    /// scanner before this sheet is shown (reusing /api/recipient/resolve or
    /// the local SuiAddress decode), so we never present an unresolved code.
    let recipient: RecipientResolution
    /// Amount the QR carried (USDsui / USD), if any. When set we seed the
    /// editable field with it; otherwise the user types the amount.
    let scannedAmount: Double?
    /// Called after a successful send + Done so the scanner can tear the
    /// whole Scan-to-Pay surface down back to Home.
    var onPaid: () -> Void

    /// Raw amount string in the user's display currency. Seeded from the
    /// scanned amount (converted into the display currency) when present.
    @State private var rawAmount: String = ""
    @State private var balance: BalancesDTO?
    @State private var sending = false
    @State private var resetSlide = false
    @State private var errorMessage: String?
    @State private var success: SendSuccess?
    @FocusState private var amountFocused: Bool

    /// USDsui-equivalent of the typed amount. Talise settles in USDsui (1:1
    /// USD) on chain; the user types in their display currency so we convert
    /// back through CurrencySettings, exactly like the Send flow does.
    private var amountUsdsui: Double {
        let cleaned = rawAmount.replacingOccurrences(of: ",", with: "")
        guard let typed = Double(cleaned), typed > 0 else { return 0 }
        return CurrencySettings.shared.convertToUsd(local: typed)
    }

    private var currency: TaliseCurrency { CurrencySettings.shared.current }

    private var availableUsdsui: Double { balance?.usdsui ?? 0 }

    /// True once the typed amount exceeds the wallet balance — drives the
    /// red "Not enough" hint and disables the slide.
    private var exceedsBalance: Bool {
        let amt = amountUsdsui
        guard amt > 0 else { return false }
        return amt > availableUsdsui
    }

    private var canPay: Bool {
        amountUsdsui > 0 && !exceedsBalance && !sending
    }

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()

            if let success {
                // Reuse the EXISTING success celebration shown by the Send
                // flow — same component, same currency formatting.
                SuccessfulTxView(
                    amountText: TaliseFormat.local2(success.usdsui),
                    onShareReceipt: { shareReceipt(digest: success.digest) },
                    // Hand control back to the scanner, which dismisses the
                    // whole Scan-to-Pay surface (scanner + this nested sheet)
                    // back to Home in one motion. Calling our own dismiss()
                    // here too would race that teardown.
                    onDone: { onPaid() }
                )
                .transition(.opacity)
            } else {
                sheetBody
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadBalance() }
        .onAppear(perform: seedAmount)
    }

    // MARK: - Sheet body

    private var sheetBody: some View {
        VStack(spacing: 0) {
            grabHandle
                .padding(.top, 10)

            Text("Confirm Payment")
                .font(TaliseFont.heading(20, weight: .semibold))
                .kerning(-0.5)
                .foregroundStyle(TaliseColor.fg)
                .padding(.top, 18)

            recipientCard
                .padding(.horizontal, 22)
                .padding(.top, 24)

            amountBlock
                .padding(.horizontal, 22)
                .padding(.top, 26)

            availableLine
                .padding(.top, 12)

            if let errorMessage {
                Text(errorMessage)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer(minLength: 28)

            SlideToConfirm(
                title: "Slide to Pay",
                tint: TaliseColor.accent,
                reset: $resetSlide,
                onConfirm: { await pay() }
            )
            .padding(.horizontal, 22)
            .opacity(canPay ? 1 : 0.45)
            .allowsHitTesting(canPay)

            cancelButton
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        // Tap anywhere off the amount field to dismiss the keyboard and
        // expose the Slide to Pay control.
        .contentShape(Rectangle())
        .onTapGesture { amountFocused = false }
    }

    private var grabHandle: some View {
        Capsule()
            .fill(TaliseColor.fgDim.opacity(0.6))
            .frame(width: 38, height: 5)
    }

    // MARK: - Recipient card

    private var recipientCard: some View {
        HStack(spacing: 14) {
            avatarDisc

            VStack(alignment: .leading, spacing: 3) {
                Text(recipientHandle)
                    .font(TaliseFont.heading(16, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Recipient")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Initials monogram in a green disc — derived from the resolved display
    /// identity (handle initials, else the address tail).
    private var avatarDisc: some View {
        ZStack {
            Circle()
                .fill(TaliseColor.accent.opacity(0.18))
            Text(monogram)
                .font(TaliseFont.heading(17, weight: .semibold))
                .foregroundStyle(TaliseColor.accent)
        }
        .frame(width: 46, height: 46)
    }

    // MARK: - Amount

    private var amountBlock: some View {
        VStack(spacing: 6) {
            Text("Amount to pay")
                .font(TaliseFont.mono(11, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currency.symbol)
                    .font(TaliseFont.heading(38, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
                TextField("0", text: $rawAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(TaliseFont.heading(48, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .tint(TaliseColor.accent)
                    .focused($amountFocused)
                    .toolbar {
                        // The decimal pad has no return key, so give the
                        // user an explicit way to dismiss it and reach the
                        // Slide to Pay control below.
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { amountFocused = false }
                                .font(TaliseFont.heading(15, weight: .medium))
                                .tint(TaliseColor.accent)
                        }
                    }
            }

            Text(assetLine)
                .font(TaliseFont.mono(11, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .frame(maxWidth: .infinity)
    }

    /// Shows the on-chain asset, plus the USDsui-equivalent when the user is
    /// typing in a non-USD display currency so the chain figure is honest.
    private var assetLine: String {
        if currency.code == "USD" {
            return "USDsui"
        }
        let amt = amountUsdsui
        guard amt > 0 else { return "USDsui" }
        return "≈ \(TaliseFormat.usd2(amt)) USDsui"
    }

    @ViewBuilder
    private var availableLine: some View {
        if exceedsBalance {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(TaliseColor.danger)
                Text("Not enough — available \(TaliseFormat.local2(availableUsdsui))")
                    .font(TaliseFont.mono(11, weight: .regular))
                    .foregroundStyle(TaliseColor.danger)
            }
        } else {
            HStack(spacing: 5) {
                Text("Available")
                    .font(TaliseFont.mono(11, weight: .regular))
                    .foregroundStyle(TaliseColor.fgDim)
                Text(TaliseFormat.local2(availableUsdsui))
                    .font(TaliseFont.mono(11, weight: .regular))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
        }
    }

    private var cancelButton: some View {
        Button(action: { dismiss() }) {
            Text("Cancel")
                .font(TaliseFont.heading(15, weight: .medium))
                .foregroundStyle(TaliseColor.fgMuted)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .disabled(sending)
    }

    // MARK: - Derived identity

    /// The @handle (or shortened 0x) shown in the recipient card.
    private var recipientHandle: String {
        if let name = recipient.displayName, !name.isEmpty, name != recipient.address {
            return name
        }
        if let d = recipient.display, !d.isEmpty, d != recipient.address {
            return d
        }
        return shortAddress(recipient.address)
    }

    /// Two-letter monogram for the avatar disc. Strips SuiNS suffixes and
    /// the leading `@`; falls back to the address tail for raw 0x sends.
    private var monogram: String {
        let raw = recipientHandle
        var cleaned = raw
            .replacingOccurrences(of: "@talise.sui", with: "")
            .replacingOccurrences(of: ".talise.sui", with: "")
            .replacingOccurrences(of: ".sui", with: "")
        if cleaned.hasPrefix("@") { cleaned.removeFirst() }

        // 0x…/short-address recipients: take the two chars after "0x".
        if cleaned.lowercased().hasPrefix("0x") {
            let tail = cleaned.dropFirst(2).prefix(2)
            return tail.isEmpty ? "0x" : String(tail).uppercased()
        }

        let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }

    // MARK: - Seed / data

    private func seedAmount() {
        guard rawAmount.isEmpty, let scanned = scannedAmount, scanned > 0 else {
            // No carried amount — focus the field so the user can type.
            amountFocused = true
            return
        }
        // The QR amount is a USDsui (USD) figure; render it into the user's
        // display currency so the big number reads in their currency.
        let (local, _) = CurrencySettings.shared.convert(usd: scanned)
        rawAmount = formatSeed(local)
    }

    /// Trim trailing zeros so a seeded "50.00" reads as "50".
    private func formatSeed(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func loadBalance() async {
        do {
            let r: BalancesDTO = try await APIClient.shared.get("/api/balances")
            await MainActor.run { self.balance = r }
        } catch {
            // Silent — "Available $0.00" + the exceeds-balance guard keep
            // the slide disabled rather than letting an unfunded send through.
        }
    }

    // MARK: - Pay (reuses the existing gasless send pipeline)

    private func pay() async {
        guard canPay else {
            resetSlide = true
            return
        }
        amountFocused = false
        sending = true
        errorMessage = nil

        let amount = amountUsdsui
        let intentLabel = "Send \(currency.symbol)\(rawAmount)"

        do {
            // EXACT same call SendFlowView.performSend uses — sponsor-prepare
            // → sign → broadcast/confirm, gasless when eligible.
            let result = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                to: recipient.address,
                amountUsd: amount,
                asset: "USDsui",
                intent: intentLabel,
                rewards: ZkLoginCoordinator.RewardsMeta(
                    kind: "send",
                    amountUsd: amount,
                    venue: nil,
                    roundupUsd: nil
                )
            )

            // Defense in depth — an empty digest means it never landed.
            guard !result.digest.isEmpty else {
                throw ConfirmPayError.noDigest
            }

            let display = recipient.displayName ?? shortAddress(recipient.address)
            let outcome = SendSuccess(
                digest: result.digest,
                displayAmount: rawAmount.isEmpty ? "0" : rawAmount,
                currency: currency,
                usdsui: amount,
                recipientAddress: recipient.address,
                recipientDisplay: display
            )

            // Fire the canonical tx event so HomeView's optimistic-balance
            // path updates — identical to the Send flow's post.
            NotificationCenter.default.post(
                name: .taliseTxCompleted,
                object: TaliseTxEvent(
                    digest: result.digest,
                    direction: "sent",
                    amountUsdsui: amount,
                    counterparty: recipient.address,
                    counterpartyName: recipient.displayName,
                    venue: nil
                )
            )

            sending = false
            withAnimation(.easeInOut(duration: 0.25)) {
                success = outcome
            }
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            // Session predates the nonce binding — sign out so the user
            // re-auths. signOut() tears the whole scan surface down.
            sending = false
            session.signOut()
        } catch {
            sending = false
            errorMessage = (error as? ConfirmPayError)?.message
                ?? error.localizedDescription
            // Spring the knob back so the user can correct + retry without
            // re-scanning.
            resetSlide = true
        }
    }

    /// Local error so the missing-digest guard reads cleanly.
    private enum ConfirmPayError: Error {
        case noDigest
        var message: String {
            switch self {
            case .noDigest: return "Payment didn't land on chain. No funds moved."
            }
        }
    }

    // MARK: - Share receipt (mirrors SendCompleteView)

    private func shareReceipt(digest: String) {
        #if canImport(UIKit)
        guard !digest.isEmpty else { return }
        let urlString = "https://suivision.xyz/txblock/\(digest)"
        let av = UIActivityViewController(
            activityItems: [urlString], // string, not URL — avoids bplist paste garbage
            applicationActivities: nil
        )
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        av.popoverPresentationController?.sourceView = top.view
        top.present(av, animated: true)
        #endif
    }

    private func shortAddress(_ a: String) -> String {
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }
}
