import Darwin
import Foundation
import OSLog
import UniformTypeIdentifiers

/// M22 folder rename and move; provider routing stays gated until the signed Finder checks pass.
extension LocationSource {
    private static let folderMoveLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    func moveFolder(_ request: FileRenameRequest, progress: Progress,
                    started: @escaping @Sendable () -> Void,
                    reply: @escaping @Sendable (Result<CreateReceipt, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { try moveFolderOnLane(request, progress: progress) }
            Self.folderMoveLog.info("folder_move request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
            if case .failure(let error) = result {
                Self.folderMoveLog.error("folder_move request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
            }
            reply(result)
        }
    }

    private func moveFolderOnLane(_ request: FileRenameRequest, progress: Progress) throws -> CreateReceipt {
        let replayed = try editNamespace.perform { () -> PendingFolderMove? in
            _ = try renameAccess()
            return try Self.renameOutbox().replayFolder(owner: domainID, request: request)
        }
        if let replayed {
            // Completed replay is only a receipt; its settlement must never be applied again.
            let completed = try replayed.isPending ? retryFolderMove(replayed.id) : replayed
            try completed.requireMoved()
            return CreateReceipt(item: request.item)
        }
        let reservation = UUID()
        let planned = try editNamespace.perform { () -> (RelativePath, RelativePath, [LocationSource])? in
            try editNamespace.requireSettled()
            _ = try renameAccess()
            let (source, destination) = try folderMovePaths(request)
            if source.string.utf8.elementsEqual(destination.string.utf8) { return nil }
            let affected = try folderMoveSources(source: source, destination: destination)
            for participant in affected { try participant.prepareRenameFolders(source: source, destination: destination) }
            for participant in affected { try participant.requireFolderMovePathsSettled([source, destination]) }
            editNamespace.reserve(reservation, paths: [source, destination])
            return (source, destination, affected)
        }
        defer { editNamespace.release(reservation) }
        guard case let (source, destination, affected)? = planned else { return CreateReceipt(item: request.item) }
        try drainFolderMove(affected, paths: [source, destination])
        let bookmark = try renameAccess()
        let record = try withWriteSession(bookmark, progress: progress) { session, _ in
            var record = try withFolderMoveRemote(session: session, progress: progress) { remote in
                var record = try admitFolderMove(request, source: source, destination: destination,
                                                 remote: remote, session: session)
                try publishFolderMove(&record, remote: remote)
                return record
            }
            try completeFolderMove(&record, session: session, progress: progress)
            return record
        }
        try record.requireMoved()
        return CreateReceipt(item: request.item)
    }

    /// Resumes a durable intent; while pending it blocks new reads, watches and writes below it.
    @discardableResult
    func retryFolderMove(_ id: UUID) throws -> PendingFolderMove {
        let (record, affected) = try editNamespace.perform { () -> (PendingFolderMove, [LocationSource]) in
            guard case .folder(let record)? = try Self.renameOutbox().intents().first(where: { $0.id == id }),
                  record.owner == domainID else { throw UploadError.unresolved }
            return (record, try record.views.map { try editNamespace.source($0.domain) })
        }
        guard record.isPending else {
            try record.requireMoved()
            return record
        }
        guard let source = RelativePath(record.source), let destination = RelativePath(record.destination) else {
            throw UploadError.unresolved
        }
        try drainFolderMove(affected, paths: [source, destination])
        let bookmark = try renameAccess()
        let progress = Progress()
        return try withWriteSession(bookmark, progress: progress) { session, _ in
            var current = record
            if current.state != .verified && current.state != .recovering {
                try withFolderMoveRemote(session: session, progress: progress) { remote in
                    try publishFolderMove(&current, remote: remote)
                }
            }
            try completeFolderMove(&current, session: session, progress: progress)
            try current.requireMoved()
            return current
        }
    }

    private func folderMovePaths(_ request: FileRenameRequest) throws -> (RelativePath, RelativePath) {
        try withCatalog { catalog in
            guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsWriting, row.kind == .folder,
                  row.contentVersion == request.contentVersion, row.metadataVersion == request.metadataVersion,
                  FileRenameRequest.supportsName(row.name),
                  let parent = try catalog.item(id: request.parent), !parent.deleted, parent.kind == .folder,
                  let relative = try catalog.relativePath(of: row.id), let path = folder.appending(relative),
                  let target = try catalog.relativePath(of: parent.id)?.appending(request.name),
                  let destination = folder.appending(target) else { throw SourceFailure.versionChanged }
            guard ![row.name, request.name].contains(where: {
                UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: .package) == true
            }) else { throw UploadError.readOnly }
            try request.validateUnchangedFields(in: row)
            guard target.components.count <= relative.components.count || !EditNamespace.contains(relative, target) else {
                throw UploadError.invalidRequest
            }
            if let other = try catalog.liveChild(parent: parent.id, nameKey: NameKey(request.name)),
               other.id != row.id { throw UploadError.collision }
            return (path, destination)
        }
    }

    private func folderMoveSources(source: RelativePath, destination: RelativePath) throws -> [LocationSource] {
        // Moving a configured root, or a subtree that holds one, would change that location's identity.
        guard !editNamespace.locationRoots().contains(where: {
            EditNamespace.contains(source, $0) || EditNamespace.contains(destination, $0)
        }) else { throw UploadError.readOnly }
        let affected = try editNamespace.affectedSources(source: source, destination: destination)
        guard affected.contains(where: { $0 === self }) else { throw UploadError.unresolved }
        return affected
    }

    /// Blocks on unfinished local data at or below either endpoint, including retained artifacts.
    func requireFolderMovePathsSettled(_ paths: [RelativePath]) throws {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let uploads = try Self.outbox(domainID: domainID), edits = try Self.editOutbox(domainID: domainID)
            let uploadRecords = try uploads.records(), editRecords = try edits.records()
            guard try uploads.pendingCount == uploadRecords.filter(\.isPending).count,
                  try edits.pendingCount == editRecords.filter(\.isPending).count else { throw UploadError.pendingWrites }
            let local = uploadRecords.filter(\.isPending).flatMap { [$0.path] + [$0.initialName?.destination].compactMap { $0 } }
                + editRecords.filter { $0.isPending || $0.completedStageRemoved == false || $0.completedBackupRemoved == false }
                    .flatMap { [$0.path, $0.stagePath, $0.recoveryPath, $0.workPath, $0.destination] }
            for path in local {
                guard let relative = RelativePath(path), let full = folder.appending(relative) else {
                    throw UploadError.unresolved
                }
                guard !paths.contains(where: { EditNamespace.contains($0, full) }) else { throw UploadError.pendingWrites }
            }
        }
    }

    /// Outside the namespace lock: a transfer finishing its read can still need that lock.
    private func drainFolderMove(_ affected: [LocationSource], paths: [RelativePath]) throws {
        var drained: [ObjectIdentifier] = []
        for participant in affected where !drained.contains(ObjectIdentifier(participant.access)) {
            drained.append(ObjectIdentifier(participant.access))
            try participant.access.drainWatches(below: paths)
        }
        try editNamespace.drainReads(below: paths)
    }

    private func admitFolderMove(_ request: FileRenameRequest, source: RelativePath, destination: RelativePath,
                                 remote: SMBEdit, session: ShareSession) throws -> PendingFolderMove {
        try editNamespace.requireSettled()
        _ = try renameAccess()
        let outbox = try Self.renameOutbox()
        let (current, target) = try folderMovePaths(request)
        guard current.string.utf8.elementsEqual(source.string.utf8),
              target.string.utf8.elementsEqual(destination.string.utf8) else { throw SourceFailure.versionChanged }
        let affected = try folderMoveSources(source: source, destination: destination)
        for participant in affected { try participant.requireFolderMovePathsSettled([source, destination]) }
        let parents = try remote.protectFolderMoveParents(source: source.string, destination: destination.string)
        guard let root = try remote.inspectFolderMoveRoot(path: source.string),
              root.name.utf8.elementsEqual((source.components.last ?? "").utf8) else { throw SourceFailure.versionChanged }
        let views = try affected.map {
            try $0.folderMoveView(request: $0 === self ? request : nil, source: source, destination: destination,
                                  parents: parents, remote: remote, mount: session.identity,
                                  session: $0.access === access ? session : nil)
        }
        return try outbox.prepareFolder(owner: domainID, request: request, source: source, destination: destination,
                                        identity: root.identity, parents: parents, views: views)
    }

    private func folderMoveView(request: FileRenameRequest?, source: RelativePath, destination: RelativePath,
                                parents: [FileRenameParent], remote: SMBEdit, mount: MountIdentity,
                                session: ShareSession?) throws -> FolderMoveView {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            let relative = RelativePath(source.components.dropFirst(folder.components.count).joined(separator: "/"))!
            let targetParent = RelativePath(destination.components.dropFirst(folder.components.count).dropLast()
                .joined(separator: "/"))!
            let name = destination.components.last!
            let (move, parentIDs) = try withCatalog { catalog -> (CatalogFolderMove, [String]) in
                func resolve(_ path: RelativePath) throws -> String {
                    var id = Catalog.rootItemID
                    for component in path.components {
                        guard let row = try catalog.liveChild(parent: id, nameKey: NameKey(component)),
                              row.name.utf8.elementsEqual(component.utf8) else { throw UploadError.unresolved }
                        id = row.id
                    }
                    return id
                }
                let id = try resolve(relative), parent = try resolve(targetParent)
                guard let row = try catalog.item(id: id), row.kind == .folder, !row.deleted, let oldParent = row.parentID,
                      request.map({ $0.item == id && $0.parent == parent }) ?? true else { throw UploadError.unresolved }
                if let other = try catalog.liveChild(parent: parent, nameKey: NameKey(name)), other.id != id {
                    throw UploadError.collision
                }
                let move = try catalog.prepareFolderMove(item: id, destinationParent: parent, destinationName: name)
                return (move, [oldParent, parent])
            }
            if let session {
                try validateRenameParents(parentIDs, parents: parents, session: session)
            } else {
                try access.withSession { session, _ in
                    // Native lookups run through the owner's mount, so every view must use the same one.
                    guard session.identity == mount else { throw UploadError.readOnly }
                    try validateRenameParents(parentIDs, parents: parents, session: session)
                }
            }
            let proofs = try historicalFolderMoveProofs(move, fresh: remote.captureFolderMoveProofs(move: move, folder: folder))
            return FolderMoveView(domain: domainID, folder: folder, move: move, proofs: proofs)
        }
    }

    /// A verified file keeps its recorded receipt; an f1 row keeps its version with fresh evidence.
    private func historicalFolderMoveProofs(_ move: CatalogFolderMove,
                                            fresh: [CatalogFolderMoveProof]) throws -> [CatalogFolderMoveProof] {
        let edits = try Self.editOutbox(domainID: domainID)
        let entries = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        return try fresh.map { proof in
            guard case .file(let current) = proof, let entry = entries[proof.item],
                  entry.contentVersion.hasPrefix("e1:") else { return proof }
            guard let receipt = try edits.base(item: entry.item, contentVersion: entry.contentVersion),
                  receipt.version.identity == current.version.identity,
                  receipt.version.hasSameContents(as: current.version),
                  receipt.version.modifiedMicroseconds == current.version.modifiedMicroseconds else {
                throw SourceFailure.versionChanged
            }
            return .file(receipt)
        }
    }

    private func withFolderMoveRemote<T>(session: ShareSession, progress: Progress,
                                         _ operation: (SMBEdit) throws -> T) throws -> T {
        try editNamespace.perform {
            guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
            let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: session.root, progress: progress)
            // The SMB connection lock and handles must end before the namespace lock is released.
            return try withExtendedLifetime(remote) { try operation(remote) }
        }
    }

    private func publishFolderMove(_ record: inout PendingFolderMove, remote: SMBEdit) throws {
        let outbox = try Self.renameOutbox()
        try editNamespace.requireSettled(excluding: record.id)
        let participants = try folderMoveParticipants(record)
        do { try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) }
        catch SourceFailure.versionChanged where [.verified, .recovering].contains(record.state) {
            // Fresh evidence no longer matches the durable target, so replan under this protection.
            try FolderMoveTransaction.replan(&record, outbox: outbox,
                                             expected: classifyFolderMove(record, participants), remote: remote)
        }
        guard record.state != .completed else { return }
        try applyFolderMoveCatalogs(&record, participants: participants, outbox: outbox, remote: remote)
    }

    private func completeFolderMove(_ record: inout PendingFolderMove, session: ShareSession,
                                     progress: Progress) throws {
        guard record.state != .completed else { return }
        let outbox = try Self.renameOutbox()
        var current = record
        defer { record = current }
        while current.state != .completed {
            let retiredKeeps = current.rootRetired
            try waitForFolderMoveSettings(current)
            try withFolderMoveRemote(session: session, progress: progress) { remote in
                try publishFolderMove(&current, remote: remote)
                guard current.state != .completed else { return }
                // A newly retired root needs Settings cleanup outside these locks before finishing.
                guard current.rootRetired == retiredKeeps else { return }
                try requireFolderMoveProtection(current, remote: remote)
                let participants = try folderMoveParticipants(current)
                for (view, source) in participants where !current.finishedDomains.contains(view.domain) {
                    let state = try source.withCatalog {
                        try $0.classifyFolderMove(view.move, proofs: view.proofs,
                                                  allowed: current.allowedCatalogStates(domain: view.domain))
                    }
                    guard try state == current.latestTarget(domain: view.domain) else { throw UploadError.unresolved }
                    try FolderMoveTransaction.finishDomain(view.domain, record: &current, outbox: outbox)
                }
                signalFolderMove(current, participants: participants)
            }
        }
    }

    private func folderMoveParticipants(_ record: PendingFolderMove) throws -> [(FolderMoveView, LocationSource)] {
        guard record.owner == domainID, let source = RelativePath(record.source),
              let destination = RelativePath(record.destination) else { throw UploadError.unresolved }
        let affected = try editNamespace.affectedSources(source: source, destination: destination)
        guard Set(affected.map(\.domainID)) == Set(record.views.map(\.domain)) else { throw UploadError.unresolved }
        return try record.views.map { view in
            let participant = try editNamespace.source(view.domain)
            guard participant.folder.string == view.folder else { throw UploadError.unresolved }
            return (view, participant)
        }
    }

    private func classifyFolderMove(_ record: PendingFolderMove, _ participants: [(FolderMoveView, LocationSource)])
        throws -> [String: CatalogFolderMoveState] {
        var states: [String: CatalogFolderMoveState] = [:]
        for (view, source) in participants {
            states[view.domain] = try source.withCatalog {
                try $0.classifyFolderMove(view.move, proofs: view.proofs, allowed: record.allowedCatalogStates(domain: view.domain))
            }
        }
        return states
    }

    private func applyFolderMoveCatalogs(_ record: inout PendingFolderMove,
                                         participants: [(FolderMoveView, LocationSource)],
                                         outbox: FileRenameOutbox, remote: SMBEdit) throws {
        let planned = record
        func applicable(_ state: CatalogFolderMoveState, domain: String) throws -> Bool {
            if try state == planned.latestTarget(domain: domain) { return true }
            if let recovery = planned.recovery?.first(where: { $0.domain == domain }) { return state == recovery.expected }
            return try state == planned.allowedCatalogStates(domain: domain).first
        }
        var states = try classifyFolderMove(record, participants)
        if try participants.contains(where: { view, _ in try !applicable(states[view.domain]!, domain: view.domain) }) {
            try FolderMoveTransaction.replan(&record, outbox: outbox, expected: states, remote: remote)
            states = try classifyFolderMove(record, participants)
        }
        for (view, source) in participants {
            let target = try record.latestTarget(domain: view.domain)
            // Receipts are durable before a catalog can hand their versions to File Provider.
            try source.storeFolderMoveReceipts(target)
            guard states[view.domain] != target else { continue }
            if let recovery = record.recovery?.first(where: { $0.domain == view.domain }) {
                try source.withCatalog {
                    try $0.applyFolderMoveRecovery(view.move, proofs: view.proofs,
                                                   expected: recovery.expected, target: recovery.target)
                }
            } else {
                guard let settlement = record.settlements?.first(where: { $0.domain == view.domain }) else {
                    throw UploadError.unresolved
                }
                try source.withCatalog { try $0.settleFolderMove(view.move, settlement: settlement.settlement) }
            }
        }
    }

    private func storeFolderMoveReceipts(_ state: CatalogFolderMoveState) throws {
        try uploadLock.withLock {
            let edits = try Self.editOutbox(domainID: domainID)
            for entry in state.entries where !entry.retired {
                guard case .file(let receipt) = entry.proof, entry.contentVersion == receipt.contentVersion else { continue }
                if let stored = try edits.base(item: receipt.item, contentVersion: receipt.contentVersion) {
                    guard stored == receipt else { throw UploadError.unresolved }
                } else {
                    try edits.storeBase(receipt)
                }
            }
        }
    }

    // The main actor can need the namespace; wait without its lock or an SMBEdit.
    private func waitForFolderMoveSettings(_ record: PendingFolderMove) throws {
        final class Outcome: @unchecked Sendable { var result: Result<Void, Error> = .failure(UploadError.unresolved) }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0), update = renameSettings
        Task {
            do {
                try await update(.folder(record))
                outcome.result = .success(())
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + .seconds(60)) == .success else { throw UploadError.unresolved }
        try outcome.result.get()
    }

    /// Fails if the SMB connection lost its handles; a later retry then reverifies all evidence.
    private func requireFolderMoveProtection(_ record: PendingFolderMove, remote: SMBEdit) throws {
        guard [.verified, .recovering].contains(record.state),
              try remote.protectFolderMoveParents(source: record.destination, destination: record.destination)
                == record.destinationParents else { throw UploadError.unresolved }
        if record.rootRetired { return }
        guard let root = try remote.inspectFolderMoveRoot(path: record.destination), root.identity == record.identity,
              root.name.utf8.elementsEqual(record.name.utf8) else { throw UploadError.unresolved }
    }

    private func signalFolderMove(_ record: PendingFolderMove, participants: [(FolderMoveView, LocationSource)]) {
        for (view, source) in participants {
            var folders: Set<String> = [view.move.destinationParent, view.move.item]
            let admitted = Dictionary(uniqueKeysWithValues: view.move.entries.map { ($0.item, $0) })
            if let root = admitted[view.move.item] { folders.insert(root.parent) }
            if let target = try? record.latestTarget(domain: view.domain) {
                for entry in target.entries where entry.retired || entry.contentVersion != admitted[entry.item]?.contentVersion {
                    if let parent = admitted[entry.item]?.parent { folders.insert(parent) }
                }
            }
            source.signalFolders(Array(folders))
            source.scheduleSignal()
        }
    }
}
