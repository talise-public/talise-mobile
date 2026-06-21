import Foundation
import DeviceCheck
import CryptoKit

/// App Attest gives the backend a hardware-attested guarantee that a request
/// originated from our App Store binary on a real Apple device. Without it,
/// anyone with the bearer token can replay requests from a Mac or a script.
///
/// Lifecycle:
/// 1. On first launch we call `bootstrap()` which generates a per-install
///    attestation key, ships it to /api/auth/attest/register with the
///    attestation object, and persists the keyId locally.
/// 2. On every API call we call `attest(requestHash:)` which produces an
///    assertion. The backend verifies the assertion + counter and rejects
///    replays.
///
/// In dev / simulator: `DCAppAttestService.isSupported` is false. The
/// `APIClient` skips the header in that case; backend allows missing header
/// when `TALISE_ATTEST_REQUIRED=0`.
@MainActor
final class AppAttestService {
    static let shared = AppAttestService()
    private init() {}

    private let service = DCAppAttestService.shared
    private let storage = UserDefaults.standard
    private let keyIdKey = "io.talise.app.attest.keyId"

    var keyId: String? {
        storage.string(forKey: keyIdKey)
    }

    var isSupported: Bool {
        service.isSupported
    }

    /// One-shot bootstrap. Idempotent — safe to call on every cold start.
    func bootstrap(bearer: String, apiBaseURL: String) async throws {
        guard service.isSupported else { return }
        if keyId != nil { return }

        let keyId = try await service.generateKey()
        let challenge = try await fetchChallenge(bearer: bearer, apiBaseURL: apiBaseURL)
        let hash = Data(SHA256.hash(data: challenge))
        let attestation = try await service.attestKey(keyId, clientDataHash: hash)
        try await registerAttestation(
            bearer: bearer,
            apiBaseURL: apiBaseURL,
            keyId: keyId,
            attestation: attestation,
            challenge: challenge
        )
        storage.set(keyId, forKey: keyIdKey)
    }

    /// Returns base64 assertion to attach as `X-App-Attest` header.
    func assertion(forRequestHash hash: Data) async -> String? {
        guard service.isSupported, let keyId else { return nil }
        do {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
            return assertion.base64EncodedString()
        } catch {
            return nil
        }
    }

    private func fetchChallenge(bearer: String, apiBaseURL: String) async throws -> Data {
        var req = URLRequest(url: URL(string: apiBaseURL + "/api/auth/attest/challenge")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let challenge: String }
        let parsed = try JSONDecoder().decode(R.self, from: data)
        guard let raw = Data(base64Encoded: parsed.challenge) else {
            throw NSError(domain: "attest", code: -1)
        }
        return raw
    }

    private func registerAttestation(
        bearer: String,
        apiBaseURL: String,
        keyId: String,
        attestation: Data,
        challenge: Data
    ) async throws {
        var req = URLRequest(url: URL(string: apiBaseURL + "/api/auth/attest/register")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "attest.register", code: -2)
        }
    }
}
