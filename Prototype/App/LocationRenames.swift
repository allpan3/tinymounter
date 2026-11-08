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
        connection.enqueue { [self] in
            started()
            let finish: @Sendable (Result<CreateReceipt, Error>) -> Void = { result in
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .info("file_rename request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
                reply(result)
            }
            let result = Result { try editNamespace.perform { () -> PendingFileRename? in
                try renameAccess()
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
                scheduleRenameRetry(after: error)
                finish(.failure(error))
            }
        }
    }

    private func startRename(_ request: FileRenameRequest, outbox: FileRenameOutbox,
                             progress: Progress) throws -> PendingFileRename? {
        try editNamespace.requireSettled()
        try renameAccess()
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
        return try connection.withSession(folder: .root, progress: progress) { remote, _ in
            let parents = try remote.protectRenameParents(source: path.string, destination: destination.string)
            guard let evidence = try remote.inspectRename(path: path.string),
                  evidence.name == path.components.last else { throw SourceFailure.versionChanged }
            let base = try FileRevision(item: request.item, version: evidence.version)
            let views = try sources.map {
                try $0.renameView(path: path, destination: destination, version: evidence.version,
                                  parents: parents)
            }
            guard let source = RelativePath((path.components.dropLast() + [evidence.name]).joined(separator: "/")) else {
                throw UploadError.unresolved
            }
            var record = try outbox.prepareFile(owner: domainID, request: request, base: base, source: source,
                                                views: views, destination: destination, parents: parents)
            // Case aliases need one delete-capable handle; publication revalidates after reopening.
            if NameKey(source.string) == NameKey(destination.string) { try remote.releaseRename(path: source.string) }
            try finishRename(&record, outbox: outbox, progress: progress, remote: remote)
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
        connection.enqueue { [self] in
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            var sharingFailure: Error?
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
                            if Self.renameSharingFailure(error) { sharingFailure = error }
                            logger.error("rename_retry id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    return (ready, folders)
                }
                for record in ready {
                    completeRename(record) { [self] result in
                        if case .failure(let error) = result {
                            logger.error("rename_settings id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        } else {
                            renameRecovered()
                        }
                    }
                }
                for id in folders {
                    do {
                        try retryFolderMove(id)
                        renameRecovered()
                    }
                    catch {
                        if Self.renameSharingFailure(error) { sharingFailure = error }
                        logger.error("folder_move_retry id=\(id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                    }
                }
            } catch {
                logger.error("rename_retry failed \(logFields(error), privacy: .public)")
            }
            if let sharingFailure { scheduleRenameRetry(after: sharingFailure) }
            else {
                renameRetryLock.withLock {
                    renameRetryWork?.work.cancel()
                    renameRetryWork = nil
                    renameRetryDelay = 2
                }
            }
            scheduleSignal()
        }
    }

    private static func renameSharingFailure(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSPOSIXErrorDomain && failure.code == Int(ETXTBSY)
    }

    func scheduleRenameRetry(after error: Error) {
        guard Self.renameSharingFailure(error) else { return }
        renameRetryLock.withLock {
            guard !renameRetryClosed, renameRetryWork == nil else { return }
            let id = UUID()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let active = self.renameRetryLock.withLock {
                    guard self.renameRetryWork?.id == id else { return false }
                    self.renameRetryWork = nil
                    return !self.renameRetryClosed
                }
                if active { self.retryRenames() }
            }
            renameRetryWork = (id, work)
            Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                .info("rename_retry_scheduled domain=\(self.domainID, privacy: .public) delay=\(self.renameRetryDelay)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(renameRetryDelay), execute: work)
            renameRetryDelay = min(renameRetryDelay * 2, 60)
        }
    }

    /// Read only is off and Remove Location has not suspended changes.
    func renameAccess() throws {
        try uploadLock.withLock {
            guard !mutationsSuspended, writable,
                  try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsWriting }) == true else {
                throw UploadError.readOnly
            }
        }
    }

    private func requireRenamePathsSettled(source: RelativePath, destination: RelativePath) throws {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let uploads = try Self.outbox(domainID: domainID)
            let pendingUploads = try uploads.records().filter(\.isPending)
            guard try uploads.pendingCount == pendingUploads.count else { throw UploadError.pendingWrites }
            for pending in pendingUploads.map(\.path) {
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

    private func renameView(path: RelativePath, destination: RelativePath, version: RemoteFileVersion,
                            parents: [FileRenameParent]) throws -> FileRenameView {
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
            try validateRenameParents([row.parentID!, destinationParent], parents: parents)
            let native = (inode: version.identity.fileID, fingerprint: try version.fingerprint)
            guard native.inode == identity else { throw SourceFailure.versionChanged }
            guard native.fingerprint == ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
            else { throw SourceFailure.versionChanged }
            return try FileRenameView(domain: domainID, folder: folder, row: row, path: actual,
                                      nativeID: identity, destinationParent: destinationParent)
        }
    }

    func validateRenameParents(_ ids: [String], parents: [FileRenameParent]) throws {
        for id in Set(ids) {
            let (relative, nativeID) = try withCatalog { catalog in
                guard let row = try catalog.item(id: id), row.kind == .folder, !row.deleted,
                      let path = try catalog.relativePath(of: id) else { throw UploadError.unresolved }
                return (path, try catalog.remoteIdentity(id))
            }
            guard let full = folder.appending(relative), let parent = parents.first(where: { $0.path == full.string }) else {
                throw UploadError.unresolved
            }
            guard relative.isRoot || parent.identity.fileID == nativeID else { throw UploadError.unresolved }
        }
    }

    private func finishRename(_ record: inout PendingFileRename, outbox: FileRenameOutbox, progress: Progress) throws {
        if record.state == .completed { return }
        try renameAccess()
        try connection.withSession(folder: .root, progress: progress) { remote, _ in
            try finishRename(&record, outbox: outbox, progress: progress, remote: remote)
        }
    }

    private func finishRename(_ record: inout PendingFileRename, outbox: FileRenameOutbox, progress: Progress,
                              remote: any RemoteSession) throws {
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
              SMBName.same(evidence.name, record.name), evidence.version.hasSameDataVersion(as: version) else {
            throw UploadError.unresolved
        }
        if NameKey(record.source) != NameKey(record.destination) {
            _ = try remote.renameSourceEntry(path: record.source)
        }
        for (view, source) in participants {
            let native = (inode: evidence.version.identity.fileID, fingerprint: try evidence.version.fingerprint)
            guard let oldName = RelativePath(view.path)?.components.last else { throw UploadError.unresolved }
            let move = try CatalogFileMove(item: view.item, sourceParent: view.parent, sourceName: oldName,
                                            contentVersion: view.contentVersion, sourceNativeID: view.nativeID,
                                            destinationParent: view.targetParent, destinationName: record.name)
            try source.withCatalog { try $0.commitFileMove(move, fingerprint: native.fingerprint, nativeID: native.inode) }
        }
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
            connection.enqueue { [self] in
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

}
