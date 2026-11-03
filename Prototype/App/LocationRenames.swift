import Darwin
import Foundation
import OSLog

extension LocationSource {
    static func renameOutbox() throws -> FileRenameOutbox {
        try FileRenameOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Renames", directoryHint: .isDirectory))
    }

    func renameRecords() throws -> [RenameIntent] {
        try editNamespace.readForStatus {
            try Self.renameOutbox().intents().filter { $0.isPending && $0.domains.contains(domainID) }
        }
    }

    func renameFile(_ request: FileRenameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let finish: @Sendable (Result<CreateReceipt, Error>) -> Void = { result in
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .info("file_rename request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
                reply(result)
            }
            let result = Result { try editNamespace.perform { () -> PendingFileRename? in
                _ = try renameAccess()
                let outbox = try Self.renameOutbox()
                if var record = try outbox.replayFile(owner: domainID, request: request) {
                    if renameCompletions[record.id] == nil {
                        try finishRename(&record, outbox: outbox, progress: progress)
                    }
                    return record
                }
                return try startRename(request, outbox: outbox, progress: progress)
            } }
            switch result {
            case .success(let record):
                if let record { completeRename(record, reply: finish) }
                else { finish(.success(CreateReceipt(item: request.item))) }
            case .failure(let error):
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .error("file_rename request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
                finish(.failure(error))
            }
        }
    }

    private func startRename(_ request: FileRenameRequest, outbox: FileRenameOutbox,
                             progress: Progress) throws -> PendingFileRename? {
        try editNamespace.requireSettled()
        let bookmark = try renameAccess()
        let (path, destination) = try withCatalog { catalog -> (RelativePath, RelativePath) in
            guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsWriting,
                  row.kind == .file, row.contentVersion == request.contentVersion,
                  FileRenameRequest.supportsName(row.name),
                  let parent = try catalog.item(id: request.parent), !parent.deleted,
                  parent.kind == .folder,
                  let relative = try catalog.relativePath(of: row.id), let path = folder.appending(relative),
                  let target = try catalog.relativePath(of: parent.id)?.appending(request.name),
                  let destination = folder.appending(target) else { throw SourceFailure.versionChanged }
            try request.validateUnchangedFields(in: row)
            if let other = try catalog.liveChild(parent: parent.id, nameKey: NameKey(request.name)),
               other.id != row.id { throw UploadError.collision }
            return (path, destination)
        }
        if SMBName.same(path.string, destination.string) { return nil }
        let sources = try editNamespace.affectedSources(source: path, destination: destination)
        for source in sources { try source.requireRenamePathsSettled(source: path, destination: destination) }
        for source in sources { try source.prepareRenameFolders(source: path, destination: destination) }
        return try withWriteSession(bookmark, progress: progress) { session, _ in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: session.root, progress: progress)
            let parents = try remote.protectRenameParents(source: path.string, destination: destination.string)
            guard let evidence = try remote.inspectRename(path: path.string),
                  evidence.name == path.components.last else { throw SourceFailure.versionChanged }
            let base: EditBaseReceipt
            if request.contentVersion.hasPrefix("e1:") {
                guard let receipt = try Self.editOutbox(domainID: domainID)
                    .base(item: request.item, contentVersion: request.contentVersion),
                      receipt.version.hasSameContents(as: evidence.version) else { throw SourceFailure.versionChanged }
                base = receipt
            } else {
                base = try EditBaseReceipt(item: request.item, version: evidence.version)
            }
            let views = try sources.map {
                try $0.renameView(path: path, destination: destination, version: evidence.version,
                                  parents: parents, session: $0.access === access ? session : nil)
            }
            guard let source = RelativePath((path.components.dropLast() + [evidence.name]).joined(separator: "/")) else {
                throw UploadError.unresolved
            }
            var record = try outbox.prepareFile(owner: domainID, request: request, base: base, source: source,
                                                views: views, destination: destination, parents: parents)
            // Case aliases need one delete-capable handle; publication revalidates after reopening.
            if NameKey(source.string) == NameKey(destination.string) { try remote.releaseRename(path: source.string) }
            try finishRename(&record, outbox: outbox, progress: progress, session: session, remote: remote)
            return record
        }
    }

    func prepareRenameFolders(source: RelativePath, destination: RelativePath) throws {
        var listed: Set<String> = []
        for path in [source, destination] {
            var id = Catalog.rootItemID
            for component in path.components.dropFirst(folder.components.count).dropLast() {
                if listed.insert(id).inserted { _ = try listOnLane(id, requestID: UUID()) }
                guard let child = try liveChild(of: id, named: component), child.kind == .folder,
                      child.name == component else { throw UploadError.unresolved }
                id = child.id
            }
            if listed.insert(id).inserted { _ = try listOnLane(id, requestID: UUID()) }
        }
    }

    func retryRenames() {
        access.enqueue { [self] in
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            do {
                let (ready, folders) = try editNamespace.perform { () -> ([PendingFileRename], [UUID]) in
                    let outbox = try Self.renameOutbox()
                    var ready: [PendingFileRename] = [], folders: [UUID] = []
                    for intent in try outbox.intents() where intent.isPending && intent.owner == domainID {
                        guard case .file(var record) = intent else {
                            folders.append(intent.id)
                            continue
                        }
                        guard renameCompletions[record.id] == nil else { continue }
                        do {
                            try finishRename(&record, outbox: outbox, progress: Progress())
                            ready.append(record)
                        } catch {
                            logger.error("rename_retry id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    return (ready, folders)
                }
                for record in ready {
                    completeRename(record) { result in
                        if case .failure(let error) = result {
                            logger.error("rename_settings id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                }
                for id in folders {
                    do { try retryFolderMove(id) }
                    catch {
                        logger.error("folder_move_retry id=\(id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                    }
                }
            } catch {
                logger.error("rename_retry failed \(logFields(error), privacy: .public)")
            }
            scheduleSignal()
        }
    }

    func renameAccess() throws -> Data {
        try uploadLock.withLock {
            guard !mutationsSuspended, let bookmark = writeBookmark,
                  try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsWriting }) == true else {
                throw UploadError.readOnly
            }
            return bookmark
        }
    }

    private func requireRenamePathsSettled(source: RelativePath, destination: RelativePath) throws {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let uploads = try Self.outbox(domainID: domainID), edits = try Self.editOutbox(domainID: domainID)
            let pendingUploads = try uploads.records().filter(\.isPending)
            let pendingEdits = try edits.records().filter(\.isPending)
            guard try uploads.pendingCount == pendingUploads.count,
                  try edits.pendingCount == pendingEdits.count else { throw UploadError.pendingWrites }
            for pending in pendingUploads.map(\.path) + pendingEdits.map(\.path) {
                guard let relative = RelativePath(pending), let full = folder.appending(relative) else {
                    throw UploadError.unresolved
                }
                let key = NameKey(full.string).value
                guard [source, destination].allSatisfy({
                    NameKey($0.string).value != key && !NameKey($0.string).value.hasPrefix(key + "/")
                }) else { throw UploadError.pendingWrites }
            }
        }
    }

    private func renameView(path: RelativePath, destination: RelativePath, version: EditFileVersion,
                            parents: [FileRenameParent], session: ShareSession?) throws -> FileRenameView {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let relative = RelativePath(path.components.dropFirst(folder.components.count).joined(separator: "/"))!
            let target = RelativePath(destination.components.dropFirst(folder.components.count).dropLast().joined(separator: "/"))!
            let (row, actual, identity, destinationParent) = try withCatalog { catalog in
                func resolve(_ path: RelativePath) throws -> String {
                    var id = Catalog.rootItemID
                    for component in path.components {
                        guard let row = try catalog.liveChild(parent: id, nameKey: NameKey(component)), row.name == component else {
                            throw UploadError.unresolved
                        }
                        id = row.id
                    }
                    return id
                }
                let id = try resolve(relative), parent = try resolve(target)
                guard let row = try catalog.item(id: id), row.kind == .file, !row.deleted,
                      let actual = try catalog.relativePath(of: id), let identity = try catalog.remoteIdentity(id),
                      folder.appending(actual)?.string == path.string,
                      let destinationRow = try catalog.item(id: parent), destinationRow.kind == .folder,
                      destinationRow.listGen != nil else { throw UploadError.unresolved }
                if let other = try catalog.liveChild(parent: parent, nameKey: NameKey(destination.components.last!)),
                   other.id != row.id { throw UploadError.collision }
                return (row, actual, identity, parent)
            }
            let native: FileSnapshot
            if let session {
                try validateRenameParents([row.parentID!, destinationParent], parents: parents, session: session)
                native = try renameSnapshot(path: actual, version: version, refresh: true,
                                            session: session, progressed: {})
            } else {
                native = try access.withSession { session, progressed in
                    try validateRenameParents([row.parentID!, destinationParent], parents: parents, session: session)
                    return try renameSnapshot(path: actual, version: version, refresh: true,
                                               session: session, progressed: progressed)
                }
            }
            guard native.inode == identity else { throw SourceFailure.versionChanged }
            if row.contentVersion.hasPrefix("e1:") {
                guard let receipt = try Self.editOutbox(domainID: domainID)
                    .base(item: row.id, contentVersion: row.contentVersion),
                      receipt.version.hasSameContents(as: version) else { throw SourceFailure.versionChanged }
            } else {
                guard native.fingerprint == ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs),
                      row.size == version.size, row.mtimeNs >= 0, row.ctimeNs >= 0,
                      UInt64(row.mtimeNs / 1_000) == version.modifiedMicroseconds,
                      UInt64(row.ctimeNs / 1_000) == version.changedMicroseconds else { throw SourceFailure.versionChanged }
            }
            return try FileRenameView(domain: domainID, folder: folder, row: row, path: actual,
                                      nativeID: identity, destinationParent: destinationParent)
        }
    }

    func validateRenameParents(_ ids: [String], parents: [FileRenameParent], session: ShareSession) throws {
        let root = try session.locationRoot(folder)
        for id in Set(ids) {
            let (relative, nativeID) = try withCatalog { catalog in
                guard let row = try catalog.item(id: id), row.kind == .folder, !row.deleted,
                      let path = try catalog.relativePath(of: id) else { throw UploadError.unresolved }
                return (path, try catalog.remoteIdentity(id))
            }
            guard let full = folder.appending(relative), let parent = parents.first(where: { $0.path == full.string }) else {
                throw UploadError.unresolved
            }
            let fd = openat(root, relative.isRoot ? "." : relative.string,
                            O_EVTONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
            guard fd >= 0 else { throw posixError("inspect move parent") }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  relative.isRoot || UInt64(info.st_ino) == nativeID,
                  full.isRoot || (info.st_birthtimespec.tv_sec > 0
                    && UInt64(info.st_birthtimespec.tv_sec) * 1_000_000 + UInt64(info.st_birthtimespec.tv_nsec / 1_000)
                        == parent.identity.birthMicroseconds) else { throw UploadError.unresolved }
        }
    }

    private func finishRename(_ record: inout PendingFileRename, outbox: FileRenameOutbox, progress: Progress) throws {
        if record.state == .completed { return }
        let bookmark = try renameAccess()
        try withWriteSession(bookmark, progress: progress) { session, _ in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: session.root, progress: progress)
            try finishRename(&record, outbox: outbox, progress: progress, session: session, remote: remote)
        }
    }

    private func finishRename(_ record: inout PendingFileRename, outbox: FileRenameOutbox, progress: Progress,
                              session: ShareSession, remote: SMBEdit) throws {
        guard record.owner == domainID, let sourcePath = RelativePath(record.source),
              let destination = RelativePath(record.destination),
              record.views.contains(where: { $0.domain == domainID && $0.folder == folder.string }) else {
            throw UploadError.unresolved
        }
        try editNamespace.requireSettled(excluding: record.id)
        let affected = try editNamespace.affectedSources(source: sourcePath, destination: destination)
        guard Set(affected.map(\.domainID)) == Set(record.views.map(\.domain)) else { throw UploadError.unresolved }
        let participants = try record.views.map { view -> (FileRenameView, LocationSource) in
            let source = try editNamespace.source(view.domain)
            guard source.folder.string == view.folder else { throw UploadError.unresolved }
            try source.withCatalog { catalog in
                guard let parent = try catalog.relativePath(of: view.targetParent),
                      source.folder.appending(parent)?.appending(record.name)?.string == destination.string else {
                    throw UploadError.unresolved
                }
            }
            return (view, source)
        }
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        guard let version = record.verified else { throw UploadError.unresolved }
        try remote.allowPublishedReads(path: record.destination, expected: version)
        guard let evidence = try remote.inspectRename(path: record.destination),
              evidence.name.utf8.elementsEqual(record.name.utf8), evidence.version.hasSameContents(as: version) else {
            throw UploadError.unresolved
        }
        let sourceEntry = try NameKey(record.source) != NameKey(record.destination)
            ? remote.renameSourceEntry(path: record.source) : nil
        for (view, source) in participants {
            let relative = RelativePath(destination.components.dropFirst(source.folder.components.count).joined(separator: "/"))!
            if NameKey(record.source) != NameKey(record.destination) {
                guard let oldPath = RelativePath(view.path) else { throw UploadError.unresolved }
                if source.access === access {
                    try source.refreshRenameSource(oldPath, entry: sourceEntry, session: session)
                } else {
                    try source.access.withSession { session, _ in
                        try source.refreshRenameSource(oldPath, entry: sourceEntry, session: session)
                    }
                }
            }
            let native = try source.access === access
                ? source.renameSnapshot(path: relative, version: version, refresh: true, session: session,
                                         progressed: { progress.completedUnitCount += 1 })
                : source.renameSnapshot(path: relative, version: version, refresh: true)
            guard let oldName = RelativePath(view.path)?.components.last else { throw UploadError.unresolved }
            let move = try CatalogFileMove(item: view.item, sourceParent: view.parent, sourceName: oldName,
                                            contentVersion: view.contentVersion, sourceNativeID: view.nativeID,
                                            destinationParent: view.targetParent, destinationName: record.name)
            try source.withCatalog { try $0.commitFileMove(move, fingerprint: native.fingerprint, nativeID: native.inode) }
        }
    }

    private func refreshRenameSource(_ path: RelativePath, entry: RenameDirectoryEntry?, session: ShareSession) throws {
        let root = try session.locationRoot(folder)
        let parent = RelativePath(path.components.dropLast().joined(separator: "/"))!
        let listing = try DirectoryListing.list(locationRoot: root, relativePath: parent, expected: session.identity)
        let key = NameKey(path.components.last!)
        guard !listing.unreadable.contains(where: { $0.key == key }),
              !listing.collisionLosers.contains(where: { $0.key == key }) else { throw UploadError.unresolved }
        guard let entry else {
            guard !listing.entries.contains(where: { $0.key == key }) else { throw UploadError.unresolved }
            return
        }
        guard listing.entries.contains(where: { $0.name == entry.name }) else { throw UploadError.unresolved }
        let fd = openat(root, path.string, O_EVTONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("refresh moved file source") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_birthtimespec.tv_sec > 0,
              UInt64(info.st_birthtimespec.tv_sec) * 1_000_000 + UInt64(info.st_birthtimespec.tv_nsec / 1_000)
                == entry.identity.birthMicroseconds else { throw UploadError.unresolved }
    }

    private func completeRename(_ record: PendingFileRename,
                                reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        if record.state == .completed { reply(.success(CreateReceipt(item: record.base.item))); return }
        if renameCompletions[record.id] != nil {
            renameCompletions[record.id]?.append(reply)
            return
        }
        renameCompletions[record.id] = [reply]
        Task { [self] in
            let settingsResult: Result<Void, Error>
            do {
                try await renameSettings(.file(record))
                settingsResult = .success(())
            } catch {
                settingsResult = .failure(error)
            }
            access.enqueue { [self] in
                let result = Result {
                    try settingsResult.get()
                    return try editNamespace.perform {
                        let outbox = try Self.renameOutbox()
                        guard case .file(var current)? = try outbox.intents().first(where: { $0.id == record.id }),
                              [.verified, .completed].contains(current.state) else { throw UploadError.unresolved }
                        if current.state == .completed { return CreateReceipt(item: current.base.item) }
                        current.state = .completed
                        try outbox.save(current)
                        for view in current.views {
                            let source = try editNamespace.source(view.domain)
                            source.signalFolders([view.parent, view.targetParent])
                            source.scheduleSignal()
                        }
                        return CreateReceipt(item: current.base.item)
                    }
                }
                let replies = renameCompletions.removeValue(forKey: record.id) ?? []
                for reply in replies { reply(result) }
            }
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
                guard listing.entries.contains(where: { $0.name == path.components.last! })
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
            let snapshot = try FileSnapshot(fd: fd)
            guard snapshot.fingerprint.ctimeNs >= 0,
                  UInt64(snapshot.fingerprint.ctimeNs / 1_000) == version.changedMicroseconds else {
                throw UploadError.unresolved
            }
            return snapshot
        }
    }
}
