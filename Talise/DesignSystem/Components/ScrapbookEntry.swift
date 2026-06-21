import SwiftUI

/// "Paper / scrapbook placement" entry animation. The view drops in
/// slightly oversized, rotated, and lifted — then settles into place
/// with a bouncy spring, the way a paper cutout wobbles when you press
/// it onto a scrapbook page. Used for the celebration illustrations
/// (piggy, coin stack) on the success popups.
///
/// `delay` staggers multiple elements (e.g. illustration first, then
/// the headline) so the screen assembles piece by piece.
struct ScrapbookEntry: ViewModifier {
    var delay: Double = 0
    /// Direction of the initial paper tilt, in degrees. Negative tilts
    /// counter-clockwise. Alternating the sign across stacked elements
    /// reads as hand-placed rather than mechanical.
    var tilt: Double = -7
    /// Initial vertical lift — the element starts this far above its
    /// resting spot and drops down.
    var lift: CGFloat = -26

    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : 1.16)
            .rotationEffect(.degrees(settled ? 0 : tilt))
            .offset(y: settled ? 0 : lift)
            .opacity(settled ? 1 : 0)
            .onAppear {
                // Low damping → a visible 1–2 wobble settle, like paper
                // springing flat. response 0.62 keeps it snappy, not
                // floaty.
                withAnimation(.spring(response: 0.62, dampingFraction: 0.56).delay(delay)) {
                    settled = true
                }
            }
    }
}

/// Lighter companion for text / secondary content — fades up with a
/// small rise and a gentler spring (no rotation), so it reads as
/// "settling in" behind the hero illustration without competing.
struct ScrapbookFadeUp: ViewModifier {
    var delay: Double = 0
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .offset(y: settled ? 0 : 14)
            .opacity(settled ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay)) {
                    settled = true
                }
            }
    }
}

extension View {
    /// Paper-placement entry — see `ScrapbookEntry`.
    func scrapbookEntry(delay: Double = 0, tilt: Double = -7, lift: CGFloat = -26) -> some View {
        modifier(ScrapbookEntry(delay: delay, tilt: tilt, lift: lift))
    }

    /// Gentle fade-up entry for text — see `ScrapbookFadeUp`.
    func scrapbookFadeUp(delay: Double = 0) -> some View {
        modifier(ScrapbookFadeUp(delay: delay))
    }
}

/// Backdrop for the dark-theme success popups. Flat clean canvas — the glow
/// blob was removed to match the flat, Apple-system look (no radial wash/blur).
struct SuccessGlowBackground: View {
    var body: some View {
        TaliseColor.bg.ignoresSafeArea()
    }
}
