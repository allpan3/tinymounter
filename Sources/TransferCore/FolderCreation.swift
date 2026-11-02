import Darwin
import Foundation

public struct RemoteFolderIdentity: Codable, Equatable, Sendable {
    public let fileID: UInt64
    public let birthMicroseconds: UInt64

    public init(fileID: UInt64, birthMicroseconds: UInt64) throws {
        guard fileID != 0, birthMicroseconds != 0 else { throw UploadError.unresolved }
        self.fileID = fileID
        self.birthMicroseconds = birthMicroseconds
    }
}

extension UploadOutbox {
    public func createFolder(_ record: inout PendingUpload, progress: Progress,
                             checkpoint: @escaping (PendingUpload.State) throws -> Void = { _ in },
                             create: (RelativePath, RemoteFolderIdentity?,
                                      (RemoteFolderIdentity) throws -> Void) throws -> UInt64) throws {
        guard record.kind == .folder, let path = RelativePath(record.path) else { throw UploadError.invalidRequest }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        if record.state == .completed { return }
        if record.state == .collision { throw UploadError.collision }
        // An attempt without a server identity is checked by creating the folder again, which
        // succeeds only while the name is absent.
        let uncertain = record.state == .attempting && record.serverFolder == nil
        if record.state == .prepared {
            record.state = .attempting
            try save(record)
            try checkpoint(.attempting)
        } else if record.serverFolder == nil, !uncertain {
            throw UploadError.unresolved
        }
        do {
            let nativeID = try create(path, record.serverFolder) { identity in
                guard record.serverFolder == nil || record.serverFolder == identity else { throw UploadError.unresolved }
                record.serverFolder = identity
                record.state = .created
                try save(record)
                try checkpoint(.created)
            }
            guard nativeID != 0, record.serverFolder != nil else { throw UploadError.unresolved }
            record.remoteID = nativeID
        } catch let failure as FolderMutationFailure where !failure.mayHaveChanged && record.serverFolder == nil {
            // After an uncertain attempt, the folder at the name may be the one that attempt created.
            if failure.code == EEXIST, uncertain { throw UploadError.unresolved }
            record.state = failure.code == EEXIST ? .collision : .prepared
            try save(record)
            if failure.code == EEXIST { throw UploadError.collision }
            throw failure
        }
        record.state = .verified
        try save(record)
        try checkpoint(.verified)
    }
}
