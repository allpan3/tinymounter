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

    func create(_ request: CreateRequest, contents: URL?, progress: Progress,
                started: @escaping @Sendable () -> Void,
                checkSpace: @escaping @Sendable (Int64) throws -> Void,
                reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try editNamespace.perform {
                try editNamespace.requireSettled()
                return try createOnLane(request, contents: contents, progress: progress, checkSpace: checkSpace)
            } }
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
            PendingCreate(id: $0.template, path: $0.path, kind: $0.kind, failure: failures[$0.template])
        }
        let failed = failures.filter { !known.contains($0.key) }.map {
            PendingCreate(id: $0.key, path: $0.value.path, kind: $0.value.kind, failure: $0.value)
        }
        return (waiting + failed).sorted { $0.path < $1.path }
    }

    /// Retry asks macOS to send the items again, and each attempt records its result again.
    func clearFailedCreates() { failedCreatesLock.withLock { failedCreates = [:] } }

    private func noteCreate(_ request: CreateRequest, result: Result<CreateReceipt, Error>) {
        guard case .failure(let error) = result else {
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
            try withWriteSession(bookmark, progress: progress) { session, root in
                if record.kind == .folder {
                    try createFolder(&record, outbox: outbox, session: session, root: root, progress: progress)
                } else {
                    try outbox.upload(&record, locationRoot: root, progress: progress)
                }
            }
            _ = try listOnLane(request.parent, requestID: request.id)
            guard let row = try liveChild(of: request.parent, named: request.name), row.kind == request.kind,
                  row.size == record.size || record.kind == .folder,
                  try withCatalog({ try $0.remoteIdentity(row.id) }) == record.remoteID else {
                throw UploadError.unresolved
            }
            if row.kind == .file, row.allowsWriting {
                try establishUploadedEditBase(record, row: row, bookmark: bookmark, progress: progress)
            }
            try outbox.complete(&record, item: row.id)
            scheduleSignal()
            return CreateReceipt(item: row.id)
        }
    }

    func withWriteSession<Result>(_ bookmark: Data, progress: Progress? = nil,
                                  _ body: (ShareSession, Int32) throws -> Result) throws -> Result {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw UploadError.readOnly }
        defer { url.stopAccessingSecurityScopedResource() }
        return try access.withSession { session, progressed in
            let observation = progress?.observe(\.completedUnitCount) { _, _ in progressed() }
            defer { observation?.invalidate() }
            let mount = try ShareAccess.connectedShares().first { $0.path == ShareAccess.filePath(url) }
            guard mount?.identity == session.identity else { throw UploadError.readOnly }
            let root = try session.locationRoot(folder)
            return try session.identity.guarding(root: root) { try body(session, root) }
        }
    }
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
}

protocol StatusLock: NSLocking { func lock(before limit: Date) -> Bool }
extension NSLock: StatusLock {}
extension NSRecursiveLock: StatusLock {}

extension StatusLock {
    /// An upload or an unresponsive share can hold the lock for minutes. Records are saved
    /// atomically, so after half a second Settings reads them without the lock.
    func readForStatus<T>(_ read: () throws -> T) rethrows -> T {
        guard lock(before: Date(timeIntervalSinceNow: 0.5)) else { return try read() }
        defer { unlock() }
        return try read()
    }
}
