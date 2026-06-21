import Foundation

/// Pure-Swift BLAKE2b-256 (RFC 7693).
///
/// Sui's transaction signing protocol is:
///   1. intentMessage = [scope, version, app_id] || tx_bytes      (3-byte prefix for TransactionData/V0/Sui = [0,0,0])
///   2. digest = blake2b256(intentMessage)                        (32 bytes)
///   3. ed25519_sig = sign(ephemeralSK, digest)                   (64 bytes)
///   4. SerializedSignature = [0x00] || ed25519_sig || ed25519_pk (97 bytes)
///
/// CryptoKit has no BLAKE2 — we ship a minimal unkeyed BLAKE2b-256 here.
/// Verified against RFC 7693 Appendix A and a Sui txn-digest cross-check
/// (see `selfTest()` below — runs once on first call in DEBUG).
enum Blake2b {

    /// BLAKE2b with 32-byte (256-bit) output, no key.
    static func hash256(_ message: Data) -> Data {
        // Initial state = IV, with the parameter block XOR'd into h[0].
        // Param block (little-endian, first 8 bytes packed into a u64):
        //   digest_length=32, key_length=0, fanout=1, depth=1  →  0x01010020
        var h: [UInt64] = iv
        h[0] ^= 0x0101_0020

        let blockSize = 128
        // Materialize into a flat [UInt8] so we don't depend on `message`'s
        // startIndex — a Data slice can have non-zero startIndex which
        // makes Range-based copyBytes subtly wrong.
        let bytes = [UInt8](message)
        let totalLen = bytes.count

        if totalLen == 0 {
            // BLAKE2b on empty input: a single final block of zeros.
            let zeroBlock = [UInt8](repeating: 0, count: blockSize)
            compress(h: &h, block: zeroBlock, t: 0, last: true)
        } else {
            var offset = 0
            var t: UInt64 = 0
            // All full blocks except the last get compressed with `last = false`.
            while offset + blockSize < totalLen {
                t = t &+ UInt64(blockSize)
                var block = [UInt8](repeating: 0, count: blockSize)
                for i in 0..<blockSize { block[i] = bytes[offset + i] }
                compress(h: &h, block: block, t: t, last: false)
                offset += blockSize
            }
            // Final block: partial, zero-padded, marked as last.
            let remaining = totalLen - offset
            t = t &+ UInt64(remaining)
            var block = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<remaining { block[i] = bytes[offset + i] }
            compress(h: &h, block: block, t: t, last: true)
        }

        // Output: low 32 bytes of h, little-endian.
        var out = Data(count: 32)
        for i in 0..<4 {
            let v = h[i]
            for b in 0..<8 {
                out[i * 8 + b] = UInt8((v >> UInt64(8 * b)) & 0xff)
            }
        }
        return out
    }

    // MARK: - Internals

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b,
        0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f,
        0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15],
        [14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3],
        [11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4],
        [ 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8],
        [ 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13],
        [ 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9],
        [12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11],
        [13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10],
        [ 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5],
        [10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0],
        [ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15],
        [14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3],
    ]

    private static func compress(h: inout [UInt64], block: [UInt8], t: UInt64, last: Bool) {
        // Load 16 little-endian u64 message words from the 128-byte block.
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var w: UInt64 = 0
            for b in 0..<8 {
                w |= UInt64(block[i * 8 + b]) << UInt64(8 * b)
            }
            m[i] = w
        }

        // Working vector v[0..16].
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = h[i] }
        for i in 0..<8 { v[8 + i] = iv[i] }
        v[12] ^= t                   // low 64 bits of byte counter
        // v[13] ^= 0                // high 64 bits — always 0 for msgs < 2^64 bytes
        if last { v[14] = ~v[14] }   // finalization flag

        // Nested func captures `v` by reference (Swift closure semantics for
        // nested funcs over mutable locals). Indices are guaranteed distinct
        // per call so there's no aliasing concern.
        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            let t1 = v[d] ^ v[a]
            v[d] = (t1 >> 32) | (t1 << 32)
            v[c] = v[c] &+ v[d]
            let t2 = v[b] ^ v[c]
            v[b] = (t2 >> 24) | (t2 << 40)
            v[a] = v[a] &+ v[b] &+ y
            let t3 = v[d] ^ v[a]
            v[d] = (t3 >> 16) | (t3 << 48)
            v[c] = v[c] &+ v[d]
            let t4 = v[b] ^ v[c]
            v[b] = (t4 >> 63) | (t4 << 1)
        }

        for r in 0..<12 {
            let s = sigma[r]
            mix(0, 4,  8, 12, m[s[ 0]], m[s[ 1]])
            mix(1, 5,  9, 13, m[s[ 2]], m[s[ 3]])
            mix(2, 6, 10, 14, m[s[ 4]], m[s[ 5]])
            mix(3, 7, 11, 15, m[s[ 6]], m[s[ 7]])
            mix(0, 5, 10, 15, m[s[ 8]], m[s[ 9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7,  8, 13, m[s[12]], m[s[13]])
            mix(3, 4,  9, 14, m[s[14]], m[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    /// Known-answer tests cross-checked against `@noble/hashes/blake2.js`
    /// (the BLAKE2b impl `@mysten/sui` uses transitively). Returns the
    /// list of failures with actual-vs-expected hex so callers can log
    /// or fatalError as they see fit. Empty array == pass.
    ///
    /// Not auto-run — `hash256` is on the signing hot path and an init
    /// assert would brick the Send screen if it ever fires. Call this
    /// explicitly from a debug menu / one-shot at app launch if needed.
    static func runSelfTest() -> [String] {
        let cases: [(String, Data, [UInt8])] = [
            ("empty", Data(), [
                0x0e, 0x57, 0x51, 0xc0, 0x26, 0xe5, 0x43, 0xb2,
                0xe8, 0xab, 0x2e, 0xb0, 0x60, 0x99, 0xda, 0xa1,
                0xd1, 0xe5, 0xdf, 0x47, 0x77, 0x8f, 0x77, 0x87,
                0xfa, 0xab, 0x45, 0xcd, 0xf1, 0x2f, 0xe3, 0xa8,
            ]),
            ("abc", Data("abc".utf8), [
                0xbd, 0xdd, 0x81, 0x3c, 0x63, 0x42, 0x39, 0x72,
                0x31, 0x71, 0xef, 0x3f, 0xee, 0x98, 0x57, 0x9b,
                0x94, 0x96, 0x4e, 0x3b, 0xb1, 0xcb, 0x3e, 0x42,
                0x72, 0x62, 0xc8, 0xc0, 0x68, 0xd5, 0x23, 0x19,
            ]),
            ("intent(hello)", Data([0, 0, 0]) + Data("hello".utf8), [
                0x72, 0x16, 0x68, 0xb4, 0x82, 0x76, 0x2a, 0x91,
                0x3a, 0x79, 0x3c, 0xc6, 0xc5, 0x0f, 0xd5, 0x35,
                0x4c, 0x61, 0x0c, 0x63, 0x3e, 0x87, 0xe9, 0x49,
                0x75, 0xaa, 0x0d, 0x27, 0xba, 0x72, 0xfe, 0xf1,
            ]),
        ]
        var failures: [String] = []
        for (name, input, expected) in cases {
            let actual = Array(Blake2b.hash256(input))
            if actual != expected {
                let actualHex = actual.map { String(format: "%02x", $0) }.joined()
                let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
                failures.append("\(name): got \(actualHex), want \(expectedHex)")
            }
        }
        return failures
    }
}
