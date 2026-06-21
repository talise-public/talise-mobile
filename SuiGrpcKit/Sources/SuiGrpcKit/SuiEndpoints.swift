// SuiEndpoints.swift
//
// Sui mainnet gRPC endpoint registry + multi-provider fallback helper.
//
// Why this exists:
//   Today's outage on `fullnode.mainnet.sui.io:443` (503 no_healthy_upstream)
//   took down the iOS gRPC test run. This file is the iOS-side mirror of
//   `web/lib/sui-endpoints.ts`: a static, ordered list of providers we can
//   try in turn, plus a `withFallback` helper that swaps endpoints on
//   `unavailable` / `deadlineExceeded` failures.
//
// What this file is NOT:
//   - It does NOT replace `SuiGrpcClient.shared`. Existing callers keep
//     their single-endpoint behavior. The substitution is the follow-up
//     cohort once we've vetted per-endpoint compatibility.
//   - The current `SuiGrpcClient` initializer is `private`, so the
//     `withFallback` body below cannot construct per-endpoint clients
//     without changes to `SuiGrpcClient.swift`. That's intentional — the
//     cohort that wires this in will widen the initializer (and add a
//     per-endpoint header bag for paid providers like Shinami / Dwellir).
//     Until then `withFallback` always routes to the singleton; the
//     scaffolding is in place so the swap is a small, reviewable diff.
//
// See: docs/sui-rpc-migration/endpoints.md

import Foundation
import GRPCCore

/// One entry in the mainnet gRPC fallback chain.
///
/// `url` is the full base URL (scheme + host + port). For URL-embedded-token
/// providers (QuickNode) callers paste the entire URL into the relevant
/// Keychain item; `requiresAuth` stays `true` so the wrapper still gates on
/// the key being present.
public struct SuiEndpoint: Sendable {
    public let url: String
    public let provider: String
    public let requiresAuth: Bool
    /// Keychain item identifier holding the API key for this provider (when
    /// `requiresAuth` is true). The follow-up cohort wires
    /// `KeychainHelper.read(_:)` against these identifiers.
    public let keychainKey: String?
    /// Header name to send the API key under (e.g. `x-api-key`). nil when
    /// the key is baked into the URL.
    public let apiKeyHeader: String?

    public init(url: String, provider: String, requiresAuth: Bool, keychainKey: String?, apiKeyHeader: String?) {
        self.url = url
        self.provider = provider
        self.requiresAuth = requiresAuth
        self.keychainKey = keychainKey
        self.apiKeyHeader = apiKeyHeader
    }
}

public enum SuiEndpoints {

    /// Ordered Sui MAINNET gRPC endpoints, preferred first.
    ///
    /// Bias: (a) free + already-default first, then (b) paid providers we
    /// already have a working key for. Anything paid-without-a-key is
    /// listed for completeness but skipped at runtime when the Keychain
    /// item is missing.
    public static let mainnetGrpcEndpoints: [SuiEndpoint] = [
        SuiEndpoint(
            url: "https://fullnode.mainnet.sui.io:443",
            provider: "mysten-fullnode",
            requiresAuth: false,
            keychainKey: nil,
            apiKeyHeader: nil
        ),
        SuiEndpoint(
            url: "https://archive.mainnet.sui.io:443",
            provider: "mysten-archive",
            requiresAuth: false,
            keychainKey: nil,
            apiKeyHeader: nil
        ),
        SuiEndpoint(
            // Shinami — we already use them for zkLogin + gas station on
            // the backend. iOS doesn't talk to Shinami directly today,
            // but if we promote the wrapper to be a direct fallback we'd
            // need a Keychain-resident mainnet US1 key under this name.
            url: "https://api.us1.shinami.com/sui/node/v1",
            provider: "shinami",
            requiresAuth: true,
            keychainKey: "talise.sui.shinami.apiKey",
            apiKeyHeader: "X-Api-Key"
        ),
        SuiEndpoint(
            url: "https://api-sui-mainnet-full.n.dwellir.com:443",
            provider: "dwellir",
            requiresAuth: true,
            keychainKey: "talise.sui.dwellir.apiKey",
            apiKeyHeader: "x-api-key"
        ),
        SuiEndpoint(
            // QuickNode bakes the token into the URL host. The Keychain
            // item stores the FULL `https://<token>.sui-mainnet.quiknode.pro:9000`
            // URL; the wrapper substitutes it in place of the placeholder.
            url: "",
            provider: "quicknode",
            requiresAuth: true,
            keychainKey: "talise.sui.quicknode.url",
            apiKeyHeader: nil
        ),
    ]

    /// Returns `true` when the error is the kind we should fall back on.
    /// Mirrors `isFallbackEligible` in `web/lib/sui-endpoints.ts`.
    ///
    /// `RPCError.code` is the canonical grpc-swift status code. We retry
    /// on `.unavailable` (`UNAVAILABLE` = 14) and `.deadlineExceeded`
    /// (`DEADLINE_EXCEEDED` = 4). Plain `NSError` / `URLError` from the
    /// TLS/HTTP2 transport surface a 503 message; we treat those as
    /// transient too.
    public static func isFallbackEligible(_ error: Error) -> Bool {
        if let rpc = error as? RPCError {
            return rpc.code == .unavailable || rpc.code == .deadlineExceeded
        }
        let msg = (error as NSError).localizedDescription.lowercased()
        return msg.contains("no_healthy_upstream")
            || msg.contains("503")
            || msg.contains("502")
            || msg.contains("504")
            || msg.contains("unavailable")
            || msg.contains("deadline")
            || msg.contains("connection")
    }

    /// Run `call` against the first reachable mainnet endpoint, retrying
    /// the next endpoint on `unavailable` / `deadlineExceeded`. Returns
    /// the first success; throws the last error if every endpoint failed.
    ///
    /// Today this routes every call to `SuiGrpcClient.shared` because the
    /// existing initializer is `private` and the cohort doc forbids
    /// modifying `SuiGrpcClient.swift` in this change. The fallback walk
    /// over `mainnetGrpcEndpoints` becomes meaningful in the next cohort
    /// (see top-of-file note).
    public static func withFallback<T>(
        call: (SuiGrpcClient) async throws -> T
    ) async throws -> T {
        var lastError: Error = NSError(
            domain: "SuiEndpoints",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "no endpoints attempted"]
        )

        // Skipped endpoints (auth required + no Keychain key) drop out of
        // the loop early. Today this whole list collapses to a single
        // attempt against the shared client; once `SuiGrpcClient` accepts
        // a per-endpoint init, replace that with a fresh client per
        // iteration.
        var attempted = 0
        for endpoint in mainnetGrpcEndpoints {
            if endpoint.requiresAuth {
                // Without a key we cannot use this endpoint. The Keychain
                // helper isn't wired here yet — see the follow-up cohort.
                continue
            }
            attempted += 1
            do {
                return try await call(SuiGrpcClient.shared)
            } catch {
                lastError = error
                if !isFallbackEligible(error) {
                    throw error
                }
                continue
            }
        }

        if attempted == 0 {
            throw NSError(
                domain: "SuiEndpoints",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "no endpoints attempted (every paid endpoint missing its Keychain key, and no free endpoints configured)"]
            )
        }
        throw lastError
    }
}
