import Foundation

public protocol EditRemote {
    func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion
    func inspect(path: String, original: Bool) throws -> EditFileVersion?
    func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion
    func move(source: String, destination: String) throws
    func update(work: String, stage: String, size: Int64) throws
    func removeArtifact(path: String, version: EditFileVersion) throws
}

/// Every mutation follows durable intent; recovery never repeats an uncertain content write.
public enum EditTransaction {
    public static func publish(_ record: inout PendingEdit, outbox: EditOutbox, remote: EditRemote) throws {
        if record.state == .completed { return }
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
            let version = try remote.stage(path: record.stagePath, contents: outbox.contentURL(record)) { identity in
                record.stageIdentity = identity
                try outbox.save(record)
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
        guard record.state == .completed, let item = record.completedItem else { throw UploadError.unresolved }
        if !record.conflict, let stage = record.stageVersion {
            try remote.removeArtifact(path: record.stagePath, version: stage)
        }
        if let backup = record.backupVersion {
            try remote.removeArtifact(path: record.recoveryPath, version: backup)
        }
        record.recoveryRetained = false
        try outbox.complete(&record, item: item)
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
            let stage = try remote.inspect(path: record.stagePath, original: false)
            guard stage.map({ $0 == stageVersion }) != false else { throw UploadError.unresolved }
            var backup: EditFileVersion?
            if [.creatingBackup, .backedUp].contains(record.state) {
                guard let backupVersion = record.backupVersion, backupVersion.identity == record.backupIdentity,
                      let previous = record.previous, backupVersion.size == previous.size,
                      backupVersion.digest == previous.digest else { throw UploadError.unresolved }
                backup = try remote.inspect(path: record.recoveryPath, original: false)
                guard backup.map({ $0 == backupVersion }) != false else { throw UploadError.unresolved }
            }
            if let stage { try remote.removeArtifact(path: record.stagePath, version: stage) }
            if let backup { try remote.removeArtifact(path: record.recoveryPath, version: backup) }
            record.state = .prepared
            record.stageIdentity = nil
            record.stageVersion = nil
            record.backupIdentity = nil
            record.backupVersion = nil
            record.previous = nil
            record.conflict = false
            try outbox.save(record)
        }
        try outbox.discard(record)
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
