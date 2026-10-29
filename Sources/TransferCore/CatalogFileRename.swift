import Foundation

extension Catalog {
    public func commitFileRename(_ rename: PendingFileRename, view: FileRenameView,
                                 fingerprint: ContentFingerprint, nativeID: UInt64) throws {
        try rename.validate()
        try write { seq in
            guard [.verified, .completed].contains(rename.state), rename.views.contains(view), view.domain == domainID,
                  fingerprint.size == rename.base.version.size, nativeID != 0,
                  let row = try item(id: view.item), !row.deleted, row.kind == .file,
                  row.parentID == view.parent, row.contentVersion == view.contentVersion,
                  let parent = try relativePath(of: view.parent),
                  parent.appending(rename.oldName)?.string.utf8.elementsEqual(view.path.utf8) == true else {
                throw UploadError.unresolved
            }
            let currentID = try remoteIdentity(row.id)
            let alreadyNamed = row.name.utf8.elementsEqual(rename.name.utf8)
            if alreadyNamed, currentID == nativeID, row.size == fingerprint.size,
               row.mtimeNs == fingerprint.mtimeNs, row.ctimeNs == fingerprint.ctimeNs { return }
            guard (row.name.utf8.elementsEqual(rename.oldName.utf8) && currentID == view.nativeID) || alreadyNamed else {
                throw UploadError.unresolved
            }
            if let other = try liveChild(parent: view.parent, nameKey: NameKey(rename.name)), other.id != row.id {
                throw UploadError.collision
            }
            seq += 1
            try database.prepare("""
                UPDATE items SET name = ?, name_key = ?, size = ?, mtime_ns = ?, ctime_ns = ?,
                                 file_id = ?, edit_version = ?, change_seq = ? WHERE id = ?
                """) {
                try $0.bind(1, rename.name)
                try $0.bind(2, NameKey(rename.name).value)
                try $0.bind(3, fingerprint.size)
                try $0.bind(4, fingerprint.mtimeNs)
                try $0.bind(5, fingerprint.ctimeNs)
                try $0.bind(6, Int64(bitPattern: nativeID))
                try $0.bind(7, view.contentVersion)
                try $0.bind(8, seq)
                try $0.bind(9, row.id)
                try $0.run()
            }
        }
    }
}
