import SwiftUI

/// Mossy-green top wash matching the onboarding gradient verbatim
/// (`WelcomeView` + `OnboardingBackground`). One palette across the
/// whole app: bright forest green at the top, fading to pure black
/// before the content area. Linear (not radial) so the brightness
/// reads evenly across the screen width instead of pooling under the
/// notch. Stops match `OnboardingBackground` exactly so a user coming
/// out of onboarding into the first authenticated tab sees the wash
/// continue without a perceptible jump.
struct TopGlow: View {
    var body: some View {
        // Light-green top glow → black, matching the onboarding palette
        // (`WelcomeView` / `OnboardingBackground`) so the authenticated
        // tabs read as a continuation of the same surface. A subtle
        // mossy-green wash fills the top band then falls into pure black
        // well before the content area, keeping cards + text legible.
        // The 380pt height clips the wash to the top of the screen.
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x6BA85A).opacity(0.55), location: 0.0),
                .init(color: Color(hex: 0x355626).opacity(0.40), location: 0.30),
                .init(color: Color.black, location: 0.78),
                .init(color: Color.black, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 380)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// Convenience modifier — add a TopGlow behind any tab's content.
struct TaliseScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            TaliseColor.bg.ignoresSafeArea()
            TopGlow()
                .ignoresSafeArea(edges: .top)
            content
        }
    }
}

extension View {
    /// Standard authenticated-screen background: black + a subtle blue
    /// top glow. Apply at the root of each tab view.
    func taliseScreenBackground() -> some View {
        modifier(TaliseScreenBackground())
    }
}

/// Reusable FLAT card treatment — glassmorphism retired. (Name kept so the
/// 75 `.taliseGlass()` call sites don't churn; it no longer uses any blur.)
///
/// Layering, outer → inner:
///   solid surface > optional flat directional tint > hairline edge
///
/// - Solid `TaliseColor.surface` fill — a clean opaque panel on the black
///   page, not an ambient frosted plate.
/// - Optional `tint` adds a quiet flat green wash (Sent / Received / Earn)
///   over the surface — no gradient, no material.
/// - One faint `TaliseColor.line` hairline defines the edge. No specular
///   gradient, no drop shadow — the Apple-system flat look.
///
/// `interactive: true` opts the card into a press-down brighten — used
/// when the card itself is a button.
///
/// Usage:
///   `.taliseGlass()`                            // 25pt default radius
///   `.taliseGlass(cornerRadius: 14)`            // smaller card
///   `.taliseGlass(tint: TaliseColor.accent)`    // directional
///   `.taliseGlass(interactive: true)`           // pressable
struct TaliseGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(cornerRadius: CGFloat = 25, tint: Color? = nil, interactive: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(
                ZStack {
                    // 1. Solid flat surface — a clean opaque panel on the
                    //    black page. No material, no blur.
                    shape.fill(TaliseColor.surface)
                    // 2. Optional quiet flat brand tint (Sent / Received /
                    //    Earn) — a single low-opacity solid color, no gradient.
                    if let tint {
                        shape.fill(tint.opacity(0.10))
                    }
                }
            )
            .overlay(
                // 3. One faint hairline edge — flat, no specular highlight.
                shape.strokeBorder(TaliseColor.line, lineWidth: 1)
            )
            .clipShape(shape)
            .opacity(isEnabled ? 1.0 : 0.6)
    }
}

extension View {
    /// Apply the Talise Liquid Glass treatment to any container.
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the rounded rect. Defaults to 25
    ///     (matches the large activity / username cards).
    ///   - tint: Optional directional color overlay (Sent red, Received
    ///     green, Earn green). When nil the card is neutral glass.
    ///   - interactive: When true the card slightly brightens on press;
    ///     attach inside a Button label or use the `.taliseGlassPressable()`
    ///     style on a Button.
    func taliseGlass(
        cornerRadius: CGFloat = 25,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(TaliseGlassCard(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

/// Press-down brighten for any glass card used as a button. Applies a
/// momentary white wash + scale to mimic the liquid-glass "tap pulse".
struct LiquidGlassPressStyle: ButtonStyle {
    var cornerRadius: CGFloat = 25

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0.0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Convenience for wrapping a Button label so it animates on press
    /// with the Liquid Glass pulse — pair with `.taliseGlass()`.
    func taliseGlassPressable(cornerRadius: CGFloat = 25) -> some View {
        buttonStyle(LiquidGlassPressStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Shared premium components (Invest + Rewards kit)
//
// One small kit, consumed by both the Invest (`EarnView`) and Rewards
// (`RewardsView`) screens so they read as a single product. Flat — no
// glassmorphism, no shadow, no blur. Built strictly on the verified
// `TaliseColor` / `TaliseFont` tokens and the flat `.taliseGlass()`
// card treatment defined above.
//
//   B.1 SectionHeader      — canonical eyebrow + optional trailing slot
//   B.2 ViewAllLink        — the trailing "View all ›" affordance
//   B.3 HeroAmount         — the ONE big figure per screen
//   B.4 PremiumListRow     — the universal grouped-list row
//   B.5 RowDivider         — inset hairline between rows
//   B.6 StatTile           — side-by-side metric tile
//   B.7 QuietProgressBar   — honest progress fill (no fake floor)

// MARK: B.1 SectionHeader

/// The canonical section eyebrow. Uppercased mono-10 / tracking-2 / fgMuted
/// label on the leading edge, with an optional trailing slot (a `ViewAllLink`
/// or a quiet count). Default trailing slot renders nothing.
///
/// Usage:
///   `SectionHeader("Where your money earns")`
///   `SectionHeader("This month") { Text("4").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim) }`
struct SectionHeader<Trailing: View>: View {
    let title: String
    var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(TaliseFont.mono(10, weight: .regular)).tracking(2.0)
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }
}

// MARK: B.2 ViewAllLink

/// The trailing affordance for a `SectionHeader` — a quiet "View all ›"
/// text button. Never a filled button cluster.
///
/// Usage:
///   `SectionHeader("Recent") { ViewAllLink { showAll = true } }`
struct ViewAllLink: View {
    var title: String = "View all"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(TaliseFont.body(12, weight: .light))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(TaliseColor.fgMuted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: B.3 HeroAmount

/// The single hero figure on a screen — lives at the top of its tinted
/// hero card. A mono-caps eyebrow, the one big display-40 number (with an
/// optional leading symbol and trailing unit, both dim mono), and one
/// quiet sub-line. Honors `loading` by redacting the figure row.
///
/// Usage:
///   `HeroAmount(eyebrow: "PROJECTED THIS YEAR", value: "1,240.00",
///               symbol: "$", caption: "Earning 8.4% on your savings",
///               captionAccent: true, loading: loading)`
struct HeroAmount: View {
    let eyebrow: String              // mono caps eyebrow above
    let value: String                // pre-formatted, NO symbol
    var unit: String? = nil          // trailing "pts" / currency code (mono, dim)
    var symbol: String? = nil        // leading "$" (mono, dim)
    var caption: String? = nil       // one quiet sub-line below
    var captionAccent: Bool = false  // caption in accent (e.g. APY nudge)
    var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(TaliseFont.mono(10, weight: .regular)).tracking(2.0)
                .foregroundStyle(TaliseColor.fgMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let symbol {
                    Text(symbol).font(TaliseFont.mono(15)).foregroundStyle(TaliseColor.fgDim)
                }
                Text(value)
                    .font(TaliseFont.display(42, weight: .semibold)).kerning(-1.6)
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(TaliseFont.mono(15)).foregroundStyle(TaliseColor.fgDim)
                }
            }
            .redacted(reason: loading ? .placeholder : [])
            if let caption {
                Text(caption).font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(captionAccent ? TaliseColor.accent : TaliseColor.fgMuted)
            }
        }
    }
}

// MARK: B.4 PremiumListRow

/// Badge kinds for `PremiumListRow`. Each maps to a fixed disc + glyph
/// color per the design-system badge rules.
enum TaliseBadgeKind {
    case earn      // disc accent@0.18  / glyph accent
    case moneyIn   // disc mint@0.42    / glyph #2E5E1F
    case moneyOut  // disc deep@0.18    / glyph accent
    case neutral   // disc surface2     / glyph fg
    case locked    // disc surface2     / glyph fgDim
}

/// The universal list row. A 36×36 kind-styled badge, a title + optional
/// mono subtitle, then a trailing slot and an optional chevron. Drop
/// several of these into ONE `.taliseGlass(cornerRadius: 20)` card with a
/// `RowDivider` between them — never a stack of floating per-row cards.
///
/// Usage:
///   `PremiumListRow(icon: "leaf.fill", kind: .earn, title: "Aave",
///                   subtitle: "Supplied $200.00", showsChevron: true) {
///        Text("8.4%").font(TaliseFont.heading(22, weight: .medium))
///            .kerning(-0.8).foregroundStyle(TaliseColor.accent)
///    }`
struct PremiumListRow<Trailing: View>: View {
    let icon: String
    var kind: TaliseBadgeKind = .earn
    let title: String
    var subtitle: String? = nil
    var trailing: Trailing
    var showsChevron: Bool = false

    init(
        icon: String,
        kind: TaliseBadgeKind = .earn,
        title: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.trailing = trailing()
    }

    private var discColor: Color {
        switch kind {
        case .earn:     return TaliseColor.accent.opacity(0.18)
        case .moneyIn:  return Color(hex: 0xCAFFB8).opacity(0.42)
        case .moneyOut: return Color(hex: 0x4B8A37).opacity(0.18)
        case .neutral:  return TaliseColor.surface2
        case .locked:   return TaliseColor.surface2
        }
    }

    private var glyphColor: Color {
        switch kind {
        case .earn:     return TaliseColor.accent
        case .moneyIn:  return Color(hex: 0x2E5E1F)
        case .moneyOut: return TaliseColor.accent
        case .neutral:  return TaliseColor.fg
        case .locked:   return TaliseColor.fgDim
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(discColor).frame(width: 36, height: 36)
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(glyphColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TaliseFont.body(14, weight: .light)).kerning(-0.48)
                    .foregroundStyle(TaliseColor.fg)
                if let subtitle {
                    Text(subtitle).font(TaliseFont.mono(11)).kerning(-0.32)
                        .foregroundStyle(TaliseColor.fgDim)
                }
            }
            Spacer(minLength: 8)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fgDim)
            }
        }
        .frame(minHeight: 60)
        .padding(.vertical, 4)
    }
}

// MARK: B.5 RowDivider

/// The inset hairline drawn between `PremiumListRow`s inside a grouped
/// card. Default 62pt leading inset aligns it under the row text, clear
/// of the 36×36 badge. Never draw after the last row.
///
/// Usage:
///   `RowDivider()`
struct RowDivider: View {
    var inset: CGFloat = 62

    var body: some View {
        Rectangle().fill(TaliseColor.line)
            .frame(height: 0.75).padding(.leading, inset)
    }
}

// MARK: B.6 StatTile

/// A side-by-side metric tile — a mono-caps eyebrow over one heading-22
/// figure, on its own r20 flat card. Lay two or three across in an
/// `HStack(spacing: 12)`. `accent` greens the value (use on one tile max);
/// `valueColor` overrides outright (e.g. `.danger` for "Spent").
///
/// Usage:
///   `StatTile(eyebrow: "Lifetime saved", value: "$1,204.00", accent: true)`
struct StatTile: View {
    let eyebrow: String
    let value: String              // pre-formatted
    var accent: Bool = false       // value in accent (use sparingly — one tile max)
    var valueColor: Color? = nil   // override (e.g. danger for "Spent")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(TaliseFont.mono(10, weight: .regular)).tracking(2.0)
                .foregroundStyle(TaliseColor.fgMuted)
            Text(value)
                .font(TaliseFont.heading(22, weight: .medium)).kerning(-0.8)
                .foregroundStyle(valueColor ?? (accent ? TaliseColor.accent : TaliseColor.fg))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .taliseGlass(cornerRadius: 20)
    }
}

// MARK: B.7 QuietProgressBar

/// An honest progress fill — `progress` is clamped to 0...1 with NO fake
/// minimum, so an empty bar reads empty. 6pt tall, accent fill over a
/// faint white track.
///
/// Usage:
///   `QuietProgressBar(progress: 0.42)`
struct QuietProgressBar: View {
    let progress: Double           // 0...1, clamped, NO minimum

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule().fill(TaliseColor.greenSweep)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
