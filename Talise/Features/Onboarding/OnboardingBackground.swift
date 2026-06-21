import SwiftUI

/// Reusable backdrop for the onboarding multi-step flow (sign-in →
/// handle pick → PIN setup → permissions). Matches `WelcomeView`'s
/// palette and direction: a mossy-green wash at the TOP of the screen
/// fading DOWN into pure black at the bottom, plus a soft pastel-green
/// bloom anchored top-right to add the frosted-glass dimensionality
/// from the reference screenshots.
///
/// Apply via `.background(OnboardingBackground())` on a ZStack-rooted
/// screen, or place it as the first child in a ZStack with
/// `.ignoresSafeArea()`.
struct OnboardingBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let W = proxy.size.width
            let H = proxy.size.height

            ZStack {
                // Black base — bottom half stays near-pure-black.
                TaliseColor.bg
                    .ignoresSafeArea()

                // Vertical wash: mossy green at top fading to black.
                // Same hex stops + direction as WelcomeView so every
                // onboarding step reads as a continuous surface.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x6BA85A),    location: 0.0),
                        .init(color: Color(hex: 0x355626),    location: 0.28),
                        .init(color: Color.black,             location: 0.68),
                        .init(color: Color.black,             location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Soft pastel-green bloom anchored top-right — the
                // "frosted glass surface" highlight. Sized so it reads
                // as a diffuse glow rather than a hard disc.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0x9BD68A).opacity(0.55),
                                Color(hex: 0x6BA85A).opacity(0.18),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: min(W, H) * 0.55
                        )
                    )
                    .frame(width: min(W, H) * 1.4, height: min(W, H) * 1.4)
                    .offset(x: W * 0.35, y: -H * 0.45)
                    .blendMode(.screen)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
    }
}
