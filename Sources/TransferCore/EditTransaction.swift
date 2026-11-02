import Foundation

public protocol EditRemote {
    func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion
    func inspect(path: String, original: Bool) throws -> EditFileVersion?
    func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion
    func move(source: String, destination: String) throws
    func update(work: String, stage: String, size: Int64) throws
    func removeArtifact(path: String, version: EditFileVersion) throws
}

/// The server answered the stage create with an error, and a lookup on the same connection found
/// nothing at the stage name, so the save did not reach the server.
public struct EditStageRefusal: Error {
    public let error: Error
    public init(_ error: Error) { self.error = error }
}

/// Every mutation follows durable intent; recovery never repeats an uncertain content write.
public enum EditTransaction {
    public static func publish(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        if let completed = try outbox.records().first(where: {
            $0.id == record.id && $0.item == record.item && $0.isPublicationComplete
        }) {
            record = completed
            return
        }
        try outbox.validateContents(record)
        let order = try outbox.order(item: record.item)
        guard order.head?.id == record.id || order.predecessors.contains(where: { $0.id == record.id }) else {
            throw UploadError.unresolved
        }
        if record.hasStartedPublication {
            try recover(&record, outbox: outbox, remote: remote)
            return
        }
        guard order.head?.id == record.id else { throw UploadError.unresolved }
        // Earlier generations resolve first: some may have reached the server; order(item:) needs it.
        guard order.predecessors.isEmpty, order.superseded.isEmpty else { throw UploadError.pendingWrites }
        if record.state == .prepared {
            record.state = .creatingStage
            try outbox.save(record)
            let version: EditFileVersion
            do {
                version = try remote.stage(path: record.stagePath, contents: outbox.contentURL(record)) { identity in
                    record.stageIdentity = identity
                    try outbox.save(record)
                }
            } catch let refusal as EditStageRefusal where record.stageIdentity == nil {
                record.state = .prepared
                try outbox.save(record)
                throw refusal.error
            }
            guard matchesEdit(version, record), version.identity == record.stageIdentity else {
                throw UploadError.unresolved
            }
            record.stageVersion = version
            record.state = .staged
            try outbox.save(record)
        } else {
            guard let stage = try remote.inspect(path: record.stagePath, original: false),
                  stage.identity == record.stageIdentity, matchesEdit(stage, record) else {
                throw UploadError.unresolved
            }
            record.stageVersion = stage
            if record.state == .creatingStage { record.state = .staged }
            try outbox.save(record)
        }
        let original = try remote.inspect(path: record.path, original: true)
        let base = try outbox.base(item: record.item, contentVersion: record.baseVersion)
        // The app's own earlier save on this base is the newer save's predecessor, not a conflict.
        let accepted = try [base?.version].compactMap { $0 } + outbox.ownPublications(before: record)
        guard let original, accepted.contains(where: {
            original.hasSameContents(as: $0) && original.modifiedMicroseconds == $0.modifiedMicroseconds
        }) else {
            guard record.state == .staged else { throw UploadError.unresolved }
            try publishConflict(&record, outbox: outbox, remote: remote)
            return
        }
        record.previous = original
        if record.state == .staged {
            record.state = .creatingBackup
            try outbox.save(record)
            let backup = try remote.backup(original: record.path, path: record.recoveryPath) { identity in
                record.backupIdentity = identity
                try outbox.save(record)
            }
            guard backup.identity == record.backupIdentity, backup.size == original.size,
                  backup.digest == original.digest else { throw UploadError.unresolved }
            record.backupVersion = backup
        } else {
            guard let backup = try remote.inspect(path: record.recoveryPath, original: false),
                  backup.identity == record.backupIdentity, backup.size == original.size,
                  backup.digest == original.digest else { throw UploadError.unresolved }
            record.backupVersion = backup
        }
        record.state = .backedUp
        try outbox.save(record)
        record.state = .movingOriginal
        try outbox.save(record)
        try remote.move(source: record.path, destination: record.workPath)
        record.state = .copying
        try outbox.save(record)
        try remote.update(work: record.workPath, stage: record.stagePath, size: record.size)
        guard let updated = try remote.inspect(path: record.workPath, original: true),
              updated.identity == record.previous?.identity, matchesEdit(updated, record) else {
            throw UploadError.unresolved
        }
        record.state = .publishing
        try outbox.save(record)
        try remote.move(source: record.workPath, destination: record.path)
        try verifyPublication(&record, outbox: outbox, remote: remote)
    }

    public static func recover(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        let order = try outbox.order(item: record.item)
        guard record.hasStartedPublication,
              order.head?.id == record.id || order.predecessors.contains(where: { $0.id == record.id }) else {
            throw UploadError.unresolved
        }
        if record.conflict, record.failOnConflict { throw UploadError.editConflict }
        if let final = try remote.inspect(path: record.destination, original: !record.conflict) {
            if record.conflict, final.identity != record.stageIdentity {
                guard let stage = try remote.inspect(path: record.stagePath, original: false),
                      stage.identity == record.stageIdentity, matchesEdit(stage, record) else {
                    throw UploadError.unresolved
                }
                try chooseConflictName(&record, outbox: outbox)
                try moveConflict(&record, outbox: outbox, remote: remote)
                return
            }
            if !record.conflict, let previous = record.previous, final.hasSameContents(as: previous),
               !matchesEdit(final, record), record.state != .published {
                record.state = .backedUp
                try outbox.save(record)
                throw UploadError.unresolved
            }
            guard final.identity == record.publishedIdentity, matchesEdit(final, record) else {
                throw UploadError.unresolved
            }
            try markPublished(&record, version: final, outbox: outbox)
            return
        }
        if record.conflict {
            guard let stage = try remote.inspect(path: record.stagePath, original: false),
                  stage.identity == record.stageIdentity, matchesEdit(stage, record) else {
                throw UploadError.unresolved
            }
            try moveConflict(&record, outbox: outbox, remote: remote)
            return
        }
        guard let old = record.previous, let work = try remote.inspect(path: record.workPath, original: true),
              work.identity == old.identity else { throw UploadError.unresolved }
        let isNew = matchesEdit(work, record)
        guard isNew || work.hasSameContents(as: old) else { throw UploadError.unresolved }
        record.state = .restoring
        try outbox.save(record)
        try remote.move(source: record.workPath, destination: record.path)
        if isNew {
            try verifyPublication(&record, outbox: outbox, remote: remote)
        } else {
            record.state = .backedUp
            try outbox.save(record)
            throw UploadError.unresolved
        }
    }

    public static func cleanup(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        try outbox.reloadCompletedCleanup(&record)
        if record.state == .completed { return }
        if record.completedCleanupStarted == true {
            try outbox.finishCompletedCleanup(&record)
            return
        }
        try outbox.validateContents(record)
        if record.completedStageRemoved == false {
            guard let stage = record.stageVersion, stage.identity == record.stageIdentity,
                  matchesEdit(stage, record),
                  try remote.inspect(path: record.stagePath, original: false) == stage else {
                throw UploadError.unresolved
            }
        }
        if record.completedBackupRemoved == false {
            guard let backup = record.backupVersion, backup.identity == record.backupIdentity,
                  try remote.inspect(path: record.recoveryPath, original: false) == backup else {
                throw UploadError.unresolved
            }
        }
        if record.completedStageRemoved == false {
            guard let stage = record.stageVersion else { throw UploadError.unresolved }
            try remote.removeArtifact(path: record.stagePath, version: stage)
            var acknowledged = record
            acknowledged.completedStageRemoved = true
            try outbox.saveCompletedProgress(acknowledged)
            record = acknowledged
        }
        if record.completedBackupRemoved == false {
            guard let backup = record.backupVersion else { throw UploadError.unresolved }
            try remote.removeArtifact(path: record.recoveryPath, version: backup)
            var acknowledged = record
            acknowledged.completedBackupRemoved = true
            try outbox.saveCompletedProgress(acknowledged)
            record = acknowledged
        }
        try outbox.finishCompletedCleanup(&record)
    }

    // Retirement uses recorded complete versions, never a fresh version of changed contents.
    public static func retire(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        guard let stored = try outbox.order(item: record.item).superseded.first(where: { $0.id == record.id }) else {
            throw UploadError.unresolved
        }
        record = stored
        if !record.isLocalOnly {
            // Without a recorded identity, the create request may still have reached the server.
            guard let stageVersion = record.stageVersion, stageVersion.identity == record.stageIdentity,
                  matchesEdit(stageVersion, record) else { throw UploadError.unresolved }
            guard let stage = try remote.inspect(path: record.stagePath, original: false),
                  stage == stageVersion else { throw UploadError.unresolved }
            if [.creatingBackup, .backedUp].contains(record.state) {
                guard let backupVersion = record.backupVersion, backupVersion.identity == record.backupIdentity,
                      let previous = record.previous, backupVersion.size == previous.size,
                      backupVersion.digest == previous.digest else { throw UploadError.unresolved }
                guard try remote.inspect(path: record.recoveryPath, original: false) == backupVersion else {
                    throw UploadError.unresolved
                }
            }
            try outbox.retainSuperseded(&record)
            try cleanupRetired(&record, outbox: outbox, remote: remote)
            return
        }
        try outbox.discard(record)
    }

    /// Inspection must hold artifact protection through removal; an absent name is unconfirmed.
    public static func cleanupRetired(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        record = try outbox.retiredRecord(record)
        try outbox.requireRetiredSuccessor(record)
        if record.retiredCleanupStarted == true {
            try outbox.discardRetired(record)
            return
        }
        try outbox.validateContents(record)
        var proved = record
        if record.retiredStageRemoved != true {
            guard let identity = record.stageIdentity,
                  let stage = try remote.inspect(path: record.stagePath, original: false),
                  stage.identity == identity, matchesEdit(stage, record),
                  record.stageVersion.map({ $0 == stage }) != false else { throw UploadError.unresolved }
            proved.stageVersion = stage
        }
        if record.retiredNeedsBackup, record.retiredBackupRemoved != true {
            guard let identity = record.backupIdentity, let previous = record.previous,
                  let backup = try remote.inspect(path: record.recoveryPath, original: false),
                  backup.identity == identity, backup.size == previous.size, backup.digest == previous.digest,
                  record.backupVersion.map({ $0 == backup }) != false else { throw UploadError.unresolved }
            proved.backupVersion = backup
        }
        if proved != record {
            try outbox.saveRetiredProgress(proved)
            record = proved
        }
        if record.retiredStageRemoved != true {
            guard let stage = record.stageVersion else { throw UploadError.unresolved }
            try remote.removeArtifact(path: record.stagePath, version: stage)
            var acknowledged = record
            acknowledged.retiredStageRemoved = true
            try outbox.saveRetiredProgress(acknowledged)
            record = acknowledged
        }
        if record.retiredNeedsBackup, record.retiredBackupRemoved != true {
            guard let backup = record.backupVersion else { throw UploadError.unresolved }
            try remote.removeArtifact(path: record.recoveryPath, version: backup)
            var acknowledged = record
            acknowledged.retiredBackupRemoved = true
            try outbox.saveRetiredProgress(acknowledged)
            record = acknowledged
        }
        var resolved = record
        resolved.retiredCleanupStarted = true
        try outbox.saveRetiredProgress(resolved)
        record = resolved
        try outbox.discardRetired(record)
    }

    private static func publishConflict(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        record.conflict = true
        try outbox.save(record)
        guard !record.failOnConflict else { throw UploadError.editConflict }
        try chooseConflictName(&record, outbox: outbox)
        try moveConflict(&record, outbox: outbox, remote: remote)
    }

    private static func chooseConflictName(_ record: inout PendingEdit, outbox: EditOutbox) throws {
        let path = URL(fileURLWithPath: record.path)
        let suffix = path.pathExtension.isEmpty ? "" : "." + path.pathExtension
        var stem = path.deletingPathExtension().lastPathComponent
        while stem.utf8.count > 160 { stem.removeLast() }
        let parent = RelativePath(record.path)!.components.dropLast().joined(separator: "/")
        let name = stem + " (conflict " + UUID().uuidString.prefix(8) + ")" + String(suffix.prefix(12))
        record.destination = (parent.isEmpty ? "" : parent + "/") + name
        record.state = .publishing
        try outbox.save(record)
    }

    private static func moveConflict(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        for _ in 0..<8 {
            do {
                try remote.move(source: record.stagePath, destination: record.destination)
            } catch UploadError.collision {
                try chooseConflictName(&record, outbox: outbox)
                continue
            }
            try verifyPublication(&record, outbox: outbox, remote: remote)
            return
        }
        throw UploadError.collision
    }

    private static func verifyPublication(_ record: inout PendingEdit, outbox: EditOutbox,
                                           remote: EditRemote) throws {
        guard let final = try remote.inspect(path: record.destination, original: !record.conflict),
              final.identity == record.publishedIdentity, matchesEdit(final, record) else {
            throw UploadError.unresolved
        }
        try markPublished(&record, version: final, outbox: outbox)
    }

    private static func markPublished(_ record: inout PendingEdit, version: EditFileVersion,
                                      outbox: EditOutbox) throws {
        let item = record.conflict ? record.id.uuidString : record.item
        if record.published?.version != version {
            record.published = try EditBaseReceipt(item: item, version: version)
        }
        record.state = .published
        record.recoveryRetained = !record.conflict || record.backupIdentity != nil
        try outbox.save(record)
    }

    private static func matchesEdit(_ version: EditFileVersion, _ record: PendingEdit) -> Bool {
        version.size == record.size && version.digest == record.digest
    }
}
