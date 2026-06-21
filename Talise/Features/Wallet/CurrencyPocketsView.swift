import SwiftUI
import UIKit

/// Currency pockets (master plan §8) — a lightweight, additive view that
/// lets a user see their balance expressed across the currencies Talise
/// supports, and preview an in-app FX quote before they ever commit to a
/// conversion.
///
/// IMPORTANT — this is presentation only. Talise settles in USDsui (1:1
/// USD) on chain; "pockets" are a UX surface over the single underlying
/// balance, not separate on-chain ledgers. We deliberately do NOT touch
/// the core balance display on Home: this is reachable from Profile as a
/// non-invasive entry. When real per-currency liquidity lands, the quote
/// block here is the seam the transfers machine plugs into.
///
/// Layout, top → bottom:
///   1. Hero — total balance in the user's current display currency.
///   2. Pockets list — the same balance shown in each currency the user
///      has "added", each row a glass card with symbol + localized amount.
///   3. "Add a currency" — opens a sheet that extends the display-currency
///      picker; picking a currency appends it as a pocket.
///   4. Tapping a pocket opens the FX quote sheet (amount in / out / locked
///      rate / spread-as-fee / countdown + SlideToConfirm).
struct CurrencyPocketsView: View {
    /// Fetched on appear so the hero + pocket rows render real money.
    /// Soft-fails to 0 — the screen still reads correctly, just empty.
    @State private var usdBalance: Double = 0
    @State private var loading = true

    /// Currency codes the user has pinned as pockets. Persisted so the
    /// set survives across launches. Always includes the current display
    /// currency so the hero currency always has a matching pocket.
    @State private var pocketCodes: [String] = CurrencyPocketStore.load()
    @State private var showAddSheet = false
    /// The pocket the user tapped to preview a conversion. Drives the
    /// FX quote sheet.
    @State private var quoteTarget: TaliseCurrency?

    private var settings: CurrencySettings { CurrencySettings.shared }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                hero
                pocketsSection
                disclaimer
                Color.clear.frame(height: 60)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("Currencies")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAddSheet) {
            AddCurrencySheet(existing: pocketCodes) { code in
                addPocket(code)
            }
            .liquidGlassSheet()
        }
        .sheet(item: $quoteTarget) { target in
            FXQuoteSheet(usdBalance: usdBalance, target: target)
                .liquidGlassSheet()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            HeroNumber(
                value: TaliseFormat.local2(usdBalance),
                eyebrow: "Total balance",
                sub: "Across all your currencies"
            )
            .redacted(reason: loading ? .placeholder : [])
        }
        .padding(.top, 8)
    }

    // MARK: - Pockets

    private var pocketsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Your pockets")
                Spacer()
                LiquidGlassPill(title: "Add a currency", icon: "plus", compact: true) {
                    showAddSheet = true
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(pocketCurrencies.enumerated()), id: \.element.id) { idx, c in
                    if idx > 0 { LiquidGlassDivider(inset: 18) }
                    pocketRow(c)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// One pocket — the underlying USDsui balance rendered in currency `c`,
    /// with a chevron to open the FX quote sheet.
    private func pocketRow(_ c: TaliseCurrency) -> some View {
        Button {
            quoteTarget = c
        } label: {
            HStack(spacing: 14) {
                currencyDisc(c)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name)
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                    Text(c.code)
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(localized(usdBalance, in: c))
                        .font(TaliseFont.heading(15, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .redacted(reason: loading ? .placeholder : [])
                    if c.code == settings.current.code {
                        MicroLabel(text: "DISPLAY", color: TaliseColor.accent)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Circular flag icon for the currency — the shared RoundedFlag used
    /// across the app (vendored circle-flags in Assets/Flags).
    private func currencyDisc(_ c: TaliseCurrency) -> some View {
        RoundedFlag(code: c.flagCode, size: 38)
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
            Text("Pockets show your one balance in each currency. Your wallet settles in USDsui (1:1 USD) — rates update live.")
                .font(TaliseFont.mono(10, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Data

    /// Resolved currencies for the pinned codes, in pinned order. The
    /// current display currency is forced to the front so the hero
    /// currency always leads the list even if the user never pinned it.
    private var pocketCurrencies: [TaliseCurrency] {
        var codes = pocketCodes
        let display = settings.current.code
        if !codes.contains(display) { codes.insert(display, at: 0) }
        else {
            codes.removeAll { $0 == display }
            codes.insert(display, at: 0)
        }
        return codes.map(TaliseCurrency.find)
    }

    /// USD → currency `c`, formatted with its symbol. Falls back to the
    /// USD figure when the rate hasn't loaded (rate defaults to 1).
    private func localized(_ usd: Double, in c: TaliseCurrency) -> String {
        let rate = settings.rates[c.code] ?? 1
        return TaliseFormat.symbolic(usd * rate, currency: c, fixed: 2)
    }

    private func addPocket(_ code: String) {
        guard !pocketCodes.contains(code) else { return }
        pocketCodes.append(code)
        CurrencyPocketStore.save(pocketCodes)
    }

    private func load() async {
        do {
            let b: BalancesDTO = try await APIClient.shared.get("/api/balances")
            usdBalance = b.usdsui
        } catch {
            // Soft-fail — keep whatever we had (0 on first load).
        }
        loading = false
        // Opportunistically refresh FX if the cache is stale so the
        // pocket rows don't quietly show day-old rates.
        if settings.isStale() { await settings.refresh() }
    }
}

// MARK: - Pocket persistence

/// Tiny UserDefaults-backed store for the user's pinned pocket codes.
/// Kept separate from CurrencySettings so this additive feature owns its
/// own state and never mutates the display-currency preference.
enum CurrencyPocketStore {
    private static let key = "io.talise.app.currencyPockets"

    static func load() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        // Validate against supported set so a removed currency can't
        // wedge the list.
        let supported = Set(TaliseCurrency.allSupported.map(\.code))
        let valid = stored.filter { supported.contains($0) }
        return valid.isEmpty ? defaultPockets() : valid
    }

    static func save(_ codes: [String]) {
        UserDefaults.standard.set(codes, forKey: key)
    }

    /// First-run default: the user's display currency plus USD, so the
    /// list is never empty and always shows the canonical settlement
    /// currency next to the local one.
    ///
    /// Reads the display-currency code straight from the same
    /// UserDefaults key `CurrencySettings` persists to, rather than
    /// touching its MainActor-isolated `current` property — this keeps
    /// the store fully nonisolated so it can be called from a `@State`
    /// default-value initializer.
    private static func defaultPockets() -> [String] {
        let display = UserDefaults.standard
            .string(forKey: "io.talise.app.displayCurrency") ?? "USD"
        return display == "USD" ? ["USD"] : [display, "USD"]
    }
}

// MARK: - Add a currency sheet

/// Extends the display-currency picker into a pocket picker. Lists every
/// supported currency that isn't already pinned; tapping one appends it
/// as a pocket and dismisses.
private struct AddCurrencySheet: View {
    let existing: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var available: [TaliseCurrency] {
        TaliseCurrency.allSupported.filter { !existing.contains($0.code) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if available.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(available.enumerated()), id: \.element.id) { idx, c in
                            if idx > 0 { LiquidGlassDivider(inset: 18) }
                            row(c)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(TaliseColor.surface)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .navigationTitle("Add a currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(TaliseColor.accent)
                }
            }
        }
    }

    private func row(_ c: TaliseCurrency) -> some View {
        Button {
            onPick(c.code)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                RoundedFlag(code: c.flagCode, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name)
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fg)
                    Text(c.code)
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(TaliseColor.accent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(TaliseColor.accent)
            Text("You've added every currency.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - FX quote sheet

/// In-app FX quote block (master plan §8): amount in, amount out, a locked
/// rate, the ~25bps spread shown as an explicit fee, and a countdown after
/// which the quote re-locks. This is a *preview* — converting between
/// pockets is a no-op today (one underlying USDsui balance), so the
/// SlideToConfirm simply acknowledges the quote and dismisses. The shape
/// is deliberately the seam the corridor-agnostic transfers machine will
/// plug into when real per-currency conversion ships.
private struct FXQuoteSheet: View {
    let usdBalance: Double
    let target: TaliseCurrency
    @Environment(\.dismiss) private var dismiss

    /// Spread Talise applies, in basis points — mirrors the Paga off-ramp
    /// (~25bps). Surfaced to the user as a fee so the rate stays honest.
    private let spreadBps: Double = 25

    /// Quote lifetime before it re-locks, in seconds. The countdown drives
    /// the user to confirm while the rate is fresh.
    private let quoteTTL: Int = 30

    /// Amount the user wants to convert FROM, denominated in their current
    /// display currency. Defaults to the full balance.
    @State private var amountIn: Double = 0
    @State private var secondsLeft: Int = 30
    @State private var lockedRate: Double = 1
    /// Re-issued each tick; SwiftUI cancels the old task on view identity
    /// change. We drive the countdown with a simple async loop.
    @State private var acknowledged = false

    private var settings: CurrencySettings { CurrencySettings.shared }
    private var fromCurrency: TaliseCurrency { settings.current }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                quoteCard
                slide
                Color.clear.frame(height: 20)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .presentationDetents([.large])
        .onAppear { lockQuote() }
        .task { await runCountdown() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Convert to \(target.code)")
            Text("\(fromCurrency.name) → \(target.name)")
                .font(TaliseFont.heading(20, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The quote block. amount in / amount out / locked rate / fee / TTL.
    private var quoteCard: some View {
        VStack(spacing: 0) {
            amountRow(
                label: "You convert",
                value: TaliseFormat.symbolic(amountIn, currency: fromCurrency, fixed: 2),
                emphasis: false
            )
            LiquidGlassDivider(inset: 18)
            amountRow(
                label: "You get",
                value: TaliseFormat.symbolic(amountOut, currency: target, fixed: 2),
                emphasis: true
            )
            LiquidGlassDivider(inset: 18)
            detailRow(label: "Locked rate", value: rateLine)
            LiquidGlassDivider(inset: 18)
            detailRow(
                label: "Talise fee",
                value: "\(TaliseFormat.symbolic(feeInTarget, currency: target, fixed: 2)) · \(String(format: "%.2f", spreadBps / 100))%"
            )
            LiquidGlassDivider(inset: 18)
            countdownRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func amountRow(label: String, value: String, emphasis: Bool) -> some View {
        HStack {
            Text(label)
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value)
                .font(TaliseFont.heading(emphasis ? 22 : 17, weight: .medium))
                .foregroundStyle(emphasis ? TaliseColor.accent : TaliseColor.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value)
                .font(TaliseFont.mono(12, weight: .light))
                .foregroundStyle(TaliseColor.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var countdownRow: some View {
        HStack {
            Text("Rate refreshes in")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(secondsLeft <= 5 ? TaliseColor.warmGold : TaliseColor.accent)
                    .frame(width: 6, height: 6)
                Text("\(secondsLeft)s")
                    .font(TaliseFont.mono(12, weight: .regular))
                    .foregroundStyle(secondsLeft <= 5 ? TaliseColor.warmGold : TaliseColor.fg)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var slide: some View {
        if acknowledged {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TaliseColor.accent)
                Text("Quote saved")
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        } else {
            SlideToConfirm(title: "Slide to lock this quote") {
                acknowledged = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(nanoseconds: 600_000_000)
                await MainActor.run { dismiss() }
            }
        }
    }

    // MARK: - Quote math
    //
    // settings.rates[code] is USD → code. A cross rate from the display
    // currency to the target is rates[target] / rates[from]. The spread is
    // taken off the gross converted amount and surfaced as the fee.

    /// Gross target amount before the spread.
    private var grossOut: Double {
        let fromRate = settings.rates[fromCurrency.code] ?? 1
        let toRate = settings.rates[target.code] ?? 1
        guard fromRate > 0 else { return 0 }
        let cross = toRate / fromRate
        return amountIn * cross
    }

    /// Net target amount the user receives after the spread.
    private var amountOut: Double {
        grossOut * (1 - spreadBps / 10_000)
    }

    /// The spread expressed as an amount in the target currency.
    private var feeInTarget: Double {
        grossOut * (spreadBps / 10_000)
    }

    /// "1 USD = ₦1,540.00" style line built from the locked cross rate.
    private var rateLine: String {
        let fromRate = settings.rates[fromCurrency.code] ?? 1
        let toRate = settings.rates[target.code] ?? 1
        guard fromRate > 0 else { return "—" }
        let cross = toRate / fromRate
        let one = TaliseFormat.symbolic(1, currency: fromCurrency, fixed: fromCurrency.code == "USD" ? 0 : 2)
        let other = TaliseFormat.symbolic(cross, currency: target, fixed: cross >= 100 ? 2 : 4)
        return "\(one) = \(other)"
    }

    /// Lock the displayed cross rate + default the amount to the full
    /// balance, expressed in the display currency.
    private func lockQuote() {
        let fromRate = settings.rates[fromCurrency.code] ?? 1
        amountIn = usdBalance * fromRate
        let toRate = settings.rates[target.code] ?? 1
        lockedRate = fromRate > 0 ? toRate / fromRate : 1
        secondsLeft = quoteTTL
    }

    /// Simple 1Hz countdown; re-locks (resets) when it hits zero so the
    /// user never confirms against a stale rate. Stops once acknowledged.
    private func runCountdown() async {
        while !acknowledged {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if acknowledged { break }
            await MainActor.run {
                if secondsLeft > 0 {
                    secondsLeft -= 1
                } else {
                    lockQuote()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CurrencyPocketsView()
    }
    .environment(AppSession())
}
