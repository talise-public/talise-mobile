import SwiftUI

extension View {
    /// The standard ramp card chrome — soft surface, radius-20, hairline ring.
    /// Shared across the Ramps module (on-ramp + cash-out screens).
    func rampCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TaliseColor.line, lineWidth: 1)
            )
    }
}

/// A circular country flag — the SAME vendored circle-flags set the web app
/// uses (`Assets.xcassets/Flags/flag-<cc>`), rendered crisp and round. This is
/// the app's standard "rounded flag" across the ramps. `code` is an ISO alpha-2
/// (or "EU"); a missing asset falls back to a neutral disc so nothing breaks.
struct RoundedFlag: View {
    let code: String
    var size: CGFloat = 40
    /// Dim the chip (used for unavailable / "soon" corridors).
    var dimmed: Bool = false

    var body: some View {
        Image("flag-\(code.lowercased())")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(TaliseColor.line, lineWidth: 1))
            .background(Circle().fill(TaliseColor.surface2)) // fallback disc
            .saturation(dimmed ? 0.2 : 1)
            .opacity(dimmed ? 0.6 : 1)
    }
}

/// A small cluster of overlapped circular flags — the compact "coming soon"
/// treatment so a long tail of not-yet-live corridors reads as one quiet row
/// of country circles rather than a wall of disabled list items. `codes` are
/// ISO alpha-2 codes.
struct OverlappedFlags: View {
    let codes: [String]
    var size: CGFloat = 32
    var max: Int = 6

    var body: some View {
        HStack(spacing: -size * 0.34) {
            ForEach(Array(codes.prefix(max).enumerated()), id: \.offset) { _, cc in
                Image("flag-\(cc.lowercased())")
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(TaliseColor.bg, lineWidth: 2))
                    .saturation(0.25)
                    .opacity(0.7)
            }
            if codes.count > max {
                Text("+\(codes.count - max)")
                    .font(TaliseFont.mono(11, weight: .medium))
                    .foregroundStyle(TaliseColor.fgDim)
                    .frame(width: size, height: size)
                    .background(Circle().fill(TaliseColor.surface2))
                    .overlay(Circle().strokeBorder(TaliseColor.bg, lineWidth: 2))
                    .clipShape(Circle())
                    .padding(.leading, size * 0.34 + 4)
            }
        }
    }
}

/// One selectable corridor row: rounded flag + name + currency/rail subtitle,
/// a trailing chevron, and a clean tappable card. Disabled rows aren't built
/// here — "soon" corridors collapse into `OverlappedFlags` instead.
struct CorridorRow: View {
    let corridor: RampCorridor
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedFlag(code: corridor.code, size: 40)
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Text(corridor.name)
                        .font(TaliseFont.heading(16, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(TaliseColor.fg)
                    Text(corridor.currencyCode)
                        .font(TaliseFont.mono(10, weight: .regular))
                        .kerning(0.6)
                        .foregroundStyle(TaliseColor.fgDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(TaliseColor.surface2))
                }
                Text(corridor.railLabel)
                    .font(TaliseFont.body(12.5, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaliseColor.greenMint)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TaliseColor.fgDim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    selected ? TaliseColor.greenMint.opacity(0.5) : TaliseColor.line,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
