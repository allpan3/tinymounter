import Foundation
import OSLog

extension LocationSource {
    private static let namingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    func nameFolder(_ request: FolderNameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        connection.enqueue { [self] in
            started()
            let result = Result { try editNamespace.perform {
                try editNamespace.requireSettled()
                return try nameFolderOnLane(request, progress: progress)
            } }
            if case .failure(let error) = result, error as? UploadError == .collision {
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
            }
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
            guard !mutationsSuspended, writable else { throw UploadError.readOnly }
            guard !progress.isCancelled else { throw TransferError.cancelled }
            let outbox = try Self.outbox(domainID: domainID)
            var record = try outbox.initialNamingRecord(item: request.item)
            guard record.parent == request.parent, let identity = record.remoteID else { throw UploadError.readOnly }
            try withCatalog { catalog in
                guard let row = try catalog.item(id: request.item), !row.deleted, row.kind == .folder,
                      row.parentID == request.parent,
                      let path = try catalog.relativePath(of: row.id),
                      path.string == record.path || path.string == record.initialName?.destination else {
                    throw UploadError.unresolved
                }
                let current = try catalog.remoteIdentity(row.id)
                guard current == record.remoteID ||
                        (row.name == record.initialName?.name && current == record.initialName?.nativeID) else {
                    throw UploadError.unresolved
                }
                if record.initialName == nil,
                   let other = try catalog.liveChild(parent: request.parent, nameKey: NameKey(request.name)),
                   other.id != request.item { throw UploadError.collision }
            }
            try connection.withSession(folder: folder) { remote, _ in
                try outbox.nameFolder(&record, name: request.name) { source, destination, identity, recovering in
                    try remote.nameFolder(from: source, to: destination, expected: identity, recoveryOnly: recovering)
                }
            }
            if record.initialName?.state == .verified {
                try withCatalog { try $0.nameCreatedFolder(id: request.item, name: request.name,
                                                         expectedIdentity: identity,
                                                         newIdentity: record.initialName?.nativeID) }
                try outbox.completeFolderName(&record)
            }
            progress.completedUnitCount = progress.totalUnitCount
            scheduleSignal()
            return CreateReceipt(item: request.item)
        }
    }

    func createFolder(_ record: inout PendingUpload, outbox: UploadOutbox, remote: any RemoteSession,
                      progress: Progress) throws {
        try outbox.createFolder(&record, progress: progress) { path, identity, persist in
            try remote.createFolder(path, expected: identity, receipt: persist)
        }
    }
}
