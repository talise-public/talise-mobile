import Foundation
import SwiftUI

/// User-facing display currency. Talise always settles in USDsui on
/// chain (1:1 USD); this picker just changes what the UI renders.
struct TaliseCurrency: Identifiable, Equatable, Hashable, Codable {
    let code: String       // ISO 4217: USD, NGN, GHS, KES, EUR, GBP, CAD, ZAR
    let symbol: String     // $, ₦, ₵, KSh, €, £, CA$, R
    let name: String       // "US Dollar", "Nigerian Naira", …
    var id: String { code }

    /// ISO alpha-2 (or "eu") for the circular flag icon in Assets/Flags,
    /// rendered via RoundedFlag. Currency code → country.
    var flagCode: String {
        switch code {
        case "USD": return "us"
        case "NGN": return "ng"
        case "GHS": return "gh"
        case "KES": return "ke"
        case "EUR": return "eu"
        case "GBP": return "gb"
        case "CAD": return "ca"
        case "ZAR": return "za"
        case "JPY": return "jp"
        case "SGD": return "sg"
        case "PHP": return "ph"
        case "IDR": return "id"
        case "VND": return "vn"
        default:    return "us"
        }
    }

    static let allSupported: [TaliseCurrency] = [
        .init(code: "USD", symbol: "$",   name: "US Dollar"),
        .init(code: "NGN", symbol: "₦",   name: "Nigerian Naira"),
        .init(code: "GHS", symbol: "₵",   name: "Ghanaian Cedi"),
        .init(code: "KES", symbol: "KSh", name: "Kenyan Shilling"),
        .init(code: "EUR", symbol: "€",   name: "Euro"),
        .init(code: "GBP", symbol: "£",   name: "British Pound"),
        .init(code: "CAD", symbol: "CA$", name: "Canadian Dollar"),
        .init(code: "ZAR", symbol: "R",   name: "South African Rand"),
        // Asian / global corridors (master plan §8). Display-only — the
        // wallet still settles in USDsui (1:1 USD); the FX rate maps the
        // figure into the user's currency.
        .init(code: "JPY", symbol: "¥",   name: "Japanese Yen"),
        .init(code: "SGD", symbol: "S$",  name: "Singapore Dollar"),
        .init(code: "PHP", symbol: "₱",   name: "Philippine Peso"),
        .init(code: "IDR", symbol: "Rp",  name: "Indonesian Rupiah"),
        .init(code: "VND", symbol: "₫",   name: "Vietnamese Dong"),
    ]

    static let usd = allSupported[0]

    static func find(code: String) -> TaliseCurrency {
        allSupported.first(where: { $0.code == code }) ?? .usd
    }
}

/// App-wide currency preference. Persists to UserDefaults; observable
/// via SwiftUI's @Environment(\.currencySettings) pattern.
///
/// On first launch we default to the country's currency when the
/// user's row carries one — Nigerian users default to NGN, etc. If
/// no match, fall back to USD.
@MainActor
@Observable
final class CurrencySettings {
    static let shared = CurrencySettings()

    private let defaultsKey = "io.talise.app.displayCurrency"
    private let ratesKey = "io.talise.app.fxRates"
    private let ratesAtKey = "io.talise.app.fxRatesAt"
    private(set) var current: TaliseCurrency
    private(set) var rates: [String: Double] = ["USD": 1]
    private(set) var ratesLoaded = false

    private init() {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        self.current = stored.map(TaliseCurrency.find) ?? .usd

        // Hydrate rates from the last persisted snapshot so the first
        // render uses real conversion factors instead of falling back to
        // 1.0 (which renders \$0.20 as "₦0.20"). The background refresh
        // updates them for the next session.
        if let data = UserDefaults.standard.data(forKey: ratesKey),
           let snap = try? JSONDecoder().decode([String: Double].self, from: data),
           !snap.isEmpty {
            rates = snap
            ratesLoaded = true
        }
    }

    func set(_ currency: TaliseCurrency) {
        current = currency
        UserDefaults.standard.set(currency.code, forKey: defaultsKey)
    }

    /// One-shot rate fetch — call from AppSession.bootstrap. Idempotent;
    /// soft-fails to USD-only. Persists every successful response so the
    /// next cold start has a warm cache.
    func refresh() async {
        struct Response: Decodable {
            let rates: [String: Double]
        }
        do {
            let r: Response = try await APIClient.shared.get("/api/fx")
            rates = r.rates
            ratesLoaded = true
            if let data = try? JSONEncoder().encode(r.rates) {
                UserDefaults.standard.set(data, forKey: ratesKey)
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: ratesAtKey
                )
            }
        } catch {
            // Keep whatever we had (cached snap or USD baseline).
        }
    }

    /// True when the persisted rates are older than `ttlSec`. Views can
    /// call refresh() on appear if this returns true so a stale offline
    /// cache doesn't quietly persist for days.
    func isStale(ttlSec: TimeInterval = 60 * 60 * 4) -> Bool {
        let ts = UserDefaults.standard.double(forKey: ratesAtKey)
        if ts == 0 { return true }
        return Date().timeIntervalSince1970 - ts > ttlSec
    }

    /// Convert a USD amount to the user's display currency. Returns
    /// (amount, currency) so callers don't need a separate symbol
    /// lookup.
    func convert(usd: Double) -> (amount: Double, currency: TaliseCurrency) {
        let rate = rates[current.code] ?? 1
        return (usd * rate, current)
    }

    /// Reverse direction — local-currency amount back to USD. Used when
    /// the user types an amount in their chosen currency on Invest /
    /// Send / etc., and we need to convert to USDsui (1:1 USD) before
    /// posting to the backend. Falls back to identity when the rate
    /// hasn't loaded yet so we never silently zero out a supply.
    func convertToUsd(local: Double) -> Double {
        let rate = rates[current.code] ?? 1
        guard rate > 0 else { return local }
        return local / rate
    }

    /// Country-code → currency-code heuristic. Used when the user
    /// completes onboarding so a Nigerian user defaults to NGN
    /// without having to flip the toggle themselves.
    static func defaultCurrency(forCountry code: String?) -> TaliseCurrency {
        let map: [String: String] = [
            "NG": "NGN", "GH": "GHS", "KE": "KES",
            "ZA": "ZAR", "GB": "GBP", "UK": "GBP",
            "DE": "EUR", "FR": "EUR", "ES": "EUR", "IT": "EUR",
            "CA": "CAD",
            // Asian / global corridors.
            "JP": "JPY", "SG": "SGD", "PH": "PHP", "ID": "IDR", "VN": "VND",
        ]
        guard let c = code, let cur = map[c.uppercased()] else { return .usd }
        return TaliseCurrency.find(code: cur)
    }
}
