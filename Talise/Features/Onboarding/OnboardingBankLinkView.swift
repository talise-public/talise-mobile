import SwiftUI

/// Off-ramp Phase 3 — optional onboarding step shown ONLY to users who
/// selected country == Nigeria ("NG") on the KYC screen. A lightweight
/// "get paid in Naira" prompt with two actions:
///
///   • Add bank account — presents the Phase-2 `AddBankAccountView` add-flow
///     (bank picker → account → `/link/prepare` → sign consent →
///     `/link/confirm`). The first account a user links auto-becomes their
///     primary server-side, so no extra "set primary" step is needed here.
///   • Skip for now — continue onboarding untouched.
///
/// After either action the screen calls `onContinue()`; the parent
/// (`KYCView`) then proceeds with `session.bootstrap()` as normal. This step
/// never blocks onboarding — it's purely additive for Nigerian users.
struct OnboardingBankLinkView: View {
    /// Invoked once the user has linked an account OR chosen to skip.
    var onContinue: () -> Void

    @State private var showAdd = false
    @State private var linked = false

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if linked {
                        linkedConfirmation
                    } else {
                        valueProps
                    }

                    Spacer(minLength: 12)

                    actions
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddBankAccountView { _ in
                // First account auto-becomes primary server-side. Flip the
                // local confirmation; the user taps Continue to proceed.
                linked = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(TaliseColor.accent)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TaliseColor.accentSoft)
                )
            Text("Get paid in Naira")
                .font(TaliseFont.display(30, weight: .medium))
                .kerning(-0.8)
                .foregroundStyle(TaliseColor.fg)
            Text("Add a Nigerian bank account so people can pay you straight to your bank — in Naira. You can always do this later from your profile.")
                .font(TaliseFont.body(14))
                .foregroundStyle(TaliseColor.fgMuted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Value props

    private var valueProps: some View {
        VStack(spacing: 0) {
            prop(icon: "naira.sign.circle.fill", title: "Receive in Naira",
                 sub: "Friends send you USDsui; it lands in your bank as NGN.")
            Rectangle().fill(TaliseColor.line).frame(height: 1)
            prop(icon: "bolt.fill", title: "No extra steps later",
                 sub: "Linked once, your @handle is ready to be paid.")
            Rectangle().fill(TaliseColor.line).frame(height: 1)
            prop(icon: "lock.fill", title: "Private",
                 sub: "Senders only see your bank name — never your account number.")
        }
        .background(
            RoundedRectangle(cornerRadius: TaliseRadius.lg, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    private func prop(icon: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(TaliseColor.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Text(sub)
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var linkedConfirmation: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(TaliseColor.greenMint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bank account linked")
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Text("You're set to get paid in Naira.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TaliseRadius.lg, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if linked {
            primaryButton(title: "Continue") { onContinue() }
        } else {
            VStack(spacing: 12) {
                primaryButton(title: "Add bank account") { showAdd = true }
                Button(action: { onContinue() }) {
                    Text("Skip for now")
                        .font(TaliseFont.body(15, weight: .regular))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(Color(hex: 0x0A140C))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TaliseColor.greenMint)
                )
        }
        .buttonStyle(.plain)
    }
}
