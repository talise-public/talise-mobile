import SwiftUI

/// Dark-mode palette. Sourced directly from Figma node 42-1819
/// (Home design). The web product is still light mode — when we add a
/// shared design system across both platforms we'll thread these through
/// `@Environment(\.colorScheme)`; for now iOS is dark by spec.
enum TaliseColor {
    static let bg = Color(hex: 0x000000)                          // page background
    static let surface = Color(hex: 0x161616)                     // flat card surface (activity, sheets, panels)
    static let surface2 = Color(hex: 0x242424)                    // raised flat surface (chips, small action buttons)
    // Glassmorphism is retired. These two were translucent-white blurs
    // (`.white.opacity(0.08/0.14)`); they're now SOLID flat surfaces so every
    // card / nav pill that referenced them reads as a clean opaque panel.
    static let surfaceGlass = Color(hex: 0x1C1C1C)                // flat card / nav pill
    static let surfaceGlassStrong = Color(hex: 0x2C2C2C)          // active nav pill (raised)
    static let usernameCard = Color(hex: 0x161616)                // flat username card
    static let fg = Color(hex: 0xFFFFFF)                          // primary text
    static let fgSubtle = Color(hex: 0xFAFAFA)                    // jude@talise text
    static let fgMuted = Color(hex: 0xB5B5B5)
    static let fgDim = Color(hex: 0x636363)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(hex: 0x79D96C)                      // "Earn up to 11%" green
    static let accentSoft = Color(hex: 0x2A2A2A)
    // The two canonical Talise brand greens (matches web/app/globals.css).
    // `greenMint` is the bright/mint accent that reads ON dark; `greenDeep`
    // is the forest CTA fill. Additive — existing surfaces keep `accent`.
    static let greenMint = Color(hex: 0xCAFFB8)                   // mint — readable accent on dark
    static let greenDeep = Color(hex: 0x4B8A37)                   // forest — solid CTA fill
    static let live = Color(hex: 0x79D96C)
    static let success = Color(hex: 0x79D96C)
    static let warmGold = Color(hex: 0xC08A3E)
    static let danger = Color(hex: 0xA05A3E)

    // Activity row badge backgrounds (extracted from the Figma Ellipse fills).
    static let badgeSent = Color(hex: 0x6C3A38).opacity(0.5)      // muted red
    static let badgeReceived = Color(hex: 0x355F40).opacity(0.5)  // muted green
    static let badgeNeutral = Color(hex: 0x4A4A4A).opacity(0.6)   // claim/invest
}

enum TaliseSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum TaliseRadius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 25      // Figma uses 25 for big cards (activity + username)
    static let pill: CGFloat = 40    // bottom nav + active pill
}

enum TaliseHeight {
    static let buttonSm: CGFloat = 32
    static let buttonMd: CGFloat = 40
    static let buttonLg: CGFloat = 44
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Flat surface helpers (glassmorphism retired)
//
// Glassmorphism is retired. This enum kept ONLY so the 100+ existing call
// sites (`TaliseGlass.edge`, `.topSheen`, `.wash(...)`, etc.) keep compiling —
// every member now returns a FLAT, calm value: a hairline color, a clear
// (no-op) fill, or a quiet solid tint. No more specular gradients, no white
// sheens, no diagonal washes. The Apple-system flat look.
enum TaliseGlass {
    /// Was a bright specular edge stroke; now a single flat hairline color.
    /// Used as a `strokeBorder` so a `LinearGradient`-shaped API still works
    /// — but it's a uniform `TaliseColor.line` (no top-to-bottom highlight).
    static let edge = LinearGradient(colors: [TaliseColor.line, TaliseColor.line], startPoint: .top, endPoint: .bottom)

    /// Was a quieter specular edge; now the same flat hairline.
    static let edgeSoft = LinearGradient(colors: [TaliseColor.line, TaliseColor.line], startPoint: .top, endPoint: .bottom)

    /// Was an interior white "crown" sheen; now a clear (no-op) fill so any
    /// `.fill(TaliseGlass.topSheen)` paints nothing.
    static let topSheen = LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .bottom)

    /// Was a soft ambient float shadow; now fully transparent so any
    /// `.shadow(color: TaliseGlass.shadow, …)` renders nothing.
    static let shadow = Color.clear

    /// Was a diagonal brand wash; now a quiet FLAT solid tint at a low
    /// opacity — same call signature, but a single uniform color (no
    /// gradient, no fade).
    static func wash(_ color: Color, strength: Double = 0.16) -> LinearGradient {
        let c = color.opacity(min(strength, 0.14))
        return LinearGradient(colors: [c, c], startPoint: .top, endPoint: .bottom)
    }
}

extension TaliseColor {
    /// Was a dimensional CTA gradient; now a FLAT solid forest fill. Kept as
    /// a `LinearGradient` (two identical stops) so `.fill(TaliseColor.greenCTA)`
    /// call sites compile unchanged while rendering a clean solid pill.
    static let greenCTA = LinearGradient(colors: [greenDeep, greenDeep], startPoint: .top, endPoint: .bottom)

    /// Was a mint→deep sweep; now a FLAT solid accent fill (uniform two-stop
    /// gradient) for progress fills — calm, no neon sweep.
    static let greenSweep = LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
}
