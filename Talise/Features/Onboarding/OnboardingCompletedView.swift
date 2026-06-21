import SwiftUI

/// Brief celebration frame shown after the KYC-tier picker resolves.
/// Animates the same checkmark treatment as `SendView.successView` (the
/// pattern is duplicated here so the Onboarding feature stays self-
/// contained — extracting it into a shared primitive is a refactor for
/// later). After ~1.4s, hands off to AppSession via `onDismiss` which
/// routes to either KYCView (country/account-type) or MainTabView.
struct OnboardingCompletedView: View {
    let onDismiss: () -> Void
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0
    @State private var checkOpacity: Double = 0

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(TaliseColor.accent.opacity(0.15))
                        .frame(width: 96, height: 96)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(TaliseColor.accent)
                        .opacity(checkOpacity)
                }

                Text("You're all set")
                    .font(TaliseFont.heading(28, weight: .medium))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                    .padding(.top, 10)

                Text("Your wallet is ready. Taking you in…")
                    .font(TaliseFont.body(14, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center)

                Spacer()
            }
        }
        .task {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                ringScale = 1.0
                ringOpacity = 1.0
            }
            withAnimation(.easeIn(duration: 0.25).delay(0.15)) {
                checkOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            onDismiss()
        }
    }
}
