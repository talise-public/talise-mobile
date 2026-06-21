import SwiftUI

/// Hairline divider — `Color.white.opacity(0.08)`, 1 device pixel tall.
/// Replaces every `Color.gray.opacity(0.2)` / `Divider()` use in the app
/// so dividers participate in the Liquid Glass language instead of
/// reading as flat gray bars on dark glass.
///
/// Visual recipe: a single semi-translucent white line. Because the
/// glass surfaces beneath it are dark, a small white opacity reads as
/// a clean separator without competing with the specular strokes on
/// surrounding cards.
struct LiquidGlassDivider: View {
    var color: Color = TaliseColor.line   // already Color.white.opacity(0.08)
    var inset: CGFloat = 0

    var body: some View {
        // A flat hairline — one solid color, full width. No specular fade.
        color
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.horizontal, inset)
    }
}

#Preview {
    ZStack {
        TaliseColor.bg.ignoresSafeArea()
        VStack(spacing: 16) {
            Text("Row one").foregroundStyle(TaliseColor.fg)
            LiquidGlassDivider()
            Text("Row two").foregroundStyle(TaliseColor.fg)
            LiquidGlassDivider(inset: 24)
            Text("Row three").foregroundStyle(TaliseColor.fg)
        }
        .padding()
        .taliseGlass(cornerRadius: 25)
        .padding()
    }
}
