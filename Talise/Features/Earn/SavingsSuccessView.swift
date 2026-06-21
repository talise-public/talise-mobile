import SwiftUI

/// Full-screen success confirmation shown after a successful NAVI supply
/// (invest). Calm, premium treatment: black field with the shared green
/// glow at the top (`SuccessGlowBackground`), a single accent checkmark
/// that settles in, a white headline, one quiet mono sub-line, and the
/// white "Back to Invest" pill.
///
/// `amountText` is pre-formatted in the user's display currency by the
/// caller (EarnView via `TaliseFormat.local2`), so a ₦ user sees
/// "₦12,000.00" and a $ user sees "$2.12".
struct SavingsSuccessView: View {
    /// Pre-formatted, currency-aware amount, e.g. "$2.12".
    let amountText: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            SuccessGlowBackground()

            VStack(spacing: 0) {
                Spacer()

                // The piggy IS the hero — the SavingsPiggy art drops in
                // with the scrapbook wobble (tilted opposite to the send
                // screen's coin stack so the two screens feel hand-placed).
                // Replaces the old checkmark-on-a-disc per the founder's
                // "have the piggy come up on successful save".
                Image("SavingsPiggy")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 240)
                    .scrapbookEntry(delay: 0.05, tilt: -6)

                Spacer().frame(height: 30)

                Text("You're now earning")
                    .font(TaliseFont.display(40, weight: .regular))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .scrapbookFadeUp(delay: 0.22)

                Text("\(amountText) is now earning on your idle balance.")
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
