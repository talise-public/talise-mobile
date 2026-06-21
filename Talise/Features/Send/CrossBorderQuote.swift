import Foundation

/// Cross-border send support (master plan §8).
///
/// Everything in this file is ADDITIVE and dormant for single-currency
/// sends: when the recipient's display currency matches the sender's
/// (the only case the product serves end-to-end today), `SendDraft`
/// reports `isCrossCurrency == false` and the Amount / Review screens
/// render exactly as before. The cross-currency branches only light up
/// when a recipient carries a *different* home currency.
///
/// Talise still settles in USDsui (1:1 USD) on chain — USDsui is the
/// unseen middle leg. The sender types in *their* currency, the chain
/// moves digital dollars, and the recipient is quoted in *their*
/// currency. This file owns the math that turns one FX snapshot into a
/// transparent, locked quote (rate + explicit spread fee + guaranteed
/// receive amount) so the views stay declarative.

// MARK: - Quote model

/// A locked cross-border quote, computed once when the Review screen
/// appears and held for `holdSeconds`. Every field is presentation-ready
/// so `SendReviewView` doesn't redo FX math inside the view body.
///
/// Money model, all USDsui-denominated internally (1:1 USD):
///   senderUsdsui    — what leaves the sender's wallet *before* spread.
///   spreadUsdsui    — the explicit fee (a slice of senderUsdsui).
///   netUsdsui       — senderUsdsui − spreadUsdsui, the value delivered.
/// The recipient's quoted amount is `netUsdsui` converted at the locked
/// recipient rate. Total debit shown to the sender is `senderUsdsui`
/// rendered in the sender's currency (the spread is *inside* the debit,
/// surfaced as an explicit line so nothing is hidden).
struct CrossBorderQuote: Equatable {
    /// Sender side.
    let senderCurrency: TaliseCurrency
    /// Recipient side.
    let recipientCurrency: TaliseCurrency

    /// USDsui units the sender is moving (the amount they typed,
    /// converted to USD). The on-chain settlement value.
    let senderUsdsui: Double
    /// Explicit spread fee, in USDsui. `~25bps` mirrors the live Paga
    /// off-ramp spread referenced in the master plan; surfaced as a
    /// fee line, never folded silently into the rate.
    let spreadUsdsui: Double

    /// FX rate from sender currency → recipient currency, locked at
    /// quote time. Display only — the math runs through USDsui so we
    /// never compound rounding across two separate rate lookups.
    let lockedRate: Double

    /// Wall-clock instant the quote was locked. Drives the countdown.
    let lockedAt: Date
    /// How long the quote is honoured. 30s per the master plan.
    let holdSeconds: TimeInterval

    /// Spread basis points used to build this quote (for the fee label).
    let spreadBps: Int

    // Derived ------------------------------------------------------------

    /// Net USDsui delivered to the recipient (after spread).
    var netUsdsui: Double { max(0, senderUsdsui - spreadUsdsui) }

    /// Total debit from the sender, in their own currency units.
    var senderDebitLocal: Double { senderUsdsui * senderRate }

    /// Spread fee expressed in the sender's currency.
    var spreadLocal: Double { spreadUsdsui * senderRate }

    /// Guaranteed receive amount, in the recipient's currency units.
    var recipientReceiveLocal: Double { netUsdsui * recipientRate }

    /// Sender-currency rate vs USD (units of sender ccy per 1 USD).
    private let senderRate: Double
    /// Recipient-currency rate vs USD (units of recipient ccy per 1 USD).
    private let recipientRate: Double

    init(
        senderCurrency: TaliseCurrency,
        recipientCurrency: TaliseCurrency,
        senderUsdsui: Double,
        senderRate: Double,
        recipientRate: Double,
        spreadBps: Int = CrossBorderQuote.defaultSpreadBps,
        holdSeconds: TimeInterval = 30,
        lockedAt: Date = Date()
    ) {
        self.senderCurrency = senderCurrency
        self.recipientCurrency = recipientCurrency
        self.senderUsdsui = max(0, senderUsdsui)
        self.senderRate = senderRate > 0 ? senderRate : 1
        self.recipientRate = recipientRate > 0 ? recipientRate : 1
        self.spreadBps = spreadBps
        self.spreadUsdsui = max(0, senderUsdsui) * (Double(spreadBps) / 10_000)
        // Locked sender→recipient rate, derived from the two USD legs so
        // the displayed "1 sender = X recipient" matches the actual
        // conversion the quote performs.
        self.lockedRate = self.senderRate > 0
            ? (self.recipientRate / self.senderRate)
            : self.recipientRate
        self.holdSeconds = holdSeconds
        self.lockedAt = lockedAt
    }

    /// Default cross-border spread — ~25 bps, matching the Paga off-ramp
    /// reference in the master plan. Centralised so a future corridor
    /// table can override per-corridor without touching the views.
    static let defaultSpreadBps = 25

    // MARK: - Countdown

    /// Seconds remaining on the hold, clamped to 0. The Review screen
    /// ticks a timer and reads this; at 0 it re-locks the quote.
    func secondsRemaining(asOf now: Date = Date()) -> Int {
        let elapsed = now.timeIntervalSince(lockedAt)
        return max(0, Int(ceil(holdSeconds - elapsed)))
    }

    /// True once the hold has lapsed and the quote must be re-locked
    /// before the user can commit.
    func isExpired(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(lockedAt) >= holdSeconds
    }

    // MARK: - Display helpers

    /// "1 ₦ = $0.00067" style locked-rate string. Always renders the
    /// rate per *one* sender unit so it reads naturally regardless of
    /// corridor direction.
    var rateLine: String {
        let recip = TaliseFormat.symbolic(lockedRate, currency: recipientCurrency, fixed: rateDecimals(lockedRate))
        return "1 \(senderCurrency.symbol) = \(recip)"
    }

    /// Recipient-currency amounts often need more precision than 2 dp
    /// (¥, ₫, Rp are large-unit; the rate per-unit can be tiny). Pick a
    /// sensible decimal count so the rate never collapses to "0.00".
    private func rateDecimals(_ v: Double) -> Int {
        if v == 0 { return 2 }
        if v >= 100 { return 0 }
        if v >= 1 { return 2 }
        if v >= 0.01 { return 4 }
        return 6
    }
}

// MARK: - Recipient currency inference

extension CrossBorderQuote {
    /// Best-effort inference of a recipient's home display currency from
    /// the data the send flow already holds (the resolved display name /
    /// SuiNS handle). Returns nil when there's no signal — callers then
    /// fall back to the sender's currency, which makes the send
    /// single-currency and leaves the UI unchanged.
    ///
    /// This is intentionally conservative: the authoritative recipient
    /// currency will come from the recipient-profile API once the
    /// compliance/profile layer lands (master plan §5/§8). Until then we
    /// only light up cross-border UX when a handle explicitly carries a
    /// corridor hint (e.g. "kenji.jp", "@maria.ph"), so production sends
    /// between same-currency users are never altered.
    static func inferRecipientCurrency(
        from resolved: RecipientResolution?,
        fallback: TaliseCurrency
    ) -> TaliseCurrency {
        guard let resolved else { return fallback }
        let hint = (resolved.displayName ?? resolved.display ?? "").lowercased()
        guard !hint.isEmpty else { return fallback }

        // Country/locale tokens we recognise inside a handle or display
        // name. Matched as suffixes or dotted segments so "kenji.jp" and
        // "kenji.tokyo.sui" both resolve to JPY without matching a random
        // "jp" inside an unrelated word.
        for (token, code) in corridorTokens {
            if hint.hasSuffix(".\(token)")
                || hint.hasSuffix("@\(token)")
                || hint.contains(".\(token).")
                || hint.contains(".\(token)@") {
                return TaliseCurrency.find(code: code)
            }
        }
        return fallback
    }

    /// Handle/locale token → ISO currency code. Covers the African and
    /// Asian/global corridors named in the directive. Order doesn't
    /// matter (suffix match is exact).
    private static let corridorTokens: [(String, String)] = [
        ("ng", "NGN"), ("ngn", "NGN"),
        ("ke", "KES"), ("kes", "KES"),
        ("gh", "GHS"), ("ghs", "GHS"),
        ("za", "ZAR"), ("zar", "ZAR"),
        ("jp", "JPY"), ("jpy", "JPY"),
        ("sg", "SGD"), ("sgd", "SGD"),
        ("ph", "PHP"), ("php", "PHP"),
        ("id", "IDR"), ("idr", "IDR"),
        ("vn", "VND"), ("vnd", "VND"),
        ("us", "USD"), ("usd", "USD"),
    ]
}

// MARK: - SendDraft cross-currency state

extension SendDraft {
    /// Resolve the recipient's display currency for this draft. Prefers
    /// an explicit `recipientCurrencyCode` override (set by a future
    /// recipient-profile lookup); otherwise infers from the resolved
    /// handle; otherwise falls back to the sender's currency.
    @MainActor
    func resolvedRecipientCurrency() -> TaliseCurrency {
        if let code = recipientCurrencyCode,
           let match = TaliseCurrency.allKnown.first(where: { $0.code == code }) {
            return match
        }
        return CrossBorderQuote.inferRecipientCurrency(
            from: resolved,
            fallback: currency
        )
    }

    /// True when the recipient is paid out in a *different* currency than
    /// the sender's. Gates every cross-border UI branch — false here
    /// means single-currency, and the Amount/Review screens render
    /// identically to before this feature.
    @MainActor
    var isCrossCurrency: Bool {
        resolvedRecipientCurrency().code != currency.code
    }

    /// Build a locked quote for the current `amountUsdsui`. Returns nil
    /// for same-currency sends (no quote needed) or zero amounts.
    @MainActor
    func makeCrossBorderQuote(lockedAt: Date = Date()) -> CrossBorderQuote? {
        guard amountUsdsui > 0 else { return nil }
        let recipient = resolvedRecipientCurrency()
        guard recipient.code != currency.code else { return nil }
        let rates = CurrencySettings.shared.rates
        let senderRate = rates[currency.code] ?? 1
        let recipientRate = rates[recipient.code] ?? 1
        return CrossBorderQuote(
            senderCurrency: currency,
            recipientCurrency: recipient,
            senderUsdsui: amountUsdsui,
            senderRate: senderRate,
            recipientRate: recipientRate,
            lockedAt: lockedAt
        )
    }

    /// Recipient-side amount for the live Amount screen (before the
    /// quote is locked). Mirrors the post-spread receive figure so the
    /// "recipient gets" preview matches the Review screen's guaranteed
    /// amount. Returns nil for same-currency / zero input.
    @MainActor
    func liveRecipientReceiveLocal() -> (amount: Double, currency: TaliseCurrency)? {
        guard let typed = Double(rawAmount), typed > 0 else { return nil }
        let recipient = resolvedRecipientCurrency()
        guard recipient.code != currency.code else { return nil }
        let rates = CurrencySettings.shared.rates
        let senderRate = rates[currency.code] ?? 1
        let recipientRate = rates[recipient.code] ?? 1
        guard senderRate > 0 else { return nil }
        let usd = typed / senderRate
        let spread = usd * (Double(CrossBorderQuote.defaultSpreadBps) / 10_000)
        let net = max(0, usd - spread)
        return (net * recipientRate, recipient)
    }
}

// MARK: - Forward-compatible currency catalogue

extension TaliseCurrency {
    /// The display currencies the picker exposes today (`allSupported`)
    /// PLUS the cross-border corridor currencies named in the directive
    /// (JPY/SGD/PHP/IDR/VND). Kept separate from `allSupported` so the
    /// picker UI is unchanged — these extra entries exist purely so the
    /// cross-border quote can *render* a recipient amount in the right
    /// symbol when a recipient's home currency isn't a sender-selectable
    /// one yet. The picker / `CurrencySettings.allSupported` stays the
    /// authoritative sender-side list.
    static let allKnown: [TaliseCurrency] = {
        let extras: [TaliseCurrency] = [
            .init(code: "JPY", symbol: "¥",   name: "Japanese Yen"),
            .init(code: "SGD", symbol: "S$",  name: "Singapore Dollar"),
            .init(code: "PHP", symbol: "₱",   name: "Philippine Peso"),
            .init(code: "IDR", symbol: "Rp",  name: "Indonesian Rupiah"),
            .init(code: "VND", symbol: "₫",   name: "Vietnamese Dong"),
        ]
        let known = Set(TaliseCurrency.allSupported.map(\.code))
        return TaliseCurrency.allSupported + extras.filter { !known.contains($0.code) }
    }()

    /// Recipient-side symbolic formatting, choosing decimal places that
    /// suit large-unit currencies (¥, ₫, Rp render with 0 decimals; the
    /// rest with 2). Used for the "recipient gets" lines.
    static func recipientSymbolic(_ amount: Double, currency: TaliseCurrency) -> String {
        let zeroDecimal: Set<String> = ["JPY", "VND", "IDR", "KRW"]
        let decimals = zeroDecimal.contains(currency.code) ? 0 : 2
        return TaliseFormat.symbolic(amount, currency: currency, fixed: decimals)
    }
}
