import Foundation

public struct CatalogFolderMoveEntry: Codable, Equatable, Sendable {
    public let item: String
    public let parent: String
    public let name: String
    public let path: String
    public let kind: CatalogRow.Kind
    public let contentVersion: String
    public let nativeID: UInt64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let changeSeq: Int64
    public let keep: Bool
    public let keepRequested: Bool
    public let listingComplete: Bool
    public let listGen: Int64?

    public init(row: CatalogRow, path: RelativePath, nativeID: UInt64) throws {
        guard !row.deleted, row.id != Catalog.rootItemID, let parent = row.parentID,
              nativeID != 0, !path.isRoot else { throw UploadError.unresolved }
        item = row.id
        self.parent = parent
        name = row.name
        self.path = path.string
        kind = row.kind
        contentVersion = row.contentVersion
        self.nativeID = nativeID
        size = row.size
        mtimeNs = row.mtimeNs
        ctimeNs = row.ctimeNs
        changeSeq = row.changeSeq
        keep = row.keep
        keepRequested = row.keepRequested
        listingComplete = row.listingComplete
        listGen = row.listGen
    }
}

public struct CatalogFolderMove: Codable, Equatable, Sendable {
    public let item: String
    public let destinationParent: String
    public let destinationName: String
    public let destinationParentPath: String
    public let entries: [CatalogFolderMoveEntry]

    public init(item: String, destinationParent: String, destinationName: String,
                destinationParentPath: RelativePath, entries: [CatalogFolderMoveEntry]) {
        self.item = item
        self.destinationParent = destinationParent
        self.destinationName = destinationName
        self.destinationParentPath = destinationParentPath.string
        self.entries = entries
    }
}

public struct CatalogFolderMoveObservation: Codable, Equatable, Sendable {
    public let item: String
    public let path: String
    public let kind: CatalogRow.Kind
    public let nativeID: UInt64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let preservesIdentity: Bool
    // True only after the caller proves the same file and its complete contents.
    public let preservesContents: Bool

    public init(item: String, path: RelativePath, kind: CatalogRow.Kind, nativeID: UInt64,
                fingerprint: ContentFingerprint, preservesIdentity: Bool, preservesContents: Bool) {
        self.item = item
        self.path = path.string
        self.kind = kind
        self.nativeID = nativeID
        size = fingerprint.size
        mtimeNs = fingerprint.mtimeNs
        ctimeNs = fingerprint.ctimeNs
        self.preservesIdentity = preservesIdentity
        self.preservesContents = preservesContents
    }
}

extension Catalog {
    public func prepareFolderMove(item id: String, destinationParent: String,
                                  destinationName: String) throws -> CatalogFolderMove {
        try database.read {
            guard id != Self.rootItemID, try item(id: id)?.kind == .folder,
                  let destination = try item(id: destinationParent), !destination.deleted,
                  destination.kind == .folder, destination.listGen != nil,
                  let parentPath = try relativePath(of: destinationParent) else { throw UploadError.unresolved }
            let entries = try folderMoveRows(id).map { row in
                guard let path = try relativePath(of: row.id), let nativeID = try remoteIdentity(row.id) else {
                    throw UploadError.unresolved
                }
                return try CatalogFolderMoveEntry(row: row, path: path, nativeID: nativeID)
            }
            let move = CatalogFolderMove(item: id, destinationParent: destinationParent,
                                         destinationName: destinationName, destinationParentPath: parentPath,
                                         entries: entries)
            _ = try folderMovePaths(move)
            return move
        }
    }

    // The caller proves every directory identity and each preserved file's complete contents.
    public func commitFolderMove(_ move: CatalogFolderMove,
                                 observations: [CatalogFolderMoveObservation]) throws {
        try write { seq in
            let paths = try folderMovePaths(move)
            let rows = try folderMoveRows(move.item)
            guard Set(rows.map(\.id)) == Set(move.entries.map(\.item)),
                  observations.count == move.entries.count,
                  Set(observations.map(\.item)) == Set(move.entries.map(\.item)),
                  let root = rows.first(where: { $0.id == move.item }),
                  let admittedRoot = move.entries.first(where: { $0.item == move.item }),
                  let destination = try item(id: move.destinationParent), !destination.deleted,
                  destination.kind == .folder, destination.listGen != nil,
                  let parentPath = try relativePath(of: destination.id),
                  parentPath.string.utf8.elementsEqual(move.destinationParentPath.utf8) else {
                throw UploadError.unresolved
            }
            if let other = try liveChild(parent: destination.id, nameKey: NameKey(move.destinationName)),
               other.id != root.id { throw UploadError.collision }
            let admitted = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
            let observed = Dictionary(uniqueKeysWithValues: observations.map { ($0.item, $0) })
            let ordered = rows.sorted {
                let first = paths[$0.id]!.components.count, second = paths[$1.id]!.components.count
                return first == second ? $0.row < $1.row : first < second
            }
            var keeps: [String: Bool] = [:]
            let moved = root.parentID == destination.id && root.name.utf8.elementsEqual(move.destinationName.utf8)
            for row in ordered {
                let before = admitted[row.id]!, after = observed[row.id]!
                let expectedParent = row.id == root.id ? destination.id : before.parent
                let expectedName = row.id == root.id ? move.destinationName : before.name
                guard row.kind == before.kind, after.kind == before.kind, after.nativeID != 0,
                      after.preservesIdentity,
                      after.size >= 0, after.path.utf8.elementsEqual(paths[row.id]!.string.utf8),
                      row.contentVersion == before.contentVersion,
                      row.kind != .file || (after.preservesContents && after.size == before.size) else {
                    throw UploadError.unresolved
                }
                let inherited = row.id == root.id ? destination.keep : keeps[before.parent]
                guard let inherited else { throw UploadError.unresolved }
                keeps[row.id] = row.keepRequested || inherited
                guard let path = try relativePath(of: row.id), let nativeID = try remoteIdentity(row.id) else {
                    throw UploadError.unresolved
                }
                if moved {
                    guard row.parentID == expectedParent, row.name.utf8.elementsEqual(expectedName.utf8),
                          path.string.utf8.elementsEqual(after.path.utf8), nativeID == after.nativeID,
                          row.size == after.size, row.mtimeNs == after.mtimeNs, row.ctimeNs == after.ctimeNs,
                          row.keep == keeps[row.id],
                          row.listingComplete == (row.kind == .folder ? false : before.listingComplete) else {
                        throw UploadError.unresolved
                    }
                } else {
                    // Keep and pause changes must not strand an already completed remote move.
                    guard row.parentID == before.parent, row.name.utf8.elementsEqual(before.name.utf8),
                          path.string.utf8.elementsEqual(before.path.utf8), nativeID == before.nativeID,
                          row.size == before.size, row.mtimeNs == before.mtimeNs, row.ctimeNs == before.ctimeNs,
                          row.listingComplete == before.listingComplete, row.listGen == before.listGen else {
                        throw UploadError.unresolved
                    }
                }
            }
            if moved { return }
            var departure: Int64 = 0
            for row in ordered {
                let after = observed[row.id]!
                seq += 1
                if row.id == root.id { departure = seq }
                // Known descendants do not prove that no new remote child arrived during the move.
                try database.prepare("""
                    UPDATE items SET parent_id = ?, name = ?, name_key = ?, size = ?, mtime_ns = ?,
                        ctime_ns = ?, file_id = ?, edit_version = CASE WHEN kind = 2 THEN ? ELSE edit_version END,
                        keep = ?, change_seq = ?,
                        listing_complete = CASE WHEN kind = 1 THEN 0 ELSE listing_complete END WHERE id = ?
                    """) {
                    let name = row.id == root.id ? move.destinationName : row.name
                    try $0.bind(1, row.id == root.id ? destination.id : admitted[row.id]!.parent)
                    try $0.bind(2, name)
                    try $0.bind(3, NameKey(name).value)
                    try $0.bind(4, after.size)
                    try $0.bind(5, after.mtimeNs)
                    try $0.bind(6, after.ctimeNs)
                    try $0.bind(7, Int64(bitPattern: after.nativeID))
                    try $0.bind(8, row.contentVersion)
                    try $0.bind(9, keeps[row.id]!)
                    try $0.bind(10, seq)
                    try $0.bind(11, row.id)
                    try $0.run()
                }
            }
            if admittedRoot.parent != destination.id {
                try database.prepare("INSERT OR REPLACE INTO departures (item, parent, seq) VALUES (?, ?, ?)") {
                    try $0.bind(1, root.id)
                    try $0.bind(2, admittedRoot.parent)
                    try $0.bind(3, departure)
                    try $0.run()
                }
                try database.prepare("DELETE FROM departures WHERE item = ? AND parent = ?") {
                    try $0.bind(1, root.id)
                    try $0.bind(2, destination.id)
                    try $0.run()
                }
            }
        }
    }

    private func folderMoveRows(_ id: String) throws -> [CatalogRow] {
        try items("""
            WITH RECURSIVE tree(id) AS (
                SELECT id FROM items WHERE id = ? AND deleted = 0
                UNION SELECT child.id FROM items child JOIN tree ON child.parent_id = tree.id WHERE child.deleted = 0)
            SELECT \(CatalogRow.columns) FROM items WHERE id IN (SELECT id FROM tree) ORDER BY row
            """) { try $0.bind(1, id) }
    }

    private func folderMovePaths(_ move: CatalogFolderMove) throws -> [String: RelativePath] {
        guard move.item != Self.rootItemID, ReaderMessage.isItemID(move.item),
              ReaderMessage.isItemID(move.destinationParent), FileRenameRequest.supportsName(move.destinationName),
              !move.entries.isEmpty, Set(move.entries.map(\.item)).count == move.entries.count,
              !move.entries.contains(where: { $0.item == move.destinationParent }),
              let root = move.entries.first(where: { $0.item == move.item }), root.kind == .folder,
              let source = RelativePath(root.path), !source.isRoot,
              let parent = RelativePath(move.destinationParentPath),
              let target = parent.appending(move.destinationName),
              root.parent != move.destinationParent || !root.name.utf8.elementsEqual(move.destinationName.utf8) else {
            throw UploadError.unresolved
        }
        let entries = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        var result: [String: RelativePath] = [:]
        for entry in move.entries {
            guard ReaderMessage.isItemID(entry.item), entry.item != Self.rootItemID,
                  ReaderMessage.isItemID(entry.parent), entry.nativeID != 0, entry.size >= 0,
                  !entry.contentVersion.isEmpty, entry.contentVersion.utf8.count <= 128,
                  let path = RelativePath(entry.path),
                  path.components.last?.utf8.elementsEqual(entry.name.utf8) == true,
                  path.components.count >= source.components.count,
                  path.components.prefix(source.components.count).joined(separator: "/")
                    .utf8.elementsEqual(source.string.utf8),
                  let suffix = RelativePath(path.components.dropFirst(source.components.count).joined(separator: "/")),
                  let destination = target.appending(suffix), destination.components.count <= Self.maxDepth else {
                throw UploadError.unresolved
            }
            if entry.item != root.item {
                guard let ancestor = entries[entry.parent], ancestor.kind == .folder,
                      let ancestorPath = RelativePath(ancestor.path)?.appending(entry.name),
                      ancestorPath.string.utf8.elementsEqual(entry.path.utf8) else { throw UploadError.unresolved }
            }
            result[entry.item] = destination
        }
        return result
    }
}
