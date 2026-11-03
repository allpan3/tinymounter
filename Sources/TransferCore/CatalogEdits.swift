import Foundation

extension Catalog {
    public func setAllowsWriting(_ enabled: Bool) throws {
        try write { seq in
            guard let root = try item(id: Self.rootItemID) else { throw UploadError.unresolved }
            guard root.allowsWriting != enabled else { return }
            try database.prepare("UPDATE meta SET allows_writing = ? WHERE id = 1") {
                try $0.bind(1, enabled)
                try $0.run()
            }
            for row in try items("SELECT \(CatalogRow.columns) FROM items WHERE deleted = 0") {
                seq += 1
                try database.prepare("UPDATE items SET change_seq = ? WHERE id = ?") {
                    try $0.bind(1, seq)
                    try $0.bind(2, row.id)
                    try $0.run()
                }
            }
        }
    }

    public func refreshEditBase(_ receipt: EditBaseReceipt, expectedVersion: String,
                                fingerprint: ContentFingerprint, nativeID: UInt64) throws {
        try write { seq in
            guard let row = try item(id: receipt.item), row.kind == .file, !row.deleted,
                  row.contentVersion == expectedVersion, fingerprint.size == receipt.version.size else {
                throw UploadError.unresolved
            }
            seq += 1
            try database.prepare("""
                UPDATE items SET size = ?, mtime_ns = ?, ctime_ns = ?, file_id = ?, edit_version = ?, change_seq = ?
                WHERE id = ?
                """) {
                try $0.bind(1, fingerprint.size)
                try $0.bind(2, fingerprint.mtimeNs)
                try $0.bind(3, fingerprint.ctimeNs)
                try $0.bind(4, Int64(bitPattern: nativeID))
                try $0.bind(5, receipt.contentVersion)
                try $0.bind(6, seq)
                try $0.bind(7, row.id)
                try $0.run()
            }
        }
    }

    public func rememberEditBase(_ receipt: EditBaseReceipt, expectedVersion: String) throws {
        try write { seq in
            guard let row = try item(id: receipt.item), row.kind == .file, !row.deleted,
                  row.allowsWriting, row.size == receipt.version.size else { throw UploadError.unresolved }
            if row.contentVersion == receipt.contentVersion { return }
            guard row.contentVersion == expectedVersion else { throw UploadError.unresolved }
            seq += 1
            try database.prepare("UPDATE items SET edit_version = ?, change_seq = ? WHERE id = ?") {
                try $0.bind(1, receipt.contentVersion)
                try $0.bind(2, seq)
                try $0.bind(3, row.id)
                try $0.run()
            }
        }
    }

    // A racing save still needs exportable local storage after its file or parent was deleted.
    public func editRetentionPath(item id: String, parent: String, name: String) throws -> RelativePath {
        guard let row = try item(id: id), row.allowsWriting, row.kind == .file,
              row.parentID == parent, row.name.utf8.elementsEqual(name.utf8),
              let path = try path(of: id, includingDeleted: true), !path.isRoot else {
            throw UploadError.readOnly
        }
        return path
    }

    public func validateEditTarget(_ edit: PendingEdit) throws {
        guard let row = try item(id: edit.item), !row.deleted, row.allowsWriting,
              row.kind == .file, row.parentID == edit.parent,
              try relativePath(of: row.id)?.string == edit.path else { throw UploadError.unresolved }
    }

    public func commitEdit(_ edit: PendingEdit, fingerprint: ContentFingerprint, nativeID: UInt64) throws -> String {
        try write { seq in
            guard edit.state == .published || edit.state == .completed, let receipt = edit.published,
                  receipt.version.identity == edit.publishedIdentity, receipt.version.digest == edit.digest,
                  receipt.version.size == edit.size, fingerprint.size == edit.size,
                  let destination = RelativePath(edit.destination), let name = destination.components.last,
                  let parent = try item(id: edit.parent), !parent.deleted, parent.kind == .folder,
                  let parentPath = try relativePath(of: parent.id), parentPath.appending(name) == destination else {
                throw UploadError.unresolved
            }
            let id = edit.conflict ? edit.id.uuidString : edit.item
            guard receipt.item == id else { throw UploadError.unresolved }
            if let collision = try liveChild(parent: parent.id, nameKey: NameKey(name)), collision.id != id {
                throw UploadError.collision
            }
            if let current = try item(id: id) {
                guard !current.deleted, current.parentID == edit.parent, current.kind == .file,
                      current.name.utf8.elementsEqual(name.utf8) else { throw UploadError.unresolved }
                if current.contentVersion == receipt.contentVersion { return id }
                guard !edit.conflict else { throw UploadError.unresolved }
                seq += 1
                try database.prepare("""
                    UPDATE items SET size = ?, mtime_ns = ?, ctime_ns = ?, file_id = ?, edit_version = ?, change_seq = ?
                    WHERE id = ?
                    """) {
                    try $0.bind(1, fingerprint.size)
                    try $0.bind(2, fingerprint.mtimeNs)
                    try $0.bind(3, fingerprint.ctimeNs)
                    try $0.bind(4, Int64(bitPattern: nativeID))
                    try $0.bind(5, receipt.contentVersion)
                    try $0.bind(6, seq)
                    try $0.bind(7, id)
                    try $0.run()
                }
            } else {
                guard edit.conflict else { throw UploadError.unresolved }
                seq += 1
                try database.prepare("""
                    INSERT INTO items(id, parent_id, name, name_key, kind, size, mtime_ns, ctime_ns, file_id,
                                      edit_version, change_seq, keep, enumeration_key)
                    VALUES (?, ?, ?, ?, 2, ?, ?, ?, ?, ?, ?, ?, ?)
                    """) {
                    try $0.bind(1, id)
                    try $0.bind(2, parent.id)
                    try $0.bind(3, name)
                    try $0.bind(4, NameKey(name).value)
                    try $0.bind(5, fingerprint.size)
                    try $0.bind(6, fingerprint.mtimeNs)
                    try $0.bind(7, fingerprint.ctimeNs)
                    try $0.bind(8, Int64(bitPattern: nativeID))
                    try $0.bind(9, receipt.contentVersion)
                    try $0.bind(10, seq)
                    try $0.bind(11, parent.keep)
                    try $0.bind(12, NameKey(name).value)
                    try $0.run()
                }
            }
            return id
        }
    }
}
