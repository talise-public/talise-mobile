import Foundation

/// Thin namespace over the `/api/onramp/*` endpoints.
///
/// Stripe Crypto Onramp has no first-party iOS SDK. Our integration is
/// the **hosted standalone onramp URL** (https://crypto.link.com…) which
/// we open in `SFSafariViewController` from `DepositFlowView`. The
/// embedded JS-SDK flow lives at `/api/onramp/session` and is reserved
/// for any future web client — iOS goes exclusively through
/// `/api/onramp/hosted-session`.
///
/// The destination wallet is locked server-side to the authenticated
/// user's `sui_address`, so the iOS client doesn't pass it; it only
/// optionally suggests a USD `amount`. Stripe delivers USDC on Sui and
/// the Home tab's AutoConvertBanner sweeps that into USDsui — net effect
/// for the user is "buy USDsui with a card".
@MainActor
enum OnrampAPI {
    /// `POST /api/onramp/hosted-session` →
    /// `{ redirectUrl: String, id: String }`.
    ///
    /// Pass `amount` in USD (1…10 000). Server clamps to that range
    /// and rounds to the nearest cent. Nil falls through to Stripe's
    /// $20 default.
    static func hostedSession(
        amount: Double?
    ) async throws -> OnrampHostedSessionResponse {
        try await APIClient.shared.post(
            "/api/onramp/hosted-session",
            body: OnrampHostedSessionRequest(amount: amount)
        )
    }
}

/// Request body for `POST /api/onramp/hosted-session`. `amount` is
/// optional — when nil, the server defaults to $20.
struct OnrampHostedSessionRequest: Codable {
    let amount: Double?
}

/// Response from `POST /api/onramp/hosted-session`. `redirectUrl` is the
/// `crypto.link.com` hosted-onramp URL we mount in SFSafariViewController.
/// `id` is the Stripe `cos_…` session id — kept for receipt logging /
/// future polling against `/v1/crypto/onramp_sessions/:id`.
struct OnrampHostedSessionResponse: Codable {
    let redirectUrl: String
    let id: String
}
