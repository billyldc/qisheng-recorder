import Foundation

public struct AppVersion: Comparable, Equatable {
    public let components: [Int]
    public init?(_ raw: String) {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public enum UpdatePolicy {
    public static func canOfferLegacyExitRecovery(version: String, launchedByOldApp: Bool) -> Bool {
        guard launchedByOldApp, let version = AppVersion(version) else { return false }
        return version >= AppVersion("1.2.0")! && version <= AppVersion("1.3.0")!
    }

    public static func validDigest(_ digest: String) -> Bool {
        digest.hasPrefix("sha256:") && digest.count == 71 && digest.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
    }
}
