import SwiftUI

/// Vertical "options list" row used by the Deposit and Withdraw flows.
/// Visual recipe: round icon badge on the left, title + subtitle in the
/// middle, optional badge after the title, chevron on the right. Same
/// glass-card chrome as the rest of the app.
///
/// Designed for tap-to-navigate (NavigationLink) — pure presentation,
/// no internal action wiring.
struct OptionCardRow: View {
    let icon: String          // SF Symbol name
    let title: String
    let subtitle: String
    var badge: String? = nil  // e.g. "No fee"
    var accent: Color = TaliseColor.accent

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 42, height: 42)
                Circle()
                    .strokeBorder(accent.opacity(0.28), lineWidth: 0.75)
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(TaliseFont.heading(15, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                    if let badge {
                        Text(badge)
                            .font(TaliseFont.mono(9, weight: .light))
                            .kerning(0.4)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(accent.opacity(0.15))
                            )
                    }
                }
                Text(subtitle)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taliseGlass(cornerRadius: 18)
    }
}

// MARK: - GlassSection (flat container — glassmorphism retired)
// Defined here (not a standalone file) so it's part of the compiled target.

/// Flat solid surface plate with an optional quiet brand tint — name kept so
/// existing `.glassSection(...)` call sites compile; it now renders the same
/// clean flat panel as `.taliseGlass()` (solid fill + faint hairline, no
/// material, no specular rim).
struct GlassSection: ViewModifier {
    var cornerRadius: CGFloat = 20
    var tint: Color? = nil
    var tintOpacity: Double = 0.07

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(
                ZStack {
                    shape.fill(TaliseColor.surface)
                    if let tint {
                        shape.fill(tint.opacity(tintOpacity))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(TaliseColor.line, lineWidth: 1)
            )
            .clipShape(shape)
    }
}

extension View {
    /// Apply the flat Talise surface treatment to a container.
    func glassSection(
        cornerRadius: CGFloat = 20,
        tint: Color? = nil,
        tintOpacity: Double = 0.07
    ) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity))
    }
}
