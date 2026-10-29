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
    }

    func configureEditing(_ enabled: Bool) throws {
        try uploadLock.withLock {
            guard !mutationsSuspended, !enabled || writeBookmark != nil else { throw UploadError.readOnly }
            if !enabled, try Self.editOutbox(domainID: domainID).pendingCount > 0 { throw UploadError.pendingWrites }
            try withCatalog { try $0.setAllowsEditing(enabled) }
        }
        scheduleSignal()
    }

    func establishUploadedEditBase(_ upload: PendingUpload, row: CatalogRow, bookmark: Data,
                                   progress: Progress) throws {
        try withWriteSession(bookmark) { session, root in
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
                    let outbox = try Self.editOutbox(domainID: domainID)
                    var record = try outbox.prepare(item: request.item, parent: request.parent, path: path,
                                                    baseVersion: request.baseVersion, failOnConflict: request.failOnConflict,
                                                    contents: contents, progress: progress, checkSpace: checkSpace)
                    try finishEdit(&record, outbox: outbox, progress: progress)
                    if record.state == .completed, !record.recoveryRetained, !record.conflict {
                        for var previous in try outbox.records() where previous.id != record.id && previous.isPending {
                            if (try? outbox.resolveEquivalent(&previous, with: record)) != nil {
                                try? finishEdit(&previous, outbox: outbox, progress: progress)
                            }
                        }
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
            try? editNamespace.perform {
                try uploadLock.withLock {
                    guard !mutationsSuspended, writeBookmark != nil,
                          try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsEditing }) == true else { return }
                    let outbox = try Self.editOutbox(domainID: domainID)
                    for var record in try outbox.records() where record.isPending {
                        try? finishEdit(&record, outbox: outbox, progress: Progress())
                    }
                }
            }
            scheduleSignal()
        }
    }

    private func finishEdit(_ record: inout PendingEdit, outbox: EditOutbox, progress: Progress) throws {
        let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
        defer {
            let id = record.id.uuidString, state = record.state.rawValue, conflict = record.conflict ? 1 : 0
            logger.info("edit_transaction id=\(id, privacy: .public) state=\(state, privacy: .public) conflict=\(conflict)")
        }
        guard let bookmark = writeBookmark, let relative = RelativePath(record.path),
              let path = folder.appending(relative) else { throw UploadError.readOnly }
        if record.state == .completed, !record.recoveryRetained { return }
        guard try !outbox.hasResourceFork(record) else {
            throw CocoaError(.featureUnsupported)
        }
        try editNamespace.requireUncontested(path: path, excluding: record.id)
        try withWriteSession(bookmark) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: record.path)
            try EditTransaction.publish(&record, outbox: outbox, remote: remote)
            if record.state != .completed {
                let native = try nativeEditSnapshot(record, root: root)
                let item = try withCatalog {
                    try $0.commitEdit(record, fingerprint: native.fingerprint, nativeID: native.inode)
                }
                try outbox.complete(&record, item: item)
            }
            // A failed cleanup remains visible and keeps the local recovery data.
            try? EditTransaction.cleanup(&record, outbox: outbox, remote: remote)
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

    func protectedTransfer(_ request: SourceReadRequest, row: CatalogRow, path: RelativePath,
                           progress: Progress, stagingDirectory: URL,
                           checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput {
        try editNamespace.perform {
            try uploadLock.withLock {
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
