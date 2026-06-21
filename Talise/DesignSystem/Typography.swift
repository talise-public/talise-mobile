import SwiftUI

/// Typography = Apple's system font (SF Pro), used directly for the clean,
/// native iOS feel. SF Pro for display/heading/body; SF Mono for the micro
/// labels (timestamps, "$0.00 FEE"-style eyebrows). Big balances lean on the
/// bold weights + tight tracking the call sites pass; everything else stays
/// regular/medium. No bundled/custom fonts — the system font IS the brand here.
enum TaliseFont {
    /// SF Pro — the primary display/heading face.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// SF Mono — for small tracked labels / numerals where a monospace reads.
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// JetBrains-Mono micro-label, uppercase tracking 0.22em — for "$0.00 FEE",
/// "YOUR MONEY LANDS HERE", and timestamps in activity rows.
struct MicroLabel: View {
    let text: String
    var color: Color = TaliseColor.fg
    var size: CGFloat = 8

    var body: some View {
        Text(text)
            .font(TaliseFont.mono(size, weight: .regular))
            .kerning(-0.32)
            .foregroundStyle(color)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(TaliseFont.mono(10, weight: .regular))
            .tracking(2.0)
            .foregroundStyle(TaliseColor.fgDim)
    }
}
