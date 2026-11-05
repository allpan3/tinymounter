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

    public func editTarget(_ request: EditRequest, checkingVersion: Bool = true) throws
        -> (CatalogRow, RelativePath) {
        guard let row = try item(id: request.item), !row.deleted else { throw SourceFailure.missing }
        guard row.allowsWriting, row.kind == .file else { throw UploadError.readOnly }
        guard row.parentID == request.parent, row.name.utf8.elementsEqual(request.name.utf8),
              let path = try relativePath(of: row.id), !path.isRoot else { throw SourceFailure.versionChanged }
        if checkingVersion && request.failOnConflict && row.contentVersion != request.baseVersion {
            throw UploadError.editConflict
        }
        return (row, path)
    }
}
