import SwiftUI

/// Clean, full-page country/currency picker for the ramps. Available
/// corridors render as tappable rows with rounded flags; the not-yet-live tail
/// collapses into a single quiet row of overlapped country circles so the
/// page reads as "here's where you can move money, and here's what's next."
struct CorridorPickerView: View {
    let direction: RampDirection
    /// The signed-in user's ISO country — gates which corridors are bookable
    /// (a Nigerian sees Nigeria cash-out; others → coming soon).
    var userCountry: String?
    let onSelect: (RampCorridor) -> Void

    private var groups: (available: [RampCorridor], soon: [RampCorridor]) {
        RampCorridors.forDirection(direction, userCountry: userCountry)
    }

    private var title: String {
        direction == .onramp ? "Add money" : "Cash out"
    }
    private var subtitle: String {
        direction == .onramp
            ? "Choose where you're funding from."
            : "Choose where your money should land."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TaliseFont.heading(26, weight: .medium))
                    .kerning(-0.6)
                    .foregroundStyle(TaliseColor.fg)
                Text(subtitle)
                    .font(TaliseFont.body(14, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if groups.available.isEmpty {
                        // Nothing bookable in this direction yet — say so plainly
                        // instead of an empty "Available now" header.
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(TaliseColor.fgMuted)
                            Text("Bank \(direction == .onramp ? "funding" : "cash-out") is rolling out — coming soon.")
                                .font(TaliseFont.body(13.5, weight: .light))
                                .foregroundStyle(TaliseColor.fgMuted)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(TaliseColor.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(TaliseColor.line, lineWidth: 1)
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "Available now").padding(.leading, 4)
                            ForEach(groups.available) { c in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    onSelect(c)
                                } label: {
                                    CorridorRow(corridor: c)
                                }
                                .buttonStyle(TilePress())
                            }
                        }
                    }

                    if !groups.soon.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "More countries soon").padding(.leading, 4)
                            HStack(spacing: 14) {
                                OverlappedFlags(codes: groups.soon.map(\.code), size: 34)
                                Text("We're expanding fast — more rails are on the way.")
                                    .font(TaliseFont.body(12.5, weight: .light))
                                    .foregroundStyle(TaliseColor.fgMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(TaliseColor.surface.opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(TaliseColor.line, lineWidth: 1)
                            )
                        }
                    }

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .background(TaliseColor.bg.ignoresSafeArea())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TaliseColor.fgDim)
            Text(
                direction == .onramp
                    ? "Funds land as USDsui — pegged 1:1 to USD on Sui."
                    : "Paid out from your USDsui — 1:1 to USD on Sui."
            )
            .font(TaliseFont.mono(10, weight: .light))
            .kerning(0.2)
            .foregroundStyle(TaliseColor.fgDim)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }
}

// MARK: - Navigation containers
//
// Thin coordinators that pair the picker with its detail screen via a
// `navigationDestination`. They assume an enclosing NavigationStack (the
// Deposit / Withdraw flows provide one), so pushing here slides in cleanly.

/// Add-money: pick a corridor → Bridge on-ramp (deposit instructions / KYC).
///
/// Cash-out is NOT here: it routes per-country to different rails (Nigeria →
/// Linq, US/Europe → Bridge), and the Linq view is private to the Withdraw
/// flow, so that unified picker lives in WithdrawFlowView (`UnifiedCashOutFlow`).
struct AddMoneyCorridorFlow: View {
    @Environment(AppSession.self) private var session
    @State private var selected: RampCorridor?
    var body: some View {
        CorridorPickerView(direction: .onramp, userCountry: session.currentUser?.country) {
            selected = $0
        }
        .navigationDestination(item: $selected) { BridgeOnrampView(corridor: $0) }
    }
}
