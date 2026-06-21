import SwiftUI

/// Full-screen success confirmation shown after adding to a savings goal.
/// Mirrors `SavingsSuccessView` (the invest success) so the two flows feel
/// identical: shared green glow, a hero that drops in with the scrapbook
/// wobble, a display headline, one quiet mono sub-line, and the white
/// "Back to Invest" pill that returns the user to the Invest screen.
///
/// The hero is a target/crosshair — the goal motif — in the brand green.
/// `amountText` is pre-formatted in the user's display currency by the caller.
struct GoalSuccessView: View {
    enum Kind { case deposit, withdraw }
    /// Which flow this confirms — drives the headline + sub-line copy. Both
    /// share the same target hero + motion so the two feel identical.
    var kind: Kind = .deposit
    /// Pre-formatted, currency-aware amount, e.g. "₦1,000.00".
    let amountText: String
    /// The goal's name, for the sub-line.
    let goalName: String
    let onDismiss: () -> Void

    private var headline: String {
        kind == .deposit ? "Getting closer to your target" : "Back in your balance"
    }
    private var subline: String {
        kind == .deposit
            ? "\(amountText) added to \(goalName)."
            : "\(amountText) withdrawn from \(goalName)."
    }

    var body: some View {
        ZStack {
            SuccessGlowBackground()

            VStack(spacing: 0) {
                Spacer()

                // Target hero — the hand-drawn crosshair illustration, dropping
                // in with the same scrapbook wobble as the savings piggy.
                Image("GoalTarget")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .scrapbookEntry(delay: 0.05, tilt: -6)

                Spacer().frame(height: 30)

                Text(headline)
                    .font(TaliseFont.display(38, weight: .regular))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .scrapbookFadeUp(delay: 0.22)

                Text(subline)
                    .font(TaliseFont.mono(13, weight: .regular))
                    .kerning(-0.26)
                    .foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 310)
                    .padding(.top, 14)
                    .scrapbookFadeUp(delay: 0.30)

                Spacer()

                Button(action: onDismiss) {
                    Text("Back to Invest")
                        .font(TaliseFont.body(15, weight: .medium))
                        .kerning(-0.3)
                        .foregroundStyle(.black)
                        .frame(width: 175, height: 41)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
                .scrapbookFadeUp(delay: 0.38)
            }
        }
        .preferredColorScheme(.dark)
    }
}
