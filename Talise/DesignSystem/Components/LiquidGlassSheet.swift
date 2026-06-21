import SwiftUI

/// Modifier that applies a FLAT solid backdrop to `.sheet` presentations.
/// Apply on the sheet's *root* view (not the parent presenting the sheet).
/// Glassmorphism retired — name + `accent` param kept for source
/// compatibility; the sheet is now a clean opaque panel.
///
/// What it does:
/// - Hides the default sheet background (`.presentationBackground(.clear)`)
///   so we can paint our own solid surface.
/// - Paints the page with the flat `TaliseColor.surface` fill — no material,
///   no blur, no bloom.
/// - Adds one faint `TaliseColor.line` hairline at the sheet's top edge.
/// - `accent` is ignored (retained only so existing call sites compile).
struct LiquidGlassSheet: ViewModifier {
    var accent: Color? = TaliseColor.accent

    func body(content: Content) -> some View {
        // `accent` is retained in the signature for source compatibility but
        // no longer paints a bloom — the sheet is a flat solid surface.
        _ = accent
        return content
            .background(
                // Solid flat sheet surface — no material, no blur, no bloom.
                TaliseColor.surface.ignoresSafeArea()
            )
            .overlay(alignment: .top) {
                // One faint flat hairline at the sheet's top edge.
                TaliseColor.line
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
            .presentationBackground(.clear)
    }
}

extension View {
    /// Apply the Liquid Glass treatment to a sheet's root view. Pass
    /// `accent: nil` to skip the top color wash for neutral sheets.
    func liquidGlassSheet(accent: Color? = TaliseColor.accent) -> some View {
        modifier(LiquidGlassSheet(accent: accent))
    }
}
