import SwiftUI

/// Three-tier KYC picker. Free is selected by default and finishes the
/// onboarding flow immediately on confirm. Verified and Pro both open
/// a placeholder alert ("coming soon") — the Sumsub wiring is Plan 11.
///
/// Local-only persistence for now: `UserDefaults["talise.kyc_tier"]` is
/// set to `free` once the user confirms. Plan 11 replaces this with the
/// `users.kyc_tier` column on the backend.
struct KycTierPicker: View {
    let onFreeChosen: () -> Void

    @State private var selected: Tier = .free
    @State private var pendingTier: Tier?
    @State private var showingComingSoon = false

    enum Tier: String, Hashable {
        case free, verified, pro
    }

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "Verification")
                        Text("Choose your limits")
                            .font(TaliseFont.heading(28, weight: .medium))
                            .kerning(-0.8)
                            .foregroundStyle(TaliseColor.fg)
                        Text("Start free in seconds. Upgrade any time to send more.")
                            .font(TaliseFont.body(14, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 12) {
                        tierCard(
                            tier: .free,
                            title: "Free",
                            limit: "$100/day",
                            requirements: "Phone only · No upload required"
                        )
                        tierCard(
                            tier: .verified,
                            title: "Verified",
                            limit: "$5,000/day",
                            requirements: "Government ID + selfie · 5-min review"
                        )
                        tierCard(
                            tier: .pro,
                            title: "Pro",
                            limit: "$50,000/day",
                            requirements: "Verified + proof of address · 24-hr review"
                        )
                    }

                    LiquidGlassButton(
                        title: continueTitle,
                        size: .lg,
                        action: handleContinue
                    )
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
        }
        .alert(
            "Verification coming soon",
            isPresented: $showingComingSoon
        ) {
            Button("OK", role: .cancel) { pendingTier = nil }
        } message: {
            Text("We'll notify you when the \(pendingTier?.rawValue.capitalized ?? "upgrade") flow is live. For now, you'll be set up on Free — you can upgrade later from Profile.")
        }
    }

    private var continueTitle: String {
        switch selected {
        case .free: return "Continue with Free"
        case .verified, .pro: return "Continue"
        }
    }

    private func handleContinue() {
        switch selected {
        case .free:
            onFreeChosen()
        case .verified, .pro:
            pendingTier = selected
            showingComingSoon = true
        }
    }

    @ViewBuilder
    private func tierCard(
        tier: Tier,
        title: String,
        limit: String,
        requirements: String
    ) -> some View {
        let isSelected = selected == tier
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selected = tier
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(TaliseFont.heading(17, weight: .medium))
                            .foregroundStyle(TaliseColor.fg)
                        Text(limit)
                            .font(TaliseFont.body(13, weight: .light))
                            .foregroundStyle(TaliseColor.accent)
                    }
                    Text(requirements)
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? TaliseColor.fg : TaliseColor.fgDim,
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(TaliseColor.fg)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .taliseGlass(cornerRadius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? TaliseColor.fg.opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
