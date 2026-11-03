import Darwin
import Foundation
import OSLog

extension LocationSource {
    func readProofCache() -> VerifiedReadCache { Self.readProofCache(domainID: domainID) }

    static func readProofCache(domainID: String) -> VerifiedReadCache {
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
            defer { withExtendedLifetime(remote) {} }
            try remote.protectAncestors(of: upload.path)
            let version = try remote.readVersion(path: upload.path, collectReadProof: true)
            guard version.size == upload.size, version.digest == upload.digest,
                  version.identity == upload.serverFile, version.identity.fileID == upload.remoteID else {
                throw UploadError.unresolved
            }
            let receipt = try EditBaseReceipt(item: row.id, version: version)
            try Self.editOutbox(domainID: domainID).storeBase(receipt)
            try withCatalog {
                try $0.refreshEditBase(receipt, expectedVersion: row.contentVersion,
                                       fingerprint: version.fingerprint, nativeID: version.identity.fileID)
            }
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

    func stopEdit(_ id: UUID, destination: URL) throws {
        try uploadLock.withLock { try Self.editOutbox(domainID: domainID).stop(id, exportingTo: destination) }
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
                    // No published version makes the provider fetch the server's, which replaces the stopped save.
                    if try outbox.takeStopped(item: request.item, contents: contents) {
                        return EditReceipt(item: request.item, conflict: false, contentVersion: "")
                    }
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
                guard var published = record.published else { throw UploadError.unresolved }
                let version = try remote.finishPublishedWrite(path: record.destination, expected: published.version,
                                                             collectReadProof: true)
                if version != published.version {
                    published = try EditBaseReceipt(item: published.item, version: version)
                    record.published = published
                    try outbox.save(record)
                }
                guard let destination = RelativePath(record.destination) else { throw UploadError.unresolved }
                let item = try withCatalog {
                    try $0.commitEdit(record, fingerprint: version.fingerprint, nativeID: version.identity.fileID)
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

    func directTransfer(_ request: SourceReadRequest, progress: Progress, stagingDirectory: URL,
                        checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput {
        let started = ContinuousClock.now
        var phase = "namespace", bytes: Int64 = 0
        defer {
            Logger(subsystem: "dev.tinymounter.prototype", category: "fetch").info("""
                direct_read request=\(request.id.uuidString, privacy: .public) \
                phase=\(phase, privacy: .public) remote_bytes=\(bytes) \
                total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 3))
                """)
        }
        return try editNamespace.perform { try uploadLock.withLock {
            let (row, path) = try readTarget(request)
            guard let fullPath = folder.appending(path) else { throw UploadError.invalidRequest }
            try editNamespace.requireUncontested(path: fullPath, excluding: request.id)
            return try access.withSession { session, progressed in
                let observation = progress.observe(\.completedUnitCount) { _, _ in progressed() }
                defer { observation.invalidate() }
                guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: session.root, progress: progress)
                defer { bytes = remote.readBytes; withExtendedLifetime(remote) {} }
                try remote.protectAncestors(of: path.string)
                let metadata = try remote.readMetadata(path: path.string)
                let expected = ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
                let outbox = try Self.editOutbox(domainID: domainID)
                let base = try outbox.base(item: row.id, contentVersion: request.version)
                guard !request.version.hasPrefix("e1:") || base != nil else { throw UploadError.unresolved }
                let fullRead = request.range.offset == 0 && request.range.length == row.size
                let range = try ByteRange(offset: request.range.offset, length: request.range.length, fileSize: row.size)
                func refresh(_ current: EditFileVersion) throws {
                    let receipt = try EditBaseReceipt(item: row.id, version: current)
                    try outbox.storeBase(receipt)
                    try withCatalog {
                        try $0.refreshEditBase(receipt, expectedVersion: row.contentVersion,
                            fingerprint: current.fingerprint, nativeID: current.identity.fileID)
                    }
                    scheduleSignal()
                }
                let catalogIdentity = try withCatalog { try $0.remoteIdentity(row.id) }
                if metadata.fingerprint != expected || metadata.identity.fileID != catalogIdentity {
                    if base != nil {
                        try refresh(remote.readVersion(path: path.string))
                    } else {
                        _ = try withCatalog {
                            try $0.updateFingerprint(item: row.id, fingerprint: metadata.fingerprint,
                                                     fileID: metadata.identity.fileID)
                        }
                        scheduleSignal()
                    }
                    throw SourceFailure.versionChanged
                }
                phase = "verify"
                var proof: VerifiedRead?, version: EditFileVersion?, rangeDigest: String?
                var staged: TransferOutput?, complete = false
                defer {
                    if !complete, let url = staged?.stagingURL { try? FileManager.default.removeItem(at: url) }
                }
                let protected = base != nil || (request.establishEditBase && row.allowsWriting)
                if protected && fullRead {
                    let downloaded = try remote.transferVersion(path: path.string, range: range,
                        stagingDirectory: stagingDirectory, progress: progress, checkSpace: checkSpace)
                    staged = downloaded.output
                    version = downloaded.version
                    proof = remote.readProof
                    if let base, !downloaded.version.hasSameContents(as: base.version) {
                        try refresh(downloaded.version)
                        throw SourceFailure.versionChanged
                    }
                } else if protected {
                    if let base, !fullRead, !request.establishEditBase {
                        proof = readProofCache().load(receipt: base, path: path)
                        if let proof {
                            rangeDigest = try remote.verifyRead(path: path.string, range: range,
                                                                base: base.version, proof: proof)
                        }
                    }
                    if rangeDigest == nil {
                        let current = try remote.readVersion(path: path.string, collectReadProof: true)
                        version = current
                        proof = remote.readProof
                        if let base, !current.hasSameContents(as: base.version) {
                            try refresh(current)
                            throw SourceFailure.versionChanged
                        }
                        rangeDigest = try fullRead ? current.digest : remote.readRangeDigest(path: path.string, range: range)
                    }
                }
                phase = "transfer"
                let verified = progress.completedUnitCount, transferProgress = Progress()
                progress.totalUnitCount = max(1, Int64(clamping: Int128(verified)
                    + Int128(range.length) * (rangeDigest == nil ? 1 : 2)))
                let transferObservation = transferProgress.observe(\.completedUnitCount) { value, _ in
                    progress.completedUnitCount = verified + value.completedUnitCount
                    if progress.isCancelled { value.cancel() }
                }
                defer { transferObservation.invalidate() }
                var output = try staged ?? remote.transfer(path: path.string, range: range,
                    stagingDirectory: stagingDirectory, progress: transferProgress, checkSpace: checkSpace)
                staged = output
                do {
                    phase = "checksum"
                    if let rangeDigest {
                        guard let url = output.stagingURL else { throw UploadError.unresolved }
                        let local = try ReadOnlyFile(url: url)
                        guard try local.checksum(range: range, progress: progress) == rangeDigest else {
                            throw TransferError.checksumMismatch
                        }
                    }
                    var receipt = base
                    if request.establishEditBase && row.allowsWriting {
                        guard fullRead, let version else { throw UploadError.unresolved }
                        let established = try base ?? EditBaseReceipt(item: row.id, version: version)
                        try outbox.storeBase(established)
                        try withCatalog { try $0.rememberEditBase(established, expectedVersion: row.contentVersion) }
                        output.contentVersion = established.contentVersion
                        receipt = established
                    }
                    if let receipt, let proof { try? readProofCache().store(proof, receipt: receipt, path: path) }
                    progress.completedUnitCount = progress.totalUnitCount
                    phase = "complete"
                    complete = true
                    return output
                } catch {
                    if let url = output.stagingURL { try? FileManager.default.removeItem(at: url) }
                    throw error
                }
            }
        } }
    }
}
