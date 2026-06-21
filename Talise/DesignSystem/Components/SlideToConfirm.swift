import SwiftUI
import UIKit

/// A "slide to confirm" track — drag the leading knob to the end to fire
/// `onConfirm`. Cash App / Revolut style. Replaces the PIN confirm on the
/// Send flow: the slide is an *intent* gesture, not authentication.
///
/// Layout: a full-width capsule (~58pt tall). The `title` sits centered and
/// fades as the knob advances. A `tint` fill trails the knob so progress
/// reads visually. Released past `confirmThreshold` snaps to the end, fires a
/// success haptic, enters `confirming` (spinner on the knob) and awaits
/// `onConfirm`. Released short → springs back to start.
///
/// Reset-on-failure: `onConfirm` is non-throwing, so the control can't know
/// whether the work succeeded. The caller controls reset via the optional
/// `reset` binding — flip it to `true` and the control springs back to start
/// and clears `confirming`, then sets it back to `false`. In the Send flow we
/// don't need it: a failure navigates away to `SendFailureView`, tearing this
/// view down (state resets naturally). The binding exists for callers that
/// keep the control mounted across a failed attempt.
struct SlideToConfirm: View {
    var title: String = "Slide to send"
    var tint: Color = TaliseColor.accent
    /// Set by the parent to force the knob back to start (e.g. after a
    /// failed `onConfirm` when the control stays mounted). The control flips
    /// it back to `false` once it has reset.
    var reset: Binding<Bool>? = nil
    var onConfirm: () async -> Void

    // Geometry
    private let trackHeight: CGFloat = 58
    private let knobInset: CGFloat = 4
    private var knobSize: CGFloat { trackHeight - knobInset * 2 }
    private let confirmThreshold: CGFloat = 0.8

    @State private var dragX: CGFloat = 0        // current knob travel, in points
    @State private var confirming = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let maxTravel = max(trackWidth - knobSize - knobInset * 2, 1)
            let progress = min(max(dragX / maxTravel, 0), 1)

            ZStack(alignment: .leading) {
                // Base track — flat dark surface capsule with a faint hairline.
                Capsule()
                    .fill(TaliseColor.surface2)
                    .overlay(Capsule().strokeBorder(TaliseColor.line, lineWidth: 1))

                // Trailing fill that follows the knob — a quiet flat brand
                // tint so progress reads as it advances. No gradient.
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(width: dragX + knobSize + knobInset * 2)

                // Title, fading out as the knob advances.
                Text(title)
                    .font(TaliseFont.heading(16, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(maxWidth: .infinity)
                    .opacity(Double(1 - progress * 1.6))

                // Knob
                knob
                    .frame(width: knobSize, height: knobSize)
                    .padding(.leading, knobInset)
                    .offset(x: dragX)
                    .gesture(dragGesture(maxTravel: maxTravel))
            }
            .frame(height: trackHeight)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dragX)
            .animation(.easeInOut(duration: 0.2), value: confirming)
        }
        .frame(height: trackHeight)
        // VoiceOver / non-drag fallback — a pure drag is inaccessible.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to confirm")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard !confirming else { return }
            fire()
        }
        .onChange(of: reset?.wrappedValue ?? false) { _, shouldReset in
            if shouldReset {
                springBack()
                confirming = false
                reset?.wrappedValue = false
            }
        }
    }

    private var knob: some View {
        ZStack {
            Circle().fill(tint)
            if confirming {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(TaliseColor.bg)
            } else {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TaliseColor.bg)
            }
        }
    }

    private func dragGesture(maxTravel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !confirming else { return }
                dragX = min(max(value.translation.width, 0), maxTravel)
            }
            .onEnded { _ in
                guard !confirming else { return }
                let progress = dragX / maxTravel
                if progress >= confirmThreshold {
                    dragX = maxTravel       // snap to end
                    fire()
                } else {
                    springBack()
                }
            }
    }

    /// Snap to end, haptic, enter confirming, run the async work.
    private func fire() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        confirming = true
        Task {
            await onConfirm()
            // If the caller didn't tear us down or trip `reset`, leave the
            // knob at the end; the Send flow always navigates away on both
            // success and failure, so this view unmounts either way.
        }
    }

    private func springBack() {
        dragX = 0
    }
}

#Preview {
    ZStack {
        TaliseColor.bg.ignoresSafeArea()
        VStack(spacing: 24) {
            SlideToConfirm(title: "Slide to send") {
                try? await Task.sleep(for: .seconds(2))
            }
            SlideToConfirm(title: "Slide to invest", tint: TaliseColor.warmGold) {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .padding(24)
    }
}
