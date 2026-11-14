import Darwin
import Foundation
import SQLite3

/// What a reconcile would change, shown to `accept` before anything is written.
public struct ReconcilePlan: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int
    /// Children whose key the listing lacks or whose kind changed, and all their live descendants.
    public let tombstoned: Int
    /// The folder had children and the listing has none. A listing with any name in it is not
    /// an empty-listing error, so renaming a folder's only child doesn't wait for D5.
    public let emptiesFolder: Bool
    public let keptFilesRemoved: Int
    /// New entries whose attributes couldn't be read. An existing row for such an entry stays.
    public let unreadableSkipped: Int
}

/// A live row that `reconcile` would remove or give to a twin, for `confirmMissing`.
public struct MissingChild: Equatable, Sendable {
    /// The row's exact stored name.
    public let name: String
    /// The file ID of the twin that would take the row; a case-insensitive server finds it by `name`.
    public let twinFileID: UInt64?

    init(name: String, twinFileID: UInt64? = nil) {
        self.name = name
        self.twinFileID = twinFileID
    }
}

// Missing names need complete checked listings; uncertainty alone cannot retire a binding.
extension Catalog {
    public static let confirmationDelay = Duration.seconds(15)

    /// Fails if the file exists: a catalog is never re-created.
    public static func create(at url: URL, domainID: String, rootName: String) throws -> Catalog {
        let path = Self.path(url)
        // SQLite's CREATE flag also opens an existing file, so O_EXCL decides the file is new.
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create catalog") }
        Darwin.close(fd)
        do {
            let database = try connect(path, flags: SQLITE_OPEN_READWRITE)
            try configureWriter(database)
            let epoch = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            try database.write {
                try database.execute(schema, operation: "create schema")
                try database.prepare("""
                    INSERT INTO meta (id, domain_id, epoch, last_seq, listing_gen, paused) VALUES (1, ?, ?, 0, 0, 0)
                    """) { statement in
                    try statement.bind(1, domainID)
                    try statement.bind(2, epoch)
                    try statement.run()
                }
                try database.prepare("""
                    INSERT INTO items (id, parent_id, name, name_key, kind, change_seq, enumeration_key)
                    VALUES (?, NULL, ?, ?, ?, 0, ?)
                    """) { statement in
                    try statement.bind(1, rootItemID)
                    try statement.bind(2, rootName)
                    try statement.bind(3, NameKey(rootName).value)
                    try statement.bind(4, CatalogRow.Kind.folder.rawValue)
                    try statement.bind(5, NameKey(rootName).value)
                    try statement.run()
                }
            }
            return Catalog(database: database, domainID: domainID, epoch: epoch)
        } catch {
            // O_EXCL made the file ours, so a failed creation leaves nothing that blocks a retry.
            for suffix in ["", "-wal", "-shm"] { unlink(path + suffix) }
            throw error
        }
    }

    /// Never creates a catalog, so a missing one stays an error.
    public static func openWriter(at url: URL, domainID: String) throws -> Catalog {
        let database = try connect(path(url), flags: SQLITE_OPEN_READWRITE)
        let epoch = try checkedEpoch(database, domainID: domainID)
        try configureWriter(database)
        return Catalog(database: database, domainID: domainID, epoch: epoch)
    }

    /// Close every connection first. A file that is already gone counts as deleted.
    public static func delete(at url: URL) throws {
        let path = Self.path(url)
        // The main file goes last, so a crash leaves a catalog that the next launch finds again.
        for suffix in ["-wal", "-shm", ""] where unlink(path + suffix) != 0 && errno != ENOENT {
            throw posixError("delete catalog")
        }
    }

    private static func configureWriter(_ database: SQLiteDatabase) throws {
        try enableWAL(database)
        // Delivered anchors must survive power loss; fsync can leave them in the drive's cache.
        try database.execute("PRAGMA synchronous = FULL", operation: "synchronous")
        try database.execute("PRAGMA fullfsync = ON", operation: "fullfsync")
    }

    public func setProviderDomainVersion(_ data: Data) throws {
        try Self.validateProviderDomainVersion(data)
        try database.write {
            try database.prepare("UPDATE meta SET provider_domain_version = ? WHERE id = 1") { statement in
                try statement.bind(1, data)
                try statement.run()
            }
            guard database.changes == 1 else { throw CatalogError.unsupportedSchema }
        }
    }

    /// D5: a refused plan waits for a second complete listing, which the app applies as it is.
    public static func needsConfirmation(_ plan: ReconcilePlan) -> Bool {
        plan.emptiesFolder || plan.keptFilesRemoved > 0
    }

    /// nil if `accept` refused the plan, and then nothing is written. A new entry that `withholding`
    /// names is not inserted: a file that a pending upload is still writing waits for its upload.
    /// A name key in `writing` changes nothing, listed or not: this Mac is saving that file, and the
    /// save records its result.
    @discardableResult
    public func reconcile(folder folderID: String, listing: DirectoryListing,
                          withholding: (DirectoryListing.Entry) -> Bool = { _ in false },
                          writing: Set<String> = [],
                          accept: (ReconcilePlan) -> Bool) throws -> ReconcilePlan? {
        try write { seq in
            guard let folder = try item(id: folderID), folder.kind == .folder, !folder.deleted else {
                throw CatalogError.notALiveFolder
            }
            var children = try liveChildren(of: folder.id)
            let childCount = children.count
            for key in writing { children[key] = nil }
            let losers = Dictionary(grouping: listing.collisionLosers, by: \.key.value)
            var changes: [(entry: DirectoryListing.Entry, row: Int64?)] = []
            var removed: [StoredChild] = []
            var unreadableSkipped = 0
            for first in listing.firsts where !writing.contains(first.key.value) {
                guard let child = children.removeValue(forKey: first.key.value) else {
                    switch first {
                    case .entry(let entry): if !withholding(entry) { changes.append((entry, nil)) }
                    case .unreadable: unreadableSkipped += 1
                    }
                    continue
                }
                guard case .entry(let entry) = child.pair(first: first, losers: losers) else { continue }
                if child.kind != entry.kind.rawValue {
                    removed.append(child)
                    changes.append((entry, nil))
                } else if !child.matches(entry) {
                    changes.append((entry, child.row))
                }
            }
            removed += children.values.sorted { $0.row < $1.row }
            let tombstones = try withDescendants(removed)
            let inserted = changes.filter { $0.row == nil }.count
            let plan = ReconcilePlan(
                inserted: inserted, updated: changes.count - inserted, tombstoned: tombstones.count,
                emptiesFolder: childCount > 0 && removed.count == childCount && listing.firsts.isEmpty,
                keptFilesRemoved: tombstones.filter(\.keep).count, unreadableSkipped: unreadableSkipped)
            guard accept(plan) else { return nil }

            // Tombstones go first, so a kind change never shows two live items with one name.
            try database.prepare("UPDATE items SET deleted = 1, change_seq = ? WHERE row = ?") { statement in
                for tombstone in tombstones {
                    seq += 1
                    try statement.bind(1, seq)
                    try statement.bind(2, tombstone.row)
                    try statement.run()
                    statement.reset()
                }
            }
            try database.prepare("""
                UPDATE items SET name = ?, size = ?, mtime_ns = ?, ctime_ns = ?, file_id = ?, change_seq = ?,
                  listing_complete = CASE WHEN kind = 1 THEN 0 ELSE listing_complete END, edit_version = NULL
                WHERE row = ?
                """) { update in
                try database.prepare("""
                    INSERT INTO items (id, parent_id, name, name_key, kind, size, mtime_ns, ctime_ns, file_id,
                                       change_seq, keep, enumeration_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """) { insert in
                    for (entry, row) in changes {
                        seq += 1
                        if let row {
                            try update.bind(1, entry.name)
                            try update.bind(2, entry.size)
                            try update.bind(3, entry.mtimeNs)
                            try update.bind(4, entry.ctimeNs)
                            try update.bind(5, Int64(bitPattern: entry.fileID))
                            try update.bind(6, seq)
                            try update.bind(7, row)
                            try update.run()
                            update.reset()
                        } else {
                            try insert.bind(1, UUID().uuidString)
                            try insert.bind(2, folder.id)
                            try insert.bind(3, entry.name)
                            try insert.bind(4, entry.key.value)
                            try insert.bind(5, entry.kind.rawValue)
                            try insert.bind(6, entry.size)
                            try insert.bind(7, entry.mtimeNs)
                            try insert.bind(8, entry.ctimeNs)
                            try insert.bind(9, Int64(bitPattern: entry.fileID))
                            try insert.bind(10, seq)
                            try insert.bind(11, folder.keep)
                            try insert.bind(12, entry.key.value)
                            try insert.run()
                            insert.reset()
                        }
                    }
                }
            }
            try database.execute("UPDATE meta SET listing_gen = listing_gen + 1 WHERE id = 1", operation: "listing_gen")
            try database.prepare("""
                UPDATE items SET list_gen = (SELECT listing_gen FROM meta WHERE id = 1), listed_at = ?,
                  listing_complete = ? WHERE row = ?
                """) { statement in
                try statement.bind(1, Date().timeIntervalSince1970)
                try statement.bind(2, listing.unreadable.isEmpty && listing.skipped.otherKinds == 0
                                   && listing.skipped.invalidNames == 0 && listing.skipped.collisions == 0)
                try statement.bind(3, folder.row)
                try statement.run()
            }
            return plan
        }
    }

    /// The rows whose stored name the listing lacks, yet `reconcile` would remove or give to a twin.
    public func missingChildren(of folderID: String, listing: DirectoryListing) throws -> [MissingChild] {
        let firsts = Dictionary(uniqueKeysWithValues: listing.firsts.map { ($0.key.value, $0) })
        let losers = Dictionary(grouping: listing.collisionLosers, by: \.key.value)
        return try liveChildren(of: folderID).sorted { $0.value.row < $1.value.row }.compactMap { key, child in
            guard let first = firsts[key] else { return MissingChild(name: child.name) }
            // The listing proves a stored-name pairing, and an unreadable twin changes nothing.
            guard case .entry(let twin) = child.pair(first: first, losers: losers),
                  !twin.name.utf8.elementsEqual(child.name.utf8) else { return nil }
            return MissingChild(name: child.name, twinFileID: twin.fileID)
        }
    }

    /// Returns false, with no new sequence, if the row already had these values.
    @discardableResult
    public func updateFingerprint(item id: String, fingerprint: ContentFingerprint, fileID: UInt64) throws -> Bool {
        try write { seq in
            guard let item = try item(id: id), item.kind == .file, !item.deleted else {
                throw CatalogError.notALiveFile
            }
            try database.prepare("""
                UPDATE items SET size = ?1, mtime_ns = ?2, ctime_ns = ?3, file_id = ?4, change_seq = ?5, edit_version = NULL
                WHERE row = ?6 AND (size, mtime_ns, ctime_ns, file_id) IS NOT (?1, ?2, ?3, ?4)
                """) { statement in
                try statement.bind(1, fingerprint.size)
                try statement.bind(2, fingerprint.mtimeNs)
                try statement.bind(3, fingerprint.ctimeNs)
                try statement.bind(4, Int64(bitPattern: fileID))
                try statement.bind(5, seq + 1)
                try statement.bind(6, item.row)
                try statement.run()
            }
            guard database.changes > 0 else { return false }
            seq += 1
            return true
        }
    }

    /// Inherited retention is recomputed below each changed request, within the same transaction.
    @discardableResult
    public func setKeep(ids: [String], value: Bool) throws -> Int {
        try write { seq in
            var changed = 0
            for id in ids {
                guard let root = try item(id: id), !root.deleted, root.keepRequested != value else { continue }
                let inherited = try root.parentID.flatMap { try item(id: $0)?.keep } ?? false
                let subtree = try retainedSubtree(id: id, rootKeep: value || inherited)
                try database.prepare("UPDATE items SET keep_request = ?, keep = ?, change_seq = ? WHERE id = ?") {
                    statement in
                    for (row, retained) in subtree {
                        let requested = row.id == id ? value : row.keepRequested
                        guard row.keep != retained || row.keepRequested != requested else { continue }
                        seq += 1
                        try statement.bind(1, requested)
                        try statement.bind(2, retained)
                        try statement.bind(3, seq)
                        try statement.bind(4, row.id)
                        try statement.run()
                        statement.reset()
                        changed += 1
                    }
                }
            }
            return changed
        }
    }

    private func retainedSubtree(id: String, rootKeep: Bool) throws -> [(CatalogRow, Bool)] {
        try database.prepare("""
            WITH RECURSIVE tree(id, retained) AS (
              SELECT id, ?2 FROM items WHERE id = ?1 AND deleted = 0
              UNION ALL
              SELECT child.id, child.keep_request OR tree.retained FROM items child
              JOIN tree ON child.parent_id = tree.id WHERE child.deleted = 0)
            SELECT \(CatalogRow.columns), (SELECT retained FROM tree WHERE tree.id = items.id)
            FROM items WHERE id IN (SELECT id FROM tree) ORDER BY row
            """) { statement in
            try statement.bind(1, id)
            try statement.bind(2, rootKeep)
            var result: [(CatalogRow, Bool)] = []
            while try statement.step() { result.append((try CatalogRow(statement), statement.bool(18))) }
            return result
        }
    }

    /// Each kept live row takes a new sequence, because its download policy changes.
    @discardableResult
    public func setPaused(_ paused: Bool) throws -> Int {
        try write { seq in
            let current = try database.prepare("SELECT paused FROM meta WHERE id = 1") { try $0.step() && $0.bool(0) }
            guard current != paused else { return 0 }
            try database.prepare("UPDATE meta SET paused = ? WHERE id = 1") { statement in
                try statement.bind(1, paused)
                try statement.run()
            }
            let kept = try keptItems().map(\.row)
            try database.prepare("UPDATE items SET change_seq = ? WHERE row = ?") { statement in
                for row in kept {
                    seq += 1
                    try statement.bind(1, seq)
                    try statement.bind(2, row)
                    try statement.run()
                    statement.reset()
                }
            }
            return kept.count
        }
    }

    /// Returns false if the root already has this exact name.
    @discardableResult
    public func setRootName(_ name: String) throws -> Bool {
        try write { seq in
            guard let root = try item(id: Self.rootItemID) else { throw CatalogError.notALiveFolder }
            guard !root.name.utf8.elementsEqual(name.utf8) else { return false }
            seq += 1
            // name_key stays: it is fixed for a row's life, and nothing looks the root up by key.
            try database.prepare("UPDATE items SET name = ?, change_seq = ? WHERE id = ?") { statement in
                try statement.bind(1, name)
                try statement.bind(2, seq)
                try statement.bind(3, Self.rootItemID)
                try statement.run()
            }
            return true
        }
    }

    public func nameCreatedFolder(id: String, name: String, expectedIdentity: UInt64,
                                  newIdentity: UInt64? = nil) throws {
        try write { seq in
            guard RelativePath.isValidComponent(name), let row = try item(id: id), !row.deleted,
                  row.kind == .folder, let parent = row.parentID else { throw UploadError.unresolved }
            let identity = newIdentity ?? expectedIdentity
            let current = try remoteIdentity(id)
            if row.name.utf8.elementsEqual(name.utf8), current == identity { return }
            guard current == expectedIdentity else { throw UploadError.unresolved }
            if let other = try liveChild(parent: parent, nameKey: NameKey(name)), other.id != id {
                throw UploadError.collision
            }
            seq += 1
            try database.prepare("UPDATE items SET name = ?, name_key = ?, change_seq = ?, file_id = ? WHERE id = ?") { statement in
                try statement.bind(1, name)
                try statement.bind(2, NameKey(name).value)
                try statement.bind(3, seq)
                try statement.bind(4, Int64(bitPattern: identity))
                try statement.bind(5, id)
                try statement.run()
            }
        }
    }

    /// `body` adds 1 per visible change, so a batch cut at its last sequence skips no row.
    func write<Result>(_ body: (inout Int64) throws -> Result) throws -> Result {
        try database.write {
            let first = try lastSeq()
            var seq = first
            let result = try body(&seq)
            if seq != first {
                try database.prepare("UPDATE meta SET last_seq = ? WHERE id = 1") { statement in
                    try statement.bind(1, seq)
                    try statement.run()
                }
            }
            return result
        }
    }

    private func liveChildren(of folderID: String) throws -> [String: StoredChild] {
        try database.prepare("""
            SELECT row, id, name, name_key, kind, size, mtime_ns, ctime_ns, file_id, keep FROM items
            WHERE parent_id = ? AND deleted = 0
            """) { statement in
            try statement.bind(1, folderID)
            var children: [String: StoredChild] = [:]
            while try statement.step() {
                // Use the stored key so listing comparisons match the unique index.
                children[statement.text(3)] = StoredChild(
                    row: statement.int64(0), id: statement.text(1), name: statement.text(2),
                    kind: Int(statement.int64(4)), size: statement.int64(5), mtimeNs: statement.int64(6),
                    ctimeNs: statement.int64(7), fileID: statement.isNull(8) ? nil : statement.int64(8),
                    keep: statement.bool(9))
            }
            return children
        }
    }

    private func withDescendants(_ removed: [StoredChild]) throws -> [(row: Int64, keep: Bool)] {
        try database.prepare("""
            WITH RECURSIVE subtree(row, id, keep) AS (
              SELECT row, id, keep FROM items WHERE parent_id = ? AND deleted = 0
              UNION ALL
              SELECT items.row, items.id, items.keep FROM items JOIN subtree ON items.parent_id = subtree.id
              WHERE items.deleted = 0)
            SELECT row, keep FROM subtree
            """) { statement in
            var rows: [(row: Int64, keep: Bool)] = []
            for child in removed {
                rows.append((child.row, child.keep))
                guard child.kind == CatalogRow.Kind.folder.rawValue else { continue }
                try statement.bind(1, child.id)
                while try statement.step() { rows.append((statement.int64(0), statement.bool(1))) }
                statement.reset()
            }
            return rows
        }
    }
}

extension DirectoryListing {
    /// One candidate per listed key: entries, then unreadable names.
    var firsts: [Candidate] { entries.map(Candidate.entry) + unreadable.map(Candidate.unreadable) }
}

private struct StoredChild {
    let row: Int64
    let id: String
    let name: String
    let kind: Int
    let size: Int64
    let mtimeNs: Int64
    let ctimeNs: Int64
    let fileID: Int64?
    let keep: Bool

    /// The existing name wins a collision: the twin with the stored bytes, else the key's first name.
    func pair(first: DirectoryListing.Candidate,
              losers: [String: [DirectoryListing.Candidate]]) -> DirectoryListing.Candidate {
        ([first] + (losers[first.key.value] ?? [])).first { $0.name.utf8.elementsEqual(name.utf8) } ?? first
    }

    func matches(_ entry: DirectoryListing.Entry) -> Bool {
        // Byte comparison: String == would hide a rename that only changes normalization.
        name.utf8.elementsEqual(entry.name.utf8) && size == entry.size && mtimeNs == entry.mtimeNs
            && ctimeNs == entry.ctimeNs && fileID == Int64(bitPattern: entry.fileID)
    }
}


extension Catalog {
    public func remoteIdentity(_ id: String) throws -> UInt64? {
        try database.prepare("SELECT file_id FROM items WHERE id = ? AND deleted = 0") { statement in
            try statement.bind(1, id)
            guard try statement.step(), !statement.isNull(0) else { return nil }
            return UInt64(bitPattern: statement.int64(0))
        }
    }
}
