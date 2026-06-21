import SwiftUI

/// Tap-only 3×4 numpad used by `SendAmountView`. Lives in its own file
/// so we can reuse it later (request flow, top-up sheet) and to keep
/// the amount view focused on layout rather than key handling.
///
/// Behavior contract:
///   - Digits append to the input string.
///   - `.` is a no-op when the input already contains a decimal mark.
///   - Backspace removes one trailing character; on an empty string it
///     does nothing (so frantic tapping doesn't crash a parent that
///     wants to compute on the value).
///   - Hard cap on the integer portion (default 9 digits, plenty for
///     ₦999,999,999 and enough headroom for everything Talise supports).
///   - Hard cap on fractional digits (default 2) so amounts always
///     fit USDsui's two-decimal display.
struct SendNumpad: View {
    @Binding var input: String

    var maxIntegerDigits: Int = 9
    var maxFractionDigits: Int = 2

    /// Optional haptic on every key press. Off by default so previews
    /// don't try to access UIKit; SendAmountView toggles it on.
    var haptics: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            row(["1", "2", "3"])
            row(["4", "5", "6"])
            row(["7", "8", "9"])
            row([".", "0", "<"])   // "<" is the backspace key
        }
    }

    private func row(_ keys: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(keys, id: \.self) { k in
                keyButton(k)
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ k: String) -> some View {
        Button {
            tap(k)
        } label: {
            keyLabel(k)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(NumpadKeyStyle())
    }

    @ViewBuilder
    private func keyLabel(_ k: String) -> some View {
        if k == "<" {
            Image(systemName: "delete.left")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(TaliseColor.fg)
        } else {
            Text(k)
                .font(TaliseFont.heading(28, weight: .regular))
                .foregroundStyle(TaliseColor.fg)
        }
    }

    private func tap(_ key: String) {
        switch key {
        case "<":
            backspace()
        case ".":
            insertDecimal()
        default:
            insertDigit(key)
        }
        fireHaptic()
    }

    private func backspace() {
        guard !input.isEmpty else { return }
        input.removeLast()
    }

    private func insertDecimal() {
        // No-op if there's already a decimal point.
        if input.contains(".") { return }
        // Bare "." reads as "0." — easier than allowing leading dots.
        if input.isEmpty {
            input = "0."
        } else {
            input += "."
        }
    }

    private func insertDigit(_ d: String) {
        // Strip a leading zero unless we're typing a decimal ("0.…").
        if input == "0" {
            input = d
            return
        }
        if let dotIdx = input.firstIndex(of: ".") {
            let fractionLen = input.distance(from: dotIdx, to: input.endIndex) - 1
            if fractionLen >= maxFractionDigits { return }
        } else {
            if input.count >= maxIntegerDigits { return }
        }
        input += d
    }

    private func fireHaptic() {
        #if canImport(UIKit)
        guard haptics else { return }
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        #endif
    }
}

/// Slight press-darken + scale so a 60pt-tall hit target still feels
/// tactile. We deliberately don't draw a filled-in chip background —
/// the spec calls for naked digits sitting on the page.
private struct NumpadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(TaliseColor.surface2)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .frame(width: 64, height: 64)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
