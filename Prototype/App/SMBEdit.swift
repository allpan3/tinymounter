import CryptoKit
import Darwin
import Foundation

/// One protected transaction, with the existing cached credential and native payload upload.
final class SMBEdit: EditRemote {
    private final class Handle {
        var bytes = [UInt8](repeating: 0, count: 16)
        func use<T>(_ body: (UnsafeMutablePointer<UInt8>) throws -> T) rethrows -> T {
            try bytes.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
        }
    }

    private let client: UnsafeMutableRawPointer
    private let folder: RelativePath
    private let root: Int32
    private let progress: Progress
    private var handles: [String: Handle] = [:]
    private var extraHandles: [Handle] = []
    private var originals: Set<String> = []
    private var hiddenOriginals: Set<String> = []
    private static let read: UInt32 = 0x20081
    private static let write: UInt32 = 2
    private static let delete: UInt32 = 0x10000

    init(endpoint: ShareAddress, folder: RelativePath, root: Int32, progress: Progress) throws {
        var error: Int32 = 0
        guard let client = tm_edit_connect(endpoint.host, endpoint.share, endpoint.account, &error) else {
            throw posixError("connect protected save", code: error)
        }
        self.client = client
        self.folder = folder
        self.root = root
        self.progress = progress
    }

    deinit { tm_edit_disconnect(client) }

    func protectAncestors(of path: String) throws {
        let full = try remotePath(path)
        let components = full.split(separator: "/").dropLast()
        var parent = ""
        for component in [""] + components.map(String.init) {
            if !component.isEmpty { parent += (parent.isEmpty ? "" : "/") + component }
            let handle = Handle()
            try handle.use { try check(tm_edit_open_directory(client, parent, 0x81, 3, $0)) }
            let values = try info(handle)
            guard values[0] != 0, values[1] != 0, values[4] & 0x410 == 0x10 else {
                throw UploadError.unresolved
            }
            extraHandles.append(handle)
        }
    }

    func readVersion(path: String) throws -> EditFileVersion {
        let handle = try open(path: path, access: Self.read, sharing: 1)
        handles[path] = handle
        return try version(handle)
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
        extraHandles.append(verifier)
        guard try info(verifier)[0...1] == expected[0...1] else { throw UploadError.unresolved }
        try handle.use { try check(tm_edit_flush(client, $0)) }
        return try version(handle)
    }

    func inspect(path: String, original: Bool) throws -> EditFileVersion? {
        if let handle = handles[path] { return try version(handle) }
        do {
            let handle = try open(path: path, access: Self.read | Self.delete | (original ? Self.write : 0), sharing: 0)
            handles[path] = handle
            if original { originals.insert(path) }
            return try version(handle)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
        guard let source = handles[original], originals.contains(original) else { throw UploadError.unresolved }
        let backup = try makePrivate(path: path, uploading: false, created: created)
        try copy(source: source, target: backup, size: Int64(try info(source)[2]))
        return try version(backup)
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
        guard let actual = try inspect(path: path, original: false) else { return }
        guard actual == expected, let handle = handles[path], try onlyMainStream(handle, size: expected.size) else {
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

    private func version(_ handle: Handle) throws -> EditFileVersion {
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
        }
        let security = try metadata(handle, security: true)
        let after = try info(handle)
        guard before[0...3] == after[0...3], before[5] == after[5] else { throw UploadError.unresolved }
        return try EditFileVersion(identity: EditFileIdentity(fileID: after[0], birthMicroseconds: after[1]),
                                   size: Int64(after[2]), digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                   modifiedMicroseconds: after[5], changedMicroseconds: after[6],
                                   attributes: UInt32(after[4]), security: Data(security))
    }

    private func onlyMainStream(_ handle: Handle, size: Int64) throws -> Bool {
        let data = try metadata(handle, security: false)
        if data.isEmpty { return size == 0 }
        var offset = 0
        while offset < data.count {
            let next = Int(try Self.integer(data, at: offset, bytes: 4))
            let length = Int(try Self.integer(data, at: offset + 4, bytes: 4))
            guard length % 2 == 0, offset + 24 + length <= data.count else { return false }
            let units = stride(from: offset + 24, to: offset + 24 + length, by: 2).map {
                UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
            }
            guard String(decoding: units, as: UTF16.self) == "::$DATA",
                  try Self.integer(data, at: offset + 8, bytes: 8) == UInt64(size) else { return false }
            if next == 0 { return true }
            guard next >= 24 + length, next <= data.count - offset else { return false }
            offset += next
        }
        return false
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
        if code != 0 { throw posixError("protected save", code: code) }
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
