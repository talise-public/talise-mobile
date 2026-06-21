import Foundation

/// Thin namespace over Talise's Bridge ramp endpoints.
///
///   • On-ramp  → POST /api/onramp/v2/session   (fiat → USDsui on Sui)
///   • Off-ramp → POST /api/offramp/bridge/cashout-address (USDsui → fiat)
///
/// The destination Sui address (on-ramp) and the source funds (off-ramp) are
/// the signed-in user's, locked server-side — the client never passes them.
/// Both are env-gated server-side: when Bridge isn't configured the on-ramp
/// session 404s (flag off) and the off-ramp 503s, which the flow views render
/// as a clean "not available yet" state.
@MainActor
enum BridgeRampAPI {
    /// Create / fetch the on-ramp funding session. Returns a hosted KYC URL
    /// (open in Safari) when identity isn't verified yet, and/or the bank
    /// deposit instructions once a virtual account exists.
    static func onrampSession(
        amountCents: Int,
        currency: String,
        provider: String = "bridge"
    ) async throws -> OnrampSessionResponse {
        try await APIClient.shared.post(
            "/api/onramp/v2/session",
            body: OnrampSessionRequest(
                amountCents: amountCents,
                provider: provider,
                sourceCurrency: currency.lowercased()
            )
        )
    }

    /// Register the payout bank account and get the persistent Sui cash-out
    /// address. Send USDsui to `address` to cash out to that bank.
    static func cashOutAddress(_ req: CashOutRequest) async throws -> CashOutResponse {
        try await APIClient.shared.post("/api/offramp/bridge/cashout-address", body: req)
    }

    /// Step 1 — swap USDsui → USDC into the user's own wallet (the "USDC
    /// pocket"), 1% fee to treasury. Sponsored bytes → signAndExecuteRaw.
    static func swapToUsdc(amountUsdsui: Double) async throws -> SwapToUsdcResponse {
        try await APIClient.shared.post(
            "/api/offramp/bridge/swap-to-usdc-prepare",
            body: ["amountUsdsui": amountUsdsui]
        )
    }

    /// Step 2 — plain USDC send from the pocket to the Bridge cash-out address
    /// (resolved server-side). Sponsored bytes → signAndExecuteRaw.
    static func sendUsdc(amountUsdc: Double, currency: String) async throws -> SendUsdcResponse {
        struct Body: Codable { let amountUsdc: Double; let currency: String }
        return try await APIClient.shared.post(
            "/api/offramp/bridge/send-usdc-prepare",
            body: Body(amountUsdc: amountUsdc, currency: currency.lowercased())
        )
    }
}

struct SwapToUsdcResponse: Codable {
    let bytes: String
    let mode: String
    let amountUsdsui: Double
    let estimatedUsdcMicros: String
}

struct SendUsdcResponse: Codable {
    let bytes: String
    let mode: String
    let amountUsdc: Double
    let destinationPaymentRail: String
}

// MARK: - On-ramp

struct OnrampSessionRequest: Codable {
    let amountCents: Int
    let provider: String
    let sourceCurrency: String
}

/// Mirrors the server `SessionResult` (+ optional `kycUrl`). For Bridge,
/// `depositInstructions` carries the bank coordinates to fund; `kycUrl` is the
/// hosted identity flow when verification isn't complete.
struct OnrampSessionResponse: Codable {
    let kycUrl: String?
    let widgetUrl: String?
    let depositInstructions: BridgeDepositInstructions?
}

struct BridgeDepositInstructions: Codable {
    let currency: String
    let paymentRails: [String]?
    let bankName: String?
    let bankAddress: String?
    let accountNumber: String?
    let routingNumber: String?
    let accountType: String?
    let beneficiaryName: String?
    let beneficiaryAddress: String?
    let iban: String?
    let bic: String?
    let depositMessage: String?
}

// MARK: - Off-ramp

/// Cash-out bank details. US ACH uses `accountNumber` + `routingNumber`;
/// SEPA/EUR uses `iban` + `bic` + name parts + `country` (ISO alpha-3).
struct CashOutRequest: Codable {
    let rail: String          // "ach" | "sepa"
    let currency: String      // "usd" | "eur"
    let accountOwnerName: String
    var accountNumber: String? = nil
    var routingNumber: String? = nil
    var checkingOrSavings: String? = nil
    var firstName: String? = nil
    var lastName: String? = nil
    var iban: String? = nil
    var bic: String? = nil
    var country: String? = nil
    // Account-holder address — Bridge requires it for US ACH payout accounts.
    var street: String? = nil
    var city: String? = nil
    var state: String? = nil
    var postalCode: String? = nil
}

struct CashOutResponse: Codable {
    /// The persistent Sui address to send USDsui to in order to cash out.
    let address: String
    let currency: String
    let destinationPaymentRail: String
    let note: String?
    // Payout bank summary (when an existing route is reused) — shown so the
    // user can confirm which account the wire lands in.
    let bankName: String?
    let accountLast4: String?
    let accountOwnerName: String?
    let accountType: String?
    /// USDC pocket balance, raw u64 micros string (6 decimals).
    let usdcMicros: String?
}
