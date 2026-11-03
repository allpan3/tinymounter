import Darwin
import Foundation
import OSLog

private final class FolderReceipt {
    let persist: (RemoteFolderIdentity) throws -> Void
    var nativeID: UInt64?
    var error: Error?
    var step = "none"

    init(persist: @escaping (RemoteFolderIdentity) throws -> Void) {
        self.persist = persist
    }

    func receive(fileID: UInt64, birth: UInt64) throws {
        step = "persist"
        let identity = try RemoteFolderIdentity(fileID: fileID, birthMicroseconds: birth)
        try persist(identity)
        nativeID = fileID
        step = "done"
    }
}

private func receiveFolder(_ context: UnsafeMutableRawPointer?, _ fileID: UInt64, _ birth: UInt64) -> Int32 {
    guard let context else { return EINVAL }
    let receipt = Unmanaged<FolderReceipt>.fromOpaque(context).takeUnretainedValue()
    do { try receipt.receive(fileID: fileID, birth: birth); return 0 }
    catch { receipt.error = error; return EIO }
}

extension LocationSource {
    private static let namingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    func nameFolder(_ request: FolderNameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
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
            guard !mutationsSuspended, let bookmark = writeBookmark else { throw UploadError.readOnly }
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
            try withWriteSession(bookmark) { session, root in
                let pin = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard pin >= 0 else { throw posixError("hold naming mount") }
                defer { Darwin.close(pin) }
                guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                try outbox.nameFolder(&record, name: request.name) { source, destination, identity, recovering in
                    guard let from = folder.appending(source), let to = folder.appending(destination) else {
                        throw UploadError.invalidRequest
                    }
                    return try folderReceipt(persist: { _ in }) { context in
                        var sent: Int32 = 0
                        let code = ShareAccess.withDirectSMB {
                            tm_smb_name_folder(endpoint.host, endpoint.share, endpoint.account,
                                               from.string, to.string, identity.fileID,
                                               identity.birthMicroseconds, recovering ? 1 : 0,
                                               receiveFolder, context, &sent)
                        }
                        guard code == 0 else { throw FolderMutationFailure(code: code, mayHaveChanged: sent != 0) }
                    }
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

    func createFolder(_ record: inout PendingUpload, outbox: UploadOutbox, session: ShareSession,
                      root: Int32, progress: Progress) throws {
        guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
        let requestID = record.id
        try outbox.createFolder(&record, progress: progress) { path, identity, persist in
            guard let source = folder.appending(path) else { throw UploadError.invalidRequest }
            return try folderReceipt(persist: persist) { context in
                var sent: Int32 = 0
                var trace = tm_smb_folder_trace()
                let code = ShareAccess.withDirectSMB {
                    tm_smb_create_folder(endpoint.host, endpoint.share, endpoint.account, source.string,
                                         identity?.fileID ?? 0, identity?.birthMicroseconds ?? 0,
                                         receiveFolder, context, &sent, &trace)
                }
                Self.logCreate(requestID, trace, Unmanaged<FolderReceipt>.fromOpaque(context).takeUnretainedValue())
                guard code == 0 else { throw FolderMutationFailure(code: code, mayHaveChanged: sent != 0) }
            }
        }
    }

    private static func logCreate(_ request: UUID, _ trace: tm_smb_folder_trace, _ receipt: FolderReceipt) {
        let stage = String(cString: tm_smb_folder_stage_name(trace.stage))
        let status = String(format: "0x%08x", trace.status)
        namingLog.notice("""
            folder_create request=\(request.uuidString, privacy: .public) stage=\(stage, privacy: .public) \
            parents=\(trace.parents) status=\(status, privacy: .public) errno=\(trace.error) \
            sent=\(trace.sent_queued)>\(trace.sent) receipt=\(receipt.step, privacy: .public)
            """)
    }

    private func folderReceipt(persist: (RemoteFolderIdentity) throws -> Void,
                               operation: (UnsafeMutableRawPointer) throws -> Void) throws -> UInt64 {
        try withoutActuallyEscaping(persist) { persist in
            let receipt = FolderReceipt(persist: persist)
            do { try operation(Unmanaged.passUnretained(receipt).toOpaque()) }
            catch { throw receipt.error ?? error }
            guard let nativeID = receipt.nativeID else { throw UploadError.unresolved }
            return nativeID
        }
    }
}
