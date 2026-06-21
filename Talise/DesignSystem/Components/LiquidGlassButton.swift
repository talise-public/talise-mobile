import SwiftUI

/// Primary CTA dressed in Liquid Glass instead of a flat fill. Use anywhere
/// we currently lean on a solid accent button — Send, Confirm, Add Money,
/// "Earn", etc. — to keep the Apple HIG glass language consistent.
///
/// Layering, outer → inner:
///   material > dark tint > directional accent wash > specular stroke > shadow
///
/// The `tint` is what gives the button its identity. A `nil` tint reads as
/// neutral glass (good for secondary actions); pass `TaliseColor.accent`
/// for the canonical green CTA, `.danger` for destructive actions, etc.
///
/// Sizes mirror `TaliseButton` so swap-in is mechanical. The press
/// interaction is handled by `LiquidGlassPressStyle` so it pulses the
/// way the rest of the system does.
struct LiquidGlassButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color? = TaliseColor.accent
    var size: TaliseButtonSize = .lg
    var loading: Bool = false
    var fullWidth: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: { if !loading { action() } }) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(labelColor)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: size.fontSize + 1, weight: .medium))
                }
                Text(title)
                    .font(TaliseFont.heading(size.fontSize, weight: .medium))
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size.hPadding)
            .background(
                ZStack {
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    if let tint {
                        // Solid flat fill — the button's identity color. The
                        // bright Talise greens render as the solid forest
                        // CTA; other tints (danger / gold) keep their solid
                        // color. No gradient, no material.
                        shape.fill(tint)
                    } else {
                        // Neutral / secondary — flat dark surface.
                        shape.fill(TaliseColor.surface2)
                    }
                }
            )
            .overlay(
                // One faint hairline only on the neutral/secondary variant so
                // it separates from the canvas; solid-tinted buttons need none.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(TaliseColor.line, lineWidth: tint == nil ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(loading ? 0.85 : 1.0)
        }
        .taliseGlassPressable(cornerRadius: cornerRadius)
        .disabled(loading)
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .sm: return 12
        case .md: return 14
        case .lg: return 16
        }
    }

    /// Dark ink on the bright Talise greens (for contrast + pop); white on
    /// the neutral surface and the darker tints (danger / gold).
    private var labelColor: Color {
        guard let tint else { return TaliseColor.fg }
        let brightGreens = [
            TaliseColor.accent, TaliseColor.greenMint,
            TaliseColor.live, TaliseColor.success,
        ]
        return brightGreens.contains(tint) ? Color(hex: 0x0A140C) : TaliseColor.fg
    }
}

#Preview {
    ZStack {
        TaliseColor.bg.ignoresSafeArea()
        TopGlow().ignoresSafeArea(edges: .top)
        VStack(spacing: 16) {
            LiquidGlassButton(title: "Send money", icon: "arrow.up.right") {}
            LiquidGlassButton(title: "Confirm", tint: nil, size: .md) {}
            LiquidGlassButton(title: "Migrate", icon: "arrow.triangle.2.circlepath", tint: TaliseColor.warmGold, size: .md) {}
            LiquidGlassButton(title: "Delete", tint: TaliseColor.danger, size: .md) {}
            LiquidGlassButton(title: "Loading…", loading: true) {}
        }
        .padding()
    }
}
