import SwiftUI

/// Small capsule CTA — "Copy", "Suiscan", "Migrate", "View all", etc.
/// Sits inline with text or in row trailing positions.
///
/// Layering, outer → inner:
///   material > dark tint > optional accent wash > specular stroke > shadow
///
/// Uses a Capsule (not RoundedRect) so it scales gracefully with the
/// label's intrinsic width. Compact by default — height 28 — to nest
/// inside cards without dominating them.
struct LiquidGlassPill: View {
    let title: String
    var icon: String? = nil
    var tint: Color? = nil
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                }
                Text(title)
                    .font(TaliseFont.body(compact ? 11 : 12, weight: .medium))
                    .kerning(-0.1)
            }
            .foregroundStyle(TaliseColor.fg)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 30)
            .background(
                ZStack {
                    // Flat dark surface capsule — no material, no blur.
                    Capsule().fill(TaliseColor.surface2)
                    if let tint {
                        Capsule().fill(tint.opacity(0.18))
                    }
                }
            )
            .overlay(Capsule().strokeBorder(TaliseColor.line, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(LiquidGlassPillPressStyle())
    }
}

/// Capsule-specific press style — same idea as `LiquidGlassPressStyle` but
/// shape-correct so the tap pulse hugs the pill edge.
private struct LiquidGlassPillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        TaliseColor.bg.ignoresSafeArea()
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                LiquidGlassPill(title: "Copy", icon: "doc.on.doc") {}
                LiquidGlassPill(title: "Suiscan", icon: "arrow.up.right.square") {}
                LiquidGlassPill(title: "Migrate", tint: TaliseColor.warmGold) {}
            }
            HStack(spacing: 10) {
                LiquidGlassPill(title: "View all", compact: true) {}
                LiquidGlassPill(title: "Live", icon: "circle.fill", tint: TaliseColor.live, compact: true) {}
            }
        }
        .padding()
    }
}
