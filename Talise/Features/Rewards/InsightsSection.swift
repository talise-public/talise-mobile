import SwiftUI

/// Phase 3 — Month Insights.
///
/// Text-only month-to-date summary derived from the user's activity
/// feed on the server: total spent / received / saved + a top-3
/// counterparties strip.
///
/// Owns its own data lifecycle — pull-to-refresh on the parent Rewards
/// view does NOT call into here; we reload via `.task` so the parent's
/// `load()` stays unaware of this section (matches the file-disjoint
/// rule for Phase 3 work).
struct InsightsSection: View {
    @State private var insights: MonthInsights?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("This month") {
                if let count = insights?.sampleSize, count > 0 {
                    Text("\(count)")
                        .font(TaliseFont.mono(10, weight: .regular))
                        .foregroundStyle(TaliseColor.fgDim)
                }
            }
            metricsRow
            counterpartiesStrip
            if let error, !error.isEmpty {
                Text(error)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .padding(.horizontal, 4)
            }
        }
        .task { await load() }
    }

    // MARK: - Tiles

    private var metricsRow: some View {
        HStack(spacing: 12) {
            StatTile(
                eyebrow: "Spent",
                value: TaliseFormat.local2(insights?.spentUsd ?? 0),
                valueColor: TaliseColor.danger
            )
            StatTile(
                eyebrow: "Received",
                value: TaliseFormat.local2(insights?.receivedUsd ?? 0)
            )
            StatTile(
                eyebrow: "Saved",
                value: TaliseFormat.local2(insights?.savedUsd ?? 0),
                accent: true
            )
        }
        .redacted(reason: loading && insights == nil ? .placeholder : [])
        .opacity(loading && insights == nil ? 0.6 : 1)
    }

    // MARK: - Counterparties strip

    @ViewBuilder
    private var counterpartiesStrip: some View {
        if let list = insights?.topCounterparties, !list.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { idx, cp in
                    counterpartyRow(cp)
                    if idx < list.count - 1 {
                        RowDivider()
                    }
                }
            }
            .padding(.horizontal, 18)
            .earnHeroGlass(cornerRadius: 20)
        } else if loading {
            VStack(spacing: 0) {
                skeletonRow
                RowDivider()
                skeletonRow
            }
            .padding(.horizontal, 18)
            .earnHeroGlass(cornerRadius: 20)
            .redacted(reason: .placeholder)
            .opacity(0.6)
        } else {
            VStack(spacing: 4) {
                Text("No movements yet this month.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
            .earnHeroGlass(cornerRadius: 20)
        }
    }

    private func counterpartyRow(_ cp: InsightsCounterparty) -> some View {
        PremiumListRow(
            icon: "arrow.left.arrow.right",
            kind: .neutral,
            title: "You moved \(TaliseFormat.local2(cp.totalUsd))",
            subtitle: "with \(cp.displayName) · \(cp.count) tx\(cp.count == 1 ? "" : "s")"
        )
    }

    private var skeletonRow: some View {
        HStack(spacing: 14) {
            Circle().fill(TaliseColor.surface2).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(TaliseColor.line).frame(width: 120, height: 10)
                Capsule().fill(TaliseColor.line).frame(width: 70, height: 8)
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 60)
        .padding(.vertical, 4)
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            insights = try await APIClient.shared.get("/api/rewards/insights")
            error = nil
        } catch {
            if !APIError.isCancellation(error) {
                self.error = error.localizedDescription
            }
        }
    }
}
