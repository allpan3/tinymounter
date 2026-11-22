import Darwin
import Foundation
import OSLog
import UniformTypeIdentifiers

/// One SMB connection, signed in with a password. `SMBClient.openSession` opens it.
final class SMBEdit: FileRenameRemote, UploadRemote {
    private final class Handle {
        var bytes = [UInt8](repeating: 0, count: 16)
        var readSnapshot: [UInt64]?

        func use<T>(_ body: (UnsafeMutablePointer<UInt8>) throws -> T) rethrows -> T {
            try bytes.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
    }

    private let client: UnsafeMutableRawPointer
    private let endpoint: ShareAddress
    private let folder: RelativePath
    private let progress: Progress
    private var handles: [String: Handle] = [:]
    private var directories: [String: Handle] = [:]
    private var deletionTarget: String?
    private var deletionParents: [ItemDeletionParent]?
    private var folderMoveRoots: [String: Handle] = [:]
    private var folderMoveFiles: [String: Handle] = [:]
    private var folderMoveParents: Set<String> = []
    private var folderMoveParentBindings: [FileRenameParent]?
    private var folderMoveAttempted = false
    private(set) var readBytes: Int64 = 0
    /// Set when a deletion traversal starts; that session never deletes.
    private var deletionTraversalFiles: [String: Handle]?
    private static let read: UInt32 = 0x20081
    /// Data and attributes: the save time is a SET_INFO on the handle that wrote the data.
    private static let write: UInt32 = 0x102
    private static let delete: UInt32 = 0x10000
    private static let statusKey = "tinymounter.smb.ntstatus"

    /// Throws `SourceFailure`.
    init(share: ShareAddress, password: Data, folder: RelativePath, previousSession: UInt64?,
         progress: Progress) throws {
        var error: Int32 = 0, status: UInt32 = 0
        guard let client = SMBClient.withLogin(host: share.host, account: share.account, password: password, {
            tm_edit_connect_password($0, share.share, previousSession ?? 0, &error, &status)
        }) else {
            throw SMBSignIn.failure(status: status, errno: error)
        }
        self.client = client
        endpoint = share
        self.folder = folder
        self.progress = progress
    }

    deinit { tm_edit_disconnect(client) }

    var sessionID: UInt64 { tm_edit_session(client) }

    var droppedSessionID: UInt64? {
        let id = tm_edit_dropped_session(client)
        return id == 0 ? nil : id
    }

    func protectAncestors(of path: String) throws {
        let full = try remotePath(path)
        let components = RelativePath(full)!.components.dropLast()
        var parent = ""
        for component in [""] + components {
            if !component.isEmpty { parent += (parent.isEmpty ? "" : "/") + component }
            if directories[parent] != nil { continue }
            let handle = Handle()
            try handle.use { try check(tm_edit_open_directory(client, parent, 0x81, 3, $0)) }
            let values = try info(handle)
            guard values[0] != 0, values[1] != 0, values[4] & 0x410 == 0x10 else {
                throw UploadError.unresolved
            }
            directories[parent] = handle
        }
    }

    func protectRenameParents(source: String, destination: String) throws -> [FileRenameParent] {
        try protectAncestors(of: source)
        try protectAncestors(of: destination)
        let paths = try Set([source, destination].flatMap { path -> [String] in
            let full = try remotePath(path)
            let components = RelativePath(full)!.components
            return (0..<components.count).map { components.prefix($0).joined(separator: "/") }
        })
        return try paths.sorted().map { path in
            guard let handle = directories[path], let relative = RelativePath(path) else {
                throw UploadError.unresolved
            }
            let values = try info(handle)
            guard values[4] & 0x410 == 0x10 else { throw UploadError.unresolved }
            let identity = try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])
            var name = ""
            if let component = relative.components.last {
                let parent = relative.components.dropLast().joined(separator: "/")
                guard let entry = try renameEntry(parent: parent, name: component),
                      entry.identity == identity, entry.name == component else { throw UploadError.unresolved }
                name = entry.name
            }
            return FileRenameParent(path: path, name: name, identity: identity)
        }
    }

    func inspectRename(path: String) throws -> FileRenameEvidence? {
        try protectAncestors(of: path)
        let full = try remotePath(path)
        let parent = RelativePath(full)!.components.dropLast().joined(separator: "/")
        let name = RelativePath(path)!.components.last!
        if handles[path] == nil {
            guard let entry = try renameEntry(parent: parent, name: name) else { return nil }
            let components = RelativePath(path)!.components.dropLast() + [entry.name]
            handles[path] = try open(path: components.joined(separator: "/"),
                                     access: Self.read | Self.delete, sharing: 1)
        }
        let current = try version(handles[path]!)
        guard let entry = try renameEntry(parent: parent, name: name), entry.identity == current.identity else {
            throw UploadError.unresolved
        }
        return FileRenameEvidence(version: current, name: entry.name)
    }

    func renameSourceEntry(path: String) throws -> RenameDirectoryEntry? {
        try protectAncestors(of: path)
        let full = try remotePath(path)
        guard let relative = RelativePath(full), let name = relative.components.last else {
            throw UploadError.unresolved
        }
        return try renameEntry(parent: relative.components.dropLast().joined(separator: "/"), name: name)
    }

    func releaseRename(path: String) throws {
        guard let handle = handles[path] else { return }
        try handle.use { try check(tm_edit_close(client, $0)) }
        handles[path] = nil
    }

    private func renameEntry(parent: String, name: String) throws -> RenameDirectoryEntry? {
        guard let directory = directories[parent] else { throw UploadError.unresolved }
        var result: RenameDirectoryEntry?, seen = 0, pages = 0, restart = true
        while true {
            try cancellation()
            var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
            try directory.use {
                try check(tm_edit_list(client, $0, restart ? 1 : 0, &buffer, UInt32(buffer.count), &count, &finished))
            }
            if finished != 0 { return result }
            pages += 1
            let entries = try RenameDirectoryEntry.parse(Array(buffer.prefix(Int(count))))
            seen += entries.count
            guard seen <= DirectoryListing.defaultLimit, pages <= DirectoryListing.defaultLimit else {
                throw SourceFailure.tooManyEntries
            }
            for entry in entries where NameKey(entry.name) == NameKey(name) {
                guard result == nil else { throw UploadError.collision }
                result = entry
            }
            progress.completedUnitCount += 1
            restart = false
        }
    }

    func readVersion(path: String) throws -> RemoteFileVersion {
        let handle = try handles[path] ?? open(path: path, access: Self.read, sharing: 1)
        handles[path] = handle
        return try version(handle)
    }

    func protectRead(path: String) throws {
        handles[path] = try open(path: path, access: Self.read, sharing: 1)
    }

    func directoryIdentity(_ path: RelativePath) throws -> RemoteFileIdentity {
        try protectAncestors(of: path.appending("child")!.string)
        guard let full = folder.appending(path), let handle = directories[full.string] else {
            throw UploadError.unresolved
        }
        let values = try info(handle)
        return try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])
    }

    func list(_ path: RelativePath, progressed: () -> Void = {}) throws -> DirectoryListing {
        let started = ContinuousClock.now
        _ = try directoryIdentity(path)
        guard let full = folder.appending(path), let handle = directories[full.string] else {
            throw UploadError.unresolved
        }
        let opened = ContinuousClock.now
        var totalCalls = 0
        for attempt in 0..<3 {
            let before = try info(handle)
            var entries: [RenameDirectoryEntry] = [], calls = 0
            while true {
                try cancellation()
                var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
                try handle.use {
                    try check(tm_edit_list(client, $0, calls == 0 ? 1 : 0, &buffer, UInt32(buffer.count), &count, &finished))
                }
                calls += 1
                totalCalls += 1
                progressed()
                if finished != 0 { break }
                let page = try RenameDirectoryEntry.parse(Array(buffer.prefix(Int(count))))
                guard page.count <= DirectoryListing.defaultLimit - entries.count,
                      calls <= DirectoryListing.defaultLimit else { throw SourceFailure.tooManyEntries }
                entries += page
            }
            let after = try info(handle)
            if before[0...1] == after[0...1], before[5...6] == after[5...6] {
                return try DirectoryListing(smbEntries: entries, openDuration: started.duration(to: opened),
                                            bulkDuration: opened.duration(to: .now), bulkCalls: totalCalls)
            }
            Logger(subsystem: "dev.tinymounter.prototype", category: "listing").info("""
                direct_list_restart attempt=\(attempt + 1) identity=\(before[0...1] != after[0...1]) \
                mtime=\(before[5] != after[5]) ctime=\(before[6] != after[6])
                """)
        }
        throw SourceFailure.listingIncomplete
    }

    func confirmMissing(_ children: [MissingChild], in path: RelativePath, progressed: () -> Void = {}) throws {
        guard !children.isEmpty else { return }
        let current = try list(path, progressed: progressed)
        for child in children {
            let key = NameKey(child.name)
            guard !current.unreadable.contains(where: { $0.key == key }),
                  !current.collisionLosers.contains(where: { $0.key == key }),
                  !current.entries.contains(where: { $0.key == key && $0.fileID != child.twinFileID }) else {
                throw SourceFailure.listingIncomplete
            }
        }
    }

    func readMetadata(path: String) throws -> (identity: RemoteFileIdentity, fingerprint: ContentFingerprint) {
        let handle = try handles[path] ?? open(path: path, access: 0x81, sharing: 7)
        handles[path] = handle
        handle.readSnapshot = nil
        let values = try info(handle)
        guard values[2] <= Int64.max, values[3] == 1, values[4] & 0x450 == 0 else {
            throw UploadError.unresolved
        }
        let identity = try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])
        let fingerprint = try ContentFingerprint(smbSize: Int64(values[2]), modifiedMicroseconds: values[5],
                                                 changedMicroseconds: values[6])
        handle.readSnapshot = values
        return (identity, fingerprint)
    }

    func transfer(path: String, range: ByteRange, stagingDirectory: URL, progress: Progress,
                  checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput {
        guard let handle = handles[path], let before = handle.readSnapshot else {
            throw UploadError.unresolved
        }
        let blockSize = Int(max(4096, min(range.length, Int64(TM_SMB_IO_BATCH_SIZE))))
        return try Transfer.run(size: Int64(before[2]), range: range, blockSize: blockSize,
            stagingDirectory: stagingDirectory, progress: progress, checkSpace: checkSpace, validate: {
                try self.cancellation()
                let after = try self.info(handle)
                guard after[0] == before[0], after[2...6] == before[2...6] else {
                    throw SourceFailure.versionChanged
                }
            }, read: { offset, buffer in
                try self.read(handle, offset: offset, buffer: buffer, reportProgress: false)
            })
    }

    private func read(_ handle: Handle, offset: Int64, buffer: UnsafeMutableRawBufferPointer,
                      reportProgress: Bool = true) throws -> Int {
        try cancellation()
        var count: UInt32 = 0
        try handle.use {
            try check(tm_edit_read(client, $0, UInt64(offset), buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                   UInt32(buffer.count), &count))
        }
        guard count > 0, count <= buffer.count else { throw UploadError.unresolved }
        readBytes += Int64(count)
        if reportProgress { progress.completedUnitCount += Int64(count) }
        return Int(count)
    }

    func allowPublishedReads(path: String, expected: RemoteFileVersion) throws {
        guard let previous = handles[path] else { throw UploadError.unresolved }
        // Revalidate after releasing the exclusive guard before allowing other readers.
        try previous.use { try check(tm_edit_close(client, $0)) }
        handles[path] = nil
        let current = try readVersion(path: path)
        guard current.hasSameDataVersion(as: expected),
              current.modifiedMicroseconds == expected.modifiedMicroseconds else {
            throw UploadError.unresolved
        }
    }

    func createUpload(path: String) throws -> RemoteFileIdentity {
        try protectAncestors(of: path)
        guard handles[path] == nil else { throw UploadError.unresolved }
        let handle = Handle(), full = try remotePath(path)
        do { try handle.use { try check(tm_edit_create(client, full, Self.read | Self.write, $0)) } }
        catch where Self.serverStatus(error) != nil {
            let refused = error
            var absent = false
            do { absent = try renameSourceEntry(path: path) == nil } catch {}
            if absent { throw UploadCreateRefusal(refused) }
            throw refused
        }
        handles[path] = handle
        let values = try info(handle)
        guard values[2] == 0, values[3] == 1, values[4] & 0x450 == 0 else { throw UploadError.unresolved }
        return try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])
    }

    func writeUpload(path: String, contents: URL, modified: Date?) throws -> RemoteFileVersion {
        guard let handle = handles[path] else { throw UploadError.unresolved }
        try writeContents(handle, contents: contents)
        keepSaveTime(handle, modified)
        let written = try version(handle)
        return try closeWritten(path: path, version: written)
    }

    func inspectUpload(path: String) throws -> RemoteFileVersion {
        try protectAncestors(of: path)
        return try readVersion(path: path)
    }

    func resumeUpload(path: String, contents: URL, identity: RemoteFileIdentity,
                      modified: Date?) throws -> RemoteFileVersion {
        guard handles[path] == nil, let entry = try renameSourceEntry(path: path),
              entry.identity == identity, entry.name.utf8.elementsEqual(RelativePath(path)!.components.last!.utf8)
        else { throw UploadError.unresolved }
        let handle = try open(path: path, access: Self.read | Self.write, sharing: 0)
        handles[path] = handle
        guard try version(handle).identity == identity else { throw UploadError.unresolved }
        try writeContents(handle, contents: contents)
        keepSaveTime(handle, modified)
        return try closeWritten(path: path, version: version(handle))
    }

    func discardUpload(path: String, identity: RemoteFileIdentity?) throws {
        guard handles[path] == nil else { throw UploadError.unresolved }
        let found: RenameDirectoryEntry?
        do { found = try renameSourceEntry(path: path) } catch {
            let status = Self.serverStatus(error).flatMap(DeletionStatus.init(rawValue:))
            // A folder above the file is gone from this path.
            guard status == .nameNotFound || status == .pathNotFound else { throw error }
            return
        }
        guard let entry = found else { return }
        guard let identity else { throw UploadError.collision }
        guard entry.identity == identity else { return }
        let handle = try open(path: (RelativePath(path)!.components.dropLast() + [entry.name]).joined(separator: "/"),
                              access: Self.read | Self.delete, sharing: 0)
        handles[path] = handle
        let values = try info(handle)
        guard values[0] == identity.fileID, values[1] == identity.birthMicroseconds else {
            throw UploadError.unresolved
        }
        try handle.use { try check(tm_edit_delete(client, $0)) }
        try handle.use { try check(tm_edit_close(client, $0)) }
        handles[path] = nil
    }

    private func closeWritten(path: String, version: RemoteFileVersion) throws -> RemoteFileVersion {
        guard let handle = handles[path] else { throw UploadError.unresolved }
        var values = [UInt64](repeating: 0, count: 5)
        try handle.use { try check(tm_edit_close_info(client, $0, &values)) }
        handles[path] = nil
        guard values[3] == UInt64(version.size) else { throw UploadError.unresolved }
        return try RemoteFileVersion(identity: version.identity, size: version.size,
            modifiedMicroseconds: values[1], changedMicroseconds: values[2], attributes: UInt32(values[4]))
    }

    func overwrite(path: String, contents: URL, expected: ContentFingerprint? = nil, modified: Date?) throws
        -> (fileID: UInt64, fingerprint: ContentFingerprint) {
        let input = try ReadOnlyFile(url: contents)
        let fork = fgetxattr(input.descriptor, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard fork <= 0 else { throw CocoaError(.featureUnsupported) }
        guard fork == 0 || errno == ENOATTR else { throw posixError("inspect upload metadata") }
        try cancellation()
        try protectAncestors(of: path)
        let handle = try open(path: path, access: 0x80 | Self.write, sharing: 1)
        handles[path] = handle
        let before = try info(handle)
        guard before[2] <= Int64.max, before[3] == 1, before[4] & 0x450 == 0 else {
            throw UploadError.unresolved
        }
        let current = try ContentFingerprint(smbSize: Int64(before[2]), modifiedMicroseconds: before[5],
                                              changedMicroseconds: before[6])
        guard expected == nil || expected == current else { throw UploadError.editConflict }
        progress.totalUnitCount = max(1, input.snapshot.size)
        try writeContents(handle, contents: contents)
        keepSaveTime(handle, modified)
        var closed = [UInt64](repeating: 0, count: 5)
        try handle.use { try check(tm_edit_close_info(client, $0, &closed)) }
        handles[path] = nil
        guard closed[3] == UInt64(input.snapshot.size) else { throw UploadError.unresolved }
        let fingerprint = try ContentFingerprint(smbSize: input.snapshot.size, modifiedMicroseconds: closed[1],
                                                 changedMicroseconds: closed[2])
        progress.completedUnitCount = progress.totalUnitCount
        return (before[0], fingerprint)
    }

    private func writeContents(_ handle: Handle, contents: URL) throws {
        let input = try ReadOnlyFile(url: contents)
        let capacity = min(input.snapshot.size, Int64(TM_SMB_IO_BATCH_SIZE))
        var buffer = [UInt8](repeating: 0, count: Int(capacity))
        var offset: Int64 = 0
        while offset < input.snapshot.size {
            try cancellation()
            let count = pread(input.descriptor, &buffer, min(buffer.count, Int(input.snapshot.size - offset)), offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError("read pending edit") }
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < count {
                    try cancellation()
                    var length: UInt32 = 0
                    try handle.use {
                        try check(tm_edit_write(client, $0, UInt64(offset) + UInt64(written),
                            bytes.baseAddress!.advanced(by: written).assumingMemoryBound(to: UInt8.self),
                            UInt32(count - written), &length))
                    }
                    guard length > 0, length <= count - written else { throw UploadError.unresolved }
                    written += Int(length)
                    progress.completedUnitCount += Int64(length)
                }
            }
            offset += Int64(count)
        }
        try input.validateUnchanged()
        try handle.use { try check(tm_edit_set_size(client, $0, UInt64(input.snapshot.size))) }
        try handle.use { try check(tm_edit_flush(client, $0)) }
    }

    /// The server keeps the local save time, as when Finder copies to SMB. The bytes are written
    /// already, so a refusal keeps the server's time; a lost connection fails the close that follows.
    private func keepSaveTime(_ handle: Handle, _ modified: Date?) {
        guard let modified, let microseconds = ContentFingerprint.smbMicroseconds(modified) else { return }
        let code = handle.use { tm_edit_set_write_time(client, $0, microseconds) }
        guard code != 0 else { return }
        let status = tm_edit_last_ntstatus(client)
        Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
            .error("save_time failed errno=\(code) status=\(status)")
    }

    func move(source: String, destination: String) throws {
        guard let handle = handles[source] else { throw UploadError.unresolved }
        let target = try remotePath(destination)
        try cancellation()
        try handle.use { try check(tm_edit_rename(client, $0, target)) }
        handles[source] = nil
        handles[destination] = handle
    }

    private func version(_ handle: Handle) throws -> RemoteFileVersion {
        let values = try info(handle)
        guard values[2] <= Int64.max, values[3] == 1, values[4] & 0x410 == 0 else {
            throw UploadError.unresolved
        }
        return try RemoteFileVersion(identity: RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1]),
                                   size: Int64(values[2]), modifiedMicroseconds: values[5],
                                   changedMicroseconds: values[6], attributes: UInt32(values[4]))
    }

    private func info(_ handle: Handle) throws -> [UInt64] {
        var values = [UInt64](repeating: 0, count: 8)
        try handle.use { try check(tm_edit_info(client, $0, &values)) }
        return values
    }

    private func open(path: String, access: UInt32, sharing: UInt32) throws -> Handle {
        let handle = Handle(), full = try remotePath(path)
        try handle.use { try check(tm_edit_open(client, full, access, sharing, $0)) }
        return handle
    }

    private func remotePath(_ path: String) throws -> String {
        guard let relative = RelativePath(path), !relative.isRoot, let full = folder.appending(relative) else {
            throw UploadError.invalidRequest
        }
        return full.string
    }

    private func cancellation() throws {
        if progress.isCancelled { throw TransferError.cancelled }
    }

    private func check(_ code: Int32) throws {
        if code == EEXIST { throw UploadError.collision }
        guard code != 0 else { return }
        let status = tm_edit_last_ntstatus(client)
        let error = posixError("protected save", code: code)
        var details = error.userInfo
        if status != 0 { details[Self.statusKey] = status }
        throw NSError(domain: error.domain, code: error.code, userInfo: details)
    }

    static func serverStatus(_ error: Error) -> UInt32? {
        let error = error as NSError
        guard error.domain == NSPOSIXErrorDomain else { return nil }
        return error.userInfo[statusKey] as? UInt32
    }

}

private final class SessionFolderReceipt {
    let persist: (RemoteFolderIdentity) throws -> Void
    var nativeID: UInt64?
    var error: Error?

    init(persist: @escaping (RemoteFolderIdentity) throws -> Void) { self.persist = persist }
}

private func receiveSessionFolder(_ context: UnsafeMutableRawPointer?, _ fileID: UInt64, _ birth: UInt64) -> Int32 {
    guard let context else { return EINVAL }
    let receipt = Unmanaged<SessionFolderReceipt>.fromOpaque(context).takeUnretainedValue()
    do {
        try receipt.persist(RemoteFolderIdentity(fileID: fileID, birthMicroseconds: birth))
        receipt.nativeID = fileID
        return 0
    } catch {
        receipt.error = error
        return EIO
    }
}

/// M18 folder creation and initial naming on this session's connection.
extension SMBEdit {
    private static let folderLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    func createFolder(_ path: RelativePath, expected: RemoteFolderIdentity?,
                      receipt: (RemoteFolderIdentity) throws -> Void) throws -> UInt64 {
        let full = try remotePath(path.string)
        return try withFolderReceipt(receipt) { context in
            var sent: Int32 = 0
            var trace = tm_smb_folder_trace()
            let code = tm_edit_create_folder(client, full, expected?.fileID ?? 0, expected?.birthMicroseconds ?? 0,
                                             receiveSessionFolder, context, &sent, &trace)
            let stage = String(cString: tm_smb_folder_stage_name(trace.stage))
            Self.folderLog.notice("""
                session_folder_create stage=\(stage, privacy: .public) parents=\(trace.parents) \
                status=\(String(format: "0x%08x", trace.status), privacy: .public) errno=\(trace.error) \
                sent=\(trace.sent_queued)>\(trace.sent)
                """)
            guard code == 0 else { throw FolderMutationFailure(code: code, mayHaveChanged: sent != 0) }
        }
    }

    func nameFolder(from source: RelativePath, to destination: RelativePath, expected: RemoteFolderIdentity,
                    recoveryOnly: Bool) throws -> UInt64 {
        let from = try remotePath(source.string), to = try remotePath(destination.string)
        return try withFolderReceipt({ _ in }) { context in
            var sent: Int32 = 0
            let code = tm_edit_name_folder(client, from, to, expected.fileID, expected.birthMicroseconds,
                                           recoveryOnly ? 1 : 0, receiveSessionFolder, context, &sent)
            guard code == 0 else { throw FolderMutationFailure(code: code, mayHaveChanged: sent != 0) }
        }
    }

    private func withFolderReceipt(_ persist: (RemoteFolderIdentity) throws -> Void,
                                   operation: (UnsafeMutableRawPointer) throws -> Void) throws -> UInt64 {
        try withoutActuallyEscaping(persist) { persist in
            let receipt = SessionFolderReceipt(persist: persist)
            do { try withExtendedLifetime(receipt) { try operation(Unmanaged.passUnretained(receipt).toOpaque()) } }
            catch { throw receipt.error ?? error }
            guard let nativeID = receipt.nativeID else { throw UploadError.unresolved }
            return nativeID
        }
    }
}

extension SMBEdit: RemoteSession {}

extension SMBEdit: FolderMoveRemote {
    private struct FolderMoveCurrent {
        let identity: RemoteFileIdentity
        let version: RemoteFileVersion?
        let nativeID: UInt64
        let fingerprint: ContentFingerprint
    }

    func protectFolderMoveParents(source: String, destination: String) throws -> [FileRenameParent] {
        guard folder.isRoot, handles.isEmpty, deletionTarget == nil else {
            throw UploadError.invalidRequest
        }
        try requireSameShare()
        let parents = try protectRenameParents(source: source, destination: destination)
        for parent in parents {
            guard SMBName.matchesStored(parent.name, requested: RelativePath(parent.path)!.components.last ?? "") else {
                throw UploadError.unresolved
            }
        }
        folderMoveParents = Set(parents.map(\.path))
        if folderMoveParentBindings == nil { folderMoveParentBindings = parents }
        return parents
    }

    func inspectFolderMoveRoot(path: String) throws -> FolderMoveEvidence? {
        let relative = try folderMovePath(path)
        let parent = relative.components.dropLast().joined(separator: "/")
        guard folderMoveParents.contains(parent) else { throw UploadError.unresolved }
        guard let entry = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(relative.components.last!) })
        else { return nil }
        guard entry.kind == .folder else { throw UploadError.collision }
        if folderMoveRoots[path] == nil {
            if let held = try folderMoveRoots.values.first(where: { try folderMoveIdentity(info($0)) == entry.identity }) {
                folderMoveRoots[path] = held
            } else {
                let handle = Handle()
                let stored = relative.components.dropLast() + [entry.name]
                try handle.use {
                    try check(tm_edit_open_directory(client, stored.joined(separator: "/"), 0x81 | Self.delete, 3, $0))
                }
                folderMoveRoots[path] = handle
            }
        }
        let values = try info(folderMoveRoots[path]!)
        guard values[4] & 0x450 == 0x10, try folderMoveIdentity(values) == entry.identity,
              let confirmed = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(entry.name) }),
              confirmed.identity == entry.identity, confirmed.name.utf8.elementsEqual(entry.name.utf8) else {
            throw UploadError.unresolved
        }
        return FolderMoveEvidence(identity: entry.identity, name: entry.name)
    }

    func releaseFolderMoveRoot(path: String) throws {
        guard let handle = folderMoveRoots[path] else { return }
        if folderMoveRoots.contains(where: { $0.key != path && $0.value === handle }) {
            folderMoveRoots[path] = nil
            return
        }
        try handle.use { try check(tm_edit_close(client, $0)) }
        folderMoveRoots[path] = nil
    }

    func captureFolderMoveProofs(move: CatalogFolderMove, folder: RelativePath) throws -> [CatalogFolderMoveProof] {
        guard !move.entries.isEmpty, move.entries.count <= DirectoryListing.defaultLimit,
              Set(move.entries.map(\.item)).count == move.entries.count,
              move.entries.allSatisfy({ RelativePath($0.path).map { !$0.isRoot } == true }),
              let rootEntry = move.entries.first(where: { $0.item == move.item }), rootEntry.kind == .folder,
              let rootRelative = RelativePath(rootEntry.path), let rootPath = folder.appending(rootRelative),
              let root = try inspectFolderMoveRoot(path: rootPath.string),
              SMBName.matchesStored(root.name, requested: rootEntry.name) else { throw SourceFailure.versionChanged }
        var proofs: [String: CatalogFolderMoveProof] = [:]
        for entry in folderMoveOrdered(move.entries) {
            guard let path = folder.appending(RelativePath(entry.path)!),
                  let current = try folderMoveCurrent(path: path, kind: entry.kind, expected: nil),
                  current.nativeID == entry.nativeID, current.fingerprint.size == entry.size,
                  current.fingerprint.mtimeNs == entry.mtimeNs, current.fingerprint.ctimeNs == entry.ctimeNs else {
                throw SourceFailure.versionChanged
            }
            if let version = current.version {
                proofs[entry.item] = .file(try FileRevision(item: entry.item, version: version))
            } else {
                proofs[entry.item] = .directory(item: entry.item, identity: current.identity)
            }
        }
        return try move.entries.map {
            guard let proof = proofs[$0.item] else { throw UploadError.unresolved }
            return proof
        }
    }

    func verifyFolderMoveSource(_ record: PendingFolderMove) throws {
        var remaining = DirectoryListing.defaultLimit
        for view in record.views {
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            for entry in folderMoveOrdered(view.move.entries) {
                guard let path = RelativePath(view.folder)?.appending(RelativePath(entry.path)!),
                      let proof = proofs[entry.item],
                      let current = try folderMoveCurrent(path: path, kind: entry.kind, expected: proof.identity) else {
                    throw SourceFailure.versionChanged
                }
                if case .file(let receipt) = proof {
                    guard let version = current.version, version.hasSameDataVersion(as: receipt.version),
                          version.modifiedMicroseconds == receipt.version.modifiedMicroseconds else {
                        throw SourceFailure.versionChanged
                    }
                } else {
                    let children = try folderMoveListing(path.string)
                    guard children.count <= remaining else { throw SourceFailure.tooManyEntries }
                    remaining -= children.count
                }
            }
        }
    }

    func releaseFolderMoveDescendants() throws {
        for path in folderMoveFiles.keys.sorted() {
            try folderMoveFiles[path]!.use { try check(tm_edit_close(client, $0)) }
            folderMoveFiles[path] = nil
        }
        for path in directories.keys.filter({ !folderMoveParents.contains($0) }).sorted(by: { $0.count > $1.count }) {
            try directories[path]!.use { try check(tm_edit_close(client, $0)) }
            directories[path] = nil
        }
    }

    func moveFolder(source: String, destination: String) throws {
        guard let handle = folderMoveRoots[source], folderMoveFiles.isEmpty,
              Set(directories.keys) == folderMoveParents else { throw UploadError.unresolved }
        _ = try folderMovePath(destination)
        try cancellation()
        folderMoveAttempted = true
        try handle.use { try check(tm_edit_rename(client, $0, destination)) }
        folderMoveRoots = folderMoveRoots.filter { $0.value !== handle }
        folderMoveRoots[destination] = handle
    }

    func folderMoveParentsAfterRename(_ parents: [FileRenameParent]) throws -> [FileRenameParent] {
        guard folderMoveParentBindings == parents, Set(parents.map(\.path)) == folderMoveParents else {
            throw UploadError.unresolved
        }
        // A directory read can change Samba's synthetic creation time; checkpoint after it.
        for parent in parents {
            guard let handle = directories[parent.path] else { throw UploadError.unresolved }
            var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
            try cancellation()
            try handle.use {
                try check(tm_edit_list(client, $0, 1, &buffer, UInt32(buffer.count), &count, &finished))
            }
        }
        return try parents.map { parent in
            guard let handle = directories[parent.path] else { throw UploadError.unresolved }
            let values = try info(handle)
            let identity = try folderMoveIdentity(values)
            guard values[4] & 0x450 == 0x10, identity.fileID == parent.identity.fileID,
                  folderMoveAttempted || identity == parent.identity else { throw UploadError.unresolved }
            return FileRenameParent(path: parent.path, name: parent.name, identity: identity)
        }
    }

    func settleFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveSettlement] {
        let states = try Dictionary(uniqueKeysWithValues: record.views.map {
            ($0.domain, try CatalogFolderMoveState.admission($0.move, proofs: $0.proofs))
        })
        return try observeFolderMove(record, states: states).map { refresh in
            let view = record.views.first { $0.domain == refresh.domain }!
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            let resolutions = try refresh.observations.map { observed -> CatalogFolderMoveResolution in
                switch observed {
                case .removed(let item): return .removed(item: item)
                case .directory(let after, _): return .preserved(after)
                case .file(let after, let version):
                    guard let proof = proofs[after.item], case .file(let before) = proof else {
                        throw UploadError.unresolved
                    }
                    if version.hasSameDataVersion(as: before.version)
                        && version.modifiedMicroseconds == before.version.modifiedMicroseconds { return .preserved(after) }
                    return .changed(after, receipt: try FileRevision(item: after.item, version: version))
                }
            }
            return FolderMoveSettlement(domain: view.domain, settlement: CatalogFolderMoveSettlement(
                proofs: view.proofs, resolutions: resolutions, listings: refresh.listings))
        }
    }

    func verifyFolderMoveSettlement(_ record: PendingFolderMove) throws {
        guard record.recovery == nil else { throw UploadError.unresolved }
        try verifyFolderMoveTarget(record)
    }

    func refreshFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveRefresh] {
        let states = try Dictionary(uniqueKeysWithValues: record.views.map {
            ($0.domain, try record.latestTarget(domain: $0.domain))
        })
        return try observeFolderMove(record, states: states)
    }

    func verifyFolderMoveRecovery(_ record: PendingFolderMove) throws {
        guard record.recovery != nil else { throw UploadError.unresolved }
        try verifyFolderMoveTarget(record)
    }

    private func verifyFolderMoveTarget(_ record: PendingFolderMove) throws {
        let refreshed = try refreshFolderMove(record)
        for refresh in refreshed {
            let state = try record.latestTarget(domain: refresh.domain)
            let entries = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.item, $0) })
            for observed in refresh.observations {
                let expected = entries[observed.item]!
                if expected.retired {
                    guard case .removed = observed else { throw UploadError.unresolved }
                    continue
                }
                let after: CatalogFolderMoveObservation
                switch observed {
                case .removed: throw SourceFailure.versionChanged
                case .directory(let value, let identity):
                    guard identity == expected.proof.identity else { throw SourceFailure.versionChanged }
                    after = value
                case .file(let value, let version):
                    guard case .file(let receipt) = expected.proof,
                          version.hasSameDataVersion(as: receipt.version),
                          version.modifiedMicroseconds == receipt.version.modifiedMicroseconds else {
                        throw SourceFailure.versionChanged
                    }
                    after = value
                }
                guard after.nativeID == expected.nativeID, after.size == expected.size,
                      after.mtimeNs == expected.mtimeNs, after.ctimeNs == expected.ctimeNs else {
                    throw SourceFailure.versionChanged
                }
            }
        }
    }

    private func observeFolderMove(_ record: PendingFolderMove, states: [String: CatalogFolderMoveState]) throws
        -> [FolderMoveRefresh] {
        var physical: [String: FolderMoveCurrent] = [:], absent: Set<String> = []
        var complete: [String: [RenameDirectoryEntry]] = [:]
        return try record.views.map { view in
            guard let state = states[view.domain] else { throw UploadError.unresolved }
            let expected = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.item, $0) })
            var observations: [String: FolderMoveObservation] = [:], listings: [CatalogFolderMoveListing] = []
            for entry in folderMoveOrdered(view.move.entries) {
                guard let before = expected[entry.item], let relative = view.destinationPath(for: entry),
                      let path = RelativePath(view.folder)?.appending(relative) else { throw UploadError.unresolved }
                if before.retired || absent.contains(path.string)
                    || observations[entry.parent].map({ if case .removed = $0 { true } else { false } }) == true {
                    observations[entry.item] = .removed(item: entry.item)
                    absent.insert(path.string)
                    continue
                }
                if physical[path.string] == nil {
                    physical[path.string] = try folderMoveCurrent(path: path, kind: entry.kind,
                        expected: before.proof.identity, moveRoot: entry.item == view.move.item)
                }
                guard let current = physical[path.string] else {
                    observations[entry.item] = .removed(item: entry.item)
                    absent.insert(path.string)
                    continue
                }
                guard current.identity == before.proof.identity else { throw UploadError.unresolved }
                let preserved: Bool
                if let version = current.version, case .file(let receipt) = before.proof {
                    preserved = version.hasSameDataVersion(as: receipt.version)
                } else { preserved = false }
                let after = CatalogFolderMoveObservation(item: entry.item, path: relative, kind: entry.kind,
                    nativeID: current.nativeID, fingerprint: current.fingerprint,
                    preservesIdentity: true, preservesContents: preserved)
                if let version = current.version { observations[entry.item] = .file(after, version: version) }
                else {
                    observations[entry.item] = .directory(after, identity: current.identity)
                    if complete[path.string] == nil { complete[path.string] = try folderMoveListing(path.string) }
                    listings.append(CatalogFolderMoveListing(parent: entry.item, path: relative, identity: current.identity,
                        complete: true, children: complete[path.string]!.map {
                            CatalogFolderMoveListing.Child(name: $0.name, identity: $0.identity, kind: $0.kind)
                        }))
                }
            }
            if case .removed? = observations[view.move.item], expected[view.move.item]?.retired == false {
                guard [.moved, .verified, .recovering].contains(record.state),
                      let relative = RelativePath(view.move.destinationParentPath),
                      let parent = RelativePath(view.folder)?.appending(relative),
                      folderMoveParents.contains(parent.string), let handle = directories[parent.string] else {
                    throw UploadError.unresolved
                }
                if complete[parent.string] == nil { complete[parent.string] = try folderMoveListing(parent.string) }
                listings.append(CatalogFolderMoveListing(parent: view.move.destinationParent, path: relative,
                    identity: try folderMoveIdentity(info(handle)), complete: true, children: complete[parent.string]!.map {
                        CatalogFolderMoveListing.Child(name: $0.name, identity: $0.identity, kind: $0.kind)
                    }))
            }
            return FolderMoveRefresh(domain: view.domain, observations: try view.move.entries.map {
                guard let value = observations[$0.item] else { throw UploadError.unresolved }
                return value
            }, listings: listings)
        }
    }

    private func folderMoveCurrent(path: RelativePath, kind: CatalogRow.Kind,
                                   expected: RemoteFileIdentity?, moveRoot: Bool = false) throws -> FolderMoveCurrent? {
        let parent = path.components.dropLast().joined(separator: "/"), name = path.components.last!
        guard let entry = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(name) }),
              expected == nil || (entry.identity == expected && SMBName.matchesStored(entry.name, requested: name)) else {
            return nil
        }
        guard entry.kind == kind, SMBName.matchesStored(entry.name, requested: name) else { throw UploadError.unresolved }
        // Open the root with delete access before a read handle can deny that access.
        if moveRoot { _ = try inspectFolderMoveRoot(path: path.string) }
        let handle: Handle
        if kind == .folder {
            if let held = folderMoveRoots[path.string] ?? directories[path.string] { handle = held }
            else {
                handle = Handle()
                try handle.use { try check(tm_edit_open_directory(client, path.string, 0x81, 3, $0)) }
                directories[path.string] = handle
            }
        } else {
            if let held = folderMoveFiles[path.string] { handle = held }
            else {
                handle = try open(path: path.string, access: Self.read, sharing: 1)
                folderMoveFiles[path.string] = handle
            }
        }
        let version = kind == .file ? try version(handle) : nil
        let values = try info(handle)
        if let version, version.modifiedMicroseconds != values[5] {
            throw SourceFailure.versionChanged
        }
        guard try folderMoveIdentity(values) == entry.identity,
              values[4] & 0x450 == (kind == .folder ? 0x10 : 0),
              let confirmed = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(name) }),
              confirmed.identity == entry.identity, SMBName.matchesStored(confirmed.name, requested: name) else {
            throw UploadError.unresolved
        }
        let native = try folderMoveFingerprint(kind: kind, values: values)
        let after = try info(handle)
        guard after[0...2] == values[0...2], after[4...6] == values[4...6] else { throw SourceFailure.versionChanged }
        return FolderMoveCurrent(identity: entry.identity, version: version,
                                 nativeID: native.0, fingerprint: native.1)
    }

    private func folderMoveListing(_ path: String) throws -> [RenameDirectoryEntry] {
        guard let handle = folderMoveRoots[path] ?? directories[path] else { throw UploadError.unresolved }
        var entries: [RenameDirectoryEntry] = [], pages = 0, restart = true
        while true {
            try cancellation()
            var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
            try handle.use {
                try check(tm_edit_list(client, $0, restart ? 1 : 0, &buffer, UInt32(buffer.count), &count, &finished))
            }
            if finished != 0 {
                guard entries.allSatisfy({ RelativePath.isValidComponent($0.name) }),
                      Set(entries.map { NameKey($0.name) }).count == entries.count else { throw UploadError.unresolved }
                return entries
            }
            pages += 1
            let page = try RenameDirectoryEntry.parse(Array(buffer.prefix(Int(count))))
            guard page.count <= DirectoryListing.defaultLimit - entries.count,
                  pages <= DirectoryListing.defaultLimit else { throw SourceFailure.tooManyEntries }
            entries += page
            progress.completedUnitCount += 1
            restart = false
        }
    }

    private func folderMoveFingerprint(kind: CatalogRow.Kind, values: [UInt64]) throws
        -> (UInt64, ContentFingerprint) {
        try requireSameShare()
        guard values[2] <= Int64.max, values[4] & 0x450 == (kind == .folder ? 0x10 : 0) else {
            throw UploadError.unresolved
        }
        return try (values[0], ContentFingerprint(smbSize: kind == .folder ? 0 : Int64(values[2]),
                                                  modifiedMicroseconds: values[5], changedMicroseconds: values[6]))
    }

    /// The session's own connection to the share is the proof that it is still the same share.
    private func requireSameShare() throws {
        guard folder.isRoot else { throw UploadError.invalidRequest }
    }

    private func folderMovePath(_ path: String) throws -> RelativePath {
        guard folder.isRoot, let path = RelativePath(path), !path.isRoot, !folderMoveParents.isEmpty else {
            throw UploadError.invalidRequest
        }
        return path
    }

    private func folderMoveIdentity(_ values: [UInt64]) throws -> RemoteFileIdentity {
        try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])
    }

    private func folderMoveOrdered(_ entries: [CatalogFolderMoveEntry]) -> [CatalogFolderMoveEntry] {
        entries.sorted {
            let left = RelativePath($0.path)!.components.count, right = RelativePath($1.path)!.components.count
            return left == right ? $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) : left < right
        }
    }
}

extension SMBEdit: DeletionRemote {
    private enum DeletionStatus: UInt32 {
        case accessDenied = 0xc0000022, nameNotFound = 0xc0000034, pathNotFound = 0xc000003a
        case sharingViolation = 0xc0000043, deletePending = 0xc0000056
        case directoryNotEmpty = 0xc0000101, cannotDelete = 0xc0000121
    }

    func protectParents(of path: String) throws -> [ItemDeletionParent] {
        guard folder.isRoot, handles.isEmpty,
              deletionTarget == nil, deletionTraversalFiles == nil else {
            throw ItemDeletionError.invalidRequest
        }
        let parents: [FileRenameParent]
        do { parents = try protectRenameParents(source: path, destination: path) } catch {
            switch Self.serverStatus(error).flatMap(DeletionStatus.init(rawValue:)) {
            case .nameNotFound, .pathNotFound: throw ItemDeletionError.parentChanged
            default: throw error
            }
        }
        deletionTarget = path
        let protected = parents.map { ItemDeletionParent(path: $0.path, name: $0.name, identity: $0.identity) }
        deletionParents = protected
        return protected
    }

    func parentsAfterDeletion(_ parents: [ItemDeletionParent]) throws -> [ItemDeletionParent] {
        guard deletionParents == parents, deletionTarget != nil, handles.isEmpty else {
            throw ItemDeletionError.invalidRequest
        }
        // Directory reads can change Samba's synthetic creation time while these handles stay held.
        for parent in parents {
            guard let handle = directories[parent.path] else { throw ItemDeletionError.unresolved }
            var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
            try cancellation()
            try handle.use {
                try check(tm_edit_list(client, $0, 1, &buffer, UInt32(buffer.count), &count, &finished))
            }
        }
        return try parents.map { parent in
            guard let handle = directories[parent.path] else { throw ItemDeletionError.unresolved }
            let values = try info(handle), identity = try folderMoveIdentity(values)
            guard values[4] & 0x450 == 0x10, identity.fileID == parent.identity.fileID else {
                throw ItemDeletionError.unresolved
            }
            return ItemDeletionParent(path: parent.path, name: parent.name, identity: identity)
        }
    }

    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
        guard path == deletionTarget, kind == .file || kind == .folder else {
            throw ItemDeletionError.invalidRequest
        }
        if handles[path] == nil {
            let handle = Handle()
            do {
                try handle.use { file in
                    let code = kind == .file
                        ? tm_edit_open(client, path, Self.read | Self.delete, 0, file)
                        : tm_edit_open_directory(client, path, Self.read | Self.delete, 0, file)
                    try check(code)
                }
            } catch {
                switch Self.serverStatus(error).flatMap(DeletionStatus.init(rawValue:)) {
                case .nameNotFound: return .nameNotFound
                case .pathNotFound: return .pathNotFound
                case .deletePending: return .deletePending
                default: throw Self.deletionFailure(error)
                }
            }
            handles[path] = handle
        }
        guard let handle = handles[path] else { throw ItemDeletionError.unresolved }
        if kind == .file { return .present(.file(try version(handle))) }
        let values = try info(handle)
        guard values[4] & 0x410 == 0x10 else { throw ItemDeletionError.unsupported }
        return .present(.directory(try RemoteFileIdentity(fileID: values[0], birthMicroseconds: values[1])))
    }

    func list(path: String) throws -> ItemDeletionListing {
        guard deletionTarget != nil, let handle = directories[path] ?? handles[path] else {
            throw ItemDeletionError.invalidRequest
        }
        var entries: [ItemDeletionEntry] = [], pages = 0, restart = true
        while true {
            try cancellation()
            var buffer = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0, finished: Int32 = 0
            try handle.use {
                try check(tm_edit_list(client, $0, restart ? 1 : 0, &buffer, UInt32(buffer.count), &count, &finished))
            }
            if finished != 0 { return ItemDeletionListing(entries: entries, isComplete: true) }
            pages += 1
            let page = try RenameDirectoryEntry.parse(Array(buffer.prefix(Int(count))))
            guard page.count <= DirectoryListing.defaultLimit - entries.count,
                  pages <= DirectoryListing.defaultLimit else { throw SourceFailure.tooManyEntries }
            entries += page.map { ItemDeletionEntry(name: $0.name, identity: $0.identity) }
            progress.completedUnitCount += 1
            restart = false
        }
    }

    func markDeletion(path: String) throws {
        guard path == deletionTarget, let handle = handles[path] else { throw ItemDeletionError.invalidRequest }
        try cancellation()
        do { try handle.use { try check(tm_edit_delete(client, $0)) } }
        catch { throw Self.deletionFailure(error) }
    }

    func closeTarget(path: String) throws {
        guard path == deletionTarget, handles.count == 1, let handle = handles[path],
              directories[path] == nil else { throw ItemDeletionError.invalidRequest }
        do { try handle.use { try check(tm_edit_close(client, $0)) } }
        catch { throw Self.deletionFailure(error) }
        handles[path] = nil
    }

    private static func deletionFailure(_ error: Error) -> Error {
        switch serverStatus(error).flatMap(DeletionStatus.init(rawValue:)) {
        case .deletePending: return ItemDeletionError.deletePending
        case .sharingViolation: return ItemDeletionError.sharingViolation
        case .directoryNotEmpty: return ItemDeletionError.directoryNotEmpty
        case .accessDenied: return ItemDeletionError.accessDenied
        case .cannotDelete: return ItemDeletionError.cannotDelete
        default: return error
        }
    }
}

/// M24 admission. A fresh session captures the tree; separate fresh sessions delete its nodes.
extension SMBEdit {
    /// Holds the parent chain, every directory and every file until releaseDeletionTraversal.
    /// Expectations must cover the selected path and lie at or below it.
    func captureDeletionTraversal(of selected: RelativePath, recursive: Bool,
                                  expecting expectations: [DeletionExpectation]) throws -> DeletionTraversal {
        let below = Array((selected.string + "/").utf8)
        var expected: [Data: [DeletionExpectation]] = [:]
        for expectation in expectations {
            guard expectation.path.string.utf8.elementsEqual(selected.string.utf8)
                    || expectation.path.string.utf8.starts(with: below) else { throw ItemDeletionError.invalidRequest }
            expected[SMBName.key(expectation.path.string), default: []].append(expectation)
        }
        guard folder.isRoot, deletionTraversalFiles == nil, deletionTarget == nil, handles.isEmpty,
              directories.isEmpty,
              folderMoveParents.isEmpty, folderMoveRoots.isEmpty, folderMoveFiles.isEmpty, !selected.isRoot,
              expected[SMBName.key(selected.string)] != nil else { throw ItemDeletionError.invalidRequest }
        deletionTraversalFiles = [:]
        guard expected.count <= DeletionPlan.maxNodes else { throw SourceFailure.tooManyEntries }
        let name = selected.components.last!
        guard selected.components.allSatisfy(FileRenameRequest.supportsName), !Self.isPackage(name) else {
            throw ItemDeletionError.unsupported
        }
        try requireSameShare()
        let chain: [FileRenameParent]
        do { chain = try protectRenameParents(source: selected.string, destination: selected.string) }
        catch { throw Self.traversalFailure(error) }
        guard chain.count == selected.components.count,
              zip(chain, [""] + selected.components.dropLast()).allSatisfy({ SMBName.same($0.name, $1) }) else {
            throw SourceFailure.versionChanged
        }
        let parent = chain.last!.path
        func selectedEntry() throws -> RenameDirectoryEntry {
            let entry: RenameDirectoryEntry?
            do { entry = try renameEntry(parent: parent, name: name) }
            catch UploadError.collision { throw ItemDeletionError.unsupported }
            guard let entry, SMBName.same(entry.name, name) else { throw SourceFailure.versionChanged }
            return entry
        }
        let root = try selectedEntry()

        // Structure first, so every limit and unsupported entry refuses before any contents are read.
        var objects: [DeletionTraversal.Object] = [], listings: [DeletionTraversal.Listing] = []
        var captured: [(String, [RenameDirectoryEntry])] = [], files: [(RelativePath, RenameDirectoryEntry)] = []
        var kinds: [Data: CatalogRow.Kind] = [:], pending = [(selected, root)], total = 1
        var seen = Set(chain.map { [$0.identity.fileID, $0.identity.birthMicroseconds] })
        while let next = pending.popLast() {
            try cancellation()
            let (path, entry) = next
            guard let kind = entry.kind,
                  seen.insert([entry.identity.fileID, entry.identity.birthMicroseconds]).inserted else {
                throw ItemDeletionError.unsupported
            }
            kinds[SMBName.key(path.string)] = kind
            guard kind == .folder else {
                files.append((path, entry))
                continue
            }
            let handle = Handle()
            do { try handle.use { try check(tm_edit_open_directory(client, path.string, 0x81, 3, $0)) } }
            catch { throw Self.traversalFailure(error) }
            directories[path.string] = handle
            let values = try info(handle)
            guard try folderMoveIdentity(values) == entry.identity else { throw SourceFailure.versionChanged }
            guard values[4] & 0x450 == 0x10 else { throw UploadError.unresolved }
            try requireDeletionExpectations(expected[SMBName.key(path.string)] ?? [], path: path, kind: kind,
                                            values: values)
            let children = try folderMoveListing(path.string)
            if !recursive, path.string.utf8.elementsEqual(selected.string.utf8), !children.isEmpty {
                throw ItemDeletionError.directoryNotEmpty
            }
            total += children.count
            guard total <= DeletionPlan.maxNodes else { throw SourceFailure.tooManyEntries }
            for child in children {
                // Unsupported entries stay in the tree, so they refuse the whole request.
                guard FileRenameRequest.supportsName(child.name), !Self.isPackage(child.name),
                      let childPath = path.appending(child.name) else { throw ItemDeletionError.unsupported }
                pending.append((childPath, child))
            }
            captured.append((path.string, children))
            listings.append(DeletionTraversal.Listing(path: path, listing: ItemDeletionListing(
                entries: children.map { ItemDeletionEntry(name: $0.name, identity: $0.identity) }, isComplete: true)))
            objects.append(DeletionTraversal.Object(path: path, evidence: .directory(entry.identity)))
        }
        for (key, claims) in expected {
            guard let kind = kinds[key], claims.allSatisfy({ $0.kind == kind }) else { throw SourceFailure.versionChanged }
        }

        for (path, entry) in files {
            let handle: Handle
            do { handle = try open(path: path.string, access: Self.read, sharing: 1) }
            catch { throw Self.traversalFailure(error) }
            deletionTraversalFiles?[path.string] = handle
            let values = try info(handle)
            guard try folderMoveIdentity(values) == entry.identity else { throw SourceFailure.versionChanged }
            guard values[4] & 0x450 == 0 else { throw UploadError.unresolved }
            guard values[3] == 1 else { throw ItemDeletionError.unsupported }
            let claims = expected[SMBName.key(path.string)] ?? []
            try requireDeletionExpectations(claims, path: path, kind: .file, values: values)
            let version = try version(handle)
            let after = try info(handle)
            guard version.identity == entry.identity, version.modifiedMicroseconds == values[5],
                  after[0...2] == values[0...2], after[4...6] == values[4...6] else { throw SourceFailure.versionChanged }
            objects.append(DeletionTraversal.Object(path: path, evidence: .file(version)))
        }

        // Held children cannot leave or be replaced, so only arrivals can change these listings.
        for (path, children) in captured {
            let before = Dictionary(uniqueKeysWithValues: children.map { (Data($0.name.utf8), $0.identity) })
            let again = try folderMoveListing(path)
            guard again.count == children.count, again.allSatisfy({ before[Data($0.name.utf8)] == $0.identity }) else {
                throw SourceFailure.versionChanged
            }
        }
        guard try selectedEntry().identity == root.identity else { throw SourceFailure.versionChanged }
        return DeletionTraversal(selected: selected, parents: chain.map {
            ItemDeletionParent(path: $0.path, name: $0.name, identity: $0.identity)
        }, objects: objects, listings: listings)
    }

    /// Call once prepare has persisted, before any per-node session: their deny-all opens would
    /// meet these handles. Acknowledged closes avoid relying on the server's disconnect cleanup.
    func releaseDeletionTraversal() throws {
        guard let files = deletionTraversalFiles else { throw ItemDeletionError.invalidRequest }
        for path in files.keys.sorted() {
            try files[path]!.use { try check(tm_edit_close(client, $0)) }
            deletionTraversalFiles?[path] = nil
        }
        for path in directories.keys.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            try directories[path]!.use { try check(tm_edit_close(client, $0)) }
            directories[path] = nil
        }
    }

    /// Folders bind by native ID only: their fresh complete listing, not the row, governs children.
    private func requireDeletionExpectations(_ claims: [DeletionExpectation], path: RelativePath,
                                             kind: CatalogRow.Kind, values: [UInt64]) throws {
        guard !claims.isEmpty else { return }
        let (nativeID, fingerprint) = try folderMoveFingerprint(kind: kind, values: values)
        guard claims.allSatisfy({
            $0.kind == kind && $0.nativeID == nativeID && (kind == .folder || $0.fingerprint == fingerprint)
        }) else { throw SourceFailure.versionChanged }
    }

    /// A name this traversal just listed disappearing means the tree changed, not that it was deleted.
    private static func traversalFailure(_ error: Error) -> Error {
        switch serverStatus(error).flatMap(DeletionStatus.init(rawValue:)) {
        case .nameNotFound, .pathNotFound: return SourceFailure.versionChanged
        default: return deletionFailure(error)
        }
    }

    /// Any registered type with the extension counts, not only the data-conforming one.
    private static func isPackage(_ name: String) -> Bool {
        let suffix = (name as NSString).pathExtension
        return !suffix.isEmpty && UTType.types(tag: suffix, tagClass: .filenameExtension, conformingTo: nil)
            .contains { $0.conforms(to: .package) }
    }
}
