import Darwin
import Foundation
import OSLog

extension LocationSource {
    static func renameOutbox() throws -> FileRenameOutbox {
        try FileRenameOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Renames", directoryHint: .isDirectory))
    }

    func renameRecords() throws -> [PendingFileRename] {
        try editNamespace.perform {
            try Self.renameOutbox().records().filter { record in
                record.isPending && record.views.contains { $0.domain == domainID }
            }
        }
    }

    func renameFile(_ request: FileRenameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try editNamespace.perform {
                _ = try renameAccess()
                let outbox = try Self.renameOutbox()
                var record: PendingFileRename
                if let previous = try outbox.replay(owner: domainID, request: request) {
                    record = previous
                } else {
                    try editNamespace.requireSettled()
                    let path = try withCatalog { catalog -> RelativePath in
                        guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsEditing,
                              row.kind == .file, row.parentID == request.parent,
                              row.contentVersion == request.contentVersion,
                              FileRenameRequest.supportsName(row.name),
                              let relative = try catalog.relativePath(of: row.id), let path = folder.appending(relative) else {
                            throw SourceFailure.versionChanged
                        }
                        if let other = try catalog.liveChild(parent: request.parent, nameKey: NameKey(request.name)),
                           other.id != row.id { throw UploadError.collision }
                        return path
                    }
                    if path.components.last?.utf8.elementsEqual(request.name.utf8) == true {
                        return CreateReceipt(item: request.item)
                    }
                    guard let base = try Self.editOutbox(domainID: domainID)
                        .base(item: request.item, contentVersion: request.contentVersion) else {
                        throw UploadError.unresolved
                    }
                    let views = try editNamespace.affectedSources(path: path).compactMap {
                        try $0.renameView(path: path, base: base.version, destination: request.name)
                    }
                    record = try outbox.prepare(owner: domainID, request: request, base: base, source: path, views: views)
                }
                try finishRename(&record, outbox: outbox, progress: progress)
                return CreateReceipt(item: request.item)
            } }
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            logger.info("file_rename request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
            if case .failure(let error) = result {
                logger.error("file_rename request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                _ = try? listOnLane(request.parent, requestID: request.id)
            }
            scheduleSignal()
            reply(result)
        }
    }

    func retryRenames() {
        access.enqueue { [self] in
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            do { try editNamespace.perform {
                let outbox = try Self.renameOutbox()
                for var record in try outbox.records() where record.isPending && record.owner == domainID {
                    do { try finishRename(&record, outbox: outbox, progress: Progress()) }
                    catch {
                        logger.error("rename_retry id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                    }
                }
            } } catch {
                logger.error("rename_retry failed \(logFields(error), privacy: .public)")
            }
            scheduleSignal()
        }
    }

    private func renameAccess() throws -> Data {
        try uploadLock.withLock {
            guard !mutationsSuspended, let bookmark = writeBookmark,
                  try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsEditing }) == true else {
                throw UploadError.readOnly
            }
            return bookmark
        }
    }

    private func renameView(path: RelativePath, base: EditFileVersion, destination: String) throws -> FileRenameView? {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let uploads = try Self.outbox(domainID: domainID), edits = try Self.editOutbox(domainID: domainID)
            guard try uploads.pendingCount == uploads.records().filter(\.isPending).count,
                  try edits.pendingCount == edits.records().filter(\.isPending).count else { throw UploadError.pendingWrites }
            let target = path.components.dropLast().joined(separator: "/") + "/" + destination
            for pending in try uploads.records().filter(\.isPending).map(\.path)
                + edits.records().filter(\.isPending).map(\.path) {
                guard let relative = RelativePath(pending), let full = folder.appending(relative) else {
                    throw UploadError.unresolved
                }
                let key = NameKey(full.string).value
                guard key != NameKey(path.string).value,
                      key != NameKey(target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).value,
                      !NameKey(path.string).value.hasPrefix(key + "/") else { throw UploadError.pendingWrites }
            }
            let relative = RelativePath(path.components.dropFirst(folder.components.count).joined(separator: "/"))!
            let candidate = try withCatalog { catalog -> (CatalogRow, RelativePath, UInt64)? in
                var id = Catalog.rootItemID
                for component in relative.components {
                    guard let row = try catalog.liveChild(parent: id, nameKey: NameKey(component)) else { return nil }
                    id = row.id
                }
                guard let row = try catalog.item(id: id), row.kind == .file, !row.deleted,
                      let actual = try catalog.relativePath(of: id), let identity = try catalog.remoteIdentity(id),
                      folder.appending(actual)?.string.utf8.elementsEqual(path.string.utf8) == true else {
                    throw UploadError.unresolved
                }
                if let other = try catalog.liveChild(parent: row.parentID!, nameKey: NameKey(destination)),
                   other.id != row.id { throw UploadError.collision }
                return (row, actual, identity)
            }
            guard let (row, actual, identity) = candidate else { return nil }
            let native = try renameSnapshot(path: actual, version: base, refresh: false)
            guard native.inode == identity else { throw SourceFailure.versionChanged }
            if row.contentVersion.hasPrefix("e1:") {
                guard let receipt = try edits.base(item: row.id, contentVersion: row.contentVersion),
                      receipt.version.hasSameContents(as: base) else { throw SourceFailure.versionChanged }
            } else {
                guard native.fingerprint == ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
                else { throw SourceFailure.versionChanged }
            }
            return try FileRenameView(domain: domainID, folder: folder, row: row, path: actual, nativeID: identity)
        }
    }

    private func finishRename(_ record: inout PendingFileRename, outbox: FileRenameOutbox, progress: Progress) throws {
        if record.state == .completed { return }
        let bookmark = try renameAccess()
        guard record.owner == domainID,
              record.views.contains(where: { $0.domain == domainID && $0.folder.utf8.elementsEqual(folder.string.utf8) })
        else { throw UploadError.unresolved }
        try editNamespace.requireSettled(excluding: record.id)
        let participants = try record.views.map { view -> (FileRenameView, LocationSource) in
            let source = try editNamespace.source(view.domain)
            guard source.folder.string.utf8.elementsEqual(view.folder.utf8) else { throw UploadError.unresolved }
            return (view, source)
        }
        try withWriteSession(bookmark, progress: progress) { session, _ in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: session.root, progress: progress)
            try remote.protectAncestors(of: record.source)
            try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
            guard let version = record.verified else { throw UploadError.unresolved }
            try remote.allowPublishedReads(path: record.destination, expected: version)
            guard let evidence = try remote.inspectRename(path: record.destination),
                  evidence.name.utf8.elementsEqual(record.name.utf8), evidence.version.hasSameContents(as: version) else {
                throw UploadError.unresolved
            }
            for (view, source) in participants {
                guard let oldPath = RelativePath(view.path),
                      let parent = RelativePath(oldPath.components.dropLast().joined(separator: "/")),
                      let destination = parent.appending(record.name) else { throw UploadError.unresolved }
                // Recovery must finish on the admitted session even if a slow handshake defers new requests.
                let native = try source.access === access
                    ? source.renameSnapshot(path: destination, version: version, refresh: true, session: session,
                                     progressed: { progress.completedUnitCount += 1 })
                    : source.renameSnapshot(path: destination, version: version, refresh: true)
                try source.withCatalog {
                    try $0.commitFileRename(record, view: view, fingerprint: native.fingerprint, nativeID: native.inode)
                }
            }
            record.state = .completed
            try outbox.save(record)
            for (_, source) in participants { source.scheduleSignal() }
        }
    }

    private func renameSnapshot(path: RelativePath, version: EditFileVersion, refresh: Bool) throws -> FileSnapshot {
        try access.withSession { session, progressed in
            try renameSnapshot(path: path, version: version, refresh: refresh, session: session, progressed: progressed)
        }
    }

    private func renameSnapshot(path: RelativePath, version: EditFileVersion, refresh: Bool,
                                session: ShareSession, progressed: @escaping Progressed) throws -> FileSnapshot {
        let root = try session.locationRoot(folder)
        return try session.identity.guarding(root: root) {
            if refresh {
                let parent = RelativePath(path.components.dropLast().joined(separator: "/"))!
                let listing = try DirectoryListing.list(locationRoot: root, relativePath: parent,
                                                        expected: session.identity, progress: progressed)
                guard listing.entries.contains(where: { $0.name.utf8.elementsEqual(path.components.last!.utf8) })
                else { throw UploadError.unresolved }
            }
            let fd = openat(root, path.string, O_EVTONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
            guard fd >= 0 else { throw posixError("inspect renamed file") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == version.size,
                  info.st_birthtimespec.tv_sec > 0,
                  UInt64(info.st_birthtimespec.tv_sec) * 1_000_000 + UInt64(info.st_birthtimespec.tv_nsec / 1_000)
                    == version.identity.birthMicroseconds,
                  info.st_mtimespec.tv_sec >= 0,
                  UInt64(info.st_mtimespec.tv_sec) * 1_000_000 + UInt64(info.st_mtimespec.tv_nsec / 1_000)
                    == version.modifiedMicroseconds else { throw UploadError.unresolved }
            return try FileSnapshot(fd: fd)
        }
    }
}
