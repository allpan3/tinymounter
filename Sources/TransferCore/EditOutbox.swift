import CryptoKit
import Darwin
import Foundation
import OSLog

public struct EditFileIdentity: Codable, Equatable, Sendable {
    public let fileID: UInt64
    public let birthMicroseconds: UInt64

    public init(fileID: UInt64, birthMicroseconds: UInt64) throws {
        guard fileID != 0, birthMicroseconds != 0 else { throw UploadError.unresolved }
        self.fileID = fileID
        self.birthMicroseconds = birthMicroseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fileID: values.decode(UInt64.self, forKey: .fileID),
                      birthMicroseconds: values.decode(UInt64.self, forKey: .birthMicroseconds))
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
    public let artifactQuarantine: Data?

    public init(identity: EditFileIdentity, size: Int64, digest: String, modifiedMicroseconds: UInt64,
                changedMicroseconds: UInt64, attributes: UInt32, security: Data,
                artifactQuarantine: Data? = nil) throws {
        guard size >= 0, Self.validDigest(digest), !security.isEmpty, security.count <= 65_536,
              artifactQuarantine.map({ $0.count <= 65_536 }) != false else {
            throw UploadError.unresolved
        }
        self.identity = identity
        self.size = size
        self.digest = digest
        self.modifiedMicroseconds = modifiedMicroseconds
        self.changedMicroseconds = changedMicroseconds
        self.attributes = attributes
        self.security = security
        self.artifactQuarantine = artifactQuarantine
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: values.decode(EditFileIdentity.self, forKey: .identity),
                      size: values.decode(Int64.self, forKey: .size),
                      digest: values.decode(String.self, forKey: .digest),
                      modifiedMicroseconds: values.decode(UInt64.self, forKey: .modifiedMicroseconds),
                      changedMicroseconds: values.decode(UInt64.self, forKey: .changedMicroseconds),
                      attributes: values.decode(UInt32.self, forKey: .attributes),
                      security: values.decode(Data.self, forKey: .security),
                      artifactQuarantine: values.decodeIfPresent(Data.self, forKey: .artifactQuarantine))
    }

    public func hasSameContents(as other: EditFileVersion) -> Bool {
        identity == other.identity && size == other.size && digest == other.digest
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

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), item: values.decode(String.self, forKey: .item),
                      version: values.decode(EditFileVersion.self, forKey: .version))
    }
}

public struct PendingEdit: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case preparing, prepared, creatingStage, staged, creatingBackup, backedUp, movingOriginal
        case copying, restoring, publishing, published, completed
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
    public var documentMetadataDigest: String? = nil
    public let stagePath: String
    public let recoveryPath: String
    public var state: State = .prepared
    public var stageIdentity: EditFileIdentity?
    public var stageVersion: EditFileVersion?
    public var backupIdentity: EditFileIdentity?
    public var backupVersion: EditFileVersion?
    public var previous: EditFileVersion?
    public var destination: String
    public var published: EditBaseReceipt?
    public var conflict = false
    public var completedItem: String?
    public var recoveryRetained = false

    public var isPending: Bool { state != .completed || recoveryRetained }
    public var publishedIdentity: EditFileIdentity? { conflict ? stageIdentity : previous?.identity }
    public var workPath: String { String(recoveryPath.dropLast("recovery".count)) + "work" }
    public var mayHaveChangedOriginal: Bool {
        !conflict && [.movingOriginal, .copying, .restoring, .publishing, .published].contains(state)
    }
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
                  record.documentMetadataDigest.map(EditFileVersion.validDigest) != false,
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
        let attributes = try Self.metadata(input.descriptor)
        let metadata = try Self.metadataDigest(attributes)
        let documentMetadata = try Self.documentMetadataDigest(attributes)
        try input.validateUnchanged()
        let existing = try records().sorted { !$0.isPending && $1.isPending }.first {
            $0.item == item && $0.parent == parent && $0.path == path.string && $0.baseVersion == baseVersion
                && $0.digest == digest && ($0.localMetadataDigest == metadata
                    || (try? retainedDocumentMetadataDigest($0)) == documentMetadata)
                && $0.size == input.snapshot.size && $0.failOnConflict == failOnConflict
        }
        if let existing, existing.state != .preparing {
            if existing.isPending { try validateContents(existing) }
            return existing
        }
        let storedPayload = try existing.flatMap { existing in try payloads.records().first { $0.id == existing.id } }
        let template = storedPayload?.template
            ?? item + ":" + baseVersion + ":" + digest + ":" + documentMetadata + ":" + String(failOnConflict)
        let request = try CreateRequest(template: template,
                                        parent: parent, name: name, kind: .file, staging: nil)
        let orphan = try payloads.records().first { $0.template == request.template }
        let id = existing?.id ?? orphan?.id ?? UUID()
        let metadataURL = directory.appending(path: id.uuidString + ".metadata")
        let hasMetadata = FileManager.default.fileExists(atPath: metadataURL.path)
        let prefix = path.components.dropLast().joined(separator: "/")
        func artifact(_ suffix: String) -> String {
            (prefix.isEmpty ? "" : prefix + "/") + ".tinymounter-\(id.uuidString)." + suffix
        }
        var record = PendingEdit(id: id, item: item, parent: parent, path: path.string,
                                 baseVersion: baseVersion, size: input.snapshot.size, digest: digest,
                                 failOnConflict: failOnConflict,
                                 localMetadataDigest: hasMetadata ? existing?.localMetadataDigest ?? metadata : metadata,
                                 documentMetadataDigest: documentMetadata, stagePath: artifact("stage"),
                                 recoveryPath: artifact("recovery"), state: .preparing, destination: path.string)
        try save(record)
        if !hasMetadata {
            try persist(attributes, id: id, extension: "metadata", exclusive: true)
        }
        let payload = try payloads.prepare(request, path: path, contents: contents, progress: progress,
                                          checkSpace: checkSpace, id: id)
        guard payload.id == id, payload.digest == digest, payload.size == input.snapshot.size else {
            throw UploadError.unresolved
        }
        let target = contentURL(record)
        guard chmod(target.path, 0o600) == 0 else { throw posixError("prepare edit metadata") }
        let fd = open(target.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open pending edit metadata") }
        defer { close(fd) }
        guard fcopyfile(input.descriptor, fd, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
            throw posixError("copy pending edit metadata")
        }
        try input.validateUnchanged()
        if try Self.metadataDigest(fd) != metadata {
            let source = try Self.metadata(input.descriptor), copied = try Self.metadata(fd)
            let missing = source.keys.filter { copied[$0] == nil }.count
            let changed = source.keys.filter { copied[$0] != nil && copied[$0] != source[$0] }.count
            let extra = copied.keys.filter { source[$0] == nil }.count
            let encoding = source["com.apple.TextEncoding"] != copied["com.apple.TextEncoding"]
            let lastUsed = source["com.apple.lastuseddate#PS"] != copied["com.apple.lastuseddate#PS"]
            let security = ["com.apple.quarantine", "com.apple.macl", "com.apple.provenance"].contains {
                source[$0] != copied[$0]
            }
            Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                .info("edit_metadata_copy missing=\(missing) changed=\(changed) extra=\(extra) encoding=\(encoding) last_used=\(lastUsed) security=\(security)")
        }
        guard fchmod(fd, 0o400) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("sync pending edit") }
        try validateContents(record)
        record.state = .prepared
        try save(record)
        return record
    }

    public func contentURL(_ record: PendingEdit) -> URL {
        directory.appending(path: "Contents/\(record.id.uuidString).data", directoryHint: .notDirectory)
    }

    public func validateContents(_ record: PendingEdit) throws {
        let file = try ReadOnlyFile(url: contentURL(record))
        let metadataDigest = try Self.metadataDigest(retainedMetadata(record, descriptor: file.descriptor))
        guard file.snapshot.size == record.size,
              try file.checksum(range: ByteRange(offset: 0, length: record.size, fileSize: record.size)) == record.digest,
              metadataDigest == record.localMetadataDigest else {
            throw UploadError.unresolved
        }
        try file.validateUnchanged()
    }

    public func export(_ record: PendingEdit, to destination: URL) throws {
        try validateContents(record)
        let source = try ReadOnlyFile(url: contentURL(record))
        let attributes = try retainedMetadata(record, descriptor: source.descriptor)
        try FileManager.default.copyItem(at: contentURL(record), to: destination)
        let fd = open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open exported edit") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw posixError("set exported file access") }
        let copied = try Self.metadata(fd)
        for (name, value) in attributes where copied[name] != value {
            // macOS assigns access and quarantine metadata to the new local file.
            if ["com.apple.macl", "com.apple.quarantine", "com.apple.provenance"].contains(name) { continue }
            let result = value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }
            guard result == 0 else { throw posixError("restore exported metadata") }
        }
        guard fsync(fd) == 0 else { throw posixError("sync exported edit") }
    }

    public func hasResourceFork(_ record: PendingEdit) throws -> Bool {
        let file = try ReadOnlyFile(url: contentURL(record))
        return try retainedMetadata(record, descriptor: file.descriptor)["com.apple.ResourceFork"]?.isEmpty == false
    }

    private func retainedMetadata(_ record: PendingEdit, descriptor: Int32) throws -> [String: Data] {
        let url = directory.appending(path: record.id.uuidString + ".metadata")
        guard FileManager.default.fileExists(atPath: url.path) else { return try Self.metadata(descriptor) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 6_291_456 else { throw UploadError.unresolved }
        return try JSONDecoder().decode([String: Data].self, from: data)
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
              receipt.version.identity == record.publishedIdentity,
              receipt.version.size == record.size, receipt.version.digest == record.digest else {
            throw UploadError.unresolved
        }
        if record.documentMetadataDigest == nil {
            record.documentMetadataDigest = try retainedDocumentMetadataDigest(record)
        }
        try storeBase(receipt)
        record.completedItem = item
        record.state = .completed
        try save(record)
        guard var payload = try payloads.records().first(where: { $0.id == record.id }) else {
            throw UploadError.unresolved
        }
        if payload.state != .completed, !record.recoveryRetained { try payloads.complete(&payload, item: item) }
        if payload.state == .completed, !record.recoveryRetained {
            let metadata = directory.appending(path: record.id.uuidString + ".metadata")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        }
    }

    public func resolveEquivalent(_ record: inout PendingEdit, with completed: PendingEdit) throws {
        guard [.prepared, .staged, .backedUp].contains(record.state),
              completed.state == .completed, !completed.recoveryRetained, !completed.conflict,
              let receipt = completed.published, completed.item == record.item,
              completed.parent == record.parent, completed.path == record.path,
              completed.size == record.size, completed.digest == record.digest,
              try retainedDocumentMetadataDigest(completed) == retainedDocumentMetadataDigest(record) else {
            throw UploadError.unresolved
        }
        try validateContents(record)
        record.previous = receipt.version
        record.published = receipt
        record.conflict = false
        record.destination = record.path
        record.state = .published
        record.recoveryRetained = record.stageIdentity != nil || record.backupIdentity != nil
        try complete(&record, item: record.item)
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
        try metadataDigest(metadata(fd))
    }

    private func retainedDocumentMetadataDigest(_ record: PendingEdit) throws -> String {
        if let digest = record.documentMetadataDigest { return digest }
        let file = try ReadOnlyFile(url: contentURL(record))
        let attributes = try retainedMetadata(record, descriptor: file.descriptor)
        guard try Self.metadataDigest(attributes) == record.localMetadataDigest else { throw UploadError.unresolved }
        return try Self.documentMetadataDigest(attributes)
    }

    private static func documentMetadataDigest(_ attributes: [String: Data]) throws -> String {
        // macOS assigns these attributes per copy; they do not identify a document edit.
        let local = Set(["com.apple.macl", "com.apple.quarantine", "com.apple.provenance"])
        return try metadataDigest(attributes.filter { !local.contains($0.key) })
    }

    private static func metadataDigest(_ attributes: [String: Data]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(attributes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func metadata(_ fd: Int32) throws -> [String: Data] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw posixError("inspect edit metadata") }
        guard size <= 65_536 else { throw UploadError.invalidRequest }
        var names = [CChar](repeating: 0, count: size)
        guard flistxattr(fd, &names, size, 0) == size else { throw UploadError.unresolved }
        var metadata: [String: Data] = [:]
        var total = 0
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let length = fgetxattr(fd, name, nil, 0, 0, 0)
            guard length >= 0 else { throw posixError("inspect edit attribute") }
            guard length <= 1_048_576, total <= 4_194_304 - length else { throw UploadError.invalidRequest }
            total += length
            var value = Data(count: length)
            let count = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
            guard count == length else { throw UploadError.unresolved }
            metadata[name] = value
        }
        return metadata
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
