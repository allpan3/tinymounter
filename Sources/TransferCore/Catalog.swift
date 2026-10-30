import Foundation
import SQLite3

public enum CatalogError: Error, Equatable, Sendable {
    /// An unsupported schema, or damaged metadata or root row.
    case unsupportedSchema
    case otherDomain
    case notALiveFolder
    case notALiveFile
    case anchorExpired
    case pageExpired
}

public struct CatalogRow: Equatable, Sendable {
    /// The raw values are the `kind` column and `DirectoryListing.Entry.Kind`'s.
    public enum Kind: Int, Codable, Sendable { case folder = 1, file = 2 }

    /// Never reused; page tokens hold it.
    public let row: Int64
    public let id: String
    /// nil only for the root.
    public let parentID: String?
    /// The exact remote name; the location's name for the root. Compare with `utf8`.
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    /// An ancestor's request can retain an item without a request of its own.
    public let keep: Bool
    public let keepRequested: Bool
    public let listingComplete: Bool
    public let deleted: Bool
    /// Set only on folders, by their last complete listing; nil until one has run.
    public let listGen: Int64?
    public let listedAt: Date?
    public let changeSeq: Int64
    /// `meta.paused` in the same read, so a kept item's download policy matches its `changeSeq`.
    public let paused: Bool
    public let allowsCreation: Bool
    public let allowsEditing: Bool
    public let editVersion: String?

    public var contentVersion: String {
        kind == .file ? editVersion ?? ContentFingerprint(size: size, mtimeNs: mtimeNs, ctimeNs: ctimeNs).contentVersion : "d1"
    }

    public var metadataVersion: String { String(changeSeq) }

    /// The `contentModificationDate` that File Provider gets. A Date can't hold all nanoseconds.
    public var modificationDate: Date { Date(timeIntervalSince1970: Double(mtimeNs) / 1e9) }

    static let columns = """
        row, id, parent_id, name, kind, size, mtime_ns, ctime_ns, keep, deleted, list_gen, listed_at, \
        change_seq, (SELECT paused FROM meta), keep_request, listing_complete, (SELECT allows_creation FROM meta), \
        (SELECT allows_editing FROM meta), edit_version
        """

    init(_ statement: Statement) throws {
        guard let kind = Kind(rawValue: Int(statement.int64(4))) else {
            throw SQLiteError(code: SQLITE_CORRUPT, operation: "read item kind")
        }
        row = statement.int64(0)
        id = statement.text(1)
        parentID = statement.isNull(2) ? nil : statement.text(2)
        name = statement.text(3)
        self.kind = kind
        size = statement.int64(5)
        mtimeNs = statement.int64(6)
        ctimeNs = statement.int64(7)
        keep = statement.bool(8)
        deleted = statement.bool(9)
        listGen = statement.isNull(10) ? nil : statement.int64(10)
        listedAt = statement.isNull(11) ? nil : Date(timeIntervalSince1970: statement.double(11))
        changeSeq = statement.int64(12)
        paused = statement.bool(13)
        keepRequested = statement.bool(14)
        listingComplete = statement.bool(15)
        allowsCreation = statement.bool(16)
        allowsEditing = statement.bool(17) && allowsCreation
        editVersion = statement.isNull(18) ? nil : statement.text(18)
    }
}

public enum ChangeScope: Equatable, Sendable {
    case all
    case parent(String)
    case item(String)
}

public struct ChangeBatch: Sendable {
    public let updated: [CatalogRow]
    public let deletedIDs: [String]
    public let anchor: Data
    public let moreComing: Bool
}

/// The downloaded files of a location, by their catalog sizes.
public struct StorageUsage: Equatable, Sendable {
    /// A partly downloaded file is not in the materialized set, so its bytes don't count.
    public let bytes: Int64
    public let files: Int
    /// Files that are not kept, for Remove Downloads; a deleted row's file is the system's to remove.
    public let removable: [String]
    public let removableBytes: Int64

    init(_ rows: [CatalogRow]) {
        let removable = rows.filter { !$0.keep && !$0.deleted }
        bytes = rows.reduce(0) { $0 + $1.size }
        files = rows.count
        self.removable = removable.map(\.id)
        removableBytes = removable.reduce(0) { $0 + $1.size }
    }
}

public struct CatalogCounts: Equatable, Sendable {
    /// Live rows, the root included.
    public let live: Int
    public let tombstones: Int
    public let listedFolders: Int
    public let kept: Int
    public let lastSeq: Int64
    public let listingGen: Int64
}

/// Use from one queue at a time: the system SQLite's multi-thread mode can't share a connection.
public final class Catalog {
    /// `NSFileProviderItemIdentifier.rootContainer.rawValue`; core doesn't import FileProvider.
    public static let rootItemID = "NSFileProviderRootContainerItemIdentifier"
    static let maxDepth = 256
    static let schemaVersion: Int64 = 7
    // No real number of writes reaches it, so a writer's `seq += 1` can't overflow.
    static let maxLastSeq = Int64.max / 2
    private static let busyTimeoutMilliseconds = 2000

    static let schema = """
        CREATE TABLE meta (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          domain_id TEXT NOT NULL,
          epoch BLOB NOT NULL,
          last_seq INTEGER NOT NULL,
          listing_gen INTEGER NOT NULL,
          paused INTEGER NOT NULL DEFAULT 0,
          allows_creation INTEGER NOT NULL DEFAULT 0,
          allows_editing INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE items (
          row INTEGER PRIMARY KEY,
          id TEXT NOT NULL UNIQUE,
          parent_id TEXT REFERENCES items(id),
          name TEXT NOT NULL,
          name_key TEXT NOT NULL,
          kind INTEGER NOT NULL,
          size INTEGER NOT NULL DEFAULT 0,
          mtime_ns INTEGER NOT NULL DEFAULT 0,
          ctime_ns INTEGER NOT NULL DEFAULT 0,
          file_id INTEGER,
          keep INTEGER NOT NULL DEFAULT 0,
          list_gen INTEGER,
          listed_at REAL,
          deleted INTEGER NOT NULL DEFAULT 0,
          change_seq INTEGER NOT NULL UNIQUE,
          keep_request INTEGER NOT NULL DEFAULT 0,
          listing_complete INTEGER NOT NULL DEFAULT 0,
          enumeration_key TEXT NOT NULL,
          edit_version TEXT);
        CREATE UNIQUE INDEX items_live_name ON items(parent_id, name_key) WHERE deleted = 0;
        CREATE INDEX items_kept ON items(row) WHERE keep = 1 AND deleted = 0;
        CREATE INDEX items_listing ON items(parent_id, enumeration_key, row) WHERE deleted = 0;
        \(departuresSchema)
        PRAGMA user_version = 7;
        """

    // One departure per item and former parent keeps repeated moves from growing history.
    static let departuresSchema = """
        CREATE TABLE departures (
          item TEXT NOT NULL REFERENCES items(id),
          parent TEXT NOT NULL REFERENCES items(id),
          seq INTEGER NOT NULL,
          PRIMARY KEY (item, parent));
        CREATE INDEX departures_parent ON departures(parent, seq);
        """

    public let domainID: String
    let database: SQLiteDatabase
    /// Fixed for the catalog's life.
    let epoch: Data

    init(database: SQLiteDatabase, domainID: String, epoch: Data) {
        self.database = database
        self.domainID = domainID
        self.epoch = epoch
    }

    /// The extension's only open: SQLITE_OPEN_READONLY, so it can't create or write a catalog.
    public static func open(at url: URL, domainID: String) throws -> Catalog {
        let database = try connect(path(url), flags: SQLITE_OPEN_READONLY)
        let epoch = try checkedEpoch(database, domainID: domainID)
        try enableWAL(database)
        return Catalog(database: database, domainID: domainID, epoch: epoch)
    }

    static func path(_ url: URL) -> String { url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }

    static func connect(_ path: String, flags: Int32) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: path, flags: flags)
        try database.execute("PRAGMA busy_timeout = \(busyTimeoutMilliseconds)", operation: "busy_timeout")
        return database
    }

    /// Call it before `enableWAL`, so a file of another kind is never switched to WAL.
    static func checkedEpoch(_ database: SQLiteDatabase, domainID: String,
                             version: Int64 = schemaVersion) throws -> Data {
        guard try database.prepare("PRAGMA user_version", { try $0.step() ? $0.int64(0) : 0 }) == version else {
            throw CatalogError.unsupportedSchema
        }
        // Damaged counters would crash the writer or expire every anchor, so they are unavailable.
        let meta = try database.prepare("""
            SELECT domain_id, epoch, last_seq BETWEEN 0 AND ?1 AND listing_gen >= 0
              AND (SELECT max(change_seq) FROM items) <= last_seq
              AND EXISTS (SELECT 1 FROM items WHERE id = ?2 AND parent_id IS NULL AND kind = ?3 AND deleted = 0)
            FROM meta WHERE id = 1
            """) { statement in
            try statement.bind(1, maxLastSeq)
            try statement.bind(2, rootItemID)
            try statement.bind(3, CatalogRow.Kind.folder.rawValue)
            return try statement.step() ? (domainID: statement.text(0), epoch: statement.blob(1),
                                           sound: statement.bool(2)) : nil
        }
        guard let meta, meta.epoch.count == 16 else { throw CatalogError.unsupportedSchema }
        guard meta.domainID == domainID else { throw CatalogError.otherDomain }
        guard meta.sound else { throw CatalogError.unsupportedSchema }
        return meta.epoch
    }

    static func enableWAL(_ database: SQLiteDatabase) throws {
        let mode = try database.prepare("PRAGMA journal_mode = WAL") { try $0.step() ? $0.text(0) : "" }
        guard mode == "wal" else { throw SQLiteError(code: SQLITE_ERROR, operation: "journal_mode") }
    }

    /// The item, tombstones included; nil for an unknown ID.
    public func item(id: String) throws -> CatalogRow? {
        try items("SELECT \(CatalogRow.columns) FROM items WHERE id = ?") { try $0.bind(1, id) }.first
    }

    /// Throws `pageExpired` unless `afterRow` is a row of one of the folder's children.
    public func children(of folderID: String, afterRow: Int64? = nil, limit: Int) throws -> [CatalogRow] {
        precondition(limit > 0)
        guard let afterRow else {
            return try items("""
                SELECT \(CatalogRow.columns) FROM items WHERE parent_id = ? AND deleted = 0 ORDER BY enumeration_key, row LIMIT ?
                """) { statement in
                try statement.bind(1, folderID)
                try statement.bind(2, limit)
            }
        }
        // The immutable enumeration key survives naming, moves and tombstones.
        let placed = try database.prepare("""
            SELECT 1 FROM items WHERE row = ?1
              AND (parent_id = ?2 OR EXISTS (SELECT 1 FROM departures WHERE item = items.id AND parent = ?2))
            """) { statement in
            try statement.bind(1, afterRow)
            try statement.bind(2, folderID)
            return try statement.step()
        }
        guard placed else { throw CatalogError.pageExpired }
        return try items("""
            SELECT \(CatalogRow.columns) FROM items WHERE parent_id = ? AND deleted = 0
            AND (enumeration_key, row) > (SELECT enumeration_key, row FROM items WHERE row = ?)
            ORDER BY enumeration_key, row LIMIT ?
            """) { statement in
            try statement.bind(1, folderID)
            try statement.bind(2, afterRow)
            try statement.bind(3, limit)
        }
    }

    public func liveChildCount(of folderID: String) throws -> Int {
        try database.prepare("SELECT count(*) FROM items WHERE parent_id = ? AND deleted = 0") { statement in
            try statement.bind(1, folderID)
            guard try statement.step() else { throw SQLiteError(code: SQLITE_CORRUPT, operation: "count children") }
            return Int(statement.int64(0))
        }
    }

    public func workingSet(afterRow: Int64? = nil, limit: Int) throws -> [CatalogRow] {
        precondition(limit > 0)
        return try items("""
            SELECT \(CatalogRow.columns) FROM items WHERE deleted = 0 AND parent_id IS NOT NULL AND row > ?
            ORDER BY row LIMIT ?
            """) { statement in
            try statement.bind(1, afterRow ?? 0)
            try statement.bind(2, limit)
        }
    }

    public func currentAnchor() throws -> Data {
        CatalogCursor.anchor(epoch: epoch, changeSeq: try lastSeq())
    }

    // Departure sequences keep old-parent anchors independent of later item changes.
    public func changes(after anchor: Data, limit: Int, scope: ChangeScope = .all) throws -> ChangeBatch {
        precondition(limit > 0)
        return try database.read {
            let lastSeq = try lastSeq()
            guard let since = CatalogCursor.anchorSeq(anchor, epoch: epoch, lastSeq: lastSeq) else {
                throw CatalogError.anchorExpired
            }
            let sql: String
            switch scope {
            case .all:
                sql = "SELECT \(CatalogRow.columns), change_seq AS event FROM items WHERE change_seq > ?1"
            case .item:
                sql = "SELECT \(CatalogRow.columns), change_seq AS event FROM items WHERE change_seq > ?1 AND id = ?3"
            case .parent:
                sql = """
                    SELECT \(CatalogRow.columns), change_seq AS event FROM items
                    WHERE change_seq > ?1 AND parent_id = ?3
                    UNION ALL
                    SELECT \(CatalogRow.columns), seq FROM departures JOIN items ON items.id = departures.item
                    WHERE seq > ?1 AND parent = ?3
                    """
            }
            let events = try database.prepare(sql + " ORDER BY event LIMIT ?2") { statement in
                try statement.bind(1, since)
                try statement.bind(2, limit)
                switch scope {
                case .all: break
                case .parent(let id), .item(let id): try statement.bind(3, id)
                }
                var events: [(row: CatalogRow, seq: Int64)] = []
                while try statement.step() { events.append((try CatalogRow(statement), statement.int64(19))) }
                return events
            }
            let rows = events.map { $0.row }
            let moreComing = events.count == limit
            let end = moreComing ? events[events.count - 1].seq : lastSeq
            return ChangeBatch(updated: rows.filter { !$0.deleted }, deletedIDs: rows.filter(\.deleted).map(\.id),
                               anchor: CatalogCursor.anchor(epoch: epoch, changeSeq: end), moreComing: moreComing)
        }
    }

    /// nil for a tombstone or an unknown ID; `pathRejected` over 256 components or for a bad name.
    public func relativePath(of id: String) throws -> RelativePath? {
        let chain = try database.prepare("""
            WITH RECURSIVE chain(depth, parent_id, name, deleted) AS (
              SELECT 0, parent_id, name, deleted FROM items WHERE id = ?1
              UNION ALL
              SELECT chain.depth + 1, items.parent_id, items.name, items.deleted
              FROM items JOIN chain ON items.id = chain.parent_id WHERE chain.depth < ?2)
            SELECT parent_id IS NULL, name, deleted FROM chain ORDER BY depth DESC
            """) { statement in
            try statement.bind(1, id)
            try statement.bind(2, Self.maxDepth)
            var chain: [(isRoot: Bool, name: String, deleted: Bool)] = []
            while try statement.step() { chain.append((statement.bool(0), statement.text(1), statement.bool(2))) }
            return chain
        }
        guard let top = chain.first, !chain.contains(where: \.deleted) else { return nil }
        guard top.isRoot else { throw SourceFailure.pathRejected }
        var path = RelativePath.root
        for link in chain.dropFirst() {
            // Names are checked again here, before any openat sees them.
            guard let next = path.appending(link.name) else { throw SourceFailure.pathRejected }
            path = next
        }
        return path
    }

    public func liveChild(parent: String, nameKey: NameKey) throws -> CatalogRow? {
        try items("SELECT \(CatalogRow.columns) FROM items WHERE parent_id = ? AND name_key = ? AND deleted = 0") {
            try $0.bind(1, parent)
            try $0.bind(2, nameKey.value)
        }.first
    }

    public func keptItems() throws -> [CatalogRow] {
        try items("SELECT \(CatalogRow.columns) FROM items WHERE keep = 1 AND deleted = 0 ORDER BY row")
    }

    /// The space of the files among these materialized item IDs, from their rows (plan §8).
    public func storage(materialized ids: [String]) throws -> StorageUsage {
        let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return StorageUsage(try items("""
            SELECT \(CatalogRow.columns) FROM items
            WHERE kind = \(CatalogRow.Kind.file.rawValue) AND id IN (SELECT value FROM json_each(?)) ORDER BY row
            """) { try $0.bind(1, list) })
    }

    public func counts() throws -> CatalogCounts {
        try database.prepare("""
            SELECT count(*) FILTER (WHERE deleted = 0), count(*) FILTER (WHERE deleted = 1),
              count(*) FILTER (WHERE deleted = 0 AND list_gen IS NOT NULL),
              count(*) FILTER (WHERE deleted = 0 AND keep = 1),
              (SELECT last_seq FROM meta), (SELECT listing_gen FROM meta)
            FROM items
            """) { statement in
            guard try statement.step() else { throw SQLiteError(code: SQLITE_CORRUPT, operation: "counts") }
            return CatalogCounts(live: Int(statement.int64(0)), tombstones: Int(statement.int64(1)),
                                 listedFolders: Int(statement.int64(2)), kept: Int(statement.int64(3)),
                                 lastSeq: statement.int64(4), listingGen: statement.int64(5))
        }
    }

    func lastSeq() throws -> Int64 {
        try database.prepare("SELECT last_seq FROM meta WHERE id = 1") { statement in
            guard try statement.step() else { throw SQLiteError(code: SQLITE_CORRUPT, operation: "read last_seq") }
            return statement.int64(0)
        }
    }

    func items(_ sql: String, _ bind: (Statement) throws -> Void = { _ in }) throws -> [CatalogRow] {
        try database.prepare(sql) { statement in
            try bind(statement)
            var items: [CatalogRow] = []
            while try statement.step() { items.append(try CatalogRow(statement)) }
            return items
        }
    }
}
