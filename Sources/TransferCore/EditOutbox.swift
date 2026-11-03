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
        case copying, restoring, publishing, published, cleaningUp, completed, retired
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
    public let documentMetadataDigest: String
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
    /// Arrival order in this outbox.
    public var sequence: UInt64
    public var retiredStageRemoved: Bool?
    public var retiredBackupRemoved: Bool?
    public var retiredCleanupStarted: Bool?
    public var conflictNoticeDismissed = false
    // Nil means no removal is required; false keeps an unconfirmed artifact pending.
    public var completedStageRemoved: Bool?
    public var completedBackupRemoved: Bool?
    public var completedCleanupStarted: Bool?

    public var isPending: Bool { state != .completed || recoveryRetained }
    public var isPublicationComplete: Bool { state == .completed || state == .cleaningUp }
    public var publishedIdentity: EditFileIdentity? { conflict ? stageIdentity : previous?.identity }
    public var workPath: String { String(recoveryPath.dropLast("recovery".count)) + "work" }
    public var hasStartedPublication: Bool {
        [.movingOriginal, .copying, .restoring, .publishing, .published].contains(state)
    }
    public var mayHaveChangedOriginal: Bool { !conflict && hasStartedPublication }
    public var isLocalOnly: Bool { [.preparing, .prepared].contains(state) }
    var retiredNeedsBackup: Bool { previous != nil || backupIdentity != nil || backupVersion != nil }
    var retiredArtifactsRemoved: Bool {
        retiredStageRemoved == true && (!retiredNeedsBackup || retiredBackupRemoved == true)
    }
    var hasCompletedCleanup: Bool {
        state == .cleaningUp || completedStageRemoved != nil || completedBackupRemoved != nil
            || completedCleanupStarted != nil
    }
    var completedArtifactsRemoved: Bool { completedStageRemoved != false && completedBackupRemoved != false }
    var validCompletedProgress: Bool {
        guard hasCompletedCleanup else { return true }
        guard isPublicationComplete, let published, published.item == completedItem,
              published.version.identity == publishedIdentity,
              published.version.size == size, published.version.digest == digest,
              !conflict || completedStageRemoved == nil else { return false }
        if !conflict, stageIdentity != nil || stageVersion != nil {
            guard completedStageRemoved != nil else { return false }
        }
        if backupIdentity != nil || backupVersion != nil {
            guard completedBackupRemoved != nil else { return false }
        }
        if completedStageRemoved == true {
            guard stageVersion.map({ $0.identity == stageIdentity && $0.size == size && $0.digest == digest }) == true
            else { return false }
        }
        if completedBackupRemoved == true {
            guard backupVersion.map({ $0.identity == backupIdentity }) == true else { return false }
        }
        guard completedCleanupStarted != true || completedArtifactsRemoved else { return false }
        return state == .cleaningUp ? recoveryRetained : !recoveryRetained && completedCleanupStarted == true
    }

    var validRetiredProgress: Bool {
        if retiredStageRemoved == nil, retiredBackupRemoved == nil, retiredCleanupStarted == nil { return true }
        guard state == .retired, recoveryRetained, published == nil, completedItem == nil else { return false }
        // Without an identity, an acknowledgement records an exclusive create that found the name free.
        if retiredStageRemoved == true, stageIdentity != nil || stageVersion != nil {
            guard stageVersion.map({ $0.identity == stageIdentity && $0.size == size && $0.digest == digest }) == true
            else { return false }
        }
        if retiredBackupRemoved == true {
            guard let previous, backupIdentity == nil && backupVersion == nil || backupVersion.map({
                $0.identity == backupIdentity && $0.size == previous.size && $0.digest == previous.digest
            }) == true else { return false }
        }
        return retiredCleanupStarted != true || retiredArtifactsRemoved
    }
}

/// One file's unfinished generations, ordered only as far as evidence allows.
public struct EditOrder: Equatable, Sendable {
    /// The newest completely staged generation; nil when it already completed.
    public var head: PendingEdit?
    /// Generations whose publication may have started; they resolve before the head.
    public var predecessors: [PendingEdit] = []
    /// Proven-earlier generations that must never publish.
    public var superseded: [PendingEdit] = []
}

/// Serialized by the location's mutation lane; complete and uncertain saves stay recoverable.
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
                  EditFileVersion.validDigest(record.documentMetadataDigest),
                  record.baseVersion.utf8.count <= 128,
                  let path = RelativePath(record.path), !path.isRoot,
                  let stage = RelativePath(record.stagePath), let recovery = RelativePath(record.recoveryPath),
                  let destination = RelativePath(record.destination),
                  stage.components.dropLast() == path.components.dropLast(),
                  recovery.components.dropLast() == path.components.dropLast(),
                  destination.components.dropLast() == path.components.dropLast(),
                  stage.components.last == ".tinymounter-\(record.id.uuidString).stage",
                  recovery.components.last == ".tinymounter-\(record.id.uuidString).recovery",
                  !destination.isRoot, record.sequence != 0,
                  record.validRetiredProgress, record.validCompletedProgress else {
                throw UploadError.invalidRequest
            }
            return record
        }.sorted(by: Self.arrival)
    }

    /// Listing order only; generation order comes from order(item:).
    private static func arrival(_ first: PendingEdit, _ second: PendingEdit) -> Bool {
        (first.sequence, first.id.uuidString) < (second.sequence, second.id.uuidString)
    }

    public func order(item: String) throws -> EditOrder {
        var all = try records()
        let sequences = all.filter { $0.item == item }.map(\.sequence)
        guard Set(sequences).count == sequences.count else { throw UploadError.unresolved }
        // A crash can leave complete newer bytes behind a preparing record.
        let preparing = all.filter { $0.item == item && $0.state == .preparing }
        if !preparing.isEmpty {
            try recoverPreparations(preparing)
            all = try records()
        }
        let generations = all.filter { $0.item == item && $0.state != .retired }
        let unfinished = generations.filter { !$0.isPublicationComplete }
        var order = EditOrder()
        let earlier: [PendingEdit]
        let latest = generations.last(where: { $0.state != .preparing })
        if let latest, !latest.isPublicationComplete {
            order.head = latest
            earlier = unfinished.filter { $0.id != latest.id && $0.sequence < latest.sequence }
        } else {
            earlier = unfinished.filter { $0.sequence < latest?.sequence ?? 0 }
        }
        for record in earlier {
            if record.hasStartedPublication { order.predecessors.append(record) }
            else { order.superseded.append(record) }
        }
        return order
    }

    // Only proven earlier publications can explain a changed original without an external conflict.
    public func ownPublications(before record: PendingEdit) throws -> [EditFileVersion] {
        guard !record.isPublicationComplete else { return [] }
        return try records().filter { earlier in
            earlier.id != record.id && earlier.item == record.item && earlier.parent == record.parent
                && earlier.path == record.path && earlier.baseVersion == record.baseVersion
                && earlier.isPublicationComplete && !earlier.conflict && earlier.published?.item == record.item
                && earlier.sequence < record.sequence
        }.compactMap { $0.published?.version }
    }

    /// Removes a superseded generation that never reached the server, once a newer one is durable.
    public func discard(_ record: PendingEdit) throws {
        let order = try self.order(item: record.item)
        guard let current = order.superseded.first(where: { $0.id == record.id }), current.isLocalOnly,
              current.stageIdentity == nil, current.backupIdentity == nil else { throw UploadError.unresolved }
        if let head = order.head { try validateContents(head) }
        try payloads.discardUnpublishedPayload(current.id)
        try removeLocalRecord(current)
    }

    private func removeLocalRecord(_ record: PendingEdit) throws {
        let metadata = directory.appending(path: record.id.uuidString + ".metadata")
        guard unlink(metadata.path) == 0 || errno == ENOENT else { throw posixError("discard local edit metadata") }
        // The record goes last, so an interrupted discard is retried rather than orphaning a payload.
        guard unlink(directory.appending(path: record.id.uuidString + ".edit").path) == 0 || errno == ENOENT else {
            throw posixError("discard local edit record")
        }
        try Self.syncDirectory(directory)
    }

    private func recoverPreparations(_ records: [PendingEdit]) throws {
        for var record in records {
            guard record.stageIdentity == nil, record.stageVersion == nil,
                  record.backupIdentity == nil, record.backupVersion == nil, record.previous == nil,
                  record.published == nil, record.completedItem == nil, !record.conflict,
                  !record.recoveryRetained, record.destination == record.path else { throw UploadError.unresolved }
            if try payloads.recoverLocalPreparation(record.id, size: record.size, digest: record.digest) {
                try validateContents(record)
                record.state = .prepared
                try save(record)
            } else {
                try removeLocalRecord(record)
            }
        }
    }

    /// Retains uncertain private artifacts without letting this superseded save publish again.
    public func retainSuperseded(_ record: inout PendingEdit) throws {
        let order = try self.order(item: record.item)
        guard var stored = order.superseded.first(where: { $0.id == record.id }),
              [.creatingStage, .staged, .creatingBackup, .backedUp].contains(stored.state),
              stored.published == nil, stored.completedItem == nil,
              let head = order.head else { throw UploadError.unresolved }
        try validateContents(head)
        try validateContents(stored)
        stored.state = .retired
        stored.recoveryRetained = true
        try save(stored)
        record = stored
    }

    func retiredRecord(_ record: PendingEdit) throws -> PendingEdit {
        let all = try records()
        guard record.state == .retired,
              let stored = all.first(where: { $0.id == record.id && $0.item == record.item }),
              stored.state == .retired, stored.recoveryRetained,
              stored.published == nil, stored.completedItem == nil else { throw UploadError.unresolved }
        return stored
    }

    func requireRetiredSuccessor(_ record: PendingEdit) throws {
        let order = try order(item: record.item)
        guard order.predecessors.isEmpty else { throw UploadError.unresolved }
        if let head = order.head {
            guard record.sequence < head.sequence,
                  head.parent == record.parent, head.path == record.path else { throw UploadError.unresolved }
            try validateContents(head)
            return
        }
        guard let completed = try records().last(where: {
                  $0.item == record.item && $0.isPublicationComplete && $0.sequence > record.sequence
              }), completed.parent == record.parent, completed.path == record.path,
              let receipt = completed.published, receipt.item == completed.completedItem,
              receipt.version.identity == completed.publishedIdentity,
              receipt.version.size == completed.size, receipt.version.digest == completed.digest,
              try base(item: receipt.item, contentVersion: receipt.contentVersion) == receipt else {
            throw UploadError.unresolved
        }
    }

    // Retired progress can add proof and acknowledgements, but never reactivate publication.
    func saveRetiredProgress(_ record: PendingEdit) throws {
        let stored = try retiredRecord(record)
        guard record.validRetiredProgress,
              stored.stageVersion.map({ $0 == record.stageVersion }) != false,
              stored.backupVersion.map({ $0 == record.backupVersion }) != false,
              stored.retiredStageRemoved != true || record.retiredStageRemoved == true,
              stored.retiredBackupRemoved != true || record.retiredBackupRemoved == true,
              stored.retiredCleanupStarted != true || record.retiredCleanupStarted == true else {
            throw UploadError.unresolved
        }
        if let stage = record.stageVersion {
            guard stage.identity == stored.stageIdentity, stage.size == stored.size, stage.digest == stored.digest else {
                throw UploadError.unresolved
            }
        }
        if let backup = record.backupVersion {
            guard let previous = stored.previous, backup.identity == stored.backupIdentity,
                  backup.size == previous.size, backup.digest == previous.digest else { throw UploadError.unresolved }
        }
        var permitted = stored
        permitted.stageVersion = record.stageVersion
        permitted.backupVersion = record.backupVersion
        permitted.retiredStageRemoved = record.retiredStageRemoved
        permitted.retiredBackupRemoved = record.retiredBackupRemoved
        permitted.retiredCleanupStarted = record.retiredCleanupStarted
        guard permitted == record else { throw UploadError.unresolved }
        if record.retiredCleanupStarted == true {
            try requireRetiredSuccessor(stored)
            if stored.retiredCleanupStarted != true { try validateContents(stored) }
        }
        try persist(record, id: record.id, extension: "edit", exclusive: false)
    }

    func discardRetired(_ record: PendingEdit) throws {
        let stored = try retiredRecord(record)
        guard stored.retiredCleanupStarted == true else { throw UploadError.unresolved }
        try requireRetiredSuccessor(stored)
        try payloads.discardUnpublishedPayload(stored.id)
        try removeLocalRecord(stored)
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

    public var contentBytes: Int64 { get throws { try payloads.contentBytes } }

    public func dismissConflictNotice(id: UUID) throws {
        guard var record = try records().first(where: { $0.id == id }),
              record.state == .completed, record.conflict, !record.recoveryRetained else {
            throw UploadError.unresolved
        }
        record.conflictNoticeDismissed = true
        try persist(record, id: record.id, extension: "edit", exclusive: false)
    }

    // Callers must deliver current contents in order; no callback identity can detect stale replay.
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
        let all = try records()
        let highest = all.map(\.sequence).max() ?? 0
        guard highest < UInt64.max else { throw UploadError.unresolved }
        let generations = all.filter { $0.item == item && $0.state != .retired }
        let replays = { (record: PendingEdit) in
            record.parent == parent && record.path == path.string && record.baseVersion == baseVersion
                && record.digest == digest && (record.localMetadataDigest == metadata
                    || record.documentMetadataDigest == documentMetadata)
                && record.size == input.snapshot.size && record.failOnConflict == failOnConflict
        }
        // Returning to older contents is a new save; only the proven newest generation is a replay.
        let newest = generations.last.flatMap { last in
            generations.dropLast().last?.sequence != last.sequence ? last : nil
        }
        // A retry before publication can use fresh private names and retain the interrupted attempt.
        let needsFreshAttempt: [PendingEdit.State] = [.creatingStage, .staged, .creatingBackup, .backedUp]
        let existing = newest.flatMap { replays($0) && !needsFreshAttempt.contains($0.state) ? $0 : nil }
        if let existing, existing.state != .preparing {
            if existing.isPending, !existing.isPublicationComplete { try validateContents(existing) }
            return existing
        }
        // Admission can wait behind other work after the caller reserves its space.
        try checkSpace?(0)
        let storedPayload = try existing.flatMap { existing in try payloads.records().first { $0.id == existing.id } }
        let id = existing?.id ?? UUID()
        // A per-generation template keeps a return to earlier contents from reusing that payload.
        let template = storedPayload?.template ?? [item, baseVersion, digest, documentMetadata,
                                                   String(failOnConflict), id.uuidString].joined(separator: ":")
        let request = try CreateRequest(template: template,
                                        parent: parent, name: name, kind: .file, staging: nil)
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
                                 recoveryPath: artifact("recovery"), state: .preparing, destination: path.string,
                                 sequence: existing?.sequence ?? highest + 1)
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
        let url = directory.appending(path: record.id.uuidString + ".edit")
        if FileManager.default.fileExists(atPath: url.path) {
            let stored = try JSONDecoder().decode(PendingEdit.self, from: Data(contentsOf: url))
            guard stored.state != .retired || record == stored else { throw UploadError.unresolved }
            if stored.hasCompletedCleanup {
                guard record == stored else { throw UploadError.unresolved }
                return
            }
        }
        guard !record.hasCompletedCleanup else { throw UploadError.unresolved }
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
        guard let stored = try records().first(where: { $0.id == record.id && $0.item == record.item }),
              stored.state != .retired else { throw UploadError.unresolved }
        if stored.isPublicationComplete || stored.state == .published {
            record = stored
        }
        guard record.state == .published || record.isPublicationComplete,
              let receipt = record.published, receipt.item == item,
              receipt.version.identity == record.publishedIdentity,
              receipt.version.size == record.size, receipt.version.digest == record.digest else {
            throw UploadError.unresolved
        }
        if record.isPublicationComplete {
            guard record.completedItem == item else { throw UploadError.unresolved }
            try reloadCompletedCleanup(&record)
            if record.state == .cleaningUp, record.completedArtifactsRemoved {
                try finishCompletedCleanup(&record)
            }
            return
        }
        try storeBase(receipt)
        record.completedItem = item
        try startCompletedCleanup(&record)
        if record.completedArtifactsRemoved { try finishCompletedCleanup(&record) }
    }

    func reloadCompletedCleanup(_ record: inout PendingEdit) throws {
        record = try completedCleanupRecord(record)
    }

    private func completedCleanupRecord(_ record: PendingEdit) throws -> PendingEdit {
        guard let stored = try records().first(where: { $0.id == record.id && $0.item == record.item }),
              stored.isPublicationComplete, let receipt = stored.published,
              receipt.item == stored.completedItem, receipt.version.identity == stored.publishedIdentity,
              receipt.version.size == stored.size, receipt.version.digest == stored.digest,
              try base(item: receipt.item, contentVersion: receipt.contentVersion) == receipt else {
            throw UploadError.unresolved
        }
        return stored
    }

    private func startCompletedCleanup(_ record: inout PendingEdit) throws {
        let stage = !record.conflict && (record.recoveryRetained || record.stageIdentity != nil
            || record.stageVersion != nil || record.backupIdentity != nil || record.backupVersion != nil)
        let backup = record.backupIdentity != nil || record.backupVersion != nil
            || (record.conflict && record.recoveryRetained)
        record.completedStageRemoved = stage ? false : nil
        record.completedBackupRemoved = backup ? false : nil
        record.completedCleanupStarted = nil
        record.state = .cleaningUp
        record.recoveryRetained = true
        guard record.validCompletedProgress else { throw UploadError.unresolved }
        try persist(record, id: record.id, extension: "edit", exclusive: false)
    }

    func saveCompletedProgress(_ record: PendingEdit) throws {
        let stored = try completedCleanupRecord(record)
        guard stored.state == .cleaningUp, record.state == .cleaningUp, record.validCompletedProgress,
              stored.completedStageRemoved == record.completedStageRemoved
                || (stored.completedStageRemoved == false && record.completedStageRemoved == true),
              stored.completedBackupRemoved == record.completedBackupRemoved
                || (stored.completedBackupRemoved == false && record.completedBackupRemoved == true),
              stored.completedCleanupStarted == record.completedCleanupStarted
                || (stored.completedCleanupStarted == nil && record.completedCleanupStarted == true) else {
            throw UploadError.unresolved
        }
        var permitted = stored
        permitted.completedStageRemoved = record.completedStageRemoved
        permitted.completedBackupRemoved = record.completedBackupRemoved
        permitted.completedCleanupStarted = record.completedCleanupStarted
        guard permitted == record else { throw UploadError.unresolved }
        if record.completedCleanupStarted == true, stored.completedCleanupStarted != true {
            try validateContents(stored)
        }
        try persist(record, id: record.id, extension: "edit", exclusive: false)
    }

    func finishCompletedCleanup(_ record: inout PendingEdit) throws {
        record = try completedCleanupRecord(record)
        if record.state == .completed, !record.recoveryRetained { return }
        guard record.state == .cleaningUp, record.completedArtifactsRemoved else { throw UploadError.unresolved }
        if record.completedCleanupStarted != true {
            var terminal = record
            terminal.completedCleanupStarted = true
            try saveCompletedProgress(terminal)
            record = terminal
        }
        try payloads.discardUnpublishedPayload(record.id)
        let metadata = directory.appending(path: record.id.uuidString + ".metadata")
        guard unlink(metadata.path) == 0 || errno == ENOENT else { throw posixError("remove completed edit metadata") }
        var completed = record
        completed.state = .completed
        completed.recoveryRetained = false
        try persist(completed, id: completed.id, extension: "edit", exclusive: false)
        record = completed
    }

    public func removeIfCompleted() throws {
        guard try pendingCount == 0, !(try records()).contains(where: \.recoveryRetained) else {
            throw UploadError.pendingWrites
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// The save never reached the server, so removing the location loses nothing that macOS does not keep.
    public static func canStopForRemoval(_ record: PendingEdit) -> Bool {
        record.isLocalOnly && record.stageIdentity == nil && record.backupIdentity == nil && record.published == nil
            && !record.recoveryRetained
    }

    /// Location removal after macOS kept the local copies of saves that never reached the server.
    public func removeForLocationRemoval() throws {
        let records = try records()
        let pending = records.filter(\.isPending)
        guard pending.allSatisfy(Self.canStopForRemoval), try pendingCount == pending.count,
              !records.contains(where: \.recoveryRetained) else { throw UploadError.pendingWrites }
        try FileManager.default.removeItem(at: directory)
    }

    private func files(ending suffix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == suffix }
    }

    private static func metadataDigest(_ fd: Int32) throws -> String {
        try metadataDigest(metadata(fd))
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
        try Self.syncDirectory(directory)
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open edit directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError("sync edit directory") }
    }
}
