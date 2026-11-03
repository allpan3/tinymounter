import Foundation

/// A validated path below a location folder. The empty path is the location folder itself.
public struct RelativePath: Hashable, Sendable {
    public static let maxComponentBytes = 255
    public static let maxBytes = 1023
    public static let root = RelativePath(validated: "")
    private static let slash = UInt8(ascii: "/")

    public let string: String

    private init(validated string: String) { self.string = string }

    public init?(_ string: String) {
        guard string.utf8.count <= Self.maxBytes else { return nil }
        // Split on bytes: a combining mark after "/" would hide it inside one Character.
        guard string.isEmpty || string.utf8.split(separator: Self.slash, omittingEmptySubsequences: false)
            .allSatisfy(Self.isValid) else { return nil }
        self.string = string
    }

    public static func isValidComponent(_ name: String) -> Bool { isValid(name.utf8[...]) }

    private static func isValid(_ bytes: Substring.UTF8View) -> Bool {
        !bytes.isEmpty && bytes.count <= maxComponentBytes && !bytes.elementsEqual(".".utf8)
            && !bytes.elementsEqual("..".utf8) && !bytes.contains(0) && !bytes.contains(slash)
    }

    public var isRoot: Bool { string.isEmpty }

    public var components: [String] {
        string.utf8.split(separator: Self.slash).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `other` below this path; nil past `maxBytes`.
    public func appending(_ other: RelativePath) -> RelativePath? {
        guard !isRoot, !other.isRoot else { return isRoot ? other : self }
        let joined = string + "/" + other.string
        return joined.utf8.count <= Self.maxBytes ? RelativePath(validated: joined) : nil
    }

    public func appending(_ component: String) -> RelativePath? {
        guard Self.isValidComponent(component) else { return nil }
        let joined = isRoot ? component : string + "/" + component
        return joined.utf8.count <= Self.maxBytes ? RelativePath(validated: joined) : nil
    }
}

/// Names with one key are one item, as on APFS, except that APFS also folds U+1C80 to U+1C88.
public struct NameKey: Hashable, Sendable {
    public let value: String

    public init(_ name: String) {
        // NFD first so folding sees marks such as U+0345; NFC last, as the catalog compares bytes.
        value = name.decomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}

/// Names as SMB clients send them: composed (NFC), as the macOS and Windows clients do. The macOS
/// client shows names decomposed, so its mount and the server can spell one name differently.
public enum SMBName {
    /// Equal for two spellings exactly when a client sends the same bytes for both.
    public static func key(_ name: String) -> Data { Data(name.precomposedStringWithCanonicalMapping.utf8) }

    /// Case-sensitive, unlike `NameKey`; only the normalization may differ.
    public static func same(_ lhs: String, _ rhs: String) -> Bool { key(lhs) == key(rhs) }
}
