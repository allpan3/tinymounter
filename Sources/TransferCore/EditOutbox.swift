import CryptoKit
import Darwin
import Foundation

public struct EditFileIdentity: Codable, Equatable, Sendable {
    public let fileID: UInt64
    public let birthMicroseconds: UInt64

    public init(fileID: UInt64, birthMicroseconds: UInt64) throws {
        guard fileID != 0, birthMicroseconds != 0 else { throw UploadError.unresolved }
        self.fileID = fileID
        self.birthMicroseconds = birthMicroseconds
    }
}

public struct EditFileVersion: Codable, Equatable, Sendable {
    public let identity: EditFileIdentity
    public let size: Int64
    public let digest: String
    public let modifiedMicroseconds: UInt64
    public let changedMicroseconds: UInt64
    public let attributes: UInt32
    public let security: Data

    public init(identity: EditFileIdentity, size: Int64, digest: String, modifiedMicroseconds: UInt64,
                changedMicroseconds: UInt64, attributes: UInt32, security: Data) throws {
        guard size >= 0, Self.validDigest(digest), !security.isEmpty else { throw UploadError.unresolved }
        self.identity = identity
        self.size = size
        self.digest = digest
        self.modifiedMicroseconds = modifiedMicroseconds
        self.changedMicroseconds = changedMicroseconds
        self.attributes = attributes
        self.security = security
    }

    static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct EditBaseReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let item: String
    public let version: EditFileVersion
    public var contentVersion: String { "e1:" + id.uuidString }

    public init(id: UUID = UUID(), item: String, version: EditFileVersion) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID else { throw UploadError.invalidRequest }
        self.id = id
        self.item = item
        self.version = version
    }
}

public struct PendingEdit: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case prepared, creatingStage, staged, movingOriginal, publishing, published, completed
    }

    public let id: UUID
    public let item: String
    public let parent: String
    public let path: String
    public let baseVersion: String
    public let size: Int64
    public let digest: String
    public let failOnConflict: Bool
    public let localMetadataDigest: String
    public let stagePath: String
    public let recoveryPath: String
    public var state: State = .prepared
    public var stageIdentity: EditFileIdentity?
    public var previous: EditFileVersion?
    public var destination: String
    public var published: EditBaseReceipt?
    public var conflict = false
    public var completedItem: String?
    public var recoveryRetained = false

    public var isPending: Bool { state != .completed }
}

/// Serialized by the location's mutation lane; incomplete generations are never replaced.
public final class EditOutbox {
    private let directory: URL
    private let payloads: UploadOutbox

    public init(directory: URL) throws {
        self.directory = directory
        payloads = try UploadOutbox(directory: directory.appending(path: "Contents", directoryHint: .isDirectory))
    }

    public func records() throws -> [PendingEdit] {
        try files(ending: "edit").map { url in
            let record = try JSONDecoder().decode(PendingEdit.self, from: Data(contentsOf: url))
            guard record.id.uuidString == url.deletingPathExtension().lastPathComponent,
                  ReaderMessage.isItemID(record.item), record.item != Catalog.rootItemID,
                  ReaderMessage.isItemID(record.parent), record.size >= 0,
                  EditFileVersion.validDigest(record.digest), EditFileVersion.validDigest(record.localMetadataDigest),
                  record.baseVersion.utf8.count <= 128,
                  let path = RelativePath(record.path), !path.isRoot,
                  let stage = RelativePath(record.stagePath), let recovery = RelativePath(record.recoveryPath),
                  let destination = RelativePath(record.destination),
                  stage.components.dropLast() == path.components.dropLast(),
                  recovery.components.dropLast() == path.components.dropLast(),
                  destination.components.dropLast() == path.components.dropLast(),
                  stage.components.last == ".tinymounter-\(record.id.uuidString).stage",
                  recovery.components.last == ".tinymounter-\(record.id.uuidString).recovery",
                  !destination.isRoot else { throw UploadError.invalidRequest }
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public var pendingCount: Int {
        get throws {
            let records = try records()
            let known = Set(records.map(\.id))
            let linked = try payloads.records().filter { $0.isPending && known.contains($0.id) }.count
            let orphaned = try payloads.pendingCount - linked
            return records.filter(\.isPending).count + orphaned
        }
    }

    public func prepare(item: String, parent: String, path: RelativePath, baseVersion: String,
                        failOnConflict: Bool, contents: URL, progress: Progress,
                        checkSpace: ((Int64) throws -> Void)? = nil) throws -> PendingEdit {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID,
              ReaderMessage.isItemID(parent), !path.isRoot, baseVersion.utf8.count <= 128,
              let name = path.components.last else { throw UploadError.invalidRequest }
        let input = try ReadOnlyFile(url: contents, allowMaterialization: true)
        guard input.filesystem.isLocal else { throw UploadError.invalidRequest }
        let digest = try input.checksum(range: ByteRange(offset: 0, length: input.snapshot.size, fileSize: input.snapshot.size))
        let metadata = try Self.metadataDigest(input.descriptor)
        try input.validateUnchanged()
        let existing = try records().first {
            $0.item == item && $0.parent == parent && $0.path == path.string && $0.baseVersion == baseVersion
                && $0.digest == digest && $0.localMetadataDigest == metadata
                && $0.size == input.snapshot.size && $0.failOnConflict == failOnConflict
        }
        if let existing {
            if existing.isPending { try validateContents(existing) }
            return existing
        }
        let request = try CreateRequest(template: item + ":" + baseVersion + ":" + digest + ":" + metadata + ":" + String(failOnConflict),
                                        parent: parent, name: name, kind: .file, staging: nil)
        let payload = try payloads.prepare(request, path: path, contents: contents, progress: progress, checkSpace: checkSpace)
        guard payload.digest == digest, payload.size == input.snapshot.size else { throw UploadError.unresolved }
        let prefix = path.components.dropLast().joined(separator: "/")
        func artifact(_ suffix: String) -> String {
            (prefix.isEmpty ? "" : prefix + "/") + ".tinymounter-\(payload.id.uuidString)." + suffix
        }
        let record = PendingEdit(id: payload.id, item: item, parent: parent, path: path.string,
                                 baseVersion: baseVersion, size: payload.size, digest: payload.digest,
                                 failOnConflict: failOnConflict, localMetadataDigest: metadata, stagePath: artifact("stage"),
                                 recoveryPath: artifact("recovery"), destination: path.string)
        let target = contentURL(record)
        guard chmod(target.path, 0o600) == 0 else { throw posixError("prepare edit metadata") }
        let fd = open(target.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open pending edit metadata") }
        defer { close(fd) }
        guard fcopyfile(input.descriptor, fd, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
            throw posixError("copy pending edit metadata")
        }
        try input.validateUnchanged()
        guard try Self.metadataDigest(fd) == metadata else { throw UploadError.unresolved }
        guard fchmod(fd, 0o400) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("sync pending edit") }
        try save(record)
        return record
    }

    public func contentURL(_ record: PendingEdit) -> URL {
        directory.appending(path: "Contents/\(record.id.uuidString).data", directoryHint: .notDirectory)
    }

    public func validateContents(_ record: PendingEdit) throws {
        let file = try ReadOnlyFile(url: contentURL(record))
        guard file.snapshot.size == record.size,
              try file.checksum(range: ByteRange(offset: 0, length: record.size, fileSize: record.size)) == record.digest,
              try Self.metadataDigest(file.descriptor) == record.localMetadataDigest else {
            throw UploadError.unresolved
        }
        try file.validateUnchanged()
    }

    public func save(_ record: PendingEdit) throws {
        try persist(record, id: record.id, extension: "edit", exclusive: false)
    }

    public func storeBase(_ receipt: EditBaseReceipt) throws {
        try persist(receipt, id: receipt.id, extension: "base", exclusive: true)
    }

    public func base(item: String, contentVersion: String) throws -> EditBaseReceipt? {
        guard contentVersion.hasPrefix("e1:"), let id = UUID(uuidString: String(contentVersion.dropFirst(3))),
              contentVersion == "e1:" + id.uuidString else { return nil }
        let url = directory.appending(path: id.uuidString + ".base")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONDecoder().decode(EditBaseReceipt.self, from: Data(contentsOf: url))
        guard receipt.id == id, receipt.item == item, receipt.version.identity.fileID != 0,
              receipt.version.identity.birthMicroseconds != 0, receipt.version.size >= 0,
              EditFileVersion.validDigest(receipt.version.digest), !receipt.version.security.isEmpty else {
            throw UploadError.unresolved
        }
        return receipt
    }

    public func complete(_ record: inout PendingEdit, item: String) throws {
        guard record.state == .published || record.state == .completed,
              let receipt = record.published, receipt.item == item,
              receipt.version.identity == record.stageIdentity,
              receipt.version.size == record.size, receipt.version.digest == record.digest else {
            throw UploadError.unresolved
        }
        try storeBase(receipt)
        record.completedItem = item
        record.state = .completed
        try save(record)
        guard var payload = try payloads.records().first(where: { $0.id == record.id }) else {
            throw UploadError.unresolved
        }
        if payload.state != .completed { try payloads.complete(&payload, item: item) }
    }

    public func removeIfCompleted() throws {
        guard try pendingCount == 0, !(try records()).contains(where: \.recoveryRetained) else {
            throw UploadError.pendingWrites
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func files(ending suffix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == suffix }
    }

    private static func metadataDigest(_ fd: Int32) throws -> String {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw posixError("inspect edit metadata") }
        var names = [CChar](repeating: 0, count: size)
        guard flistxattr(fd, &names, size, 0) == size else { throw UploadError.unresolved }
        var metadata: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = fgetxattr(fd, name, nil, 0, 0, 0)
            guard length >= 0 else { throw posixError("inspect edit attribute") }
            var value = Data(count: length)
            let count = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
            guard count == length else { throw UploadError.unresolved }
            metadata[name] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(metadata)).map { String(format: "%02x", $0) }.joined()
    }

    private func persist<Value: Encodable>(_ value: Value, id: UUID, extension suffix: String, exclusive: Bool) throws {
        let final = directory.appending(path: id.uuidString + "." + suffix)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        if exclusive, FileManager.default.fileExists(atPath: final.path) {
            guard try Data(contentsOf: final) == data else { throw UploadError.unresolved }
            return
        }
        let temporary = directory.appending(path: UUID().uuidString + ".new")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create edit record") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write edit record") }
                offset += written
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("sync edit record") }
        let result = exclusive ? renamex_np(temporary.path, final.path, UInt32(RENAME_EXCL))
            : rename(temporary.path, final.path)
        guard result == 0 else { throw posixError("publish edit record") }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError("open edit directory") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw posixError("sync edit directory") }
    }
}
