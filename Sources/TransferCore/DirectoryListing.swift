import Foundation

/// A complete listing of one folder, from a session's listing of every entry.
public struct DirectoryListing: Sendable {
    public static let defaultLimit = 100_000
    public static let defaultBufferSize = 256 * 1024

    public struct Entry: Sendable {
        /// The raw values are the catalog's `kind` column.
        public enum Kind: Int, Sendable { case folder = 1, file = 2 }

        /// Compare with `utf8`: `==` on `String` treats NFC and NFD forms as equal.
        public let name: String
        public let key: NameKey
        public let kind: Kind
        /// 0 for folders.
        public let size: Int64
        public let mtimeNs: Int64
        public let ctimeNs: Int64
        /// ATTR_CMN_FILEID: evidence only, never a key.
        public let fileID: UInt64

        init(name: String, kind: Kind, size: Int64, mtimeNs: Int64, ctimeNs: Int64, fileID: UInt64) {
            self.name = name
            key = NameKey(name)
            self.kind = kind
            self.size = size
            self.mtimeNs = mtimeNs
            self.ctimeNs = ctimeNs
            self.fileID = fileID
        }
    }

    /// Its attributes couldn't be read, so `reconcile` leaves its live row, if any, as it is.
    public struct Unreadable: Sendable {
        public let name: String
        public let key: NameKey
        /// The ATTR_CMN_ERROR errno, or ENOATTR when a needed attribute came back invalid.
        public let error: Int32

        init(name: String, error: Int32) {
            self.name = name
            key = NameKey(name)
            self.error = error
        }
    }

    public enum Candidate: Sendable {
        case entry(Entry), unreadable(Unreadable)

        public var name: String {
            switch self {
            case .entry(let entry): entry.name
            case .unreadable(let entry): entry.name
            }
        }

        public var key: NameKey {
            switch self {
            case .entry(let entry): entry.key
            case .unreadable(let entry): entry.key
            }
        }
    }

    public struct Skipped: Equatable, Sendable {
        public internal(set) var otherKinds = 0
        public internal(set) var invalidNames = 0
        public internal(set) var collisions = 0
    }

    /// Keys are unique across `entries` and `unreadable`. Every list is in name-byte order.
    public let entries: [Entry]
    public let unreadable: [Unreadable]
    /// Names whose key an earlier name has; kept, because a live row may hold one of them.
    public let collisionLosers: [Candidate]
    public let skipped: Skipped
    public let openDuration: Duration
    public let bulkDuration: Duration
    public let bulkCalls: Int

    enum Parsed {
        case entry(Entry), unreadable(Unreadable), otherKind, invalidName
    }

    public init(smbEntries: [RenameDirectoryEntry], openDuration: Duration, bulkDuration: Duration, bulkCalls: Int) throws {
        let parsed = try smbEntries.map { entry -> Parsed in
            guard RelativePath.isValidComponent(entry.name) else { return .invalidName }
            guard let kind = entry.kind else { return .otherKind }
            let fingerprint = try entry.fingerprint
            return .entry(Entry(name: entry.name, kind: kind == .file ? .file : .folder,
                size: fingerprint.size, mtimeNs: fingerprint.mtimeNs, ctimeNs: fingerprint.ctimeNs,
                fileID: entry.identity.fileID))
        }
        self.init(parsed, openDuration: openDuration, bulkDuration: bulkDuration, bulkCalls: bulkCalls)
    }

    init(_ parsed: [Parsed], openDuration: Duration = .zero, bulkDuration: Duration = .zero, bulkCalls: Int = 0) {
        self.openDuration = openDuration
        self.bulkDuration = bulkDuration
        self.bulkCalls = bulkCalls
        var skipped = Skipped()
        var candidates: [Candidate] = []
        for item in parsed {
            switch item {
            case .entry(let entry): candidates.append(.entry(entry))
            case .unreadable(let entry): candidates.append(.unreadable(entry))
            case .otherKind: skipped.otherKinds += 1
            case .invalidName: skipped.invalidNames += 1
            }
        }
        // The listing order is unspecified; byte order makes the first name of a key stable.
        candidates.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        var keys = Set<NameKey>()
        var entries: [Entry] = []
        var unreadable: [Unreadable] = []
        var collisionLosers: [Candidate] = []
        for candidate in candidates {
            guard keys.insert(candidate.key).inserted else {
                skipped.collisions += 1
                collisionLosers.append(candidate)
                continue
            }
            switch candidate {
            case .entry(let entry): entries.append(entry)
            case .unreadable(let entry): unreadable.append(entry)
            }
        }
        self.entries = entries
        self.unreadable = unreadable
        self.collisionLosers = collisionLosers
        self.skipped = skipped
    }
}
