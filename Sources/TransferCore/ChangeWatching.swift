import Foundation

// The pure parts of change watching (docs/architecture.md §7, "Change watching").

/// One SMB2 CHANGE_NOTIFY completion: MS-SMB2 2.2.36 with MS-FSCC 2.4.42 entries.
public enum SMBNotifyCompletion: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// FILE_ACTION_ADDED (1) to FILE_ACTION_RENAMED_NEW_NAME (5), or a stream action.
        public let action: UInt32
        /// Relative to the watched folder, with `/` separators, as the server spelled it.
        public let name: String
    }

    /// Entries in the folder changed.
    case changed([Entry])
    /// The server dropped changes, or the reply can't be read: the folder needs a listing.
    case overflow
    /// Another client deleted the watched folder.
    case folderGone
    /// The server ended the watch for another reason.
    case failed(UInt32)

    static let success: UInt32 = 0
    static let enumerateDirectory: UInt32 = 0x0000_010C
    static let deletePending: UInt32 = 0xC000_0056
    /// A missing or replaced folder; its listing finds out what happened.
    static let folderMissing: Set<UInt32> = [0xC000_0034, 0xC000_003A, 0xC000_0103, deletePending]

    public init(status: UInt32, buffer: [UInt8]) {
        switch status {
        case Self.success:
            // Windows servers report an overflow as success without entries.
            guard let entries = Self.entries(buffer), !entries.isEmpty else {
                self = .overflow
                return
            }
            self = .changed(entries)
        case Self.enumerateDirectory: self = .overflow
        case Self.deletePending: self = .folderGone
        default: self = .failed(status)
        }
    }

    /// Nil when the list is malformed.
    public static func entries(_ buffer: [UInt8]) -> [Entry]? {
        func word(_ at: Int) -> UInt32 {
            UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 24
        }
        var entries: [Entry] = [], offset = 0
        while offset < buffer.count {
            guard buffer.count - offset >= 12 else { return nil }
            let next = Int(word(offset)), action = word(offset + 4), length = Int(word(offset + 8))
            guard length % 2 == 0, length <= buffer.count - offset - 12 else { return nil }
            let units = stride(from: offset + 12, to: offset + 12 + length, by: 2).map {
                UInt16(buffer[$0]) | UInt16(buffer[$0 + 1]) << 8
            }
            entries.append(Entry(action: action, name: String(decoding: units, as: UTF16.self)
                .replacingOccurrences(of: "\\", with: "/")))
            guard next != 0 else { break }
            guard next >= 12 + length, next % 4 == 0 else { return nil }
            offset += next
        }
        return entries
    }

    /// What the owner of a watch on `folder` learns.
    public func notice(for folder: RelativePath) -> ChangeNotice {
        switch self {
        case .changed: .changed(folder)
        case .overflow, .folderGone: .lost(folder)
        case .failed(let status): .ended(Self.failure(status))
        }
    }

    /// A folder that can't be opened for a watch: missing folders need a listing; others, such as
    /// a refused or exhausted server, stay unwatched and the periodic listing covers them.
    public static func openFailure(_ status: UInt32, folder: RelativePath) -> ChangeNotice? {
        folderMissing.contains(status) ? .lost(folder) : nil
    }

    public static func failure(_ status: UInt32) -> SourceFailure {
        status == 0 ? .serverUnreachable : .unknown(domain: "SMB2 NTSTATUS", code: Int(status))
    }
}

/// A watcher's folders and their tokens. A folder whose watch the server ended stays unwatched
/// until a later set leaves it out.
public struct WatchTable: Sendable {
    private var tokens: [RelativePath: UInt64] = [:]
    private var paths: [UInt64: RelativePath] = [:]
    private var unavailable: Set<RelativePath> = []
    private var lastToken: UInt64 = 0

    public init() {}

    public var watched: Set<RelativePath> { Set(tokens.keys) }

    /// What to open and close so that the table holds `folders`, at most `limit` of them.
    public mutating func replace(with folders: Set<RelativePath>, limit: Int)
        -> (open: [(token: UInt64, path: RelativePath)], close: [UInt64]) {
        let wanted = Set(ChangeWatchPlan.capped(folders, limit: limit))
        unavailable.formIntersection(wanted)
        let close = tokens.filter { !wanted.contains($0.key) }.map(\.value).sorted()
        for token in close { paths.removeValue(forKey: token).map { tokens[$0] = nil } }
        var open: [(token: UInt64, path: RelativePath)] = []
        for path in ChangeWatchPlan.capped(wanted, limit: limit)
        where tokens[path] == nil && !unavailable.contains(path) {
            lastToken += 1
            tokens[path] = lastToken
            paths[lastToken] = path
            open.append((lastToken, path))
        }
        return (open, close)
    }

    public func path(of token: UInt64) -> RelativePath? { paths[token] }

    /// The watch ended without a request to close it. Returns its folder.
    @discardableResult
    public mutating func end(_ token: UInt64) -> RelativePath? {
        guard let path = paths.removeValue(forKey: token) else { return nil }
        tokens[path] = nil
        unavailable.insert(path)
        return path
    }
}

/// A discovery folder of one location, below the location folder.
public struct WatchedFolder: Hashable, Sendable {
    public let id: String
    public let parentID: String?
    public let path: RelativePath

    public init(id: String, parentID: String?, path: RelativePath) {
        self.id = id
        self.parentID = parentID
        self.path = path
    }
}

/// The watched folders of every location on one share, and which listings each notice asks for.
public struct ChangeWatchPlan: Sendable {
    private var locations: [String: [RelativePath: [WatchedFolder]]] = [:]

    public init() {}

    public var isEmpty: Bool { locations.values.allSatisfy(\.isEmpty) }
    public var domainIDs: [String] { locations.keys.sorted() }

    /// Replaces one location's folders. `root` is the location folder, from the share root.
    public mutating func setFolders(_ folders: some Sequence<WatchedFolder>, domainID: String, root: RelativePath) {
        var byPath: [RelativePath: [WatchedFolder]] = [:]
        for folder in folders {
            guard let path = root.appending(folder.path) else { continue }
            byPath[path, default: []].append(folder)
        }
        locations[domainID] = byPath
    }

    public mutating func removeLocation(_ domainID: String) { locations[domainID] = nil }

    /// Share-root paths to watch: shallower folders first when there are more than `limit`.
    public func paths(limit: Int, excluding excluded: (RelativePath) -> Bool = { _ in false }) -> Set<RelativePath> {
        let all = locations.values.reduce(into: Set<RelativePath>()) { $0.formUnion($1.keys) }
        return Set(Self.capped(all.filter { !excluded($0) }, limit: limit))
    }

    /// The folders each location lists again after `notice`. `ended` is the owner's: it lists
    /// every folder once a new watcher is open.
    public func routes(for notice: ChangeNotice) -> [(domainID: String, folderIDs: [String])] {
        let path: RelativePath, withParents: Bool
        switch notice {
        case .changed(let changed): (path, withParents) = (changed, false)
        // A lost folder can be gone; its parent's listing finds that out.
        case .lost(let lost): (path, withParents) = (lost, true)
        case .ended: return []
        }
        return domainIDs.compactMap { domainID in
            guard let folders = locations[domainID]?[path] else { return nil }
            var ids: [String] = []
            for folder in folders {
                ids.append(folder.id)
                if withParents, let parent = folder.parentID { ids.append(parent) }
            }
            return (domainID, ids)
        }
    }

    public static func capped(_ paths: Set<RelativePath>, limit: Int) -> [RelativePath] {
        Array(paths.sorted {
            let left = $0.components.count, right = $1.components.count
            return left == right ? $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) : left < right
        }.prefix(max(limit, 0)))
    }
}

/// Delays before opening a watcher again. A watcher that ends soon after opening, as on a server
/// that refuses CHANGE_NOTIFY, keeps backing off instead of reconnecting every few seconds.
public struct WatchRetry: Sendable {
    public static let delays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60)]
    public static let stableLifetime = Duration.seconds(60)
    private var attempt = 0
    private var openedAt: Duration?

    public init() {}

    public mutating func opened(now: Duration) { openedAt = now }

    /// After an open failed or a watcher ended.
    public mutating func nextDelay(now: Duration) -> Duration {
        if let openedAt, now - openedAt >= Self.stableLifetime { attempt = 0 }
        openedAt = nil
        defer { attempt += 1 }
        return Self.delays[min(attempt, Self.delays.count - 1)]
    }

    /// A new password or a recovered connection: try at once and start the delays again.
    public mutating func reset() {
        attempt = 0
        openedAt = nil
    }
}
