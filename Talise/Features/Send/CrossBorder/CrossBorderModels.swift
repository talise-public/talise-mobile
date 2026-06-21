import Foundation

/// A pickable cross-border destination — a country, its payout currency,
/// and a flag glyph for the chip. The list is seeded from the static
/// corridor registry the directive names (African + Asian/global), then
/// reconciled at runtime against `GET /api/corridors` so only bookable
/// routes are offered (and "coming soon" ones are shown disabled).
struct CrossBorderCountry: Identifiable, Equatable, Hashable {
    /// ISO 3166-1 alpha-2 (e.g. "NG", "JP"). Matches `toCountry` in the
    /// corridor registry and is what we send as `toCountry` in the quote.
    let code: String
    /// Display name ("Nigeria", "Japan").
    let name: String
    /// ISO 4217 payout currency ("NGN", "JPY").
    let currencyCode: String
    /// Emoji flag for the destination chip.
    let flag: String

    var id: String { code }

    /// The display currency for the payout, resolving the symbol from the
    /// app's known currency catalogue (covers JPY/SGD/PHP/IDR/VND too).
    var currency: TaliseCurrency {
        TaliseCurrency.find(code: currencyCode)
    }
}

/// A pickable sender-side country (where fiat is collected). The corridor
/// registry is directional `from → to`, so the sender's country picks the
/// source currency and gates which destinations have a registered route.
struct CrossBorderOrigin: Identifiable, Equatable, Hashable {
    let code: String          // ISO alpha-2 (e.g. "US")
    let name: String
    let currencyCode: String  // ISO 4217 source currency
    let flag: String

    var id: String { code }
    var currency: TaliseCurrency { TaliseCurrency.find(code: currencyCode) }
}

enum CrossBorderCatalogue {
    /// Sender-side countries that have at least one registered corridor
    /// `fromCountry`. Today the live + partner origins are US, JP, SG.
    /// Used to infer the sender's source currency when their profile
    /// country isn't a known origin.
    static let origins: [CrossBorderOrigin] = [
        .init(code: "US", name: "United States", currencyCode: "USD", flag: "🇺🇸"),
        .init(code: "JP", name: "Japan",          currencyCode: "JPY", flag: "🇯🇵"),
        .init(code: "SG", name: "Singapore",      currencyCode: "SGD", flag: "🇸🇬"),
    ]

    /// All destinations the corridor registry names (`toCountry`). Each
    /// row is shown in the picker; bookability is layered on at runtime
    /// from `/api/corridors`, so a "planned" route appears disabled
    /// rather than missing. Mirrors `CountryCode` in `web/lib/corridors.ts`.
    static let destinations: [CrossBorderCountry] = [
        .init(code: "NG", name: "Nigeria",      currencyCode: "NGN", flag: "🇳🇬"),
        .init(code: "KE", name: "Kenya",        currencyCode: "KES", flag: "🇰🇪"),
        .init(code: "GH", name: "Ghana",        currencyCode: "GHS", flag: "🇬🇭"),
        .init(code: "ZA", name: "South Africa", currencyCode: "ZAR", flag: "🇿🇦"),
        .init(code: "JP", name: "Japan",        currencyCode: "JPY", flag: "🇯🇵"),
        .init(code: "PH", name: "Philippines",  currencyCode: "PHP", flag: "🇵🇭"),
        .init(code: "ID", name: "Indonesia",    currencyCode: "IDR", flag: "🇮🇩"),
        .init(code: "VN", name: "Vietnam",      currencyCode: "VND", flag: "🇻🇳"),
        .init(code: "US", name: "United States", currencyCode: "USD", flag: "🇺🇸"),
    ]

    /// Look up a destination by country code.
    static func destination(for code: String) -> CrossBorderCountry? {
        destinations.first { $0.code == code }
    }

    /// Look up a sender origin by country code.
    static func origin(for code: String?) -> CrossBorderOrigin? {
        guard let code else { return nil }
        return origins.first { $0.code == code.uppercased() }
    }

    /// Resolve the sender's source country/currency from their profile
    /// country code. Falls back to the US (USD) origin — the live
    /// beachhead — when the profile country isn't a known corridor origin
    /// (most US→Africa / US→Asia routes collect in USD).
    static func resolveOrigin(profileCountry: String?) -> CrossBorderOrigin {
        origin(for: profileCountry) ?? origins[0]
    }
}

/// Zero-decimal payout currencies (large-unit) — rendered without
/// fractional digits in the receive lines. Shared by the cross-border
/// views so ¥/₫/Rp/₦/KSh don't show a meaningless ".00".
enum CrossBorderFormat {
    static let zeroDecimalCurrencies: Set<String> = [
        "JPY", "VND", "IDR", "KRW", "NGN", "KES", "VND",
    ]

    /// Decimal places suited to a payout currency.
    static func decimals(for currencyCode: String) -> Int {
        zeroDecimalCurrencies.contains(currencyCode) ? 0 : 2
    }

    /// Symbolic amount for a payout currency with locale-appropriate
    /// decimals (e.g. "¥15,000", "₦1,650.50").
    static func payout(_ amount: Double, currencyCode: String) -> String {
        let currency = TaliseCurrency.find(code: currencyCode)
        return TaliseFormat.symbolic(
            amount,
            currency: currency,
            fixed: decimals(for: currencyCode)
        )
    }
}
