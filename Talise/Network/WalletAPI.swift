import Foundation

/// Thin namespace over the `/api/wallet/*` endpoints.
///
/// `sweep` is the one-tap "Convert all to USDsui" call: takes a list of
/// (coinType, raw u64 amount) legs sitting in the user's plain wallet
/// (NOT the vault), routes each through the Cetus aggregator, and
/// transfers the resulting USDsui back to the owner — all in a single
/// PTB that the user signs once with the zkLogin ephemeral key. Onara
/// sponsors gas.
@MainActor
enum WalletAPI {
    /// `GET /api/wallet/balances` — flat enumeration of every coin
    /// balance in the user's plain wallet (not the vault). Drives the
    /// "Convert all to USDsui" preview + sweep payload.
    static func balances() async throws -> WalletBalancesResponse {
        try await APIClient.shared.get("/api/wallet/balances")
    }

    /// `POST /api/wallet/sweep` — builds the multi-leg Cetus PTB and
    /// returns the transaction-kind bytes for the standard sign +
    /// sponsor-execute pipeline.
    static func sweep(
        coins: [WalletSweepCoin]
    ) async throws -> WalletSweepResponse {
        try await APIClient.shared.post(
            "/api/wallet/sweep",
            body: WalletSweepRequest(coins: coins)
        )
    }
}
