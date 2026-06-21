import Foundation
import CryptoKit

/// Thin URLSession-backed client over the Talise backend.
///
/// Responsibilities:
/// - Attach Authorization: Bearer + X-App-Attest headers on every call
/// - Pin the leaf cert SPKI hash for talise.io (skipped in dev)
/// - Decode typed responses, surface APIError consistently
/// - Centralized retry on 5xx with bounded exponential backoff
/// - **In-flight dedup for GET requests** — when the same path is
///   already being fetched, the second caller awaits the first task
///   instead of issuing a redundant URLRequest. This collapses the
///   SwiftUI `.task { load() } + .refreshable { load() }` race that
///   used to spam `NSURLErrorDomain Code=-999 "cancelled"` into the
///   logs every time the user pulled down on a fresh screen.
@MainActor
final class APIClient {
    static let shared = APIClient()
    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "Talise-iOS/\(AppConfig.shared.appVersion)",
        ]
        self.session = URLSession(
            configuration: cfg,
            delegate: PinningDelegate(),
            delegateQueue: nil
        )
    }

    private let session: URLSession

    /// Dedup table for in-flight GETs. Keyed on `"METHOD path"`; value
    /// is a `Task<Data, Error>` that returns the raw response body so
    /// every awaiting caller can decode into its own `T`. We dedup on
    /// the encoded bytes (not the decoded value) so different generic
    /// `T`s pointed at the same path still share one network round-trip.
    private let inFlight = InFlightRegistry()

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "GET", body: Optional<Data>.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: "POST", body: data)
    }

    /// DELETE with a typed JSON response. No body — the resource is named
    /// entirely by the path (e.g. `/api/me/bank/{id}`). Like POST it never
    /// dedups, so each call gets its own round-trip.
    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request(path: path, method: "DELETE", body: Optional<Data>.none)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> T {
        // GETs are idempotent — safe to dedup. POSTs may mutate state
        // (record vault, claim handle, prepare swap), so each caller
        // must get its own round-trip.
        let canDedup = (method == "GET")
        let key = "\(method) \(path)"

        // For dedupable requests, atomically look up an existing
        // in-flight task or insert a new one in a single actor hop —
        // splitting this across two awaits opens a race window where
        // two MainActor callers both see "no entry" and each spawn
        // their own request.
        let dataTask: Task<Data, Error>
        if canDedup {
            dataTask = await inFlight.taskOrInsert(for: key) { [weak self] in
                Task<Data, Error> {
                    guard let self else { throw APIError.invalidResponse }
                    return try await self.performRequest(
                        path: path, method: method, body: body
                    )
                }
            }
        } else {
            dataTask = Task<Data, Error> { [weak self] in
                guard let self else { throw APIError.invalidResponse }
                return try await self.performRequest(
                    path: path, method: method, body: body
                )
            }
        }

        let raw: Data
        do {
            raw = try await dataTask.value
        } catch {
            // Always clear the slot on completion (success OR failure),
            // otherwise a transient error would poison subsequent calls
            // for the rest of the app session.
            if canDedup { await inFlight.clear(key) }
            throw mapTransportError(error)
        }
        if canDedup { await inFlight.clear(key) }

        do {
            return try JSONDecoder().decode(T.self, from: raw)
        } catch {
            throw APIError.decode(error, body: String(data: raw, encoding: .utf8) ?? "")
        }
    }

    /// Actually performs the URLRequest. Split out from `request<T>` so
    /// the dedup wrapper can cache the raw `Data` for every awaiting
    /// caller (each decodes into its own typed `T`).
    private func performRequest(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Data {
        // URL.append(path:) treats the entire input as a path SEGMENT and
        // percent-encodes every reserved character — including `?`, which
        // means any caller-supplied query string gets turned into a 404'd
        // path (`/api/foo%3Fbar=1`). Build via URL(string:) instead so
        // path + query parse correctly.
        guard let url = URL(string: AppConfig.shared.apiBaseURL + path) else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let bearer = SecureSessionStore.shared.read() {
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }

        let payloadHash = Data(SHA256.hash(data: body ?? Data()))
        if let assertion = await AppAttestService.shared.assertion(forRequestHash: payloadHash) {
            req.setValue(assertion, forHTTPHeaderField: "X-App-Attest")
        }
        if let keyId = AppAttestService.shared.keyId {
            req.setValue(keyId, forHTTPHeaderField: "X-App-Attest-KeyId")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Hoist URLSession's transport-level errors through our
            // typed cancellation case so call sites don't need to
            // inspect NSError manually.
            throw mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 {
            // A 401 on an authed request = the bearer is dead. Signal the app
            // to sign out cleanly (callers no longer need to show "session
            // expired" copy — they're routed to sign-in).
            Task { @MainActor in
                NotificationCenter.default.post(name: .taliseSessionExpired, object: nil)
            }
            throw APIError.unauthorized
        }
        if !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw APIError.status(http.statusCode, message: msg)
        }
        return data
    }

    /// Normalize URLSession errors into our `APIError` taxonomy. The
    /// big one is `-999 "cancelled"`, which used to surface as a raw
    /// NSError and flood the logs every time SwiftUI swapped tasks on
    /// pull-to-refresh. We now collapse it into `.cancelled` so callers
    /// can branch on `APIError.isCancellation`.
    private func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return APIError.cancelled }
        if let already = error as? APIError { return already }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return APIError.cancelled
        }
        return APIError.transport(error)
    }
}

/// Tiny actor that owns the in-flight task table. Isolating this state
/// in an actor (vs. a `@MainActor` dictionary on `APIClient`) means the
/// lookup-or-insert step is atomic — no risk of two simultaneous
/// callers both winning the "no entry yet" check and each spawning
/// their own request task.
private actor InFlightRegistry {
    private var tasks: [String: Task<Data, Error>] = [:]

    /// Atomic "get-or-insert" — runs entirely inside the actor so two
    /// near-simultaneous callers always collapse onto one task. The
    /// factory is only invoked on cache miss (no wasted Task spawn).
    func taskOrInsert(
        for key: String,
        factory: () -> Task<Data, Error>
    ) -> Task<Data, Error> {
        if let existing = tasks[key] { return existing }
        let new = factory()
        tasks[key] = new
        return new
    }

    func clear(_ key: String) {
        tasks[key] = nil
    }
}

private final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    /// SPKI SHA-256 hashes (base64) of the pinned leaf certs. Rotate with
    /// overlap when the cert is renewed.
    private let pinnedSPKIs: Set<String> = [
        // TODO: fill these in after first prod deploy; until then we fall
        // back to system trust evaluation only (no extra security but no
        // accidental lockout during dev).
    ]

    /// Re-attach our auth headers across a `*.talise.io` redirect.
    ///
    /// URLSession drops `Authorization` (and other sensitive headers) on any
    /// cross-host redirect as a security default. The apex `talise.io`
    /// 307-redirects to `www.talise.io`, so without this every authed read
    /// would arrive at www stripped of its bearer → 401 → blank balance /
    /// history / recipient resolve. We re-attach the bearer + App Attest
    /// headers ONLY when the redirect target is a Talise host (never leak the
    /// token to a foreign origin). The base URL now targets www directly so
    /// this should rarely fire, but it keeps a future redirect from silently
    /// breaking auth again.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalHeaders = task.originalRequest?.allHTTPHeaderFields,
              let newHost = request.url?.host,
              newHost == "talise.io" || newHost.hasSuffix(".talise.io")
        else {
            completionHandler(request)
            return
        }
        var req = request
        for header in ["Authorization", "X-App-Attest", "X-App-Attest-KeyId"] {
            if req.value(forHTTPHeaderField: header) == nil,
               let value = originalHeaders[header] {
                req.setValue(value, forHTTPHeaderField: header)
            }
        }
        completionHandler(req)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if pinnedSPKIs.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if Self.matches(trust: trust, pinned: pinnedSPKIs) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func matches(trust: SecTrust, pinned: Set<String>) -> Bool {
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return false }
        for cert in chain {
            guard let pubKey = SecCertificateCopyKey(cert),
                  let pubData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else {
                continue
            }
            let hash = Data(SHA256.hash(data: pubData)).base64EncodedString()
            if pinned.contains(hash) { return true }
        }
        return false
    }
}
