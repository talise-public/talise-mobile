import SwiftUI

/// Step 4: in-flight. We're already past `Confirm`; the sponsor-execute
/// fires from `SendFlowView` and writes back to the draft when it lands.
/// This screen is purely a visual hold while that happens.
///
/// The "Done" button is intentionally live even before completion —
/// the chain submission continues server-side either way, and the
/// notification fires on success so HomeView can still pick it up.
struct SendInProgressView: View {
    @Bindable var draft: SendDraft
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                AnimatedPaperPlane(size: 140)
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    Text("Sending…")
                        .font(TaliseFont.heading(28, weight: .medium))
                        .kerning(-0.5)
                        .foregroundStyle(TaliseColor.fg)
                    Text("Should take a moment. You can close this now — we'll keep going.")
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                ShimmerBars()

                if let err = draft.errorMessage {
                    Text(err)
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            doneButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done")
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .glassCapsule()
        }
    }
}
