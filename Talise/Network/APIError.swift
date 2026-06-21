import Foundation

enum APIError: Error, LocalizedError {
    case transport(Error)
    case decode(Error, body: String)
    case status(Int, message: String?)
    case unauthorized
    case noSession
    case pinningFailed
    case invalidResponse
    /// The underlying URLSession task was cancelled (NSURLErrorCancelled
    /// / -999). Almost always means SwiftUI tore down a prior `.task`
    /// while a refresh kicked off a fresh one. NOT a real failure —
    /// call sites should silently no-op via `APIError.isCancellation`.
    case cancelled

    /// True when `error` represents a transport-level cancellation —
    /// either Swift's `CancellationError`, NSURLErrorCancelled, or our
    /// own `.cancelled` case. Centralized so every call site can use
    /// the same predicate instead of re-implementing the NSError dance.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case APIError.cancelled = error { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    var errorDescription: String? {
        switch self {
        case .transport(let e):
            return "Network: \(e.localizedDescription)"
        case .decode(_, let body):
            // Best-effort hint: if the body is a Talise-shaped JSON
            // error (`{"error":"…"}`), surface the inner message so
            // the UI is actually debuggable. Otherwise fall back to a
            // truncated raw snippet, with HTML and overly-long bodies
            // suppressed via `safeMessage`. The full `error` + `body`
            // remain in the case payload for the caller's log.
            if let hint = Self.safeMessage(body) {
                return "Couldn't read response: \(hint)"
            }
            return "Couldn't read response from server."
        case .status(let code, let msg):
            // Same protection here. If the server returned HTML (Next.js
            // 404 page, etc.), the msg field carries it — strip anything
            // that looks like markup before showing to the user.
            if let safe = msg.flatMap(Self.safeMessage) {
                return "HTTP \(code): \(safe)"
            }
            return "HTTP \(code)"
        case .unauthorized:
            return "Session expired. Sign in again."
        case .noSession:
            return "Not signed in."
        case .pinningFailed:
            return "Server identity could not be verified."
        case .invalidResponse:
            return "Unexpected response from server."
        case .cancelled:
            return "Request was cancelled."
        }
    }

    /// Honest fallback for the GENERIC catch in money flows — translate the
    /// real underlying error into a short, true reason instead of a blanket
    /// "couldn't do it right now" line. Inspects the error's text for the
    /// known failure modes (gas sponsor exhausted / insufficient balance) and
    /// otherwise surfaces a trimmed real message (never an HTML/stack blob).
    ///
    /// Pass `fallback` for the rare case the message is unusable (HTML page,
    /// empty, or a giant blob) so each call site keeps its own neutral copy.
    static func honestMoneyError(_ error: Error, fallback: String) -> String {
        let raw = (error.localizedDescription.isEmpty
            ? "\(error)"
            : error.localizedDescription)
        let lower = raw.lowercased()

        // Gas sponsor / Onara budget exhausted, or upstream gas station down.
        if lower.contains("gas") || lower.contains("sponsor")
            || lower.contains("insufficient gas") || lower.contains("no_healthy_upstream")
            || lower.contains("budget") {
            return "Payments are briefly paused — please try again in a moment."
        }
        // Wallet balance — only when it's NOT a gas message (handled above).
        if lower.contains("balance") || lower.contains("insufficient") {
            return "You don't have enough USDsui for this."
        }
        // Otherwise: a trimmed, true message — never markup or a stack blob.
        if let safe = safeMessage(raw), safe.count <= 120 {
            return safe
        }
        if !raw.isEmpty, !lower.hasPrefix("<"), raw.count <= 120 {
            return raw
        }
        return fallback
    }

    private static func safeMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anything starting with markup is almost certainly a 404 page.
        if trimmed.hasPrefix("<") { return nil }
        // Extract `error` field from `{"error": "…"}` so the UI shows a
        // clean sentence instead of raw JSON. Falls through to the
        // verbatim path on parse failure.
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (parsed["error"] as? String) ?? (parsed["message"] as? String),
           !inner.isEmpty {
            return clip(inner)
        }
        return clip(trimmed)
    }

    private static func clip(_ s: String) -> String? {
        if s.isEmpty { return nil }
        if s.count > 140 { return String(s.prefix(137)) + "…" }
        return s
    }
}
