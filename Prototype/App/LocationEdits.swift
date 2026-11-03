import Darwin
import Foundation
import OSLog

extension LocationSource {
    func readProofCache() -> VerifiedReadCache {
        VerifiedReadCache(directory: URL.cachesDirectory
            .appending(path: "tinymounter/ReadProofs/\(domainID)", directoryHint: .isDirectory))
    }

    static func editOutbox(domainID: String) throws -> EditOutbox {
        guard UUID(uuidString: domainID)?.uuidString == domainID else { throw UploadError.invalidRequest }
        return try EditOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Edits/\(domainID)", directoryHint: .isDirectory))
    }

    static func pendingWrites(domainID: String) throws -> Int {
        try outbox(domainID: domainID).pendingCount + editOutbox(domainID: domainID).pendingCount
            + renameOutbox().pendingIntentCount(domain: domainID) + deletionOutbox().pendingCount(domain: domainID)
    }

    func establishUploadedEditBase(_ upload: PendingUpload, row: CatalogRow, bookmark: Data,
                                   progress: Progress) throws {
        try withWriteSession(bookmark, progress: progress) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom),
                  let path = RelativePath(upload.path) else { throw UploadError.unresolved }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: upload.path)
            let version = try remote.readVersion(path: upload.path, collectReadProof: true)
            let file = try ReadOnlyFile(directoryFD: root, relativePath: path, expected: session.identity)
            guard version.size == upload.size, version.digest == upload.digest,
                  file.snapshot.inode == upload.remoteID,
                  file.snapshot.fingerprint == ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
            else { throw UploadError.unresolved }
            let receipt = try EditBaseReceipt(item: row.id, version: version)
            try Self.editOutbox(domainID: domainID).storeBase(receipt)
            try withCatalog { try $0.rememberEditBase(receipt, expectedVersion: row.contentVersion) }
            if let proof = remote.readProof { try? readProofCache().store(proof, receipt: receipt, path: path) }
        }
    }

    func editRecords() throws -> [PendingEdit] {
        try uploadLock.readForStatus { try Self.editOutbox(domainID: domainID).records() }
    }

    func savedChangeBytes() throws -> Int64 {
        try uploadLock.readForStatus {
            let uploads = try Self.outbox(domainID: domainID).contentBytes
            let edits = try Self.editOutbox(domainID: domainID).contentBytes
            let (total, overflow) = uploads.addingReportingOverflow(edits)
            guard !overflow else { throw UploadError.unresolved }
            return total
        }
    }

    func dismissEditNotice(_ id: UUID) throws {
        try uploadLock.withLock { try Self.editOutbox(domainID: domainID).dismissConflictNotice(id: id) }
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
                        // A retired folder-move binding is a tombstone; its old name may hold another object.
                        guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsWriting,
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
                    if record.isPublicationComplete {
                        try finishEdit(&record, outbox: outbox, progress: progress)
                    } else {
                        try finishItem(request.item, outbox: outbox, progress: progress)
                        guard let current = try outbox.records().first(where: { $0.id == record.id }),
                              current.isPublicationComplete else { throw UploadError.pendingWrites }
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

    func retryEdits(recoverRetired: Bool = false) {
        access.enqueue { [self] in
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            let result = Result { try editNamespace.perform {
                try uploadLock.withLock {
                    guard !mutationsSuspended, writeBookmark != nil,
                          try withCatalog({ try $0.item(id: Catalog.rootItemID)?.allowsWriting }) == true else { return }
                    let outbox = try Self.editOutbox(domainID: domainID)
                    let pending = try outbox.records().filter(\.isPending)
                    for var record in pending where record.isPublicationComplete {
                        do { try finishEdit(&record, outbox: outbox, progress: Progress()) }
                        catch {
                            logger.error("edit_retry id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    for item in Set(pending.filter { !$0.isPublicationComplete }.map(\.item)).sorted() {
                        do { try finishItem(item, outbox: outbox, progress: Progress()) }
                        catch {
                            logger.error("edit_retry item=\(item, privacy: .public) failed \(logFields(error), privacy: .public)")
                        }
                    }
                    if recoverRetired {
                        for var record in try outbox.records() where record.state == .retired {
                            do { try cleanupRetiredEdit(&record, outbox: outbox) }
                            catch {
                                logger.error("edit_retained_cleanup id=\(record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                            }
                        }
                    }
                }
            } }
            if case .failure(let error) = result {
                logger.error("edit_retry failed \(logFields(error), privacy: .public)")
            }
            scheduleSignal()
        }
    }

    /// Started publications resolve first; uncertain private artifacts can remain for recovery.
    private func finishItem(_ item: String, outbox: EditOutbox, progress: Progress) throws {
        for var earlier in try outbox.order(item: item).predecessors {
            do { try finishEdit(&earlier, outbox: outbox, progress: progress) }
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
                if old.state != .retired { try outbox.retainSuperseded(&old) }
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .error("edit_superseded id=\(old.id.uuidString, privacy: .public) retained \(logFields(error), privacy: .public)")
            }
        }
        let order = try outbox.order(item: item)
        guard order.predecessors.isEmpty, order.superseded.isEmpty else { throw UploadError.pendingWrites }
        guard var head = order.head else { return }
        try finishEdit(&head, outbox: outbox, progress: progress)
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

    private func cleanupRetiredEdit(_ record: inout PendingEdit, outbox: EditOutbox) throws {
        if record.retiredCleanupStarted == true {
            try outbox.discardRetired(record)
            return
        }
        guard let bookmark = writeBookmark, let relative = RelativePath(record.path),
              let path = folder.appending(relative) else { throw UploadError.readOnly }
        try editNamespace.requireUncontested(path: path, excluding: record.id)
        let progress = Progress()
        try withWriteSession(bookmark, progress: progress) { session, root in
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: record.path)
            try EditTransaction.cleanupRetired(&record, outbox: outbox, remote: remote)
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
        if record.isPublicationComplete, !record.recoveryRetained { return }
        if record.completedCleanupStarted == true, let item = record.completedItem {
            try outbox.complete(&record, item: item)
            return
        }
        guard record.state != .preparing, record.state != .retired else { throw UploadError.unresolved }
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
            if !record.isPublicationComplete {
                guard let published = record.published else { throw UploadError.unresolved }
                try remote.allowPublishedReads(path: record.destination, expected: published.version, collectReadProof: true)
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
                if let proof = remote.readProof {
                    try? readProofCache().store(proof, receipt: published, path: destination)
                }
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
                           checkSpace: ((Int64) throws -> Void)?, started: ContinuousClock.Instant,
                           namespaceWait: Duration) throws -> TransferOutput {
        let waiting = ContinuousClock.now
        var namespaceWait = namespaceWait
        var acquired: ContinuousClock.Instant?, verifying: ContinuousClock.Instant?
        var copying: ContinuousClock.Instant?, checking: ContinuousClock.Instant?, checked: ContinuousClock.Instant?
        var phase = "namespace", mode = "none", cache = "unchecked"
        var remoteBytes: Int64 = 0
        var parallel = false, nativeMilliseconds: Double?
        defer {
            let ended = ContinuousClock.now
            func milliseconds(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> Double {
                from.map { $0.duration(to: to ?? ended) / .milliseconds(1) } ?? -1
            }
            Logger(subsystem: "dev.tinymounter.prototype", category: "fetch").info("""
                protected_read request=\(request.id.uuidString, privacy: .public) \
                phase=\(phase, privacy: .public) mode=\(mode, privacy: .public) cache=\(cache, privacy: .public) \
                edit_base=\(request.version.hasPrefix("e1:") ? 1 : 0) \
                remote_bytes=\(remoteBytes) namespace_ms=\(namespaceWait / .milliseconds(1), format: .fixed(precision: 3)) \
                setup_ms=\(milliseconds(acquired, verifying), format: .fixed(precision: 3)) \
                verify_ms=\(milliseconds(verifying, copying), format: .fixed(precision: 3)) \
                native_ms=\(parallel ? (nativeMilliseconds ?? -1) : milliseconds(copying, checking), format: .fixed(precision: 3)) \
                checksum_ms=\(milliseconds(checking, checked), format: .fixed(precision: 3)) \
                total_ms=\(milliseconds(started, ended), format: .fixed(precision: 3)) parallel=\(parallel ? 1 : 0)
                """)
        }
        return try editNamespace.perform {
            let entered = ContinuousClock.now
            acquired = entered
            namespaceWait += waiting.duration(to: entered)
            phase = "setup"
            return try uploadLock.withLock {
                let (row, path) = try readTarget(request)
                guard let fullPath = folder.appending(path) else { throw UploadError.invalidRequest }
                try editNamespace.requireUncontested(path: fullPath, excluding: UUID())
                return try access.withSession { session, progressed in
                    let observation = progress.observe(\.completedUnitCount) { _, _ in progressed() }
                    defer { observation.invalidate() }
                    guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                    let root = try session.locationRoot(folder)
                    let fullRead = request.range.offset == 0 && request.range.length == row.size
                    let verificationProgress = fullRead ? Progress() : progress
                    let cancellation = progress.observe(\.isCancelled, options: [.initial]) { value, _ in
                        if value.isCancelled, verificationProgress !== value { verificationProgress.cancel() }
                    }
                    defer { cancellation.invalidate() }
                    let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: verificationProgress)
                    defer { remoteBytes = remote.readBytes; withExtendedLifetime(remote) {} }
                    try remote.protectAncestors(of: path.string)
                    try remote.protectRead(path: path.string)
                    let outbox = try Self.editOutbox(domainID: domainID)
                    let base = try outbox.base(item: row.id, contentVersion: request.version)
                    let file = try ReadOnlyFile(directoryFD: root, relativePath: path, expected: session.identity, noCache: true)
                    _ = try ByteRange(offset: request.range.offset, length: request.range.length, fileSize: row.size)
                    let fingerprintChanged = file.snapshot.fingerprint
                        != ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
                    var cachedProof: VerifiedRead?
                    var persisted = false
                    if !fingerprintChanged, let base {
                        if verifiedReadSession === session, let cached = verifiedRead,
                           cached.receipt == base, cached.path == path {
                            cachedProof = cached.proof
                        } else {
                            cachedProof = readProofCache().load(receipt: base, path: path)
                            persisted = cachedProof != nil
                        }
                    }
                    cache = fullRead ? "full" : request.establishEditBase ? "establish"
                        : fingerprintChanged ? "fingerprint" : base == nil ? "receipt"
                        : verifiedReadSession !== session ? "session" : "miss"
                    verifying = .now
                    phase = "verify"
                    var rangeDigest: String?
                    if !fullRead, !request.establishEditBase, let base, let cachedProof {
                        mode = "blocks"
                        rangeDigest = try remote.verifyRead(path: path.string, range: request.range,
                                                            base: base.version, proof: cachedProof)
                        cache = rangeDigest == nil ? "mismatch" : persisted ? "disk" : "hit"
                    }
                    if !fullRead, rangeDigest == nil { cachedProof = nil }
                    mode = rangeDigest == nil ? "full" : "blocks"
                    var version: EditFileVersion?
                    func verify() throws -> String {
                        if let rangeDigest { return rangeDigest }
                        verifiedRead = nil
                        verifiedReadSession = nil
                        let current = try remote.readVersion(path: path.string, collectReadProof: cachedProof == nil)
                        version = current
                        let receiptChanged = request.version.hasPrefix("e1:")
                            && base.map({ current.hasSameContents(as: $0.version) }) != true
                        if fingerprintChanged || receiptChanged {
                            guard file.snapshot.size == current.size else { throw SourceFailure.versionChanged }
                            let receipt = try EditBaseReceipt(item: row.id, version: current)
                            try outbox.storeBase(receipt)
                            try withCatalog {
                                try $0.refreshEditBase(receipt, expectedVersion: row.contentVersion,
                                                       fingerprint: file.snapshot.fingerprint, nativeID: file.snapshot.inode)
                            }
                            scheduleSignal()
                            throw SourceFailure.versionChanged
                        }
                        return fullRead ? current.digest
                            : try remote.readRangeDigest(path: path.string, range: request.range)
                    }
                    var output: TransferOutput
                    if fullRead {
                        parallel = true
                        let transfer = VerifiedReadTransfer(source: file, range: request.range,
                            stagingDirectory: stagingDirectory, progress: progress,
                            verificationProgress: verificationProgress, checkSpace: checkSpace)
                        output = try transfer.run(verify: {
                            let digest = try verify()
                            copying = .now
                            return digest
                        }, willChecksum: { metrics in
                            checking = .now
                            phase = "checksum"
                            nativeMilliseconds = metrics.transferSeconds * 1_000
                        })
                        checked = .now
                    } else {
                        rangeDigest = try verify()
                        let nativeProgress = Progress()
                        let verified = progress.completedUnitCount
                        let nativeObservation = nativeProgress.observe(\.completedUnitCount) { value, _ in
                            progress.completedUnitCount = verified + value.completedUnitCount
                            if progress.isCancelled { value.cancel() }
                        }
                        defer { nativeObservation.invalidate() }
                        if progress.isCancelled { nativeProgress.cancel() }
                        copying = .now
                        phase = "native"
                        output = try Transfer.run(source: file, range: request.range, stagingDirectory: stagingDirectory,
                                                  progress: nativeProgress, checkSpace: checkSpace)
                    }
                    do {
                        if !fullRead {
                            checking = .now
                            phase = "checksum"
                            guard let url = output.stagingURL else { throw UploadError.unresolved }
                            let staged = try ReadOnlyFile(url: url)
                            guard !progress.isCancelled else { throw TransferError.cancelled }
                            guard let rangeDigest,
                                  try staged.checksum(range: request.range, progress: progress) == rangeDigest else {
                                throw UploadError.unresolved
                            }
                            checked = .now
                        }
                        phase = "receipt"
                        var receipt = base
                        if request.establishEditBase, row.allowsWriting {
                            guard fullRead, let version else { throw UploadError.unresolved }
                            let established = try base ?? EditBaseReceipt(item: row.id, version: version)
                            receipt = established
                            try outbox.storeBase(established)
                            try withCatalog { try $0.rememberEditBase(established, expectedVersion: row.contentVersion) }
                            output.contentVersion = established.contentVersion
                        }
                        if let receipt, let proof = remote.readProof ?? cachedProof,
                           version.map({ $0.hasSameContents(as: receipt.version) }) ?? (mode == "blocks") {
                            verifiedRead = (receipt, path, proof)
                            verifiedReadSession = session
                            if remote.readProof != nil { try? readProofCache().store(proof, receipt: receipt, path: path) }
                        }
                        phase = "complete"
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
