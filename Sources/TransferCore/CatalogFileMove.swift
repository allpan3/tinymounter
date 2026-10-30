import Foundation

// Only a verified remote transaction may preserve versions across a parent change.
public struct CatalogFileMove: Equatable, Sendable {
    public let item: String
    public let sourceParent: String
    public let sourceName: String
    public let contentVersion: String
    // Admission's native lookup guards catalog changes; it is not server identity.
    public let sourceNativeID: UInt64
    public let destinationParent: String
    public let destinationName: String

    public init(item: String, sourceParent: String, sourceName: String, contentVersion: String,
                sourceNativeID: UInt64, destinationParent: String, destinationName: String) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID, ReaderMessage.isItemID(sourceParent),
              ReaderMessage.isItemID(destinationParent), item != sourceParent, item != destinationParent,
              FileRenameRequest.supportsName(sourceName), FileRenameRequest.supportsName(destinationName),
              sourceParent != destinationParent || !sourceName.utf8.elementsEqual(destinationName.utf8),
              !contentVersion.isEmpty, contentVersion.utf8.count <= 128, sourceNativeID != 0 else {
            throw UploadError.invalidRequest
        }
        self.item = item
        self.sourceParent = sourceParent
        self.sourceName = sourceName
        self.contentVersion = contentVersion
        self.sourceNativeID = sourceNativeID
        self.destinationParent = destinationParent
        self.destinationName = destinationName
    }
}

extension Catalog {
    // Caller protection keeps this catalog commit tied to the verified remote move.
    public func commitFileMove(_ move: CatalogFileMove, fingerprint: ContentFingerprint, nativeID: UInt64) throws {
        try write { seq in
            guard nativeID != 0, let row = try item(id: move.item), !row.deleted, row.kind == .file,
                  row.contentVersion == move.contentVersion, row.size == fingerprint.size,
                  let destination = try item(id: move.destinationParent), !destination.deleted,
                  destination.kind == .folder, destination.listGen != nil,
                  try relativePath(of: destination.id)?.appending(move.destinationName) != nil else {
                throw UploadError.unresolved
            }
            let currentID = try remoteIdentity(row.id)
            let moved = row.parentID == destination.id && row.name.utf8.elementsEqual(move.destinationName.utf8)
            if moved, currentID == nativeID, row.mtimeNs == fingerprint.mtimeNs, row.ctimeNs == fingerprint.ctimeNs {
                return
            }
            guard moved || (row.parentID == move.sourceParent && row.name.utf8.elementsEqual(move.sourceName.utf8)
                            && currentID == move.sourceNativeID) else { throw UploadError.unresolved }
            if let other = try liveChild(parent: destination.id, nameKey: NameKey(move.destinationName)),
               other.id != row.id { throw UploadError.collision }
            seq += 1
            // The pinned version keeps the downloaded copy; a legacy version stays legacy.
            try database.prepare("""
                UPDATE items SET parent_id = ?, name = ?, name_key = ?, size = ?, mtime_ns = ?, ctime_ns = ?,
                                 file_id = ?, edit_version = ?, keep = ?, change_seq = ? WHERE row = ?
                """) {
                try $0.bind(1, destination.id)
                try $0.bind(2, move.destinationName)
                try $0.bind(3, NameKey(move.destinationName).value)
                try $0.bind(4, fingerprint.size)
                try $0.bind(5, fingerprint.mtimeNs)
                try $0.bind(6, fingerprint.ctimeNs)
                try $0.bind(7, Int64(bitPattern: nativeID))
                try $0.bind(8, row.contentVersion)
                try $0.bind(9, row.keepRequested || destination.keep)
                try $0.bind(10, seq)
                try $0.bind(11, row.row)
                try $0.run()
            }
            guard !moved, move.sourceParent != destination.id else { return }
            try database.prepare("INSERT OR REPLACE INTO departures (item, parent, seq) VALUES (?, ?, ?)") {
                try $0.bind(1, row.id)
                try $0.bind(2, move.sourceParent)
                try $0.bind(3, seq)
                try $0.run()
            }
            // An item back in a folder reaches its observers through its own row again.
            try database.prepare("DELETE FROM departures WHERE item = ? AND parent = ?") {
                try $0.bind(1, row.id)
                try $0.bind(2, destination.id)
                try $0.run()
            }
        }
    }
}
