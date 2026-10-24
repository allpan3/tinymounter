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

    func configureWrites(_ bookmark: Data?) throws {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.readOnly }
            if bookmark == nil, try outbox().pendingCount > 0 { throw UploadError.pendingWrites }
            try withCatalog { try $0.setAllowsCreation(bookmark != nil) }
            writeBookmark = bookmark
        }
        scheduleSignal()
    }

    func pendingUploads() throws -> Int { try uploadLock.withLock { try outbox().pendingCount } }

    func suspendMutations() throws {
        try uploadLock.withLock {
            guard try outbox().pendingCount == 0 else { throw UploadError.pendingWrites }
            mutationsSuspended = true
        }
    }

    func resumeMutations() { uploadLock.withLock { mutationsSuspended = false } }

    func create(_ request: CreateRequest, contents: URL?, progress: Progress,
                started: @escaping @Sendable () -> Void,
                checkSpace: @escaping @Sendable (Int64) throws -> Void,
                reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try createOnLane(request, contents: contents, progress: progress, checkSpace: checkSpace) }
            Self.uploadLog.info("upload request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) ok=\((try? result.get()) != nil ? 1 : 0)")
            reply(result)
        }
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
            try withWriteSession(bookmark) { _, root in
                try outbox.upload(&record, locationRoot: root, progress: progress)
            }
            _ = try listOnLane(request.parent, requestID: request.id)
            guard let row = try liveChild(of: request.parent, named: request.name), row.kind == request.kind,
                  row.size == record.size || record.kind == .folder,
                  try withCatalog({ try $0.remoteIdentity(row.id) }) == record.remoteID else {
                throw UploadError.unresolved
            }
            try outbox.complete(&record, item: row.id)
            scheduleSignal()
            return CreateReceipt(item: row.id)
        }
    }

    func withWriteSession<Result>(_ bookmark: Data, _ body: (ShareSession, Int32) throws -> Result) throws -> Result {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw UploadError.readOnly }
        defer { url.stopAccessingSecurityScopedResource() }
        return try access.withSession { session, _ in
            let mount = try ShareAccess.connectedShares().first { $0.path == ShareAccess.filePath(url) }
            guard mount?.identity == session.identity else { throw UploadError.readOnly }
            let root = try session.locationRoot(folder)
            return try session.identity.guarding(root: root) { try body(session, root) }
        }
    }
}
