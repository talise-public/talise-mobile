import Foundation
import CryptoKit

/// Server-issued broadcast endpoint. The Talise backend chooses which
/// fullnode the iOS direct-broadcast path should POST `sui_executeTransactionBlock`
/// to — Shinami when `SHINAMI_API_KEY` is configured server-side, the
/// public Mysten fullnode otherwise. `provider` is informational only
/// (used for the telemetry log line); the iOS client doesn't branch on
/// it. Headers (e.g. `X-Api-Key` for Shinami) must be attached verbatim
/// to the outbound JSON-RPC request.
struct BroadcastEndpoint: Codable, Equatable {
    let url: String
    let headers: [String: String]
    /// `"shinami"`, `"public"`, or `"public-fallback"` (client-injected
    /// when the config fetch itself failed and we fell back to mainnet).
    let provider: String
}

/// Tiny in-memory cache for `GET /api/sui/broadcast-config`. Lives only
/// for the lifetime of the process — by design, we DON'T persist across
/// app launches so a Shinami key rotation propagates within ~one app
/// reopen instead of needing a forced cache invalidation.
///
/// Behavior:
///   - First call (or stale call >15min): fetches via APIClient (so the
///     bearer + App-Attest gates run identically to other Talise endpoints)
///     and caches the result with a fresh timestamp.
///   - Any error during fetch: returns a public-mainnet fallback so a
///     transient network blip never breaks direct-broadcast. The
///     fallback is NOT cached, so the next call retries the server.
///   - Cache is in-memory only — process-local `static var`, never
///     touched by UserDefaults/Keychain/disk.
@MainActor
enum BroadcastConfigCache {
    /// 15 minutes. Matches the server's `Cache-Control: private, max-age=900`.
    private static let maxCacheAge: TimeInterval = 900

    /// Hardcoded public-mainnet fallback used ONLY when the config fetch
    /// itself fails (transient network, server 5xx, decode error). Kept
    /// identical to the URL we used before this helper existed so a
    /// failed config call regresses gracefully to the pre-shinami
    /// behavior — same fullnode, no auth headers.
    private static let publicFallback = BroadcastEndpoint(
        url: "https://fullnode.mainnet.sui.io:443",
        headers: [:],
        provider: "public-fallback"
    )

    /// Last successful fetch (config + timestamp). `nil` until the first
    /// successful round-trip, and re-set on every refresh.
    private static var cached: (config: BroadcastEndpoint, at: Date)?

    /// Returns a cached endpoint if fresh, otherwise refetches. Never
    /// throws: any error during fetch surfaces as the `public-fallback`
    /// provider with the mainnet URL, and the failed fetch is NOT
    /// cached (so the next caller retries).
    static func current() async -> BroadcastEndpoint {
        if let hit = cached, Date().timeIntervalSince(hit.at) < maxCacheAge {
            return hit.config
        }

        do {
            let fresh: BroadcastEndpoint = try await APIClient.shared.get(
                "/api/sui/broadcast-config"
            )
            cached = (fresh, Date())
            return fresh
        } catch {
            // Do NOT cache the fallback — we want the next call to try
            // the server again so we recover the moment connectivity
            // returns.
            return publicFallback
        }
    }

    /// Test/debug hook: clear the in-memory cache so the next `current()`
    /// call re-fetches. Not used in production code paths.
    static func invalidate() {
        cached = nil
    }
}
