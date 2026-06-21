import SwiftUI

/// Segmented progress bar shown at the top of every multi-step
/// onboarding screen after Welcome. Four (or `totalSteps`) thin pills
/// separated by 6pt gaps; the first `currentStep` pills fill with
/// `TaliseColor.fg`, the rest read as light-grey hairlines at
/// `Color.white.opacity(0.18)`.
///
/// Sits with 24pt horizontal padding and 12pt below the safe area top —
/// matches the inspiration reference's segmented indicator that's
/// pinned just under the status bar.
struct OnboardingProgressBar: View {
    let totalSteps: Int      // typically 4
    let currentStep: Int     // 1-indexed; pills [0..<currentStep) fill

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { idx in
                Capsule()
                    .fill(idx < currentStep
                          ? TaliseColor.fg
                          : Color.white.opacity(0.18))
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}
