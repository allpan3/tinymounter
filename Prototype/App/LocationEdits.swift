import Foundation
import OSLog

extension LocationSource {
    static func pendingWrites(domainID: String) throws -> Int {
        try outbox(domainID: domainID).pendingCount
            + renameOutbox().pendingIntentCount(domain: domainID) + deletionOutbox().pendingCount(domain: domainID)
    }

    func savedChangeBytes() throws -> Int64 {
        try uploadLock.readForStatus { try Self.outbox(domainID: domainID).contentBytes }
    }

    func edit(_ request: EditRequest, contents: URL, progress: Progress,
              started: @escaping @Sendable () -> Void,
              reply: @escaping @Sendable (Result<EditReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result {
                let (row, path, operation) = try editNamespace.perform {
                    try uploadLock.withLock {
                        guard !mutationsSuspended, writeBookmark != nil else { throw UploadError.readOnly }
                        let (row, path) = try withCatalog { try $0.editTarget(request) }
                        guard let full = folder.appending(path) else { throw UploadError.invalidRequest }
                        try editNamespace.requireUncontested(path: full, excluding: request.id)
                        return (row, path, try editNamespace.beginRead(full))
                    }
                }
                defer { editNamespace.endRead(operation) }
                guard let bookmark = uploadLock.withLock({ writeBookmark }) else { throw UploadError.readOnly }
                return try withWriteSession(bookmark, progress: progress) { session, root in
                    guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                    let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
                    let expected = request.failOnConflict
                        ? ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs) : nil
                    let written = try remote.overwrite(path: path.string, contents: contents, expected: expected)
                    return try withCatalog { catalog in
                        let (_, currentPath) = try catalog.editTarget(request, checkingVersion: false)
                        guard currentPath == path else { throw SourceFailure.versionChanged }
                        try catalog.updateFingerprint(item: row.id, fingerprint: written.fingerprint,
                                                      fileID: written.fileID)
                        guard let current = try catalog.item(id: row.id) else { throw UploadError.unresolved }
                        return EditReceipt(item: row.id, contentVersion: current.contentVersion)
                    }
                }
            }
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            if case .failure(let error) = result {
                logger.error("edit request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
            } else {
                logger.info("edit request=\(request.id.uuidString, privacy: .public) completed")
            }
            scheduleSignal()
            reply(result)
        }
    }

    func directTransfer(_ request: SourceReadRequest, progress: Progress, stagingDirectory: URL,
                        checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput {
        let started = ContinuousClock.now
        var phase = "prepare", bytes: Int64 = 0
        defer {
            let elapsed = started.duration(to: .now) / .milliseconds(1)
            Logger(subsystem: "dev.tinymounter.prototype", category: "fetch").info("direct_read request=\(request.id.uuidString, privacy: .public) phase=\(phase, privacy: .public) remote_bytes=\(bytes) total_ms=\(elapsed)")
        }
        let (row, path, operation) = try editNamespace.perform {
            let (row, path) = try readTarget(request)
            guard let full = folder.appending(path) else { throw UploadError.invalidRequest }
            try editNamespace.requireUncontested(path: full, excluding: request.id)
            return (row, path, try editNamespace.beginRead(full))
        }
        defer { editNamespace.endRead(operation) }
        return try access.withSession { session, progressed in
            let observation = progress.observe(\.completedUnitCount) { _, _ in progressed() }
            defer { observation.invalidate() }
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: session.root, progress: progress)
            defer { bytes = remote.readBytes; withExtendedLifetime(remote) {} }
            try remote.protectAncestors(of: path.string)
            let metadata = try remote.readMetadata(path: path.string)
            let expected = ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs)
            let identity = try withCatalog { try $0.remoteIdentity(row.id) }
            guard metadata.fingerprint == expected, metadata.identity.fileID == identity else {
                _ = try withCatalog {
                    try $0.updateFingerprint(item: row.id, fingerprint: metadata.fingerprint,
                                             fileID: metadata.identity.fileID)
                }
                scheduleSignal()
                throw SourceFailure.versionChanged
            }
            let range = try ByteRange(offset: request.range.offset, length: request.range.length, fileSize: row.size)
            phase = "transfer"
            let output = try remote.transfer(path: path.string, range: range, stagingDirectory: stagingDirectory,
                                              progress: progress, checkSpace: checkSpace)
            phase = "complete"
            return output
        }
    }
}
