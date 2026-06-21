import SwiftUI

/// Hero onboarding screen — first thing a fresh install sees after the
/// splash. A mossy-green wash fills the top ~38% of the viewport then
/// falls hard into black; the Talise pinwheel mark sits centered just
/// below the gradient transition; bottom-left "Move money without
/// borders" headline + supporting subtitle frames the two CTAs
/// (primary "Get Started", secondary "I have an account") above a
/// small Terms acknowledgement footer.
///
/// `onContinue` → start the brand-intro carousel (new user path).
/// `onSignIn`   → jump straight to the sign-in sheet (returning user).
///
/// All text uses DM Sans (variable, registered at app launch) with
/// -0.2pt letter spacing per the design spec — matches the Figma reference at
/// `https://www.figma.com/design/w4mQGGahEu1CzR9cK0cnsx/Untitled?node-id=110-2331`.
struct WelcomeView: View {
    let onContinue: () -> Void
    let onSignIn: () -> Void

    /// Letter spacing per the Figma typography spec. Figma values
    /// letter-spacing in pixels at the source font size; transposed
    /// here as `-fontSize × 0.03` because the headline spec resolves
    /// to exactly that ratio (`23.5 × -0.03 = -0.705`). Body / CTA
    /// text uses the same 3% to keep the rhythm consistent.
    private func kern(_ size: CGFloat) -> CGFloat { -size * 0.03 }

    var body: some View {
        GeometryReader { proxy in
            let H = proxy.size.height

            ZStack(alignment: .top) {
                // Black base — the gradient stops above the safe-area
                // bottom so the buttons sit on pure black anyway.
                TaliseColor.bg.ignoresSafeArea()

                // Top green wash. Linear (not radial) because the
                // Figma reference shows even-across-width brightness
                // at the top, fading vertically — radial introduces
                // unwanted side-darkening. Stops:
                //   0%   : mossy green at full saturation
                //   55%  : transition midpoint
                //   80%  : pure black
                // The whole gradient is sized to ~42% of the screen
                // height so the logo lands just below it.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x6BA85A), location: 0.0),
                        .init(color: Color(hex: 0x355626), location: 0.45),
                        .init(color: Color.black, location: 0.85),
                        .init(color: Color.black, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: H * 0.42)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    // Logo positioned just below the gradient's end —
                    // ~y=50% of screen height (vertically centered on
                    // the dark half's upper third). Calculated relative
                    // to the screen so different device heights keep
                    // the same visual rhythm.
                    Spacer().frame(height: H * 0.42)

                    logoMark
                        .frame(width: 88, height: 88)

                    Spacer(minLength: 0)

                    copyBlock
                        .padding(.horizontal, 20)
                        .padding(.bottom, 22)

                    primaryCTA
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    secondaryCTA
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)

                    termsFooter
                        .padding(.horizontal, 32)
                        .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // ── Subviews ────────────────────────────────────────────────────

    @ViewBuilder
    private var logoMark: some View {
        if UIImage(named: "TaliseLogo") != nil {
            Image("TaliseLogo")
                .resizable()
                .scaledToFit()
        } else {
            Pinwheel()
        }
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline — Figma spec: DM Sans 23.5px / 600 / -0.705 ls.
            Text("Move money without borders")
                .font(TaliseFont.heading(23.5, weight: .semibold))
                .kerning(kern(23.5))
                .foregroundStyle(TaliseColor.fg)
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(
                "Moving money across the world is complex, Talise brings simplicity to this. No network fees, smart money movement."
            )
            .font(TaliseFont.body(13, weight: .light))
            .kerning(kern(13))
            .foregroundStyle(TaliseColor.fgMuted)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryCTA: some View {
        Button(action: onContinue) {
            Text("Get Started")
                .font(TaliseFont.body(15, weight: .medium))
                .kerning(kern(15))
                .foregroundStyle(TaliseColor.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(TaliseColor.fg)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var secondaryCTA: some View {
        // Glassmorphic capsule — uses the project's `taliseGlass`
        // (ultra-thin material + dark tint + specular stroke) so the
        // pill picks up subtle white edge highlights and reads as a
        // soft-blur surface against the black page. Press pulse via
        // `taliseGlassPressable` matches the liquid-glass behavior
        // used elsewhere in the app.
        Button(action: onSignIn) {
            Text("I have an account")
                .font(TaliseFont.body(15, weight: .medium))
                .kerning(kern(15))
                .foregroundStyle(TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .taliseGlass(cornerRadius: 27)
        }
        .taliseGlassPressable(cornerRadius: 27)
    }

    private var termsFooter: some View {
        (Text("You accept ")
            + Text("Terms and Conditions").underline()
            + Text(" by continuing."))
            .font(TaliseFont.body(11, weight: .light))
            .kerning(kern(11))
            .foregroundStyle(TaliseColor.fgDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Hand-drawn approximation of the white pinwheel brand mark — same
/// geometry as `HomeView`'s `TaliseLogoMark`, duplicated here so the
/// Onboarding feature stays self-contained.
private struct Pinwheel: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r: CGFloat = size.width * 0.22
            for i in 0..<4 {
                let angle = CGFloat(i) * .pi / 2
                var transform = CGAffineTransform(translationX: cx, y: cy)
                transform = transform.rotated(by: angle)
                transform = transform.translatedBy(x: 0, y: -size.height * 0.28)
                let rect = CGRect(
                    x: -r * 0.45, y: -r * 0.55,
                    width: r * 0.9, height: r * 1.15
                ).applying(transform)
                let path = Path(ellipseIn: rect)
                ctx.fill(path, with: .color(.white))
            }
        }
    }
}
