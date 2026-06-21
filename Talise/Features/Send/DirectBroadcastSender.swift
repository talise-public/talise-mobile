import Foundation
import CryptoKit

/// Result of a successful direct-broadcast send. Three discrete timings
/// surface so the `[ios/send]` log line can attribute latency to
/// assemble (server signature stitch), broadcast (fullnode round-trip),
/// and confirm (bookkeeping fire-and-forget) independently.
struct DirectBroadcastResult {
    let digest: String
    let assembleMs: Int
    let broadcastMs: Int
    let confirmMs: Int
    /// Which broadcast provider serviced this send — `"shinami"`,
    /// `"public"`, or `"public-fallback"`. Surfaced so the
    /// `[ios/send]` log line can attribute latency to a specific
    /// fullnode operator (Shinami vs. public Mysten).
    let provider: String
}

enum DirectBroadcastError: Error {
    case assembleFailed(String)
    case broadcastFailed(String)
    case noDigest
}

/// Direct-to-fullnode gasless send dispatcher.
///
/// Replaces the `/api/send/gasless-submit` execute hop with:
///   1. `/api/zk/assemble-signature` (server stitches the zkLogin sig)
///   2. POST to `https://fullnode.mainnet.sui.io:443` (JSON-RPC
///      `sui_executeTransactionBlock`) — direct broadcast, no Vercel
///   3. `/api/send/gasless-confirm` (fire-and-forget bookkeeping)
///
/// Saves ~250-400ms per send by removing one iOS→Vercel round-trip on
/// the execute leg. Throws on assemble or broadcast failure so the
/// caller can fall back to the existing gasless-submit path. Confirm
/// errors are swallowed — the tx already landed on chain.
@MainActor
enum DirectBroadcastSender {
    /// Dedicated URLSession for the third-party fullnode broadcast.
    /// Separate from APIClient's session because:
    ///   - No Talise bearer / App Attest headers should leak to a
    ///     non-Talise host.
    ///   - The 15s request timeout is tuned for a single JSON-RPC
    ///     transaction submit, distinct from APIClient's defaults.
    private static let fullnodeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "Talise-iOS/\(AppConfig.shared.appVersion)",
        ]
        return URLSession(configuration: cfg)
    }()

    // Note: the broadcast URL is no longer hardcoded — see
    // `BroadcastConfigCache.current()` for the server-issued endpoint
    // (Shinami when configured, public Mysten fullnode otherwise).

    /// Runs assemble → fullnode broadcast → fire-and-forget confirm.
    /// Throws on assemble or broadcast failure so the caller can fall
    /// back to /api/send/gasless-submit. Confirm errors are swallowed
    /// (server-side bookkeeping is best-effort; the tx already landed).
    static func send(
        bytesB64: String,
        ephemeralPubKeyB64: String,
        maxEpoch: Int,
        randomness: String,
        userSignature: String,
        cachedProof: [String: Any]?,
        meta: [String: Any]?
    ) async throws -> DirectBroadcastResult {
        // 1. Assemble — server stitches the zkLogin signature. May
        //    mint a fresh proof if the cached one is missing/stale.
        let tAssembleStart = CFAbsoluteTimeGetCurrent()
        var assembleBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": ephemeralPubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": randomness,
            "userSignature": userSignature,
        ]
        if let cachedProof { assembleBody["cachedProof"] = cachedProof }

        let assembled = try await postTalise(
            path: "/api/zk/assemble-signature",
            body: assembleBody
        )
        guard let signature = assembled["signature"] as? String, !signature.isEmpty else {
            throw DirectBroadcastError.assembleFailed(
                (assembled["error"] as? String) ?? "missing signature in response"
            )
        }
        // Refresh the cached proof — same place the legacy path caches
        // it (see ZkLoginCoordinator.signAndSubmitSend, ~line 504-507).
        if let fresh = assembled["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        let assembleMs = Self.msSince(tAssembleStart)

        // 2. Broadcast — direct JSON-RPC to whichever fullnode the
        //    server pointed us at this session (Shinami when an API
        //    key is configured server-side, public Mysten otherwise).
        //    The endpoint's `headers` (e.g. `X-Api-Key` for Shinami)
        //    must be attached verbatim; no Talise bearer/App-Attest.
        let endpoint = await BroadcastConfigCache.current()
        let tBroadcastStart = CFAbsoluteTimeGetCurrent()
        let digest = try await broadcastToFullnode(
            bytesB64: bytesB64,
            signature: signature,
            endpoint: endpoint
        )
        let broadcastMs = Self.msSince(tBroadcastStart)

        // 3. Confirm — fire-and-forget. Tx is on chain; bookkeeping
        //    failures don't unland it. We measure confirm time
        //    OPTIMISTICALLY (the moment we fire the request), not the
        //    response time — by design, we never await it.
        // note: confirmMs is measured at FIRE time, not RESPONSE time.
        // The Task.detached below runs in the background and any error
        // is intentionally swallowed (server-side reconciliation will
        // catch missing digests later).
        let tConfirmFire = CFAbsoluteTimeGetCurrent()
        var confirmBody: [String: Any] = ["digest": digest]
        if let meta { confirmBody["meta"] = meta }
        Task.detached {
            try? await Self.postTaliseFireAndForget(
                path: "/api/send/gasless-confirm",
                body: confirmBody
            )
        }
        let confirmMs = Self.msSince(tConfirmFire)

        return DirectBroadcastResult(
            digest: digest,
            assembleMs: assembleMs,
            broadcastMs: broadcastMs,
            confirmMs: confirmMs,
            provider: endpoint.provider
        )
    }

    // MARK: - Fullnode broadcast

    private static func broadcastToFullnode(
        bytesB64: String,
        signature: String,
        endpoint: BroadcastEndpoint
    ) async throws -> String {
        // JSON-RPC body exactly as documented in the Sui RPC spec for
        // `sui_executeTransactionBlock`. We don't need effects or events
        // — just the digest — so we pass an empty options object.
        //
        // `WaitForLocalExecution` returns once ONE validator has
        // executed the tx (~300–600ms), vs `WaitForEffectsCert` which
        // waits for a ⅔ quorum signature on the effects (~1.5–2.5s).
        // For plain USDsui transfers on stable mainnet, local execution
        // is sufficient — the tx will finalize. The pending-stub
        // registry in HomeView already holds the optimistic row until
        // the canonical activity event lands, so a hypothetical reorg
        // would just re-render the row, not surface as a user-visible
        // failure. The direct-broadcast path is ONLY reached for plain
        // gasless USDsui sends (NAVI / swap go through different
        // routes that retain `WaitForEffectsCert`), so this trade is
        // scoped correctly here.
        let rpcBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sui_executeTransactionBlock",
            "params": [
                bytesB64,
                [signature],
                ["showEffects": true, "showEvents": false] as [String: Any],
                "WaitForLocalExecution",
            ] as [Any],
        ]

        guard let url = URL(string: endpoint.url) else {
            throw DirectBroadcastError.broadcastFailed(
                "bad broadcast URL: \(endpoint.url)"
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Server-issued headers (e.g. `X-Api-Key` for Shinami). Applied
        // verbatim; if the server omits them, the request is just a
        // plain JSON-RPC POST.
        for (k, v) in endpoint.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: rpcBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fullnodeSession.data(for: req)
        } catch {
            throw DirectBroadcastError.broadcastFailed(
                "transport: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw DirectBroadcastError.broadcastFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw DirectBroadcastError.broadcastFailed(msg)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectBroadcastError.broadcastFailed("malformed JSON-RPC response")
        }
        // JSON-RPC error envelope wins over result. Sui fullnodes
        // return 200 OK with an `error` body on a rejected tx
        // (insufficient gas, expired epoch, bad signature, etc.).
        if let err = parsed["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "fullnode error"
            throw DirectBroadcastError.broadcastFailed(msg)
        }
        guard let result = parsed["result"] as? [String: Any],
              let digest = result["digest"] as? String,
              !digest.isEmpty else {
            throw DirectBroadcastError.noDigest
        }
        // MONEY-SAFETY: the JSON-RPC `error` envelope only fires on PRE-execution
        // rejection (bad sig / expired epoch). A tx that is admitted then
        // Move-ABORTS returns 200 with a digest + effects.status.status == "failure".
        // Without checking effects we'd report a phantom "sent" with no funds moved.
        if let effects = result["effects"] as? [String: Any],
           let status = effects["status"] as? [String: Any],
           let s = status["status"] as? String, s != "success" {
            let reason = (status["error"] as? String) ?? "aborted on chain"
            throw DirectBroadcastError.broadcastFailed("transaction failed: \(reason) — no funds moved")
        }
        return digest
    }

    // MARK: - Talise authenticated POST

    /// Mirror of ZkLoginCoordinator.postAuthenticated but raw —
    /// returns `[String: Any]`. Bearer + App Attest headers identical
    /// so the server-side auth gate accepts the call.
    private static func postTalise(
        path: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let bearer = SecureSessionStore.shared.read() else {
            throw DirectBroadcastError.assembleFailed("not signed in")
        }
        guard let url = URL(string: AppConfig.shared.apiBaseURL + path) else {
            throw DirectBroadcastError.assembleFailed("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let payload = try JSONSerialization.data(withJSONObject: body)
        req.httpBody = payload

        let payloadHash = Data(SHA256.hash(data: payload))
        if let assertion = await AppAttestService.shared.assertion(forRequestHash: payloadHash) {
            req.setValue(assertion, forHTTPHeaderField: "X-App-Attest")
        }
        if let keyId = AppAttestService.shared.keyId {
            req.setValue(keyId, forHTTPHeaderField: "X-App-Attest-KeyId")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fullnodeSession.data(for: req)
        } catch {
            throw DirectBroadcastError.assembleFailed(
                "transport: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw DirectBroadcastError.assembleFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let friendly = (parsed["error"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw DirectBroadcastError.assembleFailed(friendly)
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectBroadcastError.assembleFailed("malformed JSON")
        }
        return parsed
    }

    /// Fire-and-forget variant. Identical wire format to `postTalise`
    /// but discards the response — the caller never awaits. Caller
    /// should already have wrapped this in a `Task.detached`.
    private static func postTaliseFireAndForget(
        path: String,
        body: [String: Any]
    ) async throws {
        guard let bearer = SecureSessionStore.shared.read() else { return }
        guard let url = URL(string: AppConfig.shared.apiBaseURL + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let payload = try JSONSerialization.data(withJSONObject: body)
        req.httpBody = payload

        let payloadHash = Data(SHA256.hash(data: payload))
        if let assertion = await AppAttestService.shared.assertion(forRequestHash: payloadHash) {
            req.setValue(assertion, forHTTPHeaderField: "X-App-Attest")
        }
        if let keyId = AppAttestService.shared.keyId {
            req.setValue(keyId, forHTTPHeaderField: "X-App-Attest-KeyId")
        }
        _ = try? await fullnodeSession.data(for: req)
    }

    private static func msSince(_ t: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - t) * 1000.0).rounded())
    }
}
