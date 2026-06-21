import Foundation
import CryptoKit
import SuiGrpcKit

/// Orchestrates the full zkLogin pipeline against the Talise backend.
///
/// Sign-in:
///   1. GoogleSignInService.signIn() → (idToken, jwtRandomness)
///   2. Generate / load ephemeral Curve25519 key
///   3. POST /api/auth/mobile/exchange { idToken, ephemeralPubKeyB64,
///        jwtRandomness, maxEpoch } → { user, bearer, proof, maxEpoch }
///   4. Persist bearer (SecureSessionStore), proof + maxEpoch + randomness
///      (ProofCache), return user
///
/// Sign+submit (sponsored, today):
///   1. Caller hands us PTB bytes (base64)
///   2. POST /api/zk/sponsor { ptbBytesB64, sender } →
///        { txBytes, sponsorSignature }
///   3. Sign txBytes with the ephemeral key (Sui intent prefix + Ed25519)
///   4. Assemble Sui-format SerializedSignature: 0x00 flag + sig + pubkey
///   5. POST /api/zk/sponsor-execute { txBytes, userSignature,
///        sponsorSignature, kind } → { digest }
///
/// The actual zkLoginSignature wrapping (proof + ephemeralSig + jwt
/// metadata) happens server-side in /api/zk/sponsor-execute. iOS only
/// produces the raw Ed25519 part — same pattern as the web app.
@MainActor
final class ZkLoginCoordinator {
    static let shared = ZkLoginCoordinator()
    private init() {}

    /// Dedicated URLSession for the zkLogin pipeline.
    ///
    /// Why not URLSession.shared? Two reasons:
    ///
    /// 1. `URLSession.shared` defaults to a 60s request timeout AND a 7-day
    ///    resource timeout. Setting `URLRequest.timeoutInterval` only governs
    ///    idle, not the total resource window — so when /api/zk/sponsor-execute
    ///    hung (Onara upstream wedge), iOS still waited a full minute before
    ///    surfacing `NSError -1001 "The request timed out."` That's exactly
    ///    what the user just saw.
    ///
    /// 2. Even with an explicit `req.timeoutInterval = 30`, sharing
    ///    URLSession.shared with the rest of the app means a slow proof
    ///    mint sits in the same connection pool as image loads, etc.
    ///
    /// This session caps request=30s (server's outer cap is 25s, so the
    /// server's clean JSON error wins the race) and resource=60s (last
    /// resort safety net). Both are explicit, not implicit.
    private static let zkSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
        ]
        return URLSession(configuration: cfg)
    }()

    struct SignInResult {
        let user: UserDTO
        /// Server-asserted flag from the auth exchange: true when this
        /// Google account already had a Talise user row BEFORE this
        /// sign-in (returning user), false when the exchange just
        /// created it (genuinely new) — or when an older server deploy
        /// didn't send the flag. Use to ENHANCE routing (welcome-back
        /// moment), never as the sole gate.
        let existing: Bool
    }

    struct SignedSubmission {
        let digest: String
        /// Server-blessed Round-up & Save amount attached to this tx
        /// (USD). 0 when round-up is off / not applicable. The Send
        /// success screen uses it for the "You saved" pop.
        var roundupUsd: Double = 0
    }

    enum CoordinatorError: LocalizedError {
        case exchangeFailed(String)
        case sponsorFailed(String)
        case executeFailed(String)
        case noEphemeralKey
        /// 4xx with a structured `code` + hints in the body. Currently
        /// emitted only by `/api/send/sponsor-prepare` returning
        /// `ACCUMULATOR_UNDERFUNDED` — SendFlowView reads `code` to
        /// decide between the consolidation-offer screen and the
        /// regular failure screen.
        case structured(message: String, code: String, hints: [String: Any])

        var errorDescription: String? {
            switch self {
            case .exchangeFailed(let s): return "Sign-in exchange failed: \(s)"
            // The .sponsorFailed name is historical. It carries every
            // send-prepare or sponsor-related error. The SendFailureView
            // already says "Send failed" as the headline; we pass the
            // server's message through verbatim so the user sees their
            // actionable text (e.g. "Top up via Deposit and try again")
            // without a misleading "Sponsorship failed:" prefix on
            // transfers that didn't need sponsorship in the first place.
            case .sponsorFailed(let s): return s
            case .executeFailed(let s): return s
            case .noEphemeralKey: return "Ephemeral key missing."
            case .structured(let m, _, _): return m
            }
        }
    }

    // MARK: - Sign-in

    func signIn() async throws -> SignInResult {
        // 1. Make sure we have an ephemeral key BEFORE OAuth so we can
        //    bind it into the start-state cookie.
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let pubKeyB64 = key.publicKey.rawRepresentation.base64EncodedString()

        // 2. Open the server-mediated OAuth flow. This uses the WEB
        //    GOOGLE_CLIENT_ID + secret so the resulting JWT has the
        //    same `aud` Shinami sees on web — same wallet, same Sui
        //    address. ASWebAuthenticationSession comes back with the
        //    minted mobile bearer via talise://auth/callback.
        let signed = try await GoogleSignInService().signIn(
            ephemeralPubKeyB64: pubKeyB64
        )
        try SecureSessionStore.shared.save(token: signed.bearer)

        // P1-5: kick off App Attest bootstrap immediately after the
        // bearer lands. Best-effort: if the device doesn't support
        // App Attest (sim, dev) the call no-ops; if the network is
        // flaky it'll retry next launch. Sensitive routes that
        // require X-App-Attest will still 401 until this completes
        // at least once, which is the intended behavior.
        Task.detached { [bearer = signed.bearer] in
            try? await AppAttestService.shared.bootstrap(
                bearer: bearer,
                apiBaseURL: AppConfig.shared.apiBaseURL
            )
        }

        // 3. Authoritative user record via /api/me (taliseHandle on
        //    chain, accountType, businessHandle, etc.).
        let me: UserDTO = try await APIClient.shared.get("/api/me")

        // 4. Warm the zkLogin proof so the first send skips Shinami's
        //    cold start. Best-effort; sponsor-execute will mint on
        //    demand if this fails.
        let randomness = SuiRandomness.generate()
        ProofCache.shared.jwtRandomness = randomness
        if let maxEpoch = await fetchMaxEpoch() {
            ProofCache.shared.maxEpoch = maxEpoch
            Task { await warmProof(
                pubKeyB64: pubKeyB64,
                randomness: randomness,
                maxEpoch: maxEpoch
            ) }
        }

        return SignInResult(user: me, existing: signed.existingAccount)
    }

    /// Native Sign in with Apple — mirrors `signIn()` but with the
    /// OAuth leg fully on-device (no ASWebAuthenticationSession).
    ///
    /// Flow:
    ///   1. Ephemeral key + randomness + maxEpoch (same pre-auth setup
    ///      as Google, except WE generate the binding triple — the
    ///      Google flow lets /api/auth/mobile/start do it server-side).
    ///   2. Fetch the zkLogin nonce for that triple (Poseidon hash —
    ///      iOS has no BN254 Poseidon, so the server computes it).
    ///   3. System Apple sheet with `request.nonce = zkNonce`; Apple
    ///      embeds it verbatim into the identity token's `nonce` claim.
    ///   4. POST /api/auth/mobile/exchange { provider: "apple", idToken,
    ///      ephemeralPubKeyB64, maxEpoch, randomness } → { bearer,
    ///      user/userId, proof?, existing }.
    ///   5. Identical post-auth bootstrap to the Google path: bearer →
    ///      Keychain, App Attest kickoff, /api/me, proof warm-up.
    ///
    /// Crucially the (pubKey, maxEpoch, randomness) triple stored in
    /// ProofCache is the SAME one the JWT nonce committed to — the
    /// prover's nonce equality check requires it.
    func signInWithApple() async throws -> SignInResult {
        // 1. Pre-auth binding material.
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let pubKeyB64 = key.publicKey.rawRepresentation.base64EncodedString()
        let randomness = SuiRandomness.generate()
        guard let maxEpoch = await fetchMaxEpoch() else {
            throw CoordinatorError.exchangeFailed("Could not read the current Sui epoch. Check your connection and try again.")
        }

        // 2. zkLogin nonce for the triple.
        let nonce = try await fetchZkNonce(
            ephemeralPubKeyB64: pubKeyB64,
            maxEpoch: maxEpoch,
            randomness: randomness
        )

        // 3. Native Apple sheet. User-cancel surfaces as the shared
        //    GoogleSignInService.SignInError.cancelled, which the
        //    sign-in screens swallow quietly.
        let idToken = try await AppleSignInService().identityToken(nonce: nonce)

        // 4. Exchange the Apple identity token for a mobile bearer.
        let resp = try await postUnauthenticated(
            path: "/api/auth/mobile/exchange",
            body: [
                "provider": "apple",
                "idToken": idToken,
                "ephemeralPubKeyB64": pubKeyB64,
                "maxEpoch": maxEpoch,
                "randomness": randomness,
            ]
        )
        if let err = resp["error"] as? String, !err.isEmpty {
            throw CoordinatorError.exchangeFailed(err)
        }
        // The exchange returns the bearer as `bearer` (current server)
        // — accept `token` too for forward/backward tolerance.
        guard let bearer = (resp["bearer"] as? String) ?? (resp["token"] as? String),
              !bearer.isEmpty else {
            throw CoordinatorError.exchangeFailed("no bearer in exchange response")
        }
        let existing = (resp["existing"] as? Bool) ?? false
        try SecureSessionStore.shared.save(token: bearer)

        // Same App Attest kickoff as the Google path (P1-5).
        Task.detached { [bearer] in
            try? await AppAttestService.shared.bootstrap(
                bearer: bearer,
                apiBaseURL: AppConfig.shared.apiBaseURL
            )
        }

        // 5. Authoritative user record — identical to the Google path.
        let me: UserDTO = try await APIClient.shared.get("/api/me")

        // Proof cache: persist the EXACT triple the JWT nonce bound.
        // If the exchange pre-minted a proof, keep it; otherwise warm
        // one in the background like signIn() does.
        ProofCache.shared.jwtRandomness = randomness
        ProofCache.shared.maxEpoch = maxEpoch
        if let proof = resp["proof"],
           JSONSerialization.isValidJSONObject(proof),
           let proofDict = proof as? [String: Any],
           proofDict["proofPoints"] is [String: Any] {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: proofDict)
        } else {
            Task { await warmProof(
                pubKeyB64: pubKeyB64,
                randomness: randomness,
                maxEpoch: maxEpoch
            ) }
        }

        return SignInResult(user: me, existing: existing)
    }

    /// Server-computed zkLogin nonce for a (ephemeralPubKey, maxEpoch,
    /// randomness) triple. The nonce is `poseidonHash(extEphPubKey,
    /// maxEpoch, randomness)` over BN254 — iOS has no Poseidon
    /// implementation, and `/api/auth/mobile/start` computes it only to
    /// redirect to Google, so the native Apple flow needs it as JSON.
    ///
    /// TODO(server-lane): needs a tiny new endpoint —
    ///   POST /api/auth/mobile/nonce
    ///   body:     { ephemeralPubKeyB64: string (standard base64, 32-byte
    ///               Ed25519 pubkey), maxEpoch: number, randomness: string
    ///               (decimal bigint, same format as /start generates) }
    ///   response: { nonce: string }
    ///   impl:     new Ed25519PublicKey(fromBase64(ephemeralPubKeyB64))
    ///             → generateNonce(pk, maxEpoch, randomness) from
    ///             @mysten/sui/zklogin — the same call /start makes at
    ///             web/app/api/auth/mobile/start/route.ts:107. Pure
    ///             function, no auth needed, rate-limit like /start.
    /// This function already speaks that contract; once the route
    /// exists, no iOS change is needed.
    private func fetchZkNonce(
        ephemeralPubKeyB64: String,
        maxEpoch: Int,
        randomness: String
    ) async throws -> String {
        let resp = try await postUnauthenticated(
            path: "/api/auth/mobile/nonce",
            body: [
                "ephemeralPubKeyB64": ephemeralPubKeyB64,
                "maxEpoch": maxEpoch,
                "randomness": randomness,
            ]
        )
        guard let nonce = resp["nonce"] as? String, !nonce.isEmpty else {
            throw CoordinatorError.exchangeFailed("no nonce in response")
        }
        return nonce
    }

    /// Idempotent warm-up. Called from AppSession.bootstrap so a
    /// returning user (bearer in Keychain, no fresh signIn this launch)
    /// still gets a usable ProofCache before they tap Send.
    ///
    /// Skips if the cache already has BOTH randomness + maxEpoch +
    /// proof bytes. Otherwise mints fresh.
    func ensureProofWarm() async {
        if ProofCache.shared.jwtRandomness != nil,
           ProofCache.shared.maxEpoch != nil,
           ProofCache.shared.proofRaw != nil {
            return
        }
        guard let key = try? EphemeralKeyStore.shared.loadOrCreate() else { return }
        let pubKeyB64 = key.publicKey.rawRepresentation.base64EncodedString()
        let randomness = ProofCache.shared.jwtRandomness ?? SuiRandomness.generate()
        ProofCache.shared.jwtRandomness = randomness
        guard let maxEpoch = await fetchMaxEpoch() else { return }
        ProofCache.shared.maxEpoch = maxEpoch
        await warmProof(
            pubKeyB64: pubKeyB64,
            randomness: randomness,
            maxEpoch: maxEpoch
        )
    }

    /// Best-effort proof pre-mint via /api/zk/proof.
    ///
    /// We DON'T go through APIClient + Codable here because the proof
    /// shape is a nested dict with arrays + objects (issBase64Details,
    /// proofPoints, headerBase64). Routing it through AnyCodable
    /// stringifies the inner JSON — sending that back to the server
    /// makes valibot reject with "Expected object, found string". So
    /// we read the raw JSON, extract the proof dict directly, and
    /// store its byte-identical re-serialization. That preserves the
    /// exact wire shape Shinami emitted.
    private func warmProof(pubKeyB64: String, randomness: String, maxEpoch: Int) async {
        guard let bearer = SecureSessionStore.shared.read() else { return }
        guard let url = URL(string: AppConfig.shared.apiBaseURL + "/api/zk/proof") else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": randomness,
        ])
        req.timeoutInterval = 30
        do {
            let (data, response) = try await Self.zkSession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proof = top["proof"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(proof) else {
                return
            }
            // Byte-identical re-serialization of the dict — no
            // AnyCodable wrapping anywhere in this path.
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: proof)
        } catch {
            // Cold cache — first send pays the Shinami latency. Fine.
        }
    }

    // MARK: - Sign + submit

    /// Sign + sponsor + submit a transaction-kind PTB through the Onara
    /// sponsored gas pipeline. `transactionKindB64` is the base64 of the
    /// PTB built locally (or via SuiKit once integrated) — the iOS app
    /// hands the kind bytes, the backend wraps them in a sponsored
    /// TransactionData with Onara as gas owner, and we sign the result.
    ///
    /// Endpoints used:
    ///   POST /api/zk/sponsor          { transactionKindB64 } → { bytes }
    ///   POST /api/zk/sponsor-execute  { bytesB64, ephemeralPubKeyB64,
    ///                                   maxEpoch, randomness, userSignature,
    ///                                   cachedProof? }       → { digest, ... }
    /// Rewards-accounting metadata. Optional; when set, the server
    /// credits points for the settled tx after Onara confirms
    /// broadcast. The kind/amount come from the iOS call site that
    /// already knows what action it's submitting — Send passes
    /// `("send", amountUsd)`, EarnView passes `("invest", amountUsd)`,
    /// withdraw passes `("withdraw", 0)`, etc.
    struct RewardsMeta {
        let kind: String      // "send" | "invest" | "withdraw" | "roundup" | "goal"
        let amountUsd: Double
        let venue: String?
        /// Phase 2 v2 — when a Send PTB includes a compound NAVI supply
        /// leg for round-up auto-save, this is the round-up amount in
        /// USDsui (server-blessed, returned from /api/send/prepare).
        /// Server credits the round-up points + bumps the savings
        /// tally separately from the send leg. Nil for sends without
        /// round-up enabled or for non-send kinds.
        let roundupUsd: Double?

        init(kind: String, amountUsd: Double, venue: String? = nil, roundupUsd: Double? = nil) {
            self.kind = kind
            self.amountUsd = amountUsd
            self.venue = venue
            self.roundupUsd = roundupUsd
        }
    }

    func signAndSubmit(
        transactionKindB64: String,
        intent: String,
        rewards: RewardsMeta? = nil
    ) async throws -> SignedSubmission {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }

        // 1. Get sponsored tx bytes.
        let sponsor = try await postAuthenticated(
            path: "/api/zk/sponsor",
            body: ["transactionKindB64": transactionKindB64]
        )
        guard let bytesB64 = sponsor["bytes"] as? String,
              let txBytesData = Data(base64Encoded: bytesB64) else {
            throw CoordinatorError.sponsorFailed("malformed sponsor response")
        }

        // 2. Sign the Sui transaction digest with ephemeral Ed25519.
        //    Sui's protocol (matches keypair.signTransaction in @mysten/sui):
        //      digest = blake2b256([0,0,0] || tx_bytes)
        //      sig    = ed25519_sign(ephemeralSK, digest)
        //    Ed25519 itself does an internal SHA-512 round; the BLAKE2b
        //    here is Sui's outer commitment to (intent, tx). Signing the
        //    raw intent message — as iOS used to — produces a signature
        //    the validator rejects with "Invalid signature was given to
        //    the function".
        let intentMessage = Data([0, 0, 0]) + txBytesData
        let digest = Blake2b.hash256(intentMessage)
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digest)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        // Sui SerializedSignature: 0x00 flag (Ed25519) + sig + pubkey
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()
        #if DEBUG
        // One-line diagnostic. Compare against the server-computed digest
        // (lib/zksigner or @mysten/sui's signTransaction) to confirm iOS
        // BLAKE2b agrees byte-for-byte with @noble.
        if AppConfig.shared.verboseConsoleLogging {
            let digestHex = digest.map { String(format: "%02x", $0) }.joined()
            let txLen = txBytesData.count
            print("[zk] sign — txBytes=\(txLen)B digest=\(digestHex) pk=\(pubKeyB64)")
        }
        #endif

        // 3. Hand to /sponsor-execute. Backend assembles zkLoginSignature
        //    (proof + ephemeral sig + jwt metadata), POSTs to Onara,
        //    returns the digest. The optional `meta` block carries the
        //    rewards-accounting hint so the server can credit points
        //    for the settled tx after broadcast.
        var executeBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
        ]
        if let r = rewards {
            var metaDict: [String: Any] = [
                "kind": r.kind,
                "amountUsd": r.amountUsd,
            ]
            if let v = r.venue { metaDict["venue"] = v }
            // Forward the server-blessed round-up amount so sponsor-
            // execute can credit the second leg's points + bump the
            // savings tally. Server validates this against its own
            // recompute (the user can't inflate by lying here — at
            // worst they earn 0 round-up points if the server reads
            // their config as disabled).
            if let ru = r.roundupUsd, ru > 0 { metaDict["roundupUsd"] = ru }
            executeBody["meta"] = metaDict
        }
        // Only forward a CACHED proof if its shape still looks like
        // what Shinami emits. Older builds wrote a stringified-JSON
        // form into the cache (AnyCodable round-trip bug); sending
        // that produces a server-side valibot error ("Expected
        // object, found string"). Dropping it here lets the server
        // mint a fresh one on this call.
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            executeBody["cachedProof"] = proofJSON
        } else {
            // Clean the corrupted bytes so we don't keep trying.
            ProofCache.shared.proofRaw = nil
        }

        let exec = try await postAuthenticated(
            path: "/api/zk/sponsor-execute",
            body: executeBody
        )
        if let err = exec["error"] as? String {
            throw mapExecuteError(err)
        }
        guard let digest = exec["digest"] as? String, !digest.isEmpty else {
            throw CoordinatorError.executeFailed("no digest in response")
        }

        // If the backend minted a fresh proof, cache it so the next send
        // skips the 2-4s Shinami round trip. Defensive type check —
        // Objective-C NSException for non-dict top-level is not catchable.
        if let fresh = exec["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        return SignedSubmission(digest: digest)
    }

    /// On-chain GoalVault op — `create` (mint + optionally fund the vault),
    /// `deposit`, or `withdraw`. Moves REAL USDsui into / out of the goal's
    /// segregated vault (not the DB tracking envelope). Mirrors the Send path:
    ///
    ///   POST /api/goals/vault/prepare { op, goalId, amountUsd, name?, targetUsd? } → { bytes }
    ///   sign(bytes) locally
    ///   POST /api/zk/sponsor-execute  { bytesB64, …, cachedProof? } → { digest }
    ///
    /// The vault prepare route always returns a fully-built SPONSORED tx (Onara
    /// is the gas owner), so there's no gasless branch. The caller records the
    /// result via POST /api/goals/vault/confirm with the returned digest.
    func signAndSubmitGoalVault(
        op: String,
        goalId: String,
        amountUsd: Double,
        name: String? = nil,
        targetUsd: Double? = nil
    ) async throws -> SignedSubmission {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }

        // 1. Build the sponsored PTB server-side.
        var prepareBody: [String: Any] = [
            "op": op,
            "goalId": goalId,
            "amountUsd": amountUsd,
        ]
        if let name { prepareBody["name"] = name }
        if let targetUsd { prepareBody["targetUsd"] = targetUsd }
        let prep = try await postAuthenticated(
            path: "/api/goals/vault/prepare",
            body: prepareBody
        )
        if let serverErr = prep["error"] as? String, !serverErr.isEmpty {
            throw CoordinatorError.sponsorFailed(serverErr)
        }
        guard let bytesB64 = prep["bytes"] as? String,
              let txBytesData = Data(base64Encoded: bytesB64) else {
            throw CoordinatorError.sponsorFailed("malformed vault/prepare response")
        }

        // 2. Sign locally — identical shape to the Send path.
        let intentMessage = Data([0, 0, 0]) + txBytesData
        let digestToSign = Blake2b.hash256(intentMessage)
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digestToSign)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()

        // 3. Execute via the Onara-sponsored rail.
        var executeBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
        ]
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            executeBody["cachedProof"] = proofJSON
        } else {
            ProofCache.shared.proofRaw = nil
        }
        let exec = try await postAuthenticated(
            path: "/api/zk/sponsor-execute",
            body: executeBody
        )
        if let err = exec["error"] as? String { throw mapExecuteError(err) }
        guard let digest = exec["digest"] as? String, !digest.isEmpty else {
            throw CoordinatorError.executeFailed("no digest in response")
        }
        if let fresh = exec["freshProof"], JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        return SignedSubmission(digest: digest)
    }

    /// Combined Send path. Replaces the legacy three-call sequence
    /// (prepare → sponsor → sponsor-execute) with two:
    ///
    ///   POST /api/send/sponsor-prepare { to, amount, asset } → { bytes, roundupUsd }
    ///   sign(bytes) locally
    ///   POST /api/zk/sponsor-execute   { bytesB64, ..., cachedProof? } → { digest }
    ///
    /// One fewer iOS→Vercel round-trip saves ~500–800ms per send. Use
    /// this instead of `signAndSubmit(transactionKindB64:)` for any
    /// Send. The legacy method stays for Earn/Vault flows which still
    /// need the explicit prepare→sponsor split.
    /// `sponsorFallback` lets a send fall back to the Onara-sponsored rail
    /// when the gasless rail can't serve it — instead of failing. Gasless is
    /// still tried FIRST, so a user whose USDsui is already in the
    /// Address-Balance accumulator gets a genuinely free transfer; only when
    /// gasless can't build (the common case: funds in `Coin<USDSUI>` objects)
    /// does it sponsor. Talise-facilitated money-out flows (off-ramp
    /// cash-out, pay-to-bank) set this — they promise a fee-free transfer
    /// ("No network fee — sponsored by Talise") and MUST land regardless of
    /// the user's balance shape. Plain P2P sends leave it false: a gasless
    /// failure stays a hard error (a "free" send must never silently sponsor).
    func signAndSubmitSend(
        to: String,
        amountUsd: Double,
        asset: String = "USDsui",
        intent: String,
        sponsorFallback: Bool = false,
        rewards: RewardsMeta? = nil
    ) async throws -> SignedSubmission {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }

        // 1. Combined build + (sponsor OR gasless decision) in a
        //    single server-side call. The server returns `mode`:
        //      - "gasless"   → submit via /api/send/gasless-submit
        //                       (no Onara, no gas, Sui's
        //                       0x2::coin::send_funds path)
        //      - "sponsored" → submit via /api/zk/sponsor-execute
        //                       (Onara as gas owner, full PaymentKit
        //                       + optional NAVI round-up leg)
        //
        // Per-step timing surfaced as one structured log line at the
        // end (`[ios/send] prepare=Nms sign=Nms execute=Nms total=Nms`).
        // We need this to read END-TO-END latency from the user's
        // perspective — server-side logs miss the iOS→Vercel network
        // hops (cold TLS, route latency, mobile carrier RTT). Uses
        // `CFAbsoluteTimeGetCurrent` (monotonic seconds since 2001
        // epoch — survives wall-clock adjustments mid-flight) so the
        // numbers are stable even if NTP nudges the system clock.
        func msSince(_ t: CFAbsoluteTime) -> Int {
            Int(((CFAbsoluteTimeGetCurrent() - t) * 1000.0).rounded())
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        var prepareBody: [String: Any] = [
            "to": to,
            "amount": amountUsd,
            "asset": asset,
        ]
        // Allow a sponsored fallback for Talise-facilitated money-out flows:
        // try gasless first (free when funds are in the accumulator), and let
        // the server sponsor only when the gasless build can't serve the send
        // (e.g. the user's USDsui is in Coin objects).
        if sponsorFallback { prepareBody["sponsorFallback"] = true }
        let prep = try await postAuthenticated(
            path: "/api/send/sponsor-prepare",
            body: prepareBody
        )
        let tPrepareMs = msSince(t0)
        let tAfterPrepare = CFAbsoluteTimeGetCurrent()
        // Explicit server-error check BEFORE the bytes guard. If
        // postAuthenticated decoded a 2xx body that still contains an
        // `error` field (e.g. ACCUMULATOR_UNDERFUNDED surfaced as 200
        // by a misconfigured route), surface it as sponsorFailed with
        // the server-provided message instead of falling through to a
        // generic "malformed sponsor-prepare response".
        if let serverErr = prep["error"] as? String, !serverErr.isEmpty {
            throw CoordinatorError.sponsorFailed(serverErr)
        }
        guard let bytesB64 = prep["bytes"] as? String,
              let txBytesData = Data(base64Encoded: bytesB64) else {
            throw CoordinatorError.sponsorFailed("malformed sponsor-prepare response")
        }
        let mode = (prep["mode"] as? String) ?? "sponsored"
        // Server-blessed round-up amount, forwarded to sponsor-execute
        // so the rewards engine credits the auto-save leg too. Gasless
        // mode never has round-up (round-up disqualifies gasless).
        let serverRoundupUsd = prep["roundupUsd"] as? Double ?? 0

        // 2. Sign locally — Sui intent prefix + BLAKE2b digest, Ed25519.
        //    Same path as `signAndSubmit`; the bytes shape is identical
        //    (sponsor-prepare runs the same `tx.build(client:)` that
        //    `/api/zk/sponsor` did).
        let intentMessage = Data([0, 0, 0]) + txBytesData
        let digest = Blake2b.hash256(intentMessage)
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digest)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()
        let tSignMs = msSince(tAfterPrepare)
        let tAfterSign = CFAbsoluteTimeGetCurrent()

        // 3. Build the execute body. Merge the server-blessed round-up
        //    into the rewards meta so the second-leg points credit.
        var executeBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
        ]
        if let r = rewards {
            var metaDict: [String: Any] = [
                "kind": r.kind,
                "amountUsd": r.amountUsd,
            ]
            if let v = r.venue { metaDict["venue"] = v }
            // Prefer the server's value (recomputed from the user's
            // current round-up config) over whatever the caller passed.
            let roundup = serverRoundupUsd > 0 ? serverRoundupUsd : (r.roundupUsd ?? 0)
            if roundup > 0 { metaDict["roundupUsd"] = roundup }
            executeBody["meta"] = metaDict
        }
        // Forward a CACHED proof if available + well-shaped. Skipping
        // the prover entirely on send #2+ is the single biggest win
        // once the user has authenticated once.
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            executeBody["cachedProof"] = proofJSON
        } else {
            ProofCache.shared.proofRaw = nil
        }

        // Route by mode. Gasless skips Onara entirely — direct
        // fullnode broadcast via /api/send/gasless-submit. Saves the
        // Onara round-trip (~300-500ms) on plain USDsui sends.
        //
        // When the directBroadcast feature flag is on AND we're in
        // gasless mode, try the new direct-to-fullnode path first:
        // assemble-signature → fullnode → fire-and-forget confirm.
        // Skips one Vercel hop on the execute leg (~250-400ms saved).
        // Any assemble/broadcast failure falls back transparently to
        // the legacy /api/send/gasless-submit path below.
        let cachedProofJSON: [String: Any]? = {
            guard let proofData = ProofCache.shared.proofRaw,
                  let json = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
                  json["proofPoints"] is [String: Any] else { return nil }
            return json
        }()

        if mode == "gasless" && AppConfig.shared.directBroadcastEnabled {
            do {
                let metaForConfirm = executeBody["meta"] as? [String: Any]
                let direct = try await DirectBroadcastSender.send(
                    bytesB64: bytesB64,
                    ephemeralPubKeyB64: pubKeyB64,
                    maxEpoch: maxEpoch,
                    randomness: jwtRandomness,
                    userSignature: userSig,
                    cachedProof: cachedProofJSON,
                    meta: metaForConfirm
                )
                let tTotalMs = msSince(t0)
                // New log shape: assemble/broadcast/confirm replace the
                // single `execute=` field. mode=gasless-direct tells the
                // server-side parser to bucket separately from the
                // legacy gasless rows.
                print(
                    "[ios/send] prepare=\(tPrepareMs)ms sign=\(tSignMs)ms assemble=\(direct.assembleMs)ms broadcast=\(direct.broadcastMs)ms confirm=\(direct.confirmMs)ms total=\(tTotalMs)ms mode=gasless-direct provider=\(direct.provider)"
                )
                _ = intent
                return SignedSubmission(digest: direct.digest, roundupUsd: serverRoundupUsd)
            } catch {
                // Direct-broadcast failed at assemble or broadcast.
                // Log + fall through to the legacy gasless-submit path
                // below so the user's send still lands.
                print("[ios/send] direct-broadcast failed, falling back: \(error)")
            }
        }

        let executePath = mode == "gasless"
            ? "/api/send/gasless-submit"
            : "/api/zk/sponsor-execute"
        let exec = try await postAuthenticated(
            path: executePath,
            body: executeBody
        )
        if let err = exec["error"] as? String {
            throw mapExecuteError(err)
        }
        guard let digestStr = exec["digest"] as? String, !digestStr.isEmpty else {
            throw CoordinatorError.executeFailed("no digest in response")
        }
        if let fresh = exec["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        // Single end-to-end log line per send. Two reasons this used to
        // be invisible in the user's Xcode console:
        //   (1) gated by AppConfig.verboseConsoleLogging which defaults
        //       to false in normal dev builds.
        //   (2) NSLog routes through os_log under iOS 14+ and gets
        //       filtered out of Xcode's default debug console.
        // print() bypasses both and goes straight to stderr, where it
        // shows up next to the matching `[zk] sign — txBytes=...` line
        // (which already uses print at line 302). Cost is one short
        // string per send — negligible.
        let tExecuteMs = msSince(tAfterSign)
        let tTotalMs = msSince(t0)
        print(
            "[ios/send] prepare=\(tPrepareMs)ms sign=\(tSignMs)ms execute=\(tExecuteMs)ms total=\(tTotalMs)ms mode=\(mode)"
        )
        _ = intent // currently unused server-side; kept in signature for parity with signAndSubmit
        return SignedSubmission(digest: digestStr, roundupUsd: serverRoundupUsd)
    }

    /// Result of a one-time accumulator consolidation. `alreadyGasless`
    /// is true when the server found zero `Coin<USDsui>` objects to move
    /// — there was nothing to do, the user is already on the gasless
    /// rail. `digest` will be empty in that case. On a real
    /// consolidation, both `digest` is non-empty and `alreadyGasless` is
    /// false.
    struct ConsolidationResult {
        let digest: String
        let alreadyGasless: Bool
        let coinCount: Int
        let totalMicrosMoved: UInt64
    }

    /// One-time "Enable gasless balance" action. Calls
    /// `/api/wallet/consolidate-prepare` to build an Onara-sponsored PTB
    /// that consolidates every `Coin<USDsui>` object the user holds into
    /// their Address Balance accumulator, signs the bytes locally, then
    /// submits via the regular `/api/zk/sponsor-execute` path with
    /// `meta.kind = "consolidate"`. After this lands, every future
    /// gasless send works for amounts up to the new accumulator total.
    ///
    /// Mirrors `signAndSubmitSend` for the sign+submit dance — only the
    /// prepare endpoint and the meta-kind differ. Onara pays the (~$0.001
    /// SUI) gas; the user pays nothing.
    ///
    /// Idempotent on the server side: a second call after the user is
    /// already fully consolidated returns `alreadyGasless: true` with no
    /// digest. SendFlowView's auto-resubmit treats that as "good, retry
    /// the original send".
    func consolidateToAccumulator(asset: String = "USDsui") async throws -> ConsolidationResult {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }

        // 1. Server builds the PTB + filters out the accumulator-shadow
        //    coin object. Response shape mirrors sponsor-prepare:
        //    `{ bytes, mode: "consolidation", coinCount, totalMicrosMoved }`
        //    or `{ alreadyGasless: true, ... }` on the no-op path.
        let prep = try await postAuthenticated(
            path: "/api/wallet/consolidate-prepare",
            body: ["asset": asset]
        )
        if let alreadyGasless = prep["alreadyGasless"] as? Bool, alreadyGasless {
            return ConsolidationResult(
                digest: "",
                alreadyGasless: true,
                coinCount: 0,
                totalMicrosMoved: 0
            )
        }
        if let serverErr = prep["error"] as? String, !serverErr.isEmpty {
            throw CoordinatorError.sponsorFailed(serverErr)
        }
        guard let bytesB64 = prep["bytes"] as? String,
              let txBytesData = Data(base64Encoded: bytesB64) else {
            throw CoordinatorError.sponsorFailed("malformed consolidate-prepare response")
        }
        let coinCount = (prep["coinCount"] as? Int) ?? 0
        let totalMicrosMoved: UInt64 = {
            if let s = prep["totalMicrosMoved"] as? String, let v = UInt64(s) { return v }
            if let n = prep["totalMicrosMoved"] as? Double { return UInt64(n) }
            return 0
        }()

        // 2. Sign locally — same intent prefix + BLAKE2b + Ed25519 as
        //    every other money-moving leg. Identical to signAndSubmitSend.
        let intentMessage = Data([0, 0, 0]) + txBytesData
        let digest = Blake2b.hash256(intentMessage)
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digest)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()

        // 3. Submit through the regular sponsor-execute pipeline. The
        //    only thing distinguishing this from a send is
        //    `meta.kind = "consolidate"` — the server-side rewards
        //    engine doesn't credit consolidations as transfers (kind is
        //    not in its allowed earn set), and the analytics label
        //    keeps the two flows separate.
        var executeBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
            "meta": ["kind": "consolidate"],
        ]
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            executeBody["cachedProof"] = proofJSON
        } else {
            ProofCache.shared.proofRaw = nil
        }

        let exec = try await postAuthenticated(
            path: "/api/zk/sponsor-execute",
            body: executeBody
        )
        if let err = exec["error"] as? String {
            throw mapExecuteError(err)
        }
        guard let digestStr = exec["digest"] as? String, !digestStr.isEmpty else {
            throw CoordinatorError.executeFailed("no digest in response")
        }
        if let fresh = exec["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        return ConsolidationResult(
            digest: digestStr,
            alreadyGasless: false,
            coinCount: coinCount,
            totalMicrosMoved: totalMicrosMoved
        )
    }

    /// Generic sign-and-execute for ANY pre-built sponsored PTB. Caller
    /// has already POSTed to a `*-prepare` route and received `bytesB64`;
    /// this helper signs locally with the ephemeral Ed25519 key and
    /// forwards to `/api/zk/sponsor-execute` with the caller-supplied
    /// `meta` block (e.g. `["kind": "retarget"]`). Returns the on-chain
    /// digest.
    ///
    /// Used by the Profile RetargetHandleSheet — the existing
    /// `signAndSubmitSend` / `consolidateToAccumulator` paths bake their
    /// own prepare hop in, but the retarget flow already has its own
    /// `/api/handle/retarget` prepare so we only need the sign+submit
    /// half here. Identical signing dance to consolidate: intent prefix
    /// `[0,0,0]` || tx_bytes → BLAKE2b-256 → Ed25519 → SerializedSig.
    func signAndExecuteRaw(
        bytesB64: String,
        meta: [String: Any]
    ) async throws -> String {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }
        guard let txBytesData = Data(base64Encoded: bytesB64) else {
            throw CoordinatorError.sponsorFailed("malformed sponsored bytes")
        }

        let intentMessage = Data([0, 0, 0]) + txBytesData
        let digest = Blake2b.hash256(intentMessage)
        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digest)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()

        var executeBody: [String: Any] = [
            "bytesB64": bytesB64,
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
            "meta": meta,
        ]
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            executeBody["cachedProof"] = proofJSON
        } else {
            ProofCache.shared.proofRaw = nil
        }

        let exec = try await postAuthenticated(
            path: "/api/zk/sponsor-execute",
            body: executeBody
        )
        if let err = exec["error"] as? String {
            throw mapExecuteError(err)
        }
        guard let digestStr = exec["digest"] as? String, !digestStr.isEmpty else {
            throw CoordinatorError.executeFailed("no digest in response")
        }
        if let fresh = exec["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        return digestStr
    }

    /// Single primitive for executing EXTERNALLY-prepared sponsor-ready
    /// bytes through the Onara pipeline. The caller has already POSTed to
    /// some on-chain `*-create` / `reclaim` / `cancel` route and received
    /// sponsor-ready `bytesB64` (the SAME shape `/api/zk/sponsor` returns).
    /// This assembles the user's zkLogin signature EXACTLY like
    /// `signAndSubmitSend` does — reusing the ProofCache `maxEpoch` +
    /// `jwtRandomness`, the intent-prefixed BLAKE2b → Ed25519 sign, and the
    /// POST `/api/zk/sponsor-execute {bytesB64, ephemeralPubKeyB64, maxEpoch,
    /// randomness, userSignature, cachedProof?}` → `{digest}` — and returns
    /// the digest wrapped in `SignedSubmission`.
    ///
    /// Used by the on-chain cheque create + reclaim and the on-chain stream
    /// create + cancel flows: they hand us bytes the backend already built,
    /// we sign and submit, they record the resulting digest.
    ///
    /// `intent` is a human-readable label ("Fund cheque", "Reclaim cheque",
    /// "Start stream", "Cancel stream") forwarded to the per-action log line
    /// for parity with `signAndSubmitSend`; it's not sent over the wire.
    func executeSponsorReady(
        bytesB64: String,
        intent: String,
        rewards: RewardsMeta? = nil
    ) async throws -> SignedSubmission {
        var meta: [String: Any] = [:]
        if let r = rewards {
            meta["kind"] = r.kind
            meta["amountUsd"] = r.amountUsd
            if let v = r.venue { meta["venue"] = v }
            if let ru = r.roundupUsd, ru > 0 { meta["roundupUsd"] = ru }
        }
        let digest = try await signAndExecuteRaw(bytesB64: bytesB64, meta: meta)
        _ = intent // kept for log/analytics parity with signAndSubmitSend
        return SignedSubmission(digest: digest)
    }

    /// Signs an arbitrary UTF-8 string as a Sui PERSONAL MESSAGE and returns
    /// the full, base64 zkLogin signature ready to verify off-chain.
    ///
    /// Used by off-ramp bank-account attestation when the server hands back
    /// an `attestMessage` (a string to sign) rather than a sponsored tx.
    ///
    /// Sui personal-message signing (matches `keypair.signPersonalMessage` in
    /// @mysten/sui):
    ///   bcsMessage   = ULEB128(len) || utf8(message)          (BCS vector<u8>)
    ///   intentMessage = [3, 0, 0] || bcsMessage               (PersonalMessage scope)
    ///   digest       = blake2b256(intentMessage)
    ///   sig          = ed25519_sign(ephemeralSK, digest)
    /// We then POST the ephemeral signature to `/api/zk/assemble-signature`,
    /// which wraps it with the zkLogin proof + JWT metadata and returns the
    /// composite zkLogin signature string.
    func signPersonalMessage(_ message: String) async throws -> String {
        guard let maxEpoch = ProofCache.shared.maxEpoch,
              let jwtRandomness = ProofCache.shared.jwtRandomness else {
            throw CoordinatorError.exchangeFailed("no proof cache — sign in again")
        }

        let messageBytes = Data(message.utf8)
        // BCS vector<u8> = ULEB128 length prefix + raw bytes.
        let bcsMessage = Self.uleb128(messageBytes.count) + messageBytes
        // Personal-message intent scope is [3, 0, 0] (vs [0,0,0] for a tx).
        let intentMessage = Data([3, 0, 0]) + bcsMessage
        let digest = Blake2b.hash256(intentMessage)

        let key = try EphemeralKeyStore.shared.loadOrCreate()
        let rawSig = try key.signature(for: digest)
        let pubKey = key.publicKey.rawRepresentation
        let pubKeyB64 = pubKey.base64EncodedString()
        // Sui SerializedSignature: 0x00 flag (Ed25519) + sig + pubkey.
        let userSig = (Data([0x00]) + rawSig + pubKey).base64EncodedString()

        // The assemble-signature endpoint binds the proof to `bytesB64` — for
        // a personal message we hand it the BCS-encoded message so the server
        // attaches the proof to the exact bytes we signed over.
        var body: [String: Any] = [
            "bytesB64": bcsMessage.base64EncodedString(),
            "ephemeralPubKeyB64": pubKeyB64,
            "maxEpoch": maxEpoch,
            "randomness": jwtRandomness,
            "userSignature": userSig,
        ]
        if let proofData = ProofCache.shared.proofRaw,
           let proofJSON = try? JSONSerialization.jsonObject(with: proofData) as? [String: Any],
           proofJSON["proofPoints"] is [String: Any] {
            body["cachedProof"] = proofJSON
        } else {
            ProofCache.shared.proofRaw = nil
        }

        let resp = try await postAuthenticated(
            path: "/api/zk/assemble-signature",
            body: body
        )
        if let err = resp["error"] as? String {
            throw mapExecuteError(err)
        }
        guard let signature = resp["signature"] as? String, !signature.isEmpty else {
            throw CoordinatorError.executeFailed("no signature in response")
        }
        if let fresh = resp["freshProof"],
           JSONSerialization.isValidJSONObject(fresh) {
            ProofCache.shared.proofRaw = try? JSONSerialization.data(withJSONObject: fresh)
        }
        return signature
    }

    /// Minimal unsigned-LEB128 encoder for a non-negative length. Sui's BCS
    /// prefixes every variable-length collection with its element count this
    /// way. Account numbers + bank names produce messages far below 127 bytes
    /// (one byte), but we encode the general case for safety.
    private static func uleb128(_ value: Int) -> Data {
        var v = UInt(value)
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    // MARK: - Helpers

    /// Fetches the current Sui epoch and returns `epoch + 2` — the standard
    /// zkLogin window (~48 hours). Shinami's prover rejects maxEpoch values
    /// outside this band.
    ///
    /// Two paths in priority order:
    ///   1. Our backend `/api/sui/epoch` (fast, already-warm SuiClient)
    ///   2. Direct mainnet gRPC fallback via `SuiGrpcClient` — so a
    ///      dev-server outage or stale cache doesn't block sign-in. The
    ///      epoch is public chain state; either source returns the same
    ///      value. Sub-plan 5.6 removed the legacy JSON-RPC fallback in
    ///      favour of unconditional gRPC (deployment target is now iOS 18).
    private func fetchMaxEpoch() async -> Int? {
        if let v = await fetchEpochViaBackend() { return v + 2 }
        if let v = await fetchEpochViaMainnetGrpc() { return v + 2 }
        return nil
    }

    /// Direct gRPC fallback to the mainnet fullnode. `SuiGrpcClient` has
    /// an 8s per-request timeout and one built-in retry on transient
    /// failures; if we still got an error here, both attempts failed and
    /// nil bubbles up to the caller, which surfaces a "Sign in again" UX.
    /// Better than crashing.
    private func fetchEpochViaMainnetGrpc() async -> Int? {
        do {
            let epoch = try await SuiGrpcClient.shared.getLatestEpoch()
            return Int(epoch.epoch)
        } catch {
            return nil
        }
    }

    private func fetchEpochViaBackend() async -> Int? {
        struct Response: Decodable { let epoch: String }
        do {
            let r: Response = try await APIClient.shared.get("/api/sui/epoch")
            return Int(r.epoch)
        } catch {
            return nil
        }
    }

    /// Bare JSON POST (no bearer) — used for the sign-in exchange that
    /// produces the bearer.
    private func postUnauthenticated(
        path: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        var url = URL(string: AppConfig.shared.apiBaseURL)!
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, response) = try await Self.zkSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CoordinatorError.exchangeFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw CoordinatorError.exchangeFailed(msg)
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoordinatorError.exchangeFailed("malformed JSON")
        }
        return parsed
    }

    /// Specific error iOS surfaces when the backend returns
    /// `code: session_rebind_required` — older bearer that predates
    /// the Poseidon-nonce binding. SignInView intercepts this and
    /// auto-signs-out so the user just sees a normal re-auth prompt.
    enum SessionError: Error { case rebindRequired }

    /// Map a sponsor-execute / Onara error to the right failure. A zkLogin
    /// PROOF-verification failure ("Groth16 proof verify failed" / "invalid user
    /// signature" / "signature is not valid") means the cached proof no longer
    /// matches the chain — its `maxEpoch` expired or the ephemeral key rotated.
    /// The ONLY fix is re-auth (a new JWT nonce), so we clear the stale proof and
    /// route into the session-rebind path (clean sign-out + "sign in again")
    /// instead of surfacing a cryptic crypto error the user can't act on.
    private func mapExecuteError(_ err: String) -> Error {
        let l = err.lowercased()
        let proofFailure =
            l.contains("groth16") || l.contains("proof verify failed")
            || l.contains("invalid user signature") || l.contains("signature is not valid")
        if proofFailure {
            ProofCache.shared.clear()
            Task { @MainActor in
                NotificationCenter.default.post(name: .taliseSessionExpired, object: nil)
            }
            return SessionError.rebindRequired
        }
        return CoordinatorError.executeFailed(err)
    }

    private func postAuthenticated(
        path: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let bearer = SecureSessionStore.shared.read() else {
            throw CoordinatorError.sponsorFailed("not signed in")
        }
        var url = URL(string: AppConfig.shared.apiBaseURL)!
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        let payload = try JSONSerialization.data(withJSONObject: body)
        req.httpBody = payload
        // 30s here is the OUTER ceiling — the server caps the route at
        // 25s, so a clean JSON `{error, code}` always wins this race.
        req.timeoutInterval = 30
        // Mirror APIClient: attach App Attest assertion + keyId hashed over
        // the exact JSON payload. The web side (/api/zk/sponsor-execute,
        // /api/zk/sponsor) rejects calls missing these headers.
        let payloadHash = Data(SHA256.hash(data: payload))
        if let assertion = await AppAttestService.shared.assertion(forRequestHash: payloadHash) {
            req.setValue(assertion, forHTTPHeaderField: "X-App-Attest")
        }
        if let keyId = AppAttestService.shared.keyId {
            req.setValue(keyId, forHTTPHeaderField: "X-App-Attest-KeyId")
        }
        let (data, response) = try await Self.zkSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CoordinatorError.sponsorFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Detect the special "your session predates the nonce
            // binding" 401 from /api/zk/sponsor-execute. Surface as
            // SessionError.rebindRequired so the UI auto-signs-out.
            if http.statusCode == 401,
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (parsed["code"] as? String) == "session_rebind_required" {
                // Signal the app to sign out cleanly (no "session over" copy).
                await MainActor.run {
                    NotificationCenter.default.post(name: .taliseSessionExpired, object: nil)
                }
                throw SessionError.rebindRequired
            }
            // Surface the server's friendly `error` field rather than
            // dumping the raw JSON envelope into the failure screen.
            // Server routes uniformly respond with
            //   { "error": "<user-facing>", "detail": "<technical>",
            //     "code": "<TOKEN>" }
            // on every 4xx/5xx — we only want the first field for UX.
            // Fallback to the raw body if parsing fails or no `error`
            // is present (defense in depth, never blank).
            let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let friendly = (parsed["error"] as? String) ?? ""
            // NEVER surface a raw non-JSON body as the error — a 404/500 returns
            // the app's HTML page, which previously dumped the entire HTML
            // document into the UI. Use the server's `error` field, else a clean
            // status line.
            let msg = friendly.isEmpty ? "HTTP \(http.statusCode)" : friendly
            // Always carry a code so callers can branch on the failure: prefer
            // the server's structured code (e.g. ACCUMULATOR_UNDERFUNDED), else
            // synthesize one from the status (e.g. HTTP_404) so a missing /
            // not-yet-deployed endpoint can be handled gracefully rather than
            // shown as a hard error.
            let code = (parsed["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "HTTP_\(http.statusCode)"
            throw CoordinatorError.structured(message: msg, code: code, hints: parsed)
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoordinatorError.sponsorFailed("malformed JSON")
        }
        return parsed
    }

    private func parseUser(_ json: [String: Any]) throws -> UserDTO {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(UserDTO.self, from: data)
    }
}

/// Keychain-backed cache for the per-session zkLogin proof + metadata
/// the server needs to assemble a SerializedSignature on every
/// sponsor-execute.
///
/// Previously in-memory only — meant the cache evaporated on every cold
/// start. Users who relaunched the app between actions hit
/// "no proof cache — sign in again" on the next Send, even though
/// they were still signed in. Now we persist a small blob (JSON of
/// maxEpoch + randomness + proof) under a Keychain item with the
/// same accessibility as the bearer, so it survives relaunches but
/// stays per-device.
@MainActor
final class ProofCache {
    static let shared = ProofCache()
    private init() { hydrate() }

    var maxEpoch: Int? {
        didSet { persist() }
    }
    var jwtRandomness: String? {
        didSet { persist() }
    }
    var proofRaw: Data? {
        didSet { persist() }
    }

    func clear() {
        maxEpoch = nil
        jwtRandomness = nil
        proofRaw = nil
        wipe()
    }

    // MARK: - Keychain backing

    private let service = "io.talise.app.proof-cache"
    private let account = "v1"

    private struct Snapshot: Codable {
        let maxEpoch: Int?
        let jwtRandomness: String?
        let proofRaw: Data?
    }

    private func hydrate() {
        guard let data = readKeychain(),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        // Bypass didSet by writing the snapshot atomically without
        // re-triggering persist() three times in a row.
        let alreadyHydrated = (maxEpoch ?? -1) == (snap.maxEpoch ?? -2)
        if alreadyHydrated { return }
        maxEpoch = snap.maxEpoch
        jwtRandomness = snap.jwtRandomness
        proofRaw = snap.proofRaw
    }

    private func persist() {
        let snap = Snapshot(
            maxEpoch: maxEpoch,
            jwtRandomness: jwtRandomness,
            proofRaw: proofRaw
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        writeKeychain(data)
    }

    private func writeKeychain(_ data: Data) {
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(delete as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private func readKeychain() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private func wipe() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
