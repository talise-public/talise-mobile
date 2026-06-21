import SwiftUI

/// Three-slide swipeable carousel showing the headline value props.
/// Each slide hosts a placeholder illustration (the Higgsfield exports
/// drop in later via the `OnboardingHero_<n>` asset entries) plus the
/// punchy one-liner. The "Continue" button advances through slides and
/// finally calls `onContinue` once past the third.
struct BrandIntroCarousel: View {
    @Binding var selection: OnboardingStep
    let onContinue: () -> Void

    private let slides: [Slide] = [
        Slide(
            step: .intro1,
            asset: "OnboardingHero_1",
            headline: "Sub-second sends — sign with Face ID, never see a seed phrase."
        ),
        Slide(
            step: .intro2,
            asset: "OnboardingHero_2",
            headline: "A payment that does more — pay, save, and earn in one tap."
        ),
        Slide(
            step: .intro3,
            asset: "OnboardingHero_3",
            headline: "Cash in, cash out — Stripe in, mobile money out, all in one app."
        ),
    ]

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(slides, id: \.step) { slide in
                        slideView(slide)
                            .tag(slide.step)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                // Dot indicators — driven by the bound selection so the
                // active dot tracks both swipes and the Continue button.
                HStack(spacing: 8) {
                    ForEach(slides, id: \.step) { slide in
                        Circle()
                            .fill(slide.step == selection
                                  ? TaliseColor.fg
                                  : TaliseColor.fgDim)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 24)

                LiquidGlassButton(
                    title: "Continue",
                    size: .lg,
                    action: handleContinue
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    private func handleContinue() {
        // Advance through the slides, then hand off to the sign-in step.
        if let idx = slides.firstIndex(where: { $0.step == selection }) {
            if idx < slides.count - 1 {
                withAnimation(.easeInOut(duration: 0.28)) {
                    selection = slides[idx + 1].step
                }
            } else {
                onContinue()
            }
        } else {
            onContinue()
        }
    }

    @ViewBuilder
    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 32) {
            Spacer(minLength: 32)
            illustration(slide.asset)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .padding(.horizontal, 32)

            Text(slide.headline)
                .font(TaliseFont.heading(24, weight: .medium))
                .kerning(-0.6)
                .foregroundStyle(TaliseColor.fg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func illustration(_ asset: String) -> some View {
        // Once Higgsfield emits the real PNG, the asset catalog entry
        // gains an image and we render it here. Until then, fall back
        // to a glass placeholder card with a small caption so the layout
        // is stable across the missing-asset → asset-present transition.
        if UIImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TaliseColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(TaliseColor.line, lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(TaliseColor.fgDim)
                        MicroLabel(
                            text: "ILLUSTRATION COMING",
                            color: TaliseColor.fgDim,
                            size: 9
                        )
                    }
                )
        }
    }

    private struct Slide {
        let step: OnboardingStep
        let asset: String
        let headline: String
    }
}
