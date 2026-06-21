import SwiftUI

/// A fiat corridor for the ramps (add money / cash out). Each row is a
/// country + its currency + a flag, plus how Talise serves it:
///
///   • `.bridge` — live via Bridge (USD/EUR/GBP/MXN/BRL/COP). Bridge moves
///     fiat ↔ USDsui DIRECTLY on Sui, both directions.
///   • `.local`  — served by a dedicated local rail (Nigeria/NGN via Linq),
///     off-ramp only today.
///   • `.soon`   — known corridor, not yet bookable; shown disabled so the
///     map of "where Talise is going" is honest.
struct RampCorridor: Identifiable, Equatable, Hashable {
    /// ISO 3166-1 alpha-2 (e.g. "US", "NG"); "EU" for the Eurozone.
    let code: String
    /// Display name ("United States").
    let name: String
    /// ISO 4217 fiat currency ("USD").
    let currencyCode: String
    let availability: Availability
    /// Which directions this corridor supports.
    let onramp: Bool
    let offramp: Bool

    var id: String { code }

    /// Asset name for the vendored circular flag SVG (matches the web app's
    /// circle-flags set): `flag-<cc>` in Assets.xcassets/Flags.
    var flagAsset: String { "flag-\(code.lowercased())" }

    enum Availability: Equatable, Hashable {
        case bridge
        case local
        case soon
    }

    var isAvailable: Bool { availability != .soon }

    /// Short rail label for the row subtitle.
    var railLabel: String {
        switch availability {
        case .bridge: return "Bank transfer · USDsui on Sui"
        case .local: return "Local bank"
        case .soon: return "Coming soon"
        }
    }
}

/// The corridor catalogue. Available rows are first-class; "soon" rows keep
/// the picker honest about coverage without pretending they work.
enum RampCorridors {
    /// Bridge fiat corridors (live when Bridge is configured). Bridge delivers
    /// USDsui on Sui directly — no swap — for both add-money and cash-out.
    // Every code below has a vendored circular flag in Assets.xcassets/Flags
    // (the web app's circle-flags set). "EU" → the Eurozone (Bridge SEPA),
    // rendered with the EU flag rather than listing each member state.
    static let all: [RampCorridor] = [
        // ── Live via Bridge (USD/EUR/GBP) ──
        .init(code: "US", name: "United States", currencyCode: "USD",
              availability: .bridge, onramp: true, offramp: true),
        .init(code: "EU", name: "Europe", currencyCode: "EUR",
              availability: .bridge, onramp: true, offramp: true),
        // GBP add-money is live (virtual account); GBP cash-out (Faster
        // Payments) isn't wired yet → onramp only.
        .init(code: "GB", name: "United Kingdom", currencyCode: "GBP",
              availability: .bridge, onramp: true, offramp: false),
        // ── Live via a local rail (Linq) ──
        .init(code: "NG", name: "Nigeria", currencyCode: "NGN",
              availability: .local, onramp: false, offramp: true),
        // ── On the map, not yet bookable ──
        .init(code: "KE", name: "Kenya", currencyCode: "KES",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "GH", name: "Ghana", currencyCode: "GHS",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "ZA", name: "South Africa", currencyCode: "ZAR",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "PH", name: "Philippines", currencyCode: "PHP",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "IN", name: "India", currencyCode: "INR",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "ID", name: "Indonesia", currencyCode: "IDR",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "VN", name: "Vietnam", currencyCode: "VND",
              availability: .soon, onramp: false, offramp: false),
        .init(code: "EG", name: "Egypt", currencyCode: "EGP",
              availability: .soon, onramp: false, offramp: false),
    ]

    /// Corridors that support a given direction, available ones first, "soon"
    /// last — both groups alphabetical by name.
    static func forDirection(
        _ direction: RampDirection,
        userCountry: String?
    ) -> (available: [RampCorridor], soon: [RampCorridor]) {
        // Nigeria-first: an unset/empty country defaults to NG so a user who
        // never picked one still gets Nigerian cash-out (the live rail) rather
        // than an all-"coming soon" wall.
        let raw = (userCountry ?? "").trimmingCharacters(in: .whitespaces)
        let cc = (raw.isEmpty ? "NG" : raw).uppercased()
        let supports: (RampCorridor) -> Bool = { c in
            direction == .onramp ? c.onramp : c.offramp
        }
        // A corridor is bookable NOW only if it supports the direction, its rail
        // is live, AND it matches the user's country:
        //   • local (Linq/Nigeria) → only for a user whose country is that code
        //     (a Nigerian sees Nigeria cash-out; everyone else → coming soon).
        //   • Bridge corridors → only once `RampFlags.bridgeLive` is on, and for
        //     a matching-country user (EUR covers the whole Eurozone).
        // Everything else falls to "coming soon".
        let live: (RampCorridor) -> Bool = { c in
            switch c.availability {
            case .local: return cc == c.code
            case .bridge: return RampFlags.bridgeLive && c.code == cc
            case .soon: return false
            }
        }
        let bookable: (RampCorridor) -> Bool = { live($0) && supports($0) }
        let available = all.filter(bookable).sorted { $0.name < $1.name }
        let soon = all.filter { !bookable($0) }.sorted { $0.name < $1.name }
        return (available, soon)
    }
}

enum RampDirection {
    case onramp   // add money: fiat → USDsui
    case offramp  // cash out: USDsui → fiat
}

/// Feature gating for the ramps. Until the Bridge account is live (KYB
/// approved + API key + webhook), only Nigeria's local rail (Linq) is bookable
/// — the Bridge corridors (US/EU/GB/…) show as "coming soon". Flip
/// `bridgeLive` to true to switch them on with no other code change.
enum RampFlags {
    static let bridgeLive = false
}
