import Foundation

/// USD currency formatting. Pinned to en_US locale + a literal `$` symbol
/// so the output is always "$1,234.50" regardless of the device locale —
/// otherwise a phone in en_GB/en_NG renders "US$1,234.50" which reads
/// awkwardly inside a Talise UI where every amount is implicitly USD.
enum TaliseFormat {
    /// Smart decimals: under $1 → 4 decimals (so daily yields don't
    /// collapse to "$0.00"); $1 and over → 2 decimals.
    static func usd(_ v: Double) -> String {
        formatter(decimals: v < 1.0 ? 4 : 2).string(from: NSNumber(value: v)) ?? "$0.00"
    }

    /// Fixed 2-decimal formatter — for amounts where consistent column
    /// width matters more than precision (header totals, activity rows).
    static func usd2(_ v: Double) -> String {
        formatter(decimals: 2).string(from: NSNumber(value: v)) ?? "$0.00"
    }

    private static func formatter(decimals: Int) -> NumberFormatter {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.locale = Locale(identifier: "en_US")
        fmt.currencyCode = "USD"
        fmt.currencySymbol = "$"
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        return fmt
    }

    /// Render a USD amount in the user's chosen display currency,
    /// applying the FX rate from CurrencySettings. Talise always settles
    /// in USDsui (1:1 USD) on chain — this only changes presentation.
    /// Falls back to USD output when rates haven't loaded yet.
    @MainActor
    static func local(_ usd: Double) -> String {
        let s = CurrencySettings.shared
        let (amount, currency) = s.convert(usd: usd)
        return symbolic(amount, currency: currency)
    }

    /// Companion that pins decimal places for headline figures.
    @MainActor
    static func local2(_ usd: Double) -> String {
        let s = CurrencySettings.shared
        let (amount, currency) = s.convert(usd: usd)
        return symbolic(amount, currency: currency, fixed: 2)
    }

    /// Render a raw NGN figure with the ₦ symbol and grouped thousands,
    /// e.g. "₦142,350.00". Used for fiat cash-out (off-ramp) payouts where
    /// the server already gives us the naira amount — we do NOT run it
    /// through the USD→display FX path because it's already in naira.
    static func ngn(_ amount: Double, decimals: Int = 2) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        let body = fmt.string(from: NSNumber(value: amount)) ?? "0"
        return "\u{20A6}\(body)"
    }

    /// Render an amount in any TaliseCurrency without going through
    /// CurrencySettings — used in the picker preview rows.
    static func symbolic(
        _ amount: Double,
        currency: TaliseCurrency,
        fixed: Int? = nil
    ) -> String {
        let decimals: Int = {
            if let f = fixed { return f }
            if amount < 1 { return 4 }
            return 2
        }()
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = decimals
        fmt.maximumFractionDigits = decimals
        let body = fmt.string(from: NSNumber(value: amount)) ?? "0"
        return "\(currency.symbol)\(body)"
    }
}
