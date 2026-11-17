import AppKit
import Darwin
import Foundation
import OSLog

extension LocationSource {
    private static let uploadLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    static func outbox(domainID: String) throws -> UploadOutbox {
        guard UUID(uuidString: domainID)?.uuidString == domainID else { throw UploadError.invalidRequest }
        return try UploadOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Uploads/\(domainID)", directoryHint: .isDirectory))
    }

    private func outbox() throws -> UploadOutbox { try Self.outbox(domainID: domainID) }

    func checkReimport(_ request: CreateRequest) throws {
        try uploadLock.withLock {
            var path: RelativePath?
            if request.recoveringReimport {
                path = try? withCatalog { try $0.relativePath(of: request.parent)?.appending(request.name) }
            }
            try outbox().checkReimport(request, path: path)
        }
    }

    func reimportRecoveries() throws -> [ReimportRecovery] {
        try uploadLock.readForStatus { try outbox().reimportRecoveries().sorted { $0.path < $1.path } }
    }

    func configureWriteMode(_ writable: Bool) throws {
        try editNamespace.perform { try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.readOnly }
            if !writable, try Self.pendingWrites(domainID: domainID) > 0 { throw UploadError.pendingWrites }
            try withCatalog { try $0.setAllowsWriting(writable) }
            self.writable = writable
        } }
        scheduleSignal()
    }

    func pendingUploads() throws -> Int {
        do { return try uploadLock.readForStatus { try Self.pendingWrites(domainID: domainID) } }
        catch {
            Self.uploadLog.error("pending_writes failed \(logFields(error), privacy: .public)")
            throw error
        }
    }

    func suspendMutations() throws {
        try editNamespace.perform { try uploadLock.withLock {
            guard try Self.pendingWrites(domainID: domainID) == 0 else { throw UploadError.pendingWrites }
            mutationsSuspended = true
        } }
    }

    func resumeMutations() { uploadLock.withLock { mutationsSuspended = false } }

    /// What Remove Location would stop, and what blocks it.
    static func removalItems(domainID: String) throws -> RemovalItems {
        var stoppable: [String] = [], blocking: [String] = []
        for record in try outbox(domainID: domainID).records() where record.isPending {
            let text = record.kind == .folder ? UIText.newFolderPending(record.path) : UIText.newFilePending(record.path)
            if record.isStoppable { stoppable.append(text) } else { blocking.append(text) }
        }
        blocking += try renameOutbox().intents().filter { $0.isPending && $0.domains.contains(domainID) }
            .map(UIText.renameDescription)
        blocking += try deletionOutbox().records()
            .filter { $0.isPending && $0.plan.views.contains { $0.domain == domainID } }
            .map { try UIText.deletionPending($0.selectedPath(in: domainID)) }
        // Contents whose record is missing count as pending but have no name.
        let unnamed = try pendingWrites(domainID: domainID) - stoppable.count - blocking.count
        if unnamed > 0 { blocking.append(UIText.unnamedPending(unnamed)) }
        return RemovalItems(stoppable: stoppable.sorted(), blocking: blocking.sorted())
    }

    /// Remove Location: refuses unless the items it would stop are the ones the user confirmed.
    func suspendForRemoval(stopping confirmed: [String]) throws {
        try editNamespace.perform { try uploadLock.withLock {
            let items = try Self.removalItems(domainID: domainID)
            guard items.blocking.isEmpty, items.stoppable == confirmed else { throw UploadError.pendingWrites }
            mutationsSuspended = true
        } }
    }

    func create(_ request: CreateRequest, contents: URL?, progress: Progress,
                started: @escaping @Sendable () -> Void,
                checkSpace: @escaping @Sendable (Int64) throws -> Void,
                reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        connection.enqueue { [self] in
            uploadRetry.started("create:" + request.template)
            started()
            // Retry releases only throttled items, so a failure clears when its item is tried again.
            failedCreatesLock.withLock { failedCreates[request.template] = nil }
            let result = Result { () throws -> CreateReceipt in
                try checkReimport(request)
                // A stopped item is told to stay on this Mac before anything else is checked.
                if try uploadLock.withLock({ try outbox().takeStopped(template: request.template) }) {
                    throw UploadError.excluded
                }
                return try createOnLane(request, contents: contents, progress: progress, checkSpace: checkSpace)
            }
            if case .failure(let error) = result, error as? UploadError == .collision {
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
            }
            noteCreate(request, result: result)
            uploadRetry.finished("create:" + request.template, result: result)
            var failure = ""
            if case .failure(let error) = result { failure = " " + logFields(error) }
            Self.uploadLog.info("""
                upload request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                ok=\(failure.isEmpty ? 1 : 0)\(failure, privacy: .public)
                """)
            reply(result)
        }
    }

    func pendingCreates() throws -> [PendingCreate] {
        let records = try uploadLock.readForStatus { try outbox().records().filter(\.isPending) }
        let failures = failedCreatesLock.withLock { failedCreates }
        let known = Set(records.map(\.template))
        let waiting = records.map { record in
            let writing = RelativePath(record.path).flatMap(folder.appending).map(editNamespace.isWriting) ?? true
            return PendingCreate(id: record.template, path: record.path, kind: record.kind,
                                 failure: failures[record.template],
                                 stoppable: record.isStoppable || (record.isStoppableAfterCheck && !writing),
                                 partialOnServer: record.isPartialOnServer)
        }
        let failed = failures.filter { !known.contains($0.key) }.map {
            PendingCreate(id: $0.key, path: $0.value.path, kind: $0.value.kind, failure: $0.value, stoppable: false,
                          partialOnServer: false)
        }
        return (waiting + failed).sorted { $0.path < $1.path }
    }

    /// The stopped record is no longer pending; macOS keeps the item on this Mac when it sends the
    /// item again. A file that reached the server loses its partial server file first.
    func stopCreate(_ template: String) throws {
        let outbox = try outbox()
        let record = try uploadLock.withLock {
            guard let record = try outbox.records().first(where: { $0.template == template && $0.isPending }) else {
                throw UploadError.invalidRequest
            }
            if record.isStoppable { try outbox.stop(record.id) }
            else if !record.isStoppableAfterCheck { throw UploadError.unresolved }
            return record
        }
        if !record.isStoppable {
            try editNamespace.perform { try uploadLock.withLock {
                guard !mutationsSuspended, writable else { throw UploadError.readOnly }
                guard let full = RelativePath(record.path).flatMap(folder.appending) else { throw UploadError.invalidRequest }
                // The upload that writes the file holds it open; it ends first.
                guard !editNamespace.isWriting(full) else { throw UploadError.pendingWrites }
                try connection.withSession(folder: folder) { remote, _ in try outbox.stop(record.id, remote: remote) }
            } }
            Self.uploadLog.info("upload_stopped domain=\(self.domainID, privacy: .public) partial=\(record.isPartialOnServer)")
        }
        failedCreatesLock.withLock { failedCreates[template] = nil }
        uploadRetry.finished("create:" + template, result: Result<Void, Error>.success(()))
    }

    private func noteCreate(_ request: CreateRequest, result: Result<CreateReceipt, Error>) {
        guard case .failure(let error) = result, error as? UploadError != .excluded else {
            failedCreatesLock.withLock { failedCreates[request.template] = nil }
            return
        }
        guard error as? TransferError != .cancelled else { return }
        let parent = try? withCatalog { try $0.relativePath(of: request.parent) }
        let path = parent?.appending(request.name)?.string ?? request.name
        let failure = FailedCreate(path: path, kind: request.kind, reason: UIText.uploadFailure(error), date: .now)
        failedCreatesLock.withLock { failedCreates[request.template] = failure }
    }

    /// The namespace lock covers the checks, the server create and the final listing. A file's
    /// contents are written outside it, as an edit's are, so that reads and first listings in this
    /// share don't wait for the transfer.
    private func createOnLane(_ request: CreateRequest, contents: URL?, progress: Progress,
                              checkSpace: @escaping (Int64) throws -> Void) throws -> CreateReceipt {
        let outbox = try outbox()
        let prepared = try editNamespace.perform { () throws -> (record: PendingUpload, path: RelativePath) in
            try editNamespace.requireSettled()
            try finishPendingFolderName(request.parent)
            return try uploadLock.withLock {
                guard !mutationsSuspended, writable else { throw UploadError.readOnly }
                let path = try withCatalog { catalog -> RelativePath in
                    guard let parent = try catalog.item(id: request.parent), !parent.deleted, parent.kind == .folder,
                          let base = try catalog.relativePath(of: parent.id), let path = base.appending(request.name) else {
                        throw UploadError.invalidRequest
                    }
                    return path
                }
                if try !outbox.records().contains(where: { $0.template == request.template }),
                   try liveChild(of: request.parent, named: request.name) != nil { throw UploadError.collision }
                let record = try outbox.prepare(request, path: path, contents: contents, progress: progress,
                                                checkSpace: checkSpace)
                return (record, path)
            }
        }
        var record = prepared.record
        let path = prepared.path
        if record.state == .completed, let item = record.item { return CreateReceipt(item: item) }
        // Listings and notices that skipped the file while it was written list again at the end.
        var write: UUID?
        var relist: [(source: LocationSource, folder: String)] = []
        defer {
            if let write { relist = editNamespace.perform { editNamespace.endWrite(write) } }
            for (source, folderID) in relist { source.list(folderID, requestID: UUID()) }
        }
        if record.kind == .folder {
            try editNamespace.perform { try uploadLock.withLock {
                try connection.withSession(folder: folder, progress: progress) { remote, _ in
                    try createFolder(&record, outbox: outbox, remote: remote, progress: progress)
                }
            } }
        } else {
            try connection.withSession(folder: folder, progress: progress) { remote, _ in
                let (step, transfer) = try editNamespace.perform { try uploadLock.withLock {
                    // The locks were released while the session opened.
                    try editNamespace.requireSettled()
                    guard !mutationsSuspended, writable else { throw UploadError.readOnly }
                    if try outbox.takeStopped(template: request.template) { throw UploadError.excluded }
                    guard let full = folder.appending(path) else { throw UploadError.invalidRequest }
                    // A folder move waits for the transfer, as for a read.
                    let transfer = try editNamespace.beginRead(full)
                    write = editNamespace.beginWrite(full)
                    do { return (try outbox.beginUpload(&record, remote: remote, progress: progress), transfer) }
                    catch {
                        editNamespace.endRead(transfer)
                        throw error
                    }
                } }
                defer { editNamespace.endRead(transfer) }
                try outbox.finishUpload(&record, step: step, remote: remote, progress: progress)
            }
        }
        return try editNamespace.perform { try uploadLock.withLock {
            if let ended = write {
                write = nil
                // This listing of the parent covers its own notices.
                relist = editNamespace.endWrite(ended).filter { $0.source !== self || $0.folder != request.parent }
            }
            _ = try listOnLane(request.parent, requestID: request.id)
            let listed = try liveChild(of: record.parent, named: record.name)
            guard let row = listed, row.kind == request.kind, row.size == record.size || record.kind == .folder,
                  try withCatalog({ try $0.remoteIdentity(row.id) }) == record.remoteID else {
                Self.uploadLog.error("""
                    upload_unresolved request=\(request.id.uuidString, privacy: .public) listed=\(listed != nil) \
                    kind=\(listed?.kind == request.kind) size=\(listed?.size == record.size)
                    """)
                throw UploadError.unresolved
            }
            try outbox.complete(&record, item: row.id)
            pruneCompletedUploads(outbox)
            scheduleSignal()
            return CreateReceipt(item: row.id)
        } }
    }

    /// Completed records stay for an hour, so a create that macOS sends again after a lost reply
    /// gets the same item. Runs at most once an hour, with the upload lock held.
    private func pruneCompletedUploads(_ outbox: UploadOutbox) {
        guard lastUploadPrune.map({ $0.timeIntervalSinceNow < -3600 }) ?? true else { return }
        lastUploadPrune = .now
        do { try outbox.pruneCompleted(before: Date(timeIntervalSinceNow: -3600)) }
        catch { Self.uploadLog.error("upload_prune failed \(logFields(error), privacy: .public)") }
    }
}

struct RemovalItems: Equatable, Sendable {
    /// Items that never reached the server; macOS keeps them on this Mac when the location goes.
    var stoppable: [String] = []
    /// Changes that may have reached the server; they must finish first.
    var blocking: [String] = []
}

struct FailedCreate: Sendable {
    let path: String
    let kind: CatalogRow.Kind
    let reason: String
    let date: Date
}

struct PendingCreate: Identifiable, Sendable {
    let id: String
    let path: String
    let kind: CatalogRow.Kind
    let failure: FailedCreate?
    /// Stop Uploading is offered: nothing reached the server, or a server check can settle it.
    let stoppable: Bool
    /// Stop Uploading deletes the partial file that the upload left on the server.
    let partialOnServer: Bool
}

protocol StatusLock: NSLocking { func lock(before limit: Date) -> Bool }
extension NSLock: StatusLock {}
extension NSRecursiveLock: StatusLock {}

extension StatusLock {
    /// An upload or an unresponsive share can hold the lock for minutes. Records are saved
    /// atomically, so after half a second Settings reads them without the lock.
    func readForStatus<T>(_ read: () throws -> T) rethrows -> T {
        guard lock(before: Date(timeIntervalSinceNow: 0.5)) else {
            // A change of several files can remove one between listing and reading; read once more.
            if let result = try? read() { return result }
            return try read()
        }
        defer { unlock() }
        return try read()
    }
}
