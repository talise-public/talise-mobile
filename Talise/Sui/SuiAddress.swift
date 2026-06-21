import Foundation

struct SuiAddress: Hashable, CustomStringConvertible {
    let raw: String

    init?(_ raw: String) {
        let trimmed = raw.lowercased()
        guard trimmed.hasPrefix("0x"),
              trimmed.count == 66,
              trimmed.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        self.raw = trimmed
    }

    var short: String {
        guard raw.count > 14 else { return raw }
        return String(raw.prefix(8)) + "…" + String(raw.suffix(6))
    }

    var description: String { raw }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
}

/// USDsui has 6 decimals, SUI has 9. We work in human-readable doubles for
/// display and convert to the on-chain integer at PTB build time.
enum SuiAsset: String {
    case usdsui = "USDsui"
    case sui = "SUI"

    var decimals: Int {
        switch self {
        case .usdsui: return 6
        case .sui: return 9
        }
    }

    func toOnChain(_ amount: Double) -> UInt64 {
        UInt64((amount * pow(10.0, Double(decimals))).rounded())
    }
}
