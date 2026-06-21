import SwiftUI

/// First frame the user ever sees. Pure black, Talise wordmark centered.
/// Auto-advances after 1.2s into the Welcome screen. The fade is driven
/// by `OnboardingRoot`'s top-level transition — this view itself just
/// fires the timer and renders the mark.
struct SplashView: View {
    let onAdvance: () -> Void

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()
            Text("Talise")
                .font(TaliseFont.heading(40, weight: .medium))
                .kerning(-1.2)
                .foregroundStyle(TaliseColor.fg)
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onAdvance()
        }
    }
}
