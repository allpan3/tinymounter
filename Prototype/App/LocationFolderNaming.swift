import Darwin
import Foundation
import OSLog

extension LocationSource {
    private static let namingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    func nameFolder(_ request: FolderNameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try nameFolderOnLane(request, progress: progress) }
            Self.namingLog.info("folder_name request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil ? 1 : 0)")
            reply(result)
        }
    }

    func finishPendingFolderName(_ item: String) throws {
        guard let record = try Self.outbox(domainID: domainID).records().first(where: { $0.item == item }),
              let naming = record.initialName, naming.isPending else { return }
        let request = try FolderNameRequest(item: item, parent: record.parent, name: naming.name)
        _ = try nameFolderOnLane(request, progress: Progress(totalUnitCount: 1))
    }

    private func nameFolderOnLane(_ request: FolderNameRequest, progress: Progress) throws -> CreateReceipt {
        try uploadLock.withLock {
            guard !mutationsSuspended, let bookmark = writeBookmark else { throw UploadError.readOnly }
            guard !progress.isCancelled else { throw TransferError.cancelled }
            let outbox = try Self.outbox(domainID: domainID)
            var record = try outbox.initialNamingRecord(item: request.item)
            guard record.parent == request.parent, let identity = record.remoteID else { throw UploadError.readOnly }
            try withCatalog { catalog in
                guard let row = try catalog.item(id: request.item), !row.deleted, row.kind == .folder,
                      row.parentID == request.parent, try catalog.remoteIdentity(row.id) == record.remoteID,
                      let path = try catalog.relativePath(of: row.id),
                      path.string == record.path || path.string == record.initialName?.destination else {
                    throw UploadError.unresolved
                }
                if record.initialName == nil,
                   let other = try catalog.liveChild(parent: request.parent, nameKey: NameKey(request.name)),
                   other.id != request.item { throw UploadError.collision }
            }
            try withWriteSession(bookmark) { session, root in
                let pin = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard pin >= 0 else { throw posixError("hold naming mount") }
                defer { Darwin.close(pin) }
                guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                try outbox.nameFolder(&record, name: request.name) { source, destination, identity, recovering in
                    guard let from = folder.appending(source), let to = folder.appending(destination) else {
                        throw UploadError.invalidRequest
                    }
                    var sent: Int32 = 0
                    let code = tm_smb_name_folder(endpoint.host, endpoint.share, endpoint.account,
                                                  from.string, to.string, identity, recovering ? 1 : 0, &sent)
                    guard code == 0 else { throw FolderNamingFailure(code: code, mayHaveRenamed: sent != 0) }
                }
            }
            if record.initialName?.state == .verified {
                try withCatalog { try $0.nameCreatedFolder(id: request.item, name: request.name,
                                                         expectedIdentity: identity) }
                try outbox.completeFolderName(&record)
            }
            progress.completedUnitCount = progress.totalUnitCount
            scheduleSignal()
            return CreateReceipt(item: request.item)
        }
    }
}
