import SwiftUI
import UIKit

/// Phase 4 — Redemption catalogue.
///
/// Renders a grouped list of perks the user can spend `pointsTotal` on.
/// Each row: kind-styled badge, label, one-line description, and a trailing
/// "X pts" pill (tappable when affordable) or dim "X pts" hint when locked.
/// Tap → confirm sheet → `POST /api/rewards/redeem` → success haptic +
/// parent refetch.
///
/// Sits at `// ANCHOR: redeem-section` in `RewardsView.swift`. Owns its
/// own load lifecycle (catalogue fetch is independent of the rewards
/// summary), but bubbles a successful redeem up via `onRedeemed` so the
/// parent can update its tier card / points balance.
struct RedemptionsSection: View {
    /// Current points balance, passed in from the parent so the section
    /// can render affordability before the catalogue endpoint resolves
    /// (the server also returns canAfford on each row — this is just
    /// the optimistic local hint).
    let pointsTotal: Int
    /// Fired after a successful redeem so the parent can `await load()`.
    let onRedeemed: () -> Void

    @State private var items: [RedeemSKU] = []
    @State private var loading = false
    @State private var error: String?
    @State private var confirming: RedeemSKU?
    @State private var redeemingSku: String?
    @State private var lastRedeemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Redeem points") {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(TaliseColor.fgMuted)
                }
            }

            if loading && items.isEmpty {
                skeletonCard
            } else if items.isEmpty && error == nil {
                emptyState
            } else {
                catalogueCard
            }

            if let lastRedeemError {
                Text(lastRedeemError)
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .padding(.horizontal, 4)
            }
        }
        .task { await loadCatalogue() }
        .sheet(item: $confirming) { sku in
            confirmSheet(sku)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Catalogue list

    /// One grouped r20 card of `PremiumListRow`s with inset hairlines —
    /// never a stack of floating per-item cards.
    private var catalogueCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 {
                    RowDivider()
                }
            }
        }
        .padding(.horizontal, 18)
        .earnHeroGlass(cornerRadius: 20)
    }

    private func row(_ item: RedeemSKU) -> some View {
        let affordable = item.canAfford || item.pointsCost <= pointsTotal
        let needed = max(0, item.pointsCost - pointsTotal)
        return PremiumListRow(
            icon: item.icon ?? "gift",
            kind: affordable ? .earn : .locked,
            title: item.label,
            subtitle: item.description
        ) {
            if affordable {
                LiquidGlassPill(
                    title: redeemingSku == item.sku ? "…" : "\(item.pointsCost) pts",
                    tint: TaliseColor.accent,
                    compact: true
                ) {
                    confirming = item
                }
            } else {
                // Non-interactive dim text — not a fake button.
                Text("\(needed) pts")
                    .font(TaliseFont.mono(11, weight: .regular))
                    .foregroundStyle(TaliseColor.fgDim)
            }
        }
        .opacity(affordable ? 1.0 : 0.55)
    }

    // MARK: - Loading skeleton

    /// Two skeleton rows inside the real card shape (A.8).
    private var skeletonCard: some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { index in
                HStack(spacing: 14) {
                    Circle().fill(TaliseColor.surface2).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(TaliseColor.line).frame(width: 80, height: 10)
                        Capsule().fill(TaliseColor.line).frame(width: 50, height: 8)
                    }
                    Spacer()
                }
                .frame(minHeight: 60)
                .padding(.vertical, 4)
                if index < 1 { RowDivider() }
            }
        }
        .redacted(reason: .placeholder)
        .opacity(0.6)
        .padding(.horizontal, 18)
        .earnHeroGlass(cornerRadius: 20)
    }

    // MARK: - Empty / error states

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(error ?? "No perks available right now")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
            Text("Earn points by sending and saving — perks unlock as you go.")
                .font(TaliseFont.mono(10, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .earnHeroGlass(cornerRadius: 20)
    }

    // MARK: - Confirm sheet

    private func confirmSheet(_ sku: RedeemSKU) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CONFIRM REDEMPTION")
                    .font(TaliseFont.mono(10, weight: .regular)).tracking(2.0)
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(sku.label)
                    .font(TaliseFont.heading(22, weight: .medium)).kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                Text(sku.description)
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                PremiumListRow(
                    icon: sku.icon ?? "gift",
                    kind: .earn,
                    title: "Cost"
                ) {
                    Text("\(sku.pointsCost) pts")
                        .font(TaliseFont.body(14, weight: .light)).kerning(-0.56)
                        .foregroundStyle(TaliseColor.accent)
                }
                RowDivider()
                PremiumListRow(
                    icon: "creditcard",
                    kind: .neutral,
                    title: "Balance after"
                ) {
                    Text("\(max(0, pointsTotal - sku.pointsCost)) pts")
                        .font(TaliseFont.body(14, weight: .light)).kerning(-0.56)
                        .foregroundStyle(TaliseColor.fg)
                }
            }
            .padding(.horizontal, 18)
            .earnHeroGlass(cornerRadius: 20)

            Spacer()

            LiquidGlassButton(
                title: redeemingSku == sku.sku ? "Redeeming…" : "Confirm redemption",
                tint: TaliseColor.accent,
                size: .lg,
                loading: redeemingSku == sku.sku
            ) {
                Task { await redeem(sku) }
            }
            .disabled(redeemingSku == sku.sku)

            Button {
                confirming = nil
            } label: {
                Text("Cancel")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .liquidGlassSheet(accent: TaliseColor.accent)
    }

    // MARK: - Network

    private func loadCatalogue() async {
        loading = true
        defer { loading = false }
        do {
            let res: RedemptionsCatalogue = try await APIClient.shared.get(
                "/api/rewards/catalogue"
            )
            items = res.items
            error = nil
        } catch {
            if !APIError.isCancellation(error) {
                self.error = error.localizedDescription
            }
        }
    }

    private func redeem(_ sku: RedeemSKU) async {
        redeemingSku = sku.sku
        lastRedeemError = nil
        defer { redeemingSku = nil }
        do {
            let _: RedemptionResponse = try await APIClient.shared.post(
                "/api/rewards/redeem",
                body: RedeemRequest(sku: sku.sku)
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            confirming = nil
            // Refresh both the local catalogue (canAfford flips on
            // remaining cards) and the parent summary (tier badge +
            // points balance + recent events).
            await loadCatalogue()
            onRedeemed()
        } catch APIError.status(_, let message) {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            lastRedeemError = parseErrorMessage(message) ?? "Couldn't redeem — try again."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            lastRedeemError = error.localizedDescription
        }
    }

    /// Pull the friendly `error` field out of the server's JSON body,
    /// falling back to the raw payload string if it doesn't parse.
    private func parseErrorMessage(_ body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return body }
        return (json["error"] as? String) ?? body
    }
}
