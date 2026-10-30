import CryptoKit
import Darwin
import Foundation
import OSLog

/// One protected transaction, with the existing cached credential and native payload upload.
final class SMBEdit: EditRemote, FileRenameRemote {
    private final class Handle {
        var bytes = [UInt8](repeating: 0, count: 16)
        func use<T>(_ body: (UnsafeMutablePointer<UInt8>) throws -> T) rethrows -> T {
            try bytes.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
    }

    private let client: UnsafeMutableRawPointer
    private let endpoint: ShareAddress
    private let folder: RelativePath
    private let root: Int32
    private let progress: Progress
    private var handles: [String: Handle] = [:]
    private var stageVerifiers: [String: Handle] = [:]
    private var directories: [String: Handle] = [:]
    private var originals: Set<String> = []
    private var hiddenOriginals: Set<String> = []
    private var deletionTarget: String?
    private var folderMoveMount: MountIdentity?
    private var folderMoveRoots: [String: Handle] = [:]
    private var folderMoveFiles: [String: Handle] = [:]
    private var folderMoveParents: Set<String> = []
    private static let read: UInt32 = 0x20081
    private static let write: UInt32 = 2
    private static let delete: UInt32 = 0x10000
    private static let statusKey = "tinymounter.smb.ntstatus"

    init(endpoint: ShareAddress, folder: RelativePath, root: Int32, progress: Progress) throws {
        var error: Int32 = 0
        guard let client = tm_edit_connect(endpoint.host, endpoint.share, endpoint.account, &error) else {
            throw posixError("connect protected save", code: error)
        }
        self.client = client
        self.endpoint = endpoint
        self.folder = folder
        self.root = root
        self.progress = progress
    }

    deinit { tm_edit_disconnect(client) }

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
            let identity = try EditFileIdentity(fileID: values[0], birthMicroseconds: values[1])
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

    func readVersion(path: String) throws -> EditFileVersion {
        let handle = try open(path: path, access: Self.read, sharing: 1)
        handles[path] = handle
        return try version(handle)
    }

    func allowPublishedReads(path: String, expected: EditFileVersion) throws {
        guard let previous = handles[path] else { throw UploadError.unresolved }
        // Revalidate after releasing the exclusive guard so native SMB can inspect the saved file.
        try previous.use { try check(tm_edit_close(client, $0)) }
        handles[path] = nil
        let current = try readVersion(path: path)
        guard current.hasSameContents(as: expected),
              current.modifiedMicroseconds == expected.modifiedMicroseconds else {
            throw UploadError.unresolved
        }
    }

    func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
        let handle = try makePrivate(path: path, uploading: true, created: created)
        let expected = try info(handle)
        let input = try ReadOnlyFile(url: contents)
        let fd = openat(root, path, O_WRONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open owned edit stage") }
        var closed = false
        defer { if !closed { Darwin.close(fd) } }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size == 0,
              metadata.st_birthtimespec.tv_sec > 0,
              UInt64(metadata.st_birthtimespec.tv_sec) * 1_000_000
                + UInt64(metadata.st_birthtimespec.tv_nsec / 1_000) == expected[1] else {
            throw UploadError.unresolved
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset: Int64 = 0
        while offset < input.snapshot.size {
            try cancellation()
            let count = pread(input.descriptor, &buffer, min(buffer.count, Int(input.snapshot.size - offset)), offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError("read pending edit") }
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < count {
                    let length = pwrite(fd, bytes.baseAddress!.advanced(by: written), count - written, offset + Int64(written))
                    if length < 0, errno == EINTR { continue }
                    guard length > 0 else { throw posixError("upload private edit") }
                    written += length
                }
            }
            offset += Int64(count)
            progress.completedUnitCount += Int64(count)
        }
        try input.validateUnchanged()
        guard fsync(fd) == 0 else { throw posixError("flush native edit") }
        let result = Darwin.close(fd)
        closed = true
        guard result == 0 else { throw posixError("close native edit") }
        let verifier = try open(path: path, access: Self.read, sharing: 5)
        stageVerifiers[path] = verifier
        guard try info(verifier)[0...1] == expected[0...1] else { throw UploadError.unresolved }
        return try version(handle, artifactPath: path)
    }

    func inspect(path: String, original: Bool) throws -> EditFileVersion? {
        if let handle = handles[path] { return try version(handle, artifactPath: original ? nil : path) }
        let handle: Handle
        do {
            handle = try open(path: path, access: Self.read | Self.delete | (original ? Self.write : 0), sharing: 0)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
        handles[path] = handle
        if original { originals.insert(path) }
        return try version(handle, artifactPath: original ? nil : path)
    }

    func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
        guard let source = handles[original], originals.contains(original) else { throw UploadError.unresolved }
        let backup = try makePrivate(path: path, uploading: false, created: created)
        try copy(source: source, target: backup, size: Int64(try info(source)[2]))
        return try version(backup, artifactPath: path)
    }

    func move(source: String, destination: String) throws {
        guard let handle = handles[source] else { throw UploadError.unresolved }
        let target = try remotePath(destination)
        try cancellation()
        try handle.use { try check(tm_edit_rename(client, $0, target)) }
        handles[source] = nil
        handles[destination] = handle
        if originals.remove(source) != nil {
            originals.insert(destination)
            if destination.hasSuffix(".work") { hiddenOriginals.insert(destination) }
        }
        hiddenOriginals.remove(source)
    }

    func update(work: String, stage: String, size: Int64) throws {
        guard hiddenOriginals.contains(work), let target = handles[work], let source = handles[stage] else {
            throw UploadError.unresolved
        }
        try copy(source: source, target: target, size: size)
    }

    func removeArtifact(path: String, version expected: EditFileVersion) throws {
        guard !originals.contains(path), !hiddenOriginals.contains(path),
              path.hasSuffix(".stage") || path.hasSuffix(".recovery") else { throw UploadError.unresolved }
        // Reacquire exclusive protection so no verifier can defer deletion past its close reply.
        if let verifier = stageVerifiers[path] {
            try verifier.use { try check(tm_edit_close(client, $0)) }
            stageVerifiers[path] = nil
            guard let handle = handles[path] else { throw UploadError.unresolved }
            try handle.use { try check(tm_edit_close(client, $0)) }
            handles[path] = nil
        }
        guard let actual = try inspect(path: path, original: false) else { throw UploadError.unresolved }
        guard actual == expected else {
            Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                .error("edit_cleanup_version contents=\(actual.hasSameContents(as: expected)) modified=\(actual.modifiedMicroseconds == expected.modifiedMicroseconds) changed=\(actual.changedMicroseconds == expected.changedMicroseconds) attributes=\(actual.attributes == expected.attributes) security=\(actual.security == expected.security)")
            throw UploadError.unresolved
        }
        guard let handle = handles[path] else {
            throw UploadError.unresolved
        }
        try handle.use { try check(tm_edit_delete(client, $0)) }
        try handle.use { try check(tm_edit_close(client, $0)) }
        handles[path] = nil
    }

    private func makePrivate(path: String, uploading: Bool,
                             created: (EditFileIdentity) throws -> Void) throws -> Handle {
        var security = Self.privateSecurity(owner: [])
        let handle = Handle()
        let full = try remotePath(path)
        let access = Self.read | Self.delete | 0x40000 | (uploading ? 0 : Self.write)
        try handle.use { file in
            try security.withUnsafeBytes {
                try check(tm_edit_open_private(client, full, access, uploading ? 3 : 0,
                                                $0.bindMemory(to: UInt8.self).baseAddress!, UInt32($0.count), file))
            }
        }
        handles[path] = handle
        let values = try info(handle)
        let identity = try EditFileIdentity(fileID: values[0], birthMicroseconds: values[1])
        try created(identity)
        let initial = try metadata(handle, security: true)
        guard try Self.dacl(initial) == Self.dacl(security) else { throw UploadError.unresolved }
        let ownerOffset = Int(try Self.integer(initial, at: 4, bytes: 4))
        guard ownerOffset >= 20, ownerOffset + 8 <= initial.count, initial[ownerOffset] == 1 else {
            throw UploadError.unresolved
        }
        let ownerSize = 8 + Int(initial[ownerOffset + 1]) * 4
        guard ownerSize <= 68, ownerOffset + ownerSize <= initial.count else { throw UploadError.unresolved }
        security = Self.privateSecurity(owner: Array(initial[ownerOffset..<ownerOffset + ownerSize]))
        try handle.use { file in
            try security.withUnsafeMutableBytes {
                try check(tm_edit_set_metadata(client, file, 1, $0.bindMemory(to: UInt8.self).baseAddress!, UInt32($0.count)))
            }
        }
        guard try Self.dacl(metadata(handle, security: true)) == Self.dacl(security) else {
            throw UploadError.unresolved
        }
        return handle
    }

    private func copy(source: Handle, target: Handle, size: Int64) throws {
        var key = [UInt8](repeating: 0, count: 24)
        try source.use { try check(tm_edit_resume_key(client, $0, &key)) }
        var offset: UInt64 = 0
        while offset < UInt64(size) {
            try cancellation()
            let count = UInt32(min(1_048_576, UInt64(size) - offset))
            var response = [UInt8](repeating: 0, count: 12)
            try target.use { try check(tm_edit_copy_chunk(client, $0, key, offset, offset, count, &response)) }
            guard try Self.integer(response, at: 0, bytes: 4) == 1,
                  try Self.integer(response, at: 4, bytes: 4) == 0,
                  try Self.integer(response, at: 8, bytes: 4) == count else { throw UploadError.unresolved }
            offset += UInt64(count)
            progress.completedUnitCount += Int64(count)
        }
        try target.use { try check(tm_edit_set_size(client, $0, UInt64(size))) }
        try target.use { try check(tm_edit_flush(client, $0)) }
    }

    private func version(_ handle: Handle, artifactPath: String? = nil) throws -> EditFileVersion {
        let before = try info(handle)
        guard before[2] <= Int64.max, before[3] == 1, before[4] & 0x410 == 0 else {
            throw UploadError.unresolved
        }
        var hash = SHA256(), offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while offset < before[2] {
            try cancellation()
            var count: UInt32 = 0
            try handle.use {
                try check(tm_edit_read(client, $0, offset, &buffer, UInt32(min(UInt64(buffer.count), before[2] - offset)), &count))
            }
            guard count > 0, count <= buffer.count, UInt64(count) <= before[2] - offset else {
                throw UploadError.unresolved
            }
            hash.update(data: buffer.prefix(Int(count)))
            offset += UInt64(count)
            progress.completedUnitCount += Int64(count)
        }
        let security = try metadata(handle, security: true)
        let quarantine = try artifactPath.flatMap { try artifactQuarantine(handle, path: $0, size: Int64(before[2])) }
        let after = try info(handle)
        guard before[0...3] == after[0...3], before[5] == after[5] else { throw UploadError.unresolved }
        return try EditFileVersion(identity: EditFileIdentity(fileID: after[0], birthMicroseconds: after[1]),
                                   size: Int64(after[2]), digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                   modifiedMicroseconds: after[5], changedMicroseconds: after[6],
                                   attributes: UInt32(after[4]), security: Data(security), artifactQuarantine: quarantine)
    }

    private func artifactQuarantine(_ handle: Handle, path: String, size: Int64) throws -> Data? {
        let data = try metadata(handle, security: false)
        if data.isEmpty {
            guard size == 0 else { throw UploadError.unresolved }
            return nil
        }
        var offset = 0
        var streams: [String: UInt64] = [:]
        while offset < data.count {
            let next = Int(try Self.integer(data, at: offset, bytes: 4))
            let length = Int(try Self.integer(data, at: offset + 4, bytes: 4))
            guard length % 2 == 0, offset + 24 + length <= data.count else { throw UploadError.unresolved }
            let units = stride(from: offset + 24, to: offset + 24 + length, by: 2).map {
                UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
            }
            let name = String(decoding: units, as: UTF16.self)
            guard streams[name] == nil else { throw UploadError.unresolved }
            streams[name] = try Self.integer(data, at: offset + 8, bytes: 8)
            if next == 0 { break }
            guard next >= 24 + length, next < data.count - offset else { throw UploadError.unresolved }
            offset += next
        }
        let quarantineName = ":com.apple.quarantine:$DATA"
        guard streams["::$DATA"] == UInt64(size),
              Set(streams.keys).isSubset(of: ["::$DATA", quarantineName]) else { throw UploadError.unresolved }
        guard let length = streams[quarantineName] else { return nil }
        guard length <= 65_536 else { throw UploadError.unresolved }
        let stream = Handle(), full = try remotePath(path)
        try stream.use { try check(tm_edit_open_quarantine(client, full, $0)) }
        defer { stream.use { _ = tm_edit_close(client, $0) } }
        var bytes = [UInt8](repeating: 0, count: Int(max(1, length))), offsetRead: UInt64 = 0
        while offsetRead < length {
            var count: UInt32 = 0
            try stream.use { file in
                try bytes.withUnsafeMutableBufferPointer { buffer in
                    try check(tm_edit_read(client, file, offsetRead, buffer.baseAddress!.advanced(by: Int(offsetRead)),
                                           UInt32(length - offsetRead), &count))
                }
            }
            guard count > 0, UInt64(count) <= length - offsetRead else { throw UploadError.unresolved }
            offsetRead += UInt64(count)
        }
        return Data(bytes.prefix(Int(length)))
    }

    private func info(_ handle: Handle) throws -> [UInt64] {
        var values = [UInt64](repeating: 0, count: 8)
        try handle.use { try check(tm_edit_info(client, $0, &values)) }
        return values
    }

    private func metadata(_ handle: Handle, security: Bool) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 65_536), count: UInt32 = 0
        try handle.use { try check(tm_edit_metadata(client, $0, security ? 7 : 0, &bytes, UInt32(bytes.count), &count)) }
        return Array(bytes.prefix(Int(count)))
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

    private static func integer(_ bytes: [UInt8], at offset: Int, bytes count: Int) throws -> UInt64 {
        guard offset >= 0, count <= 8, offset <= bytes.count - count else { throw UploadError.unresolved }
        return (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    private static func dacl(_ security: [UInt8]) throws -> [UInt8] {
        let offset = Int(try integer(security, at: 16, bytes: 4))
        let length = Int(try integer(security, at: offset + 2, bytes: 2))
        guard offset >= 20, length >= 8, offset <= security.count - length else { throw UploadError.unresolved }
        return Array(security[offset..<offset + length])
    }

    private static func privateSecurity(owner: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [1, 0, 4, 0x90, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0]
        let size = 8 + (owner.isEmpty ? 0 : 8 + owner.count)
        bytes += [2, 0, UInt8(size), 0, owner.isEmpty ? 0 : 1, 0, 0, 0]
        if !owner.isEmpty { bytes += [0, 0, UInt8(8 + owner.count), 0, 0xff, 1, 0x1f, 0] + owner }
        return bytes
    }
}

extension SMBEdit: FolderMoveRemote {
    private struct FolderMoveCurrent {
        let identity: EditFileIdentity
        let version: EditFileVersion?
        let nativeID: UInt64
        let fingerprint: ContentFingerprint
    }

    func protectFolderMoveParents(source: String, destination: String) throws -> [FileRenameParent] {
        guard folder.isRoot, handles.isEmpty, stageVerifiers.isEmpty, deletionTarget == nil else {
            throw UploadError.invalidRequest
        }
        _ = try folderMoveMountIdentity()
        let parents = try protectRenameParents(source: source, destination: destination)
        for parent in parents {
            guard parent.name.utf8.elementsEqual((RelativePath(parent.path)!.components.last ?? "").utf8) else {
                throw UploadError.unresolved
            }
        }
        folderMoveParents = Set(parents.map(\.path))
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
              root.name.utf8.elementsEqual(rootEntry.name.utf8) else { throw SourceFailure.versionChanged }
        var proofs: [String: CatalogFolderMoveProof] = [:]
        for entry in folderMoveOrdered(move.entries) {
            guard let path = folder.appending(RelativePath(entry.path)!),
                  let current = try folderMoveCurrent(path: path, kind: entry.kind, expected: nil),
                  current.nativeID == entry.nativeID, current.fingerprint.size == entry.size,
                  current.fingerprint.mtimeNs == entry.mtimeNs, current.fingerprint.ctimeNs == entry.ctimeNs else {
                throw SourceFailure.versionChanged
            }
            if let version = current.version {
                proofs[entry.item] = .file(try EditBaseReceipt(item: entry.item, version: version))
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
        for view in record.views {
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            for entry in folderMoveOrdered(view.move.entries) {
                guard let path = RelativePath(view.folder)?.appending(RelativePath(entry.path)!),
                      let proof = proofs[entry.item],
                      let current = try folderMoveCurrent(path: path, kind: entry.kind, expected: proof.identity) else {
                    throw SourceFailure.versionChanged
                }
                if case .file(let receipt) = proof {
                    guard let version = current.version, version.hasSameContents(as: receipt.version),
                          version.modifiedMicroseconds == receipt.version.modifiedMicroseconds else {
                        throw SourceFailure.versionChanged
                    }
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
        try handle.use { try check(tm_edit_rename(client, $0, destination)) }
        folderMoveRoots = folderMoveRoots.filter { $0.value !== handle }
        folderMoveRoots[destination] = handle
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
                    if version.hasSameContents(as: before.version)
                        && version.modifiedMicroseconds == before.version.modifiedMicroseconds { return .preserved(after) }
                    return .changed(after, receipt: try EditBaseReceipt(item: after.item, version: version))
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
                          version.hasSameContents(as: receipt.version),
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
                    physical[path.string] = try folderMoveCurrent(path: path, kind: entry.kind, expected: before.proof.identity)
                }
                guard let current = physical[path.string] else {
                    guard entry.item != view.move.item else { throw SourceFailure.versionChanged }
                    observations[entry.item] = .removed(item: entry.item)
                    absent.insert(path.string)
                    continue
                }
                guard current.identity == before.proof.identity else { throw UploadError.unresolved }
                let preserved: Bool
                if let version = current.version, case .file(let receipt) = before.proof {
                    preserved = version.hasSameContents(as: receipt.version)
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
            return FolderMoveRefresh(domain: view.domain, observations: try view.move.entries.map {
                guard let value = observations[$0.item] else { throw UploadError.unresolved }
                return value
            }, listings: listings)
        }
    }

    private func folderMoveCurrent(path: RelativePath, kind: CatalogRow.Kind,
                                   expected: EditFileIdentity?) throws -> FolderMoveCurrent? {
        let parent = path.components.dropLast().joined(separator: "/"), name = path.components.last!
        guard let entry = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(name) }),
              expected == nil || entry.identity == expected else { return nil }
        guard entry.kind == kind, entry.name.utf8.elementsEqual(name.utf8) else { throw UploadError.unresolved }
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
        guard try folderMoveIdentity(values) == entry.identity,
              values[4] & 0x450 == (kind == .folder ? 0x10 : 0),
              let confirmed = try folderMoveListing(parent).first(where: { NameKey($0.name) == NameKey(name) }),
              confirmed.identity == entry.identity, confirmed.name.utf8.elementsEqual(name.utf8) else {
            throw UploadError.unresolved
        }
        let native = try folderMoveNative(path: path, kind: kind, values: values)
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

    private func folderMoveNative(path: RelativePath, kind: CatalogRow.Kind, values: [UInt64]) throws
        -> (UInt64, ContentFingerprint) {
        let mount = try folderMoveMountIdentity()
        return try mount.guarding(root: root) {
            try mount.requireMounted(root)
            let parent = RelativePath(path.components.dropLast().joined(separator: "/"))!, name = path.components.last!
            let listing = try DirectoryListing.list(locationRoot: root, relativePath: parent, expected: mount)
            guard let listed = listing.entries.first(where: { $0.name.utf8.elementsEqual(name.utf8) }),
                  listed.kind.rawValue == kind.rawValue else { throw UploadError.unresolved }
            let descriptor = openat(root, parent.isRoot ? "." : parent.string,
                                    O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixError("inspect moved folder parent") }
            defer { Darwin.close(descriptor) }
            guard try MountIdentity(descriptor: descriptor) == mount else { throw SourceFailure.pathRejected }
            guard let protectedParent = folderMoveRoots[parent.string] ?? directories[parent.string] else {
                throw UploadError.unresolved
            }
            let parentValues = try info(protectedParent)
            var parentMetadata = stat()
            guard fstat(descriptor, &parentMetadata) == 0, parentMetadata.st_mode & S_IFMT == S_IFDIR,
                  parent.isRoot || (parentMetadata.st_birthtimespec.tv_sec > 0
                    && UInt64(parentMetadata.st_birthtimespec.tv_sec) * 1_000_000
                      + UInt64(parentMetadata.st_birthtimespec.tv_nsec / 1_000) == parentValues[1]) else {
                throw UploadError.unresolved
            }
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError("inspect moved descendant")
            }
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_FSID)
            var filesystem = [UInt32](repeating: 0, count: 3)
            guard getattrlistat(descriptor, name, &attributes, &filesystem, 12, UInt(FSOPT_NOFOLLOW)) == 0 else {
                throw posixError("inspect moved descendant filesystem")
            }
            guard filesystem[0] == 12, UInt64(filesystem[1]) | UInt64(filesystem[2]) << 32 == mount.fsid,
                  metadata.st_dev == parentMetadata.st_dev else { throw SourceFailure.pathRejected }
            let fingerprint = ContentFingerprint(size: kind == .folder ? 0 : metadata.st_size,
                mtimeNs: ContentFingerprint.nanoseconds(seconds: Int64(metadata.st_mtimespec.tv_sec),
                                                       nanoseconds: Int64(metadata.st_mtimespec.tv_nsec)),
                ctimeNs: ContentFingerprint.nanoseconds(seconds: Int64(metadata.st_ctimespec.tv_sec),
                                                       nanoseconds: Int64(metadata.st_ctimespec.tv_nsec)))
            guard metadata.st_mode & S_IFMT == (kind == .folder ? S_IFDIR : S_IFREG), metadata.st_ino != 0,
                  metadata.st_birthtimespec.tv_sec > 0,
                  UInt64(metadata.st_birthtimespec.tv_sec) * 1_000_000
                    + UInt64(metadata.st_birthtimespec.tv_nsec / 1_000) == values[1],
                  kind == .folder || (metadata.st_nlink == 1 && metadata.st_size >= 0 && UInt64(metadata.st_size) == values[2]),
                  fingerprint.mtimeNs >= 0, fingerprint.ctimeNs >= 0,
                  UInt64(fingerprint.mtimeNs / 1_000) == values[5], UInt64(fingerprint.ctimeNs / 1_000) == values[6],
                  listed.fileID == UInt64(metadata.st_ino), listed.size == fingerprint.size,
                  listed.mtimeNs == fingerprint.mtimeNs, listed.ctimeNs == fingerprint.ctimeNs else {
                throw UploadError.unresolved
            }
            guard try MountIdentity(descriptor: descriptor) == mount else { throw SourceFailure.pathRejected }
            try mount.requireMounted(root)
            return (UInt64(metadata.st_ino), fingerprint)
        }
    }

    private func folderMoveMountIdentity() throws -> MountIdentity {
        if let mount = folderMoveMount { try mount.requireMounted(root); return mount }
        let mount = try MountIdentity(descriptor: root)
        guard folder.isRoot, mount.typeName == "smbfs", ShareAddress(mount.mountFrom) == endpoint else {
            throw UploadError.invalidRequest
        }
        folderMoveMount = mount
        return mount
    }

    private func folderMovePath(_ path: String) throws -> RelativePath {
        guard folder.isRoot, let path = RelativePath(path), !path.isRoot, !folderMoveParents.isEmpty else {
            throw UploadError.invalidRequest
        }
        return path
    }

    private func folderMoveIdentity(_ values: [UInt64]) throws -> EditFileIdentity {
        try EditFileIdentity(fileID: values[0], birthMicroseconds: values[1])
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
        guard folder.isRoot, handles.isEmpty, stageVerifiers.isEmpty,
              originals.isEmpty, hiddenOriginals.isEmpty, deletionTarget == nil else {
            throw ItemDeletionError.invalidRequest
        }
        let parents = try protectRenameParents(source: path, destination: path)
        deletionTarget = path
        return parents.map { ItemDeletionParent(path: $0.path, name: $0.name, identity: $0.identity) }
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
        return .present(.directory(try EditFileIdentity(fileID: values[0], birthMicroseconds: values[1])))
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
              directories[path] == nil, stageVerifiers.isEmpty else { throw ItemDeletionError.invalidRequest }
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
