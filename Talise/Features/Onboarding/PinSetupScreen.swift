import SwiftUI
import LocalAuthentication

/// Step 3/4: set a 4-digit PIN (or enroll biometrics) to secure the
/// wallet. Mirrors the inspiration screenshot: filled circles for entered
/// digits, a "Show PIN" reveal toggle, a 4×3 iOS-style numeric keypad,
/// and TWO CTAs (`Use Biometrics` secondary above `Continue` primary).
///
/// PIN handling: NEVER stores the raw PIN. Once the user has typed four
/// digits and tapped Continue, we hand the digits to `PinService.shared`
/// which writes `salt(16) || sha256(salt || pin)` to the Keychain
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
///
/// Biometrics path: `LAContext().canEvaluatePolicy(...)` first to gate
/// the secondary CTA. On success we flip a UserDefaults flag and
/// continue without requiring a PIN entry — the underlying account
/// still needs a PIN registered for the existing PinGate flow, so this
/// path also requires the user to have typed four digits.
///
/// This file is intentionally separate from `PinEntrySheet.swift`
/// (which handles unlock/verify post-onboarding) — the design language
/// is the same but the setup UX is full-screen, not a sheet.
struct PinSetupScreen: View {
    let userId: String
    let onContinue: () -> Void

    @State private var entry: String = ""
    @State private var showPin: Bool = false
    @State private var biometricsAvailable: Bool = false
    @State private var failureMessage: String?

    private let pinLength = 4

    private func kern(_ size: CGFloat) -> CGFloat { -size * 0.03 }

    var body: some View {
        ZStack(alignment: .top) {
            OnboardingBackground()

            VStack(spacing: 0) {
                OnboardingProgressBar(totalSteps: 4, currentStep: 3)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Secure your wallet")
                        .font(TaliseFont.heading(23.5, weight: .semibold))
                        .kerning(kern(23.5))
                        .foregroundStyle(TaliseColor.fg)

                    Text("Set a 4-digit PIN or use biometrics to secure your wallet. Talise doesn't know your PIN.")
                        .font(TaliseFont.body(13, weight: .light))
                        .kerning(kern(13))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                pinDisplay
                    .padding(.top, 22)

                Button {
                    showPin.toggle()
                } label: {
                    Text(showPin ? "Hide PIN" : "Show PIN")
                        .font(TaliseFont.body(12, weight: .medium))
                        .kerning(kern(12))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .underline()
                        .padding(.vertical, 8)
                }

                if let msg = failureMessage {
                    Text(msg)
                        .font(TaliseFont.body(12))
                        .foregroundStyle(TaliseColor.danger)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)

                numpad
                    .padding(.horizontal, 40)

                Spacer().frame(height: 12)

                if biometricsAvailable {
                    secondaryCTA
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                }

                primaryCTA
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            biometricsAvailable = checkBiometricsAvailable()
        }
    }

    // MARK: - PIN display

    /// Four squares — empty when slot is unfilled, a filled circle (or
    /// the literal digit when `Show PIN` is toggled on) when it is.
    private var pinDisplay: some View {
        HStack(spacing: 14) {
            ForEach(0..<pinLength, id: \.self) { idx in
                pinSlot(at: idx)
            }
        }
    }

    private func pinSlot(at idx: Int) -> some View {
        let filled = idx < entry.count
        let digit: String = {
            guard filled, showPin, idx < entry.count else { return "" }
            let i = entry.index(entry.startIndex, offsetBy: idx)
            return String(entry[i])
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: 56, height: 64)

            if filled && !showPin {
                Circle()
                    .fill(TaliseColor.fg)
                    .frame(width: 14, height: 14)
                    .transition(.scale.combined(with: .opacity))
            } else if !digit.isEmpty {
                Text(digit)
                    .font(TaliseFont.heading(24, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: entry)
        .animation(.easeInOut(duration: 0.18), value: showPin)
    }

    // MARK: - Keypad

    private var numpad: some View {
        let rows: [[NumKey]] = [
            [.digit("1"), .digit("2"), .digit("3")],
            [.digit("4"), .digit("5"), .digit("6")],
            [.digit("7"), .digit("8"), .digit("9")],
            [.blank,      .digit("0"), .delete],
        ]
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        keyView(rows[r][c])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: NumKey) -> some View {
        switch key {
        case .digit(let d):
            Button { tapDigit(d) } label: {
                Text(d)
                    .font(.system(size: 30, weight: .regular, design: .rounded))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NumKeyStyle())
        case .delete:
            Button { tapDelete() } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .blank:
            Color.clear.frame(maxWidth: .infinity).frame(height: 58)
        }
    }

    private enum NumKey {
        case digit(String)
        case delete
        case blank
    }

    // MARK: - CTAs

    private var primaryCTA: some View {
        Button(action: persistAndContinue) {
            Text("Continue")
                .font(TaliseFont.body(15, weight: .medium))
                .kerning(kern(15))
                .foregroundStyle(TaliseColor.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(entry.count == pinLength ? TaliseColor.accent : TaliseColor.accent.opacity(0.4))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(entry.count != pinLength)
        .animation(.easeInOut(duration: 0.18), value: entry.count)
    }

    private var secondaryCTA: some View {
        Button(action: requestBiometrics) {
            HStack(spacing: 8) {
                Image(systemName: "faceid")
                    .font(.system(size: 16, weight: .medium))
                Text("Use Biometrics")
                    .font(TaliseFont.body(15, weight: .medium))
                    .kerning(kern(15))
            }
            .foregroundStyle(TaliseColor.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.white.opacity(0.08))
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        // Require a 4-digit PIN FIRST — biometrics augments the PIN, it doesn't
        // replace it (PinGate's verify path needs a PIN on file). Prevents a
        // user finishing onboarding with no PIN registered.
        .disabled(entry.count != pinLength)
        .opacity(entry.count == pinLength ? 1 : 0.4)
    }

    // MARK: - Handlers

    private func tapDigit(_ d: String) {
        guard entry.count < pinLength else { return }
        failureMessage = nil
        entry.append(d)
    }

    private func tapDelete() {
        guard !entry.isEmpty else { return }
        entry.removeLast()
        failureMessage = nil
    }

    private func persistAndContinue() {
        guard entry.count == pinLength else { return }
        do {
            try PinService.shared.setPin(entry, userId: userId)
            UserDefaults.standard.set(false, forKey: "talise.onboarding.biometricsEnabled")
            onContinue()
        } catch {
            failureMessage = "Couldn't save PIN. Try again."
            entry = ""
        }
    }

    private func checkBiometricsAvailable() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func requestBiometrics() {
        // A PIN is mandatory on file (the unlock gate verifies against it);
        // biometrics only adds a faster path. The button is disabled until 4
        // digits are entered, but guard here too as defense in depth.
        guard entry.count == pinLength else {
            failureMessage = "Set your 4-digit PIN first."
            return
        }
        // Persist the PIN NOW so it's always registered before we enable
        // biometrics — even if the OS prompt is then cancelled.
        do {
            try PinService.shared.setPin(entry, userId: userId)
        } catch {
            failureMessage = "Couldn't save your PIN. Please try again."
            return
        }
        let ctx = LAContext()
        var policyError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            // No biometrics on device — the PIN is already saved, so just go.
            UserDefaults.standard.set(false, forKey: "talise.onboarding.biometricsEnabled")
            onContinue()
            return
        }
        ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Enable biometric unlock for Talise"
        ) { success, _ in
            Task { @MainActor in
                // PIN is already on file either way; biometrics is the bonus.
                UserDefaults.standard.set(success, forKey: "talise.onboarding.biometricsEnabled")
                onContinue()
            }
        }
    }
}

/// Tap feedback for the setup numpad — matches the unlock-sheet keys.
private struct NumKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0))
                    .frame(width: 68, height: 68)
                    .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            )
    }
}
