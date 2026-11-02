import CryptoKit
import Darwin
import Foundation

public struct PendingUpload: Codable, Sendable {
    public enum State: String, Codable, Sendable { case staging, prepared, attempting, created, verified, completed, collision }
    public let id: UUID
    public let template: String
    public let parent: String
    public var name: String
    public var path: String
    public let kind: CatalogRow.Kind
    public let size: Int64
    public let digest: String
    public var state: State
    public var remoteID: UInt64?
    public var item: String?
    public var initialName: InitialFolderName?
    public var serverFolder: RemoteFolderIdentity?

    public var isPending: Bool { state != .completed || initialName?.isPending == true }
}

/// Private app storage; callers serialize operations and preserve unresolved remote attempts.
public final class UploadOutbox {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open outbox") }
        defer { close(fd) }
        guard try FileSystemInfo(fd: fd).isLocal else { throw UploadError.invalidRequest }
    }

    public func records() throws -> [PendingUpload] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw UploadError.invalidRequest
                }
                let record = try JSONDecoder().decode(PendingUpload.self, from: Data(contentsOf: url))
                guard record.id == id, RelativePath(record.path) != nil, !record.path.isEmpty,
                      RelativePath.isValidComponent(record.name), record.size >= 0,
                      record.serverFolder.map({ record.kind == .folder && $0.fileID != 0 && $0.birthMicroseconds != 0 }) != false,
                      record.initialName?.isValid(for: record) != false else {
                    throw UploadError.invalidRequest
                }
                return record
            }
    }

    public var pendingCount: Int {
        get throws {
            let records = try records()
            let known = Set(records.map { $0.id.uuidString })
            let orphans = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "data" && !known.contains($0.deletingPathExtension().lastPathComponent) }
            return records.filter(\.isPending).count + orphans.count
        }
    }

    public var contentBytes: Int64 {
        get throws {
            var total: Int64 = 0
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "data" {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw posixError("inspect retained contents") }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw UploadError.unresolved }
                let (sum, overflow) = total.addingReportingOverflow(info.st_size)
                guard !overflow else { throw UploadError.unresolved }
                total = sum
            }
            return total
        }
    }

    public func prepare(_ request: CreateRequest, path: RelativePath, contents: URL?,
                        progress: Progress, checkSpace: ((Int64) throws -> Void)? = nil,
                        id: UUID = UUID()) throws -> PendingUpload {
        if var previous = try records().first(where: { $0.template == request.template }) {
            let renamedCollision = previous.state == .collision && !previous.name.utf8.elementsEqual(request.name.utf8)
            let createdName = previous.initialName.flatMap { RelativePath($0.source)?.components.last }
            guard previous.parent == request.parent,
                  previous.name.utf8.elementsEqual(request.name.utf8)
                    || createdName?.utf8.elementsEqual(request.name.utf8) == true || renamedCollision,
                  previous.kind == request.kind else { throw UploadError.unresolved }
            if request.kind == .file {
                let file = try contents.map { try ReadOnlyFile(url: $0, allowMaterialization: true) }
                let size = file?.snapshot.size ?? 0
                let digest = try file.map { try $0.checksum(range: ByteRange(offset: 0, length: size, fileSize: size)) }
                    ?? Self.emptyDigest
                guard previous.size == size, previous.digest == digest else { throw UploadError.unresolved }
            }
            if previous.state == .staging {
                try stage(previous, contents: contents, progress: progress, checkSpace: checkSpace)
                previous.state = .prepared
                try save(previous)
            }
            if renamedCollision {
                previous.name = request.name
                previous.path = path.string
                previous.state = .prepared
                previous.remoteID = nil
                previous.serverFolder = nil
                try save(previous)
            }
            return previous
        }
        let file = try contents.map { try ReadOnlyFile(url: $0, allowMaterialization: true) }
        guard file?.filesystem.isLocal != false else { throw UploadError.invalidRequest }
        let size = file?.snapshot.size ?? 0
        let digest = try file.map { try $0.checksum(range: ByteRange(offset: 0, length: size, fileSize: size)) }
            ?? Self.emptyDigest
        try file?.validateUnchanged()
        var record = PendingUpload(id: id, template: request.template, parent: request.parent, name: request.name,
                                   path: path.string, kind: request.kind, size: size, digest: digest,
                                   state: request.kind == .file ? .staging : .prepared)
        try save(record)
        if request.kind == .file {
            try stage(record, contents: contents, progress: progress, checkSpace: checkSpace)
            record.state = .prepared
            try save(record)
        }
        return record
    }

    private func stage(_ record: PendingUpload, contents: URL?, progress: Progress,
                       checkSpace: ((Int64) throws -> Void)?) throws {
        let source = try contents.map { try ReadOnlyFile(url: $0, allowMaterialization: true) }
        guard source?.filesystem.isLocal != false, source?.snapshot.size ?? 0 == record.size,
              try source.map({ try $0.checksum(range: ByteRange(offset: 0, length: record.size, fileSize: record.size)) })
                ?? Self.emptyDigest == record.digest else { throw UploadError.unresolved }
        if try finishStagedPayload(record) { return }
        let destination = contentURL(record.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let fd = open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create pending content") }
        defer { close(fd) }
        progress.totalUnitCount = max(1, Int64(clamping: Int128(record.size) * 2))
        if let source {
            try Self.copy(from: source.descriptor, to: fd, size: record.size, progress: progress, checkSpace: checkSpace)
            try source.validateUnchanged()
        }
        guard try Self.checksum(fd, size: record.size) == record.digest else { throw UploadError.unresolved }
        guard fsync(fd) == 0, fchmod(fd, 0o400) == 0 else { throw posixError("sync pending content") }
    }

    public func save(_ record: PendingUpload) throws {
        let final = directory.appending(path: record.id.uuidString + ".json")
        let temporary = directory.appending(path: record.id.uuidString + ".new")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open upload state") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(record))
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, final.path) == 0 else { throw posixError("save upload state") }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw posixError("open upload state directory") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw posixError("sync upload state directory") }
    }

    public func complete(_ record: inout PendingUpload, item: String) throws {
        record.item = item
        record.state = .completed
        try save(record)
        if record.kind == .file { try FileManager.default.removeItem(at: contentURL(record.id)) }
    }

    public func removeIfCompleted() throws {
        guard try pendingCount == 0 else { throw UploadError.pendingWrites }
        try FileManager.default.removeItem(at: directory)
    }

    // A complete payload can outlive a failed state update; only incomplete staging is disposable.
    func recoverLocalPreparation(_ id: UUID, size: Int64, digest: String) throws -> Bool {
        if var record = try records().first(where: { $0.id == id }) {
            guard record.kind == .file, [.staging, .prepared].contains(record.state),
                  record.size == size, record.digest == digest, record.remoteID == nil, record.item == nil,
                  record.initialName == nil, record.serverFolder == nil else { throw UploadError.unresolved }
            if try finishStagedPayload(record) {
                record.state = .prepared
                try save(record)
                return true
            }
            guard record.state == .staging else { throw UploadError.unresolved }
        } else if try stagedFile(id) != nil {
            throw UploadError.unresolved
        }
        try discardUnpublishedPayload(id)
        return false
    }

    private func stagedFile(_ id: UUID) throws -> ReadOnlyFile? {
        do { return try ReadOnlyFile(url: contentURL(id)) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    private func finishStagedPayload(_ record: PendingUpload) throws -> Bool {
        guard let file = try stagedFile(record.id) else { return false }
        guard file.filesystem.isLocal else { throw UploadError.unresolved }
        if file.snapshot.size < record.size { return false }
        guard file.snapshot.size == record.size,
              try file.checksum(range: ByteRange(offset: 0, length: record.size, fileSize: record.size)) == record.digest
        else { throw UploadError.unresolved }
        guard fchmod(file.descriptor, 0o400) == 0, fcntl(file.descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("sync recovered payload")
        }
        return true
    }

    // EditOutbox proves supersession or incomplete local preparation before removing a payload.
    func discardUnpublishedPayload(_ id: UUID) throws {
        if let record = try records().first(where: { $0.id == id }) {
            guard record.kind == .file, [.staging, .prepared].contains(record.state),
                  record.remoteID == nil, record.item == nil,
                  record.initialName == nil, record.serverFolder == nil else { throw UploadError.unresolved }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open payload directory") }
        defer { close(fd) }
        guard unlink(contentURL(id).path) == 0 || errno == ENOENT else { throw posixError("discard local payload") }
        // A surviving payload must keep its staging receipt after an interrupted cleanup.
        guard fsync(fd) == 0 else { throw posixError("sync payload removal") }
        for suffix in ["json", "new"] {
            guard unlink(directory.appending(path: id.uuidString + "." + suffix).path) == 0 || errno == ENOENT else {
                throw posixError("discard local payload record")
            }
        }
        guard fsync(fd) == 0 else { throw posixError("sync payload removal") }
    }

    /// An interrupted existing file is read and proved complete, never reopened for writing.
    public func upload(_ record: inout PendingUpload, locationRoot: Int32, progress: Progress,
                       checkpoint: (PendingUpload.State) throws -> Void = { _ in }) throws {
        guard record.kind == .file else { throw UploadError.readOnly }
        guard record.state != .staging else { throw UploadError.unresolved }
        guard record.state != .collision else { throw UploadError.collision }
        guard record.state != .completed else { return }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        guard let path = RelativePath(record.path), let name = path.components.last else { throw UploadError.invalidRequest }
        let parentPath = path.components.dropLast().joined(separator: "/")
        let parent = openat(locationRoot, parentPath.isEmpty ? "." : parentPath,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard parent >= 0 else { throw posixError("open upload parent") }
        defer { close(parent) }
        if record.state != .prepared {
            try verify(record, parent: parent, name: name)
            record.state = .verified
            try save(record)
            return
        }
        record.state = .attempting
        try save(record)
        try checkpoint(.attempting)
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { try creationFailed(&record); return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError("stat created upload") }
        record.remoteID = info.st_ino
        record.state = .created
        try save(record)
        try checkpoint(.created)
        let local = try ReadOnlyFile(url: contentURL(record.id))
        guard local.snapshot.size == record.size,
              try local.checksum(range: ByteRange(offset: 0, length: record.size, fileSize: record.size)) == record.digest else {
            throw UploadError.unresolved
        }
        progress.totalUnitCount = max(1, Int64(clamping: Int128(record.size) * 2))
        try Self.copy(from: local.descriptor, to: fd, size: record.size, progress: progress)
        try local.validateUnchanged()
        guard fsync(fd) == 0 else { throw posixError("sync upload") }
        try verify(record, parent: parent, name: name)
        record.state = .verified
        try save(record)
        try checkpoint(.verified)
    }

    private func creationFailed(_ record: inout PendingUpload) throws {
        let code = errno
        if code == EEXIST {
            record.state = .collision
            try save(record)
            throw UploadError.collision
        }
        // The server refused the create, so nothing exists and the next attempt starts again. After a
        // timeout or a lost connection the outcome is unknown, so the record stays unresolved.
        if Self.refusals.contains(code) {
            record.state = .prepared
            try save(record)
        }
        throw posixError("create upload", code: code)
    }

    private static let refusals: Set<Int32> = [EACCES, EPERM, ENOENT, ENOTDIR, ENAMETOOLONG, EINVAL, EILSEQ,
                                                EROFS, ENOSPC, EDQUOT]

    private func verify(_ record: PendingUpload, parent: Int32, name: String) throws {
        guard let identity = record.remoteID, identity != 0 else { throw UploadError.unresolved }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw UploadError.unresolved }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_ino == identity else { throw UploadError.unresolved }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size == record.size,
                  try Self.checksum(fd, size: record.size) == record.digest,
                  fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw UploadError.unresolved
            }
    }

    private func contentURL(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".data") }
    private static var emptyDigest: String { SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined() }

    private static func copy(from source: Int32, to destination: Int32, size: Int64, progress: Progress,
                             checkSpace: ((Int64) throws -> Void)? = nil) throws {
        let capacity = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
        defer { buffer.deallocate() }
        var offset: Int64 = 0
        while offset < size {
            guard !progress.isCancelled else { throw TransferError.cancelled }
            let count = pread(source, buffer, min(capacity, Int(size - offset)), offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError("read pending upload") }
            var written = 0
            while written < count {
                let n = pwrite(destination, buffer.advanced(by: written), count - written, offset + Int64(written))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw posixError("write pending upload") }
                written += n
            }
            offset += Int64(count)
            progress.completedUnitCount += Int64(count)
            try checkSpace?(offset)
        }
    }

    private static func checksum(_ fd: Int32, size: Int64) throws -> String {
        let capacity = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
        defer { buffer.deallocate() }
        var hash = SHA256(), offset: Int64 = 0
        while offset < size {
            let count = pread(fd, buffer, min(capacity, Int(size - offset)), offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw UploadError.unresolved }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            offset += Int64(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
