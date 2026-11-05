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

    func configureWriteMode(_ bookmark: Data?) throws {
        try editNamespace.perform { try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.readOnly }
            if bookmark == nil, try Self.pendingWrites(domainID: domainID) > 0 { throw UploadError.pendingWrites }
            try withCatalog { try $0.setAllowsWriting(bookmark != nil) }
            writeBookmark = bookmark
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
        access.enqueue { [self] in
            started()
            // Retry releases only throttled items, so a failure clears when its item is tried again.
            failedCreatesLock.withLock { failedCreates[request.template] = nil }
            let result = Result { () throws -> CreateReceipt in
                // A stopped item is told to stay on this Mac before anything else is checked.
                if try uploadLock.withLock({ try outbox().takeStopped(template: request.template) }) {
                    throw UploadError.excluded
                }
                return try editNamespace.perform {
                    try editNamespace.requireSettled()
                    return try createOnLane(request, contents: contents, progress: progress, checkSpace: checkSpace)
                }
            }
            if case .failure(let error) = result, error as? UploadError == .collision {
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
            }
            noteCreate(request, result: result)
            Self.uploadLog.info("upload request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) ok=\((try? result.get()) != nil ? 1 : 0)")
            reply(result)
        }
    }

    func pendingCreates() throws -> [PendingCreate] {
        let records = try uploadLock.readForStatus { try outbox().records().filter(\.isPending) }
        let failures = failedCreatesLock.withLock { failedCreates }
        let known = Set(records.map(\.template))
        let waiting = records.map {
            PendingCreate(id: $0.template, path: $0.path, kind: $0.kind, failure: failures[$0.template],
                          stoppable: $0.isStoppable)
        }
        let failed = failures.filter { !known.contains($0.key) }.map {
            PendingCreate(id: $0.key, path: $0.value.path, kind: $0.value.kind, failure: $0.value, stoppable: false)
        }
        return (waiting + failed).sorted { $0.path < $1.path }
    }

    /// The stopped record is no longer pending; macOS keeps the item on this Mac when it sends the
    /// item again.
    func stopCreate(_ template: String) throws {
        try uploadLock.withLock {
            let outbox = try outbox()
            guard let record = try outbox.records().first(where: { $0.template == template && $0.isPending }) else {
                throw UploadError.invalidRequest
            }
            try outbox.stop(record.id)
        }
        failedCreatesLock.withLock { failedCreates[template] = nil }
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

    private func createOnLane(_ request: CreateRequest, contents: URL?, progress: Progress,
                              checkSpace: @escaping (Int64) throws -> Void) throws -> CreateReceipt {
        try finishPendingFolderName(request.parent)
        return try uploadLock.withLock {
            guard !mutationsSuspended, let bookmark = writeBookmark else { throw UploadError.readOnly }
            let path = try withCatalog { catalog -> RelativePath in
                guard let parent = try catalog.item(id: request.parent), !parent.deleted, parent.kind == .folder,
                      let base = try catalog.relativePath(of: parent.id), let path = base.appending(request.name) else {
                    throw UploadError.invalidRequest
                }
                return path
            }
            let outbox = try outbox()
            if try !outbox.records().contains(where: { $0.template == request.template }),
               try liveChild(of: request.parent, named: request.name) != nil { throw UploadError.collision }
            var record = try outbox.prepare(request, path: path, contents: contents, progress: progress, checkSpace: checkSpace)
            if record.state == .completed, let item = record.item { return CreateReceipt(item: item) }
            try withWriteSession(bookmark, progress: progress) { session in
                if record.kind == .folder {
                    try createFolder(&record, outbox: outbox, session: session, progress: progress)
                } else {
                    guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                    let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: session.root, progress: progress)
                    try outbox.upload(&record, remote: remote, progress: progress)
                }
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
            scheduleSignal()
            return CreateReceipt(item: row.id)
        }
    }

    func withWriteSession<Result>(_ bookmark: Data, progress: Progress? = nil,
                                  _ body: (ShareSession) throws -> Result) throws -> Result {
        return try access.withSession { session, progressed in
            // Resolution waits while the server does not answer, so it counts toward the stall limit.
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw UploadError.readOnly }
            defer { url.stopAccessingSecurityScopedResource() }
            let observation = progress?.observe(\.completedUnitCount) { _, _ in progressed() }
            defer { observation?.invalidate() }
            let mount = try ShareAccess.connectedShares().first { $0.path == ShareAccess.filePath(url) }
            guard mount?.identity == session.identity else { throw UploadError.readOnly }
            return try session.identity.guarding(root: session.root) { try body(session) }
        }
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
    /// Nothing reached the server, so Stop Uploading is offered.
    let stoppable: Bool
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
