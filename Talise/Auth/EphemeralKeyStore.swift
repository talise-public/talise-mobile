import Foundation
import CryptoKit
import Security

/// Manages the zkLogin ephemeral keypair.
///
/// **Why not Secure Enclave**: zkLogin signatures must be **Ed25519** (sig
/// scheme flag 0x00). Secure Enclave only supports P-256, and `SecKeyCreateRandomKey`
/// for SE keys is rejected outright on iOS Simulator
/// (`com.apple.LocalAuthentication / -1020: not supported on iOS Simulator`).
/// So we use `Curve25519.Signing.PrivateKey` from CryptoKit and persist the
/// 32-byte raw representation in Keychain.
///
/// The Keychain item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// — readable after the user unlocks the phone the first time post-boot,
/// but never leaves the device and never syncs to iCloud. Biometric
/// confirmation on individual signatures happens at the UI layer (Face ID
/// prompts before `signAndSubmit`), not at every Keychain read.
@MainActor
final class EphemeralKeyStore {
    static let shared = EphemeralKeyStore()
    private init() {}

    private let service = "io.talise.app.zklogin.ephemeral"
    private let account = "v1"

    enum KeyError: Error {
        case keychainWrite(OSStatus)
        case keychainRead(OSStatus)
        case keyDecode
    }

    /// Returns the current keypair, creating + persisting one on first call.
    func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let raw = readRaw(),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let new = Curve25519.Signing.PrivateKey()
        try writeRaw(new.rawRepresentation)
        return new
    }

    /// 32-byte raw Ed25519 public key, base64-encoded — what the backend
    /// expects in `ephemeralPubKeyB64`.
    func publicKeyB64() throws -> String {
        try loadOrCreate().publicKey.rawRepresentation.base64EncodedString()
    }

    /// Sign raw bytes with the current ephemeral Ed25519 key.
    /// Caller is responsible for prepending the Sui intent prefix
    /// (`Data([0, 0, 0])`) before the tx bytes.
    func sign(_ payload: Data) throws -> Data {
        try loadOrCreate().signature(for: payload)
    }

    func wipe() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Keychain primitives

    private func writeRaw(_ data: Data) throws {
        // Delete-then-insert is the simplest way to upsert in Keychain.
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
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychainWrite(status) }
    }

    private func readRaw() -> Data? {
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
}

/// Generates a 16-byte big-endian decimal string for zkLogin randomness +
/// salt. Sui's zkLogin requires values that fit in the BN254 scalar field,
/// and Mysten's prover specifically wants a base-10 string.
enum SuiRandomness {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytesToDecimalString(bytes)
    }

    static func bytesToDecimalString(_ bytes: [UInt8]) -> String {
        var digits = bytes
        var result = ""
        while !digits.allSatisfy({ $0 == 0 }) {
            var remainder: UInt32 = 0
            for i in 0..<digits.count {
                let current = (UInt32(remainder) << 8) | UInt32(digits[i])
                digits[i] = UInt8(current / 10)
                remainder = current % 10
            }
            result = "\(remainder)" + result
        }
        return result.isEmpty ? "0" : result
    }
}
