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
        connection.enqueue { [self] in
            started()
            var phase = "catalog"
            var relist: [(source: LocationSource, folder: String)] = []
            let result = Result {
                let (row, path, operation, write) = try editNamespace.perform {
                    try uploadLock.withLock {
                        guard !mutationsSuspended, writable else { throw UploadError.readOnly }
                        let (row, path) = try withCatalog { try $0.editTarget(request) }
                        guard let full = folder.appending(path) else { throw UploadError.invalidRequest }
                        try editNamespace.requireUncontested(path: full, excluding: request.id)
                        return (row, path, try editNamespace.beginRead(full), editNamespace.beginWrite(full))
                    }
                }
                defer { editNamespace.endRead(operation) }
                var writing = true
                defer { if writing { editNamespace.perform { _ = editNamespace.endWrite(write) } } }
                guard uploadLock.withLock({ writable }) else { throw UploadError.readOnly }
                phase = "connect"
                return try connection.withSession(folder: folder, progress: progress) { remote, _ in
                    let expected = request.failOnConflict
                        ? ContentFingerprint(size: row.size, mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs) : nil
                    phase = "overwrite"
                    let written = try remote.overwrite(path: path.string, contents: contents, expected: expected,
                                                       modified: request.modified)
                    phase = "catalog-update"
                    // One step for listings: the row changes only with the save's result.
                    return try editNamespace.perform {
                        let receipt = try withCatalog { catalog in
                            let (_, currentPath) = try catalog.editTarget(request, checkingVersion: false)
                            guard currentPath == path else { throw SourceFailure.versionChanged }
                            try catalog.updateFingerprint(item: row.id, fingerprint: written.fingerprint,
                                                          fileID: written.fileID)
                            guard let current = try catalog.item(id: row.id) else { throw UploadError.unresolved }
                            return EditReceipt(item: row.id, contentVersion: current.contentVersion)
                        }
                        writing = false
                        relist = editNamespace.endWrite(write)
                        return receipt
                    }
                }
            }
            // Listings that kept the row while the save ran now see its result.
            for (source, folderID) in relist { source.list(folderID, requestID: UUID()) }
            let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            if case .failure(let error) = result {
                logger.error("edit request=\(request.id.uuidString, privacy: .public) phase=\(phase, privacy: .public) failed \(logFields(error), privacy: .public)")
            } else {
                logger.info("edit request=\(request.id.uuidString, privacy: .public) completed")
            }
            uploadRetry.finished("edit:" + request.item, result: result)
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
        return try connection.withSession(folder: folder, progress: progress) { remote, _ in
            defer { bytes = remote.readBytes }
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
