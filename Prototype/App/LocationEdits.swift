import Darwin
import Foundation
import OSLog

extension LocationSource {
    static func editOutbox(domainID: String) throws -> EditOutbox {
        guard UUID(uuidString: domainID)?.uuidString == domainID else { throw UploadError.invalidRequest }
        return try EditOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Edits/\(domainID)", directoryHint: .isDirectory))
    }

    static func pendingWrites(domainID: String) throws -> Int {
        try outbox(domainID: domainID).pendingCount + editOutbox(domainID: domainID).pendingCount
            + renameOutbox().pendingCount(domain: domainID)
    }

    func establishUploadedEditBase(_ upload: PendingUpload, row: CatalogRow, bookmark: Data,
                                   progress: Progress) throws {
        try withWriteSession(bookmark, progress: progress) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom),
                  let path = RelativePath(upload.path) else { throw UploadError.unresolved }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: upload.path)
            let version = try remote.readVersion(path: upload.path)
            let file = try ReadOnlyFile(directoryFD: root, relativePath: path, expected: session.identity)
            guard version.size == upload.size, version.digest == upload.digest,
                  file.snapshot.inode == upload.remoteID,
                  file.snapshot.fingerprint == ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
            else { throw UploadError.unresolved }
            let receipt = try EditBaseReceipt(item: row.id, version: version)
            try Self.editOutbox(domainID: domainID).storeBase(receipt)
            try withCatalog { try $0.rememberEditBase(receipt, expectedVersion: row.contentVersion) }
        }
    }

    func editRecords() throws -> [PendingEdit] {
        try uploadLock.withLock { try Self.editOutbox(domainID: domainID).records() }
    }

    func exportEdit(_ id: UUID, destination: URL) throws {
        try uploadLock.withLock {
            let outbox = try Self.editOutbox(domainID: domainID)
            guard let record = try outbox.records().first(where: { $0.id == id && $0.isPending }) else {
                throw UploadError.invalidRequest
            }
            try outbox.export(record, to: destination)
        }
    }

    func edit(_ request: EditRequest, contents: URL, progress: Progress,
              started: @escaping @Sendable () -> Void, checkSpace: @escaping @Sendable (Int64) throws -> Void,
              reply: @escaping @Sendable (Result<EditReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try editNamespace.perform {
                try uploadLock.withLock {
                    guard !mutationsSuspended, writeBookmark != nil else { throw UploadError.readOnly }
                    let path = try withCatalog { catalog -> RelativePath in
                        guard let row = try catalog.item(id: request.item), row.allowsEditing,
                              row.kind == .file, row.parentID == request.parent,
                              row.name == request.name,
                              let parent = try catalog.relativePath(of: request.parent),
                              let path = parent.appending(row.name) else {
                            throw UploadError.readOnly
                        }
                        return path
                    }
                    guard let fullPath = folder.appending(path) else { throw UploadError.invalidRequest }
                    let outbox = try Self.editOutbox(domainID: domainID)
                    // Retain this file's new save before resolving any of its earlier publications.
                    try editNamespace.requireUncontested(path: fullPath, excluding: request.id,
                                                          retaining: (domainID, request.item))
                    var record = try outbox.prepare(item: request.item, parent: request.parent, path: path,
                                                    baseVersion: request.baseVersion, failOnConflict: request.failOnConflict,
                                                    contents: contents, progress: progress, checkSpace: checkSpace)
                    if record.state == .completed {
                        try finishEdit(&record, outbox: outbox, progress: progress)
                    } else {
                        try finishItem(request.item, outbox: outbox, progress: progress)
                        guard let current = try outbox.records().first(where: { $0.id == record.id }),
                              current.state == .completed else { throw UploadError.pendingWrites }
                        record = current
                    }
                    return EditReceipt(item: record.completedItem ?? record.item, conflict: record.conflict,
                                       contentVersion: record.published?.contentVersion ?? "")
                }
            } }
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            logger.info("edit request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil ? 1 : 0)")
            if case .failure(let error) = result {
                logger.error("edit request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
            }
            if case .success(let receipt) = result, receipt.conflict {
                _ = try? listOnLane(request.parent, requestID: request.id)
            }
            scheduleSignal()
            reply(result)
        }
    }

    func retryEdits() {
        access.enqueue { [self] in
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            let result = Result { try editNamespace.perform {
                try uploadLock.withLock {
                    guard !mutationsSuspended, writeBookmark != nil,
                          try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsEditing }) == true else { return }
                    let outbox = try Self.editOutbox(domainID: domainID)
                    let pending = try outbox.records().filter(\.isPending)
                    for var record in pending where record.state == .completed {
                        do { try finishEdit(&record, outbox: outbox, progress: Progress()) }
                        catch {
                            logger.error("edit_retry id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    for item in Set(pending.filter { $0.state != .completed }.map(\.item)).sorted() {
                        do { try finishItem(item, outbox: outbox, progress: Progress()) }
                        catch {
                            logger.error("edit_retry item=\(item, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    try outbox.releaseOrderingGuardIfSettled()
                }
            } }
            if case .failure(let error) = result {
                logger.error("edit_retry failed \(logFields(error), privacy: .public)")
            }
            scheduleSignal()
        }
    }

    /// Earlier work resolves before the newest complete save; superseded saves never publish.
    private func finishItem(_ item: String, outbox: EditOutbox, progress: Progress) throws {
        for var earlier in try outbox.order(item: item).predecessors {
            do { try finishResolvingEquivalents(&earlier, outbox: outbox, progress: progress) }
            catch {
                // Restoring the old original ends that publication without completing it.
                if try outbox.order(item: item).predecessors.contains(where: { $0.id == earlier.id }) { throw error }
            }
        }
        for var old in try outbox.order(item: item).superseded {
            do {
                if old.isLocalOnly { try outbox.discard(old) }
                else { try retireEdit(&old, outbox: outbox, progress: progress) }
            } catch {
                // Without evidence the superseded save stays retained, and the head waits for it.
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .error("edit_superseded id=\(old.id.uuidString, privacy: .public) retained \(logFields(error), privacy: .public)")
            }
        }
        let order = try outbox.order(item: item)
        guard order.predecessors.isEmpty, order.superseded.isEmpty else { throw UploadError.pendingWrites }
        guard order.unordered.isEmpty else { throw UploadError.unresolved }
        guard var head = order.head else { return }
        try finishResolvingEquivalents(&head, outbox: outbox, progress: progress)
    }

    /// Unordered saves with the contents this one just published need no publication of their own.
    private func finishResolvingEquivalents(_ record: inout PendingEdit, outbox: EditOutbox,
                                            progress: Progress) throws {
        try finishEdit(&record, outbox: outbox, progress: progress)
        guard record.state == .completed, !record.conflict, !record.recoveryRetained else { return }
        for var other in try outbox.records()
            where other.id != record.id && other.item == record.item && other.state != .completed {
            if (try? outbox.resolveEquivalent(&other, with: record)) != nil {
                try? finishEdit(&other, outbox: outbox, progress: progress)
            }
        }
    }

    private func retireEdit(_ record: inout PendingEdit, outbox: EditOutbox, progress: Progress) throws {
        guard let bookmark = writeBookmark else { throw UploadError.readOnly }
        try withWriteSession(bookmark, progress: progress) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: record.path)
            try EditTransaction.retire(&record, outbox: outbox, remote: remote)
        }
    }

    private func finishEdit(_ record: inout PendingEdit, outbox: EditOutbox, progress: Progress) throws {
        let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
        defer {
            let id = record.id.uuidString, state = record.state.rawValue, conflict = record.conflict ? 1 : 0
            let recovery = record.recoveryRetained
            logger.info("edit_transaction id=\(id, privacy: .public) state=\(state, privacy: .public) conflict=\(conflict) recovery=\(recovery)")
        }
        guard let bookmark = writeBookmark, let relative = RelativePath(record.path),
              let path = folder.appending(relative) else { throw UploadError.readOnly }
        if record.state == .completed, !record.recoveryRetained { return }
        guard record.state != .preparing else { throw UploadError.unresolved }
        try outbox.validateContents(record)
        guard try !outbox.hasResourceFork(record) else {
            throw CocoaError(.featureUnsupported)
        }
        try editNamespace.requireUncontested(path: path, excluding: record.id)
        try withWriteSession(bookmark, progress: progress) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: record.path)
            try EditTransaction.publish(&record, outbox: outbox, remote: remote)
            if record.state != .completed {
                guard let published = record.published else { throw UploadError.unresolved }
                try remote.allowPublishedReads(path: record.destination, expected: published.version)
                guard let destination = RelativePath(record.destination),
                      let parent = RelativePath(destination.components.dropLast().joined(separator: "/")) else {
                    throw UploadError.unresolved
                }
                // Refresh native name caches after the direct SMB rename, without reconciling artifacts.
                _ = try DirectoryListing.list(locationRoot: root, relativePath: parent, expected: session.identity)
                let native = try nativeEditSnapshot(record, root: root)
                let item = try withCatalog {
                    try $0.commitEdit(record, fingerprint: native.fingerprint, nativeID: native.inode)
                }
                try outbox.complete(&record, item: item)
            }
            // A failed cleanup remains visible and keeps the local recovery data.
            do { try EditTransaction.cleanup(&record, outbox: outbox, remote: remote) }
            catch {
                let id = record.id.uuidString
                logger.error("edit_cleanup id=\(id, privacy: .public) failed \(logFields(error), privacy: .public)")
            }
        }
    }

    private func nativeEditSnapshot(_ record: PendingEdit, root: Int32) throws -> FileSnapshot {
        let fd = openat(root, record.destination, O_EVTONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("inspect saved file") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, let version = record.published?.version,
              info.st_mode & S_IFMT == S_IFREG, info.st_size == version.size,
              info.st_birthtimespec.tv_sec > 0,
              UInt64(info.st_birthtimespec.tv_sec) * 1_000_000 + UInt64(info.st_birthtimespec.tv_nsec / 1_000)
                == version.identity.birthMicroseconds,
              info.st_mtimespec.tv_sec >= 0,
              UInt64(info.st_mtimespec.tv_sec) * 1_000_000 + UInt64(info.st_mtimespec.tv_nsec / 1_000)
                == version.modifiedMicroseconds else { throw UploadError.unresolved }
        return try FileSnapshot(fd: fd)
    }

    func protectedTransfer(_ request: SourceReadRequest, progress: Progress, stagingDirectory: URL,
                           checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput {
        try editNamespace.perform {
            try uploadLock.withLock {
                let (row, path) = try readTarget(request)
                guard let fullPath = folder.appending(path) else { throw UploadError.invalidRequest }
                try editNamespace.requireUncontested(path: fullPath, excluding: UUID())
                return try access.withSession { session, progressed in
                    let observation = progress.observe(\.completedUnitCount) { _, _ in progressed() }
                    defer { observation.invalidate() }
                    guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                    let root = try session.locationRoot(folder)
                    let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
                    try remote.protectAncestors(of: path.string)
                    let version = try remote.readVersion(path: path.string)
                    let outbox = try Self.editOutbox(domainID: domainID)
                    let base = try outbox.base(item: row.id, contentVersion: request.version)
                    let file = try ReadOnlyFile(directoryFD: root, relativePath: path, expected: session.identity, noCache: true)
                    let fingerprintChanged = file.snapshot.fingerprint
                        != ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
                    let receiptChanged = request.version.hasPrefix("e1:")
                        && base.map({ version.hasSameContents(as: $0.version) }) != true
                    if fingerprintChanged || receiptChanged {
                        guard file.snapshot.size == version.size else { throw SourceFailure.versionChanged }
                        let receipt = try EditBaseReceipt(item: row.id, version: version)
                        try outbox.storeBase(receipt)
                        try withCatalog {
                            try $0.refreshEditBase(receipt, expectedVersion: row.contentVersion,
                                                   fingerprint: file.snapshot.fingerprint, nativeID: file.snapshot.inode)
                        }
                        scheduleSignal()
                        throw SourceFailure.versionChanged
                    }
                    let nativeProgress = Progress()
                    let verified = progress.completedUnitCount
                    let nativeObservation = nativeProgress.observe(\.completedUnitCount) { value, _ in
                        progress.completedUnitCount = verified + value.completedUnitCount
                        if progress.isCancelled { value.cancel() }
                    }
                    defer { nativeObservation.invalidate() }
                    if progress.isCancelled { nativeProgress.cancel() }
                    var output = try Transfer.run(source: file, range: request.range, stagingDirectory: stagingDirectory,
                                                  progress: nativeProgress, checkSpace: checkSpace)
                    do {
                        if request.establishEditBase, row.allowsEditing, let url = output.stagingURL {
                            let staged = try ReadOnlyFile(url: url)
                            guard request.range.offset == 0, request.range.length == row.size,
                                  try staged.checksum(range: request.range) == version.digest else { throw UploadError.unresolved }
                            let receipt = try base ?? EditBaseReceipt(item: row.id, version: version)
                            try outbox.storeBase(receipt)
                            try withCatalog { try $0.rememberEditBase(receipt, expectedVersion: row.contentVersion) }
                            output.contentVersion = receipt.contentVersion
                        }
                        return output
                    } catch {
                        if let url = output.stagingURL { try? FileManager.default.removeItem(at: url) }
                        throw error
                    }
                }
            }
        }
    }
}
