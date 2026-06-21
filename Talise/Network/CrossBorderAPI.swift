import Foundation

/// iOS client for the cross-border transfer rail.
///
/// Wraps the two server-authoritative endpoints that drive an
/// international send end-to-end:
///
///   POST /api/transfers/cross-border/quote   → a locked, priced quote
///   POST /api/transfers/cross-border/confirm → commit + state machine
///
/// Both sit behind the SAME auth gate as `/api/send/sponsor-prepare`
/// (session/bearer + App Attest), which `APIClient` already attaches on
/// every request. The chain stays invisible here: the client speaks only
/// in fiat (`fromCcy`/`toCcy`, `amount`) — USDsui/USDC settlement is the
/// server's middle leg.
///
/// Unlike the same-currency send (which builds + signs a PTB on device),
/// the cross-border confirm is server-driven: the backend runs the
/// on-chain settle leg AND the fiat-out (Paga for the live NG corridor;
/// `fiat_out_pending` for partner corridors). iOS just commits the held
/// quote by `transferId` and reads back the resulting `state`.
///
/// Everything here is additive and self-contained — it does not touch the
/// existing `/api/send/*` rail or the client-side `CrossBorderQuote`
/// math (that estimator still powers the same-currency-adjacent preview;
/// this rail is the authoritative, server-locked path).
@MainActor
enum CrossBorderAPI {
    // MARK: - Quote

    /// POST /api/transfers/cross-border/quote
    ///
    /// `amount` is in the corridor's SOURCE currency (what the sender
    /// types). On 4xx the server returns `{ error, code }`; we map the
    /// `code` into `CrossBorderError` so the UI can branch on it cleanly
    /// (TIER_BLOCKED / LIMIT_EXCEEDED / OVER_CAP / …).
    static func quote(
        fromCountry: String,
        toCountry: String,
        amount: Double
    ) async throws -> CrossBorderQuoteDTO {
        do {
            return try await APIClient.shared.post(
                "/api/transfers/cross-border/quote",
                body: QuoteRequest(
                    fromCountry: fromCountry,
                    toCountry: toCountry,
                    amount: amount
                )
            )
        } catch {
            throw CrossBorderError.from(error)
        }
    }

    /// POST /api/transfers/cross-border/confirm
    ///
    /// Commits the held quote and drives the transfers state machine.
    /// Returns the resulting `state` (e.g. `settled` for the live NG
    /// corridor's synchronous Paga path, or `fiat_out_pending` for a
    /// partner corridor whose payout settles asynchronously).
    static func confirm(transferId: String) async throws -> CrossBorderConfirmDTO {
        do {
            return try await APIClient.shared.post(
                "/api/transfers/cross-border/confirm",
                body: ConfirmRequest(transferId: transferId)
            )
        } catch {
            throw CrossBorderError.from(error)
        }
    }

    /// GET /api/corridors — the corridor registry. Used to gate the
    /// destination picker so users only see routes that are actually
    /// bookable (live + partner), and to surface "coming soon" routes.
    static func corridors() async throws -> CorridorRegistryDTO {
        try await APIClient.shared.get("/api/corridors")
    }

    // MARK: - Request bodies

    private struct QuoteRequest: Encodable {
        let fromCountry: String
        let toCountry: String
        let amount: Double
    }

    private struct ConfirmRequest: Encodable {
        let transferId: String
    }
}

// MARK: - Response DTOs

/// 200 body of POST /api/transfers/cross-border/quote.
///
/// Mirrors the contract exactly:
///   { transferId, corridor, quote, amountUsd, tier, recipientGets }
struct CrossBorderQuoteDTO: Codable, Equatable {
    let transferId: String
    let corridor: CorridorDTO
    let quote: LockedQuoteDTO
    /// USD value of the send (USDsui is 1:1 USD). Drives the per-tx cap
    /// notice and the on-chain settlement amount.
    let amountUsd: Double
    /// The sender's KYC tier the server priced this against (0…3).
    let tier: Int
    let recipientGets: RecipientGetsDTO
}

/// Corridor metadata as returned inside a quote. A subset of the full
/// registry `Corridor` — only what the review screen renders.
struct CorridorDTO: Codable, Equatable, Hashable {
    let id: String
    let fromCcy: String
    let toCcy: String
    /// "live" | "partner" | "planned"
    let status: String
    let spreadBps: Int
    /// Per-transaction cap in USD, when the rail is legally capped
    /// (e.g. JP's ¥1M ≈ ~$6,400). Nil when uncapped.
    let perTxCapUsd: Double?

    /// True when the corridor is bookable now (live OR a partner rail is
    /// up). Planned corridors are display-only.
    var isBookable: Bool { status == "live" || status == "partner" }

    /// True for production corridors where the fiat-out settles
    /// synchronously (today: the NG/Paga path). Partner corridors
    /// advance to `fiat_out_pending` instead.
    var isLive: Bool { status == "live" }
}

/// The server-locked quote block. The `rate`/`spreadBps`/`toAmount` are
/// authoritative — the client renders them verbatim and never re-derives
/// FX. `expiresAt` is epoch-ms; the review screen counts down to it.
struct LockedQuoteDTO: Codable, Equatable {
    let rate: Double
    let spreadBps: Int
    let toAmount: Double
    /// Epoch-ms instant the held rate lapses. ~30s out per the contract.
    let expiresAt: Double
}

/// What the recipient receives, in their payout currency.
struct RecipientGetsDTO: Codable, Equatable {
    let amount: Double
    /// ISO 4217 payout currency code (e.g. "NGN", "JPY").
    let currency: String
}

/// 200 body of POST /api/transfers/cross-border/confirm.
struct CrossBorderConfirmDTO: Codable, Equatable {
    /// Resulting transfers-machine state — e.g. "onchain_settled",
    /// "settled", "fiat_out_pending", "failed".
    let state: String
    let transferId: String

    /// True once the confirm has COMMITTED the transfer: the user's funds are
    /// debited and the on-chain settlement leg is in flight or done. This —
    /// not `isChainFinal` — is the success criterion for the review screen.
    ///
    /// The LIVE NG corridor returns `onchain_settling` from confirm (on-chain
    /// finality + the Paga payout land later via the broadcast-confirm hook,
    /// per the server's commit-point semantics), so treating only
    /// `onchain_settled+` as success made a perfectly good NG confirm render
    /// as "Transfer didn't go through." Anything from `onchain_settling`
    /// onward is a successful submission; a 4xx (caller's catch) or an
    /// explicit `failed`/`refunded` is the only real failure.
    var isCommitted: Bool {
        switch state {
        case "onchain_settling", "onchain_settled", "fiat_out_pending", "settled":
            return true
        default:
            return false
        }
    }

    /// True when the on-chain leg is final (chain-irreversible),
    /// regardless of whether the local fiat payout has landed yet.
    /// Anything at/after `onchain_settled` qualifies.
    var isChainFinal: Bool {
        switch state {
        case "onchain_settled", "fiat_out_pending", "settled":
            return true
        default:
            return false
        }
    }

    /// True only once the recipient's local payout has fully settled.
    var isPayoutSettled: Bool { state == "settled" }
}

/// GET /api/corridors response. We decode only `corridors` (the full
/// registry); `live`/`planned` are conveniences the route also returns
/// but we re-derive them client-side from `status`.
struct CorridorRegistryDTO: Codable {
    let corridors: [CorridorRegistryEntryDTO]
}

/// One row of the corridor registry. Carries the country endpoints (the
/// quote DTO's `CorridorDTO` omits these) so the destination picker can
/// map a country → its payout currency + bookability.
struct CorridorRegistryEntryDTO: Codable, Identifiable, Hashable {
    let id: String
    let fromCountry: String
    let fromCcy: String
    let toCountry: String
    let toCcy: String
    let status: String
    let spreadBps: Int
    let perTxCapUsd: Double?

    var isBookable: Bool { status == "live" || status == "partner" }
    var isLive: Bool { status == "live" }
}

// MARK: - Typed errors

/// The contract's 4xx error codes, plus transport/unknown fallbacks.
/// Lets the UI render a clean, code-specific message for each gate
/// (tier block, monthly limit, per-tx cap, …) instead of a raw HTTP
/// string.
enum CrossBorderError: Error, LocalizedError, Equatable {
    case unknownCorridor
    case notBookable
    case overCap
    case tierBlocked
    case limitExceeded
    case fx
    case badInput
    /// Server returned a 4xx with an unrecognized `code`, or a non-4xx
    /// failure. Carries the best message we could extract.
    case other(String)
    /// URLSession cancellation — not a real failure; callers no-op.
    case cancelled

    /// Map an arbitrary thrown error (usually `APIError`) into a typed
    /// cross-border error. Pulls the `code` out of the server's
    /// `{ error, code }` 4xx body when present.
    static func from(_ error: Error) -> CrossBorderError {
        if APIError.isCancellation(error) { return .cancelled }
        if let cb = error as? CrossBorderError { return cb }

        // The server's 4xx body rides in APIError.status(_, message:) as
        // the raw JSON string. Parse out `code` first, falling back to
        // the `error` message.
        if case let APIError.status(_, message) = error,
           let raw = message,
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = obj["code"] as? String,
               let mapped = mapCode(code) {
                return mapped
            }
            if let msg = obj["error"] as? String, !msg.isEmpty {
                return .other(msg)
            }
        }
        return .other(error.localizedDescription)
    }

    private static func mapCode(_ code: String) -> CrossBorderError? {
        switch code {
        case "UNKNOWN_CORRIDOR": return .unknownCorridor
        case "NOT_BOOKABLE":     return .notBookable
        case "OVER_CAP":         return .overCap
        case "TIER_BLOCKED":     return .tierBlocked
        case "LIMIT_EXCEEDED":   return .limitExceeded
        case "FX":               return .fx
        case "BAD_INPUT":        return .badInput
        default:                 return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .unknownCorridor:
            return "We don't have a route to that country yet."
        case .notBookable:
            return "This corridor isn't open yet — we're onboarding the local payout partner."
        case .overCap:
            return "That's over the single-transfer cap for this corridor. Try a smaller amount."
        case .tierBlocked:
            return "Cross-border sends need a verified account. Finish identity verification to unlock."
        case .limitExceeded:
            return "This would put you over your transfer limit. Upgrade your tier or send less."
        case .fx:
            return "Couldn't lock an exchange rate right now. Try again in a moment."
        case .badInput:
            return "Something about that transfer didn't check out. Double-check the amount and try again."
        case .other(let msg):
            return msg
        case .cancelled:
            return "Request was cancelled."
        }
    }

    /// True when re-trying the SAME inputs could plausibly succeed (vs a
    /// hard gate like a tier block). Drives whether the failure screen
    /// offers "Try again" vs "Verify identity".
    var isTransient: Bool {
        switch self {
        case .fx, .other, .cancelled: return true
        default: return false
        }
    }
}
