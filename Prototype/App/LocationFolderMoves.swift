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
        connection.enqueue { [self] in
            started()
            let result = Result { try moveFolderOnLane(request, progress: progress) }
            Self.folderMoveLog.info("folder_move request=\(request.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
            if case .failure(let error) = result {
                Self.folderMoveLog.error("folder_move request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                _ = try? listOnLane(request.parent, requestID: request.id)
                scheduleSignal()
                scheduleRenameRetry(after: error)
            }
            reply(result)
        }
    }

    private func moveFolderOnLane(_ request: FileRenameRequest, progress: Progress) throws -> CreateReceipt {
        let replayed = try editNamespace.perform { () -> PendingFolderMove? in
            try renameAccess()
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
            try renameAccess()
            let (source, destination) = try folderMovePaths(request)
            if SMBName.same(source.string, destination.string) { return nil }
            let affected = try folderMoveSources(source: source, destination: destination)
            for participant in affected { try participant.prepareRenameFolders(source: source, destination: destination) }
            for participant in affected { try participant.requireFolderMovePathsSettled([source, destination]) }
            editNamespace.reserve(reservation, paths: [source, destination])
            return (source, destination, affected)
        }
        defer { editNamespace.release(reservation) }
        guard case let (source, destination, affected)? = planned else { return CreateReceipt(item: request.item) }
        try drainChanges(affected, below: [source, destination])
        try renameAccess()
        var record = try withFolderMoveRemote(progress: progress) { remote in
            var record = try admitFolderMove(request, source: source, destination: destination, remote: remote)
            try publishFolderMove(&record, remote: remote)
            return record
        }
        try completeFolderMove(&record, progress: progress)
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
        try drainChanges(affected, below: [source, destination])
        try renameAccess()
        let progress = Progress()
        var current = record
        if current.state != .verified && current.state != .recovering {
            try withFolderMoveRemote(progress: progress) { remote in
                try publishFolderMove(&current, remote: remote)
            }
        }
        try completeFolderMove(&current, progress: progress)
        try current.requireMoved()
        return current
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
            let uploads = try Self.outbox(domainID: domainID)
            let uploadRecords = try uploads.records()
            guard try uploads.pendingCount == uploadRecords.filter(\.isPending).count else { throw UploadError.pendingWrites }
            let local = uploadRecords.filter(\.isPending).flatMap { [$0.path] + [$0.initialName?.destination].compactMap { $0 } }
            for path in local {
                guard let relative = RelativePath(path), let full = folder.appending(relative) else {
                    throw UploadError.unresolved
                }
                guard !paths.contains(where: { EditNamespace.contains($0, full) }) else { throw UploadError.pendingWrites }
            }
        }
    }

    /// Outside the namespace lock: a transfer finishing its read can still need that lock.
    func drainChanges(_ affected: [LocationSource], below paths: [RelativePath]) throws {
        var drained: [ObjectIdentifier] = []
        // Locations of one share through two accounts have two connections, each with its watches.
        for participant in affected where !drained.contains(ObjectIdentifier(participant.connection)) {
            drained.append(ObjectIdentifier(participant.connection))
            participant.connection.changeWatch.drain(below: paths)
        }
        try editNamespace.drainReads(below: paths)
    }

    private func admitFolderMove(_ request: FileRenameRequest, source: RelativePath, destination: RelativePath,
                                 remote: any RemoteSession) throws -> PendingFolderMove {
        try editNamespace.requireSettled()
        try renameAccess()
        let outbox = try Self.renameOutbox()
        let (current, target) = try folderMovePaths(request)
        guard current.string.utf8.elementsEqual(source.string.utf8),
              target.string.utf8.elementsEqual(destination.string.utf8) else { throw SourceFailure.versionChanged }
        let affected = try folderMoveSources(source: source, destination: destination)
        for participant in affected { try participant.requireFolderMovePathsSettled([source, destination]) }
        let parents = try remote.protectFolderMoveParents(source: source.string, destination: destination.string)
        guard let root = try remote.inspectFolderMoveRoot(path: source.string),
              SMBName.same(root.name, source.components.last ?? "") else { throw SourceFailure.versionChanged }
        let views = try affected.map {
            try $0.folderMoveView(request: $0 === self ? request : nil, source: source, destination: destination,
                                  parents: parents, remote: remote)
        }
        return try outbox.prepareFolder(owner: domainID, request: request, source: source, destination: destination,
                                        identity: root.identity, parents: parents, views: views)
    }

    private func folderMoveView(request: FileRenameRequest?, source: RelativePath, destination: RelativePath,
                                parents: [FileRenameParent], remote: any RemoteSession) throws -> FolderMoveView {
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
            try validateRenameParents(parentIDs, parents: parents)
            let proofs = try remote.captureFolderMoveProofs(move: move, folder: folder)
            return FolderMoveView(domain: domainID, folder: folder, move: move, proofs: proofs)
        }
    }

    // The session ends, releasing its SMB handles, before another namespace operation can start.
    private func withFolderMoveRemote<T>(progress: Progress, _ operation: (any RemoteSession) throws -> T) throws -> T {
        try editNamespace.perform {
            try connection.withSession(folder: .root, progress: progress) { remote, _ in try operation(remote) }
        }
    }

    private func publishFolderMove(_ record: inout PendingFolderMove, remote: any RemoteSession) throws {
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

    private func completeFolderMove(_ record: inout PendingFolderMove, progress: Progress) throws {
        guard record.state != .completed else { return }
        let outbox = try Self.renameOutbox()
        var current = record
        defer { record = current }
        while current.state != .completed {
            let retiredKeeps = current.rootRetired
            try waitForFolderMoveSettings(current)
            try withFolderMoveRemote(progress: progress) { remote in
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
        editNamespace.resumeWrites()
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
                                         outbox: FileRenameOutbox, remote: any RemoteSession) throws {
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

    // The main actor can need the namespace; wait without its lock or a session.
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
    private func requireFolderMoveProtection(_ record: PendingFolderMove, remote: any RemoteSession) throws {
        guard [.verified, .recovering].contains(record.state),
              try remote.protectFolderMoveParents(source: record.destination, destination: record.destination)
                == record.destinationParents else { throw UploadError.unresolved }
        if record.rootRetired { return }
        guard let root = try remote.inspectFolderMoveRoot(path: record.destination), root.identity == record.identity,
              SMBName.matchesStored(root.name, requested: record.name) else { throw UploadError.unresolved }
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
