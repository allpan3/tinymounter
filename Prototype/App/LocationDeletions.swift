import Foundation
import OSLog

// Provider routing remains gated on signed recursive-deletion checks.
extension LocationSource {
    private static let deletionLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
    private static let deletionPage = 512
    private typealias DeletionRow = (path: RelativePath, row: CatalogRow, nativeID: UInt64)

    // Settlement takes the namespace lock and finishes only reconciled domains.
    typealias DeletionSettlement = @Sendable (inout PendingDeletion) throws -> Void

    func deleteItem(_ request: DeletionRequest, recursive: Bool, progress: Progress,
                    started: @escaping @Sendable () -> Void, settle: @escaping DeletionSettlement,
                    reply: @escaping @Sendable (Result<PendingDeletion, Error>) -> Void) {
        access.enqueue { [self] in
            started()
            let result = Result { () throws -> PendingDeletion in
                var record = try deleteOnLane(request, recursive: recursive, progress: progress)
                if !record.isComplete { try settle(&record) }
                try requireDeleted(record)
                return record
            }
            switch result {
            case .success(let record):
                Self.deletionLog.info("deletion id=\(record.id.uuidString, privacy: .public) ok=1")
            case .failure(let error):
                Self.deletionLog.error("deletion item=\(request.item, privacy: .public) failed \(logFields(error), privacy: .public)")
            }
            reply(result)
        }
    }

    // The owner lane serializes admission and replay; catalog settlement follows remote execution.
    func deleteOnLane(_ request: DeletionRequest, recursive: Bool, progress: Progress) throws -> PendingDeletion {
        if var replayed = try replayedDeletion(request) {
            // A replay resumes the admitted evidence; it never captures a new tree.
            if !replayed.isSettled { try runDeletion(&replayed, progress: progress) }
            return replayed
        }
        let reservation = UUID()
        let (path, affected) = try editNamespace.perform { () -> (RelativePath, [LocationSource]) in
            try editNamespace.requireSettled()
            _ = try renameAccess()
            let path = try deletionPath(request)
            let affected = try deletionSources(path)
            for participant in affected { try participant.prepareRenameFolders(source: path, destination: path) }
            for participant in affected { try participant.requireFolderMovePathsSettled([path]) }
            editNamespace.reserve(reservation, paths: [path])
            return (path, affected)
        }
        defer { editNamespace.release(reservation) }
        try drainDeletion(affected, path: path)
        var record = try editNamespace.perform {
            try admitDeletion(request, recursive: recursive, path: path, planned: affected, progress: progress)
        }
        if !record.isSettled { try runDeletion(&record, progress: progress) }
        return record
    }

    // The durable plan blocks new work below it, so recovery never captures another traversal.
    func resumeDeletionOnLane(_ id: UUID, progress: Progress) throws -> PendingDeletion {
        var record = try editNamespace.perform { try ownedDeletion(id) }
        if !record.isSettled { try runDeletion(&record, progress: progress) }
        return record
    }

    // Stop runs on the owner lane after cancellation has ended the active node session.
    func stopDeletionOnLane(_ id: UUID) throws -> PendingDeletion {
        try editNamespace.perform {
            var record = try ownedDeletion(id)
            try Self.deletionOutbox().stop(&record)
            return record
        }
    }

    // A replacement may retain the selected catalog ID after reconciliation.
    func requireDeleted(_ record: PendingDeletion) throws {
        guard record.plan.owner == domainID else { throw ItemDeletionError.invalidRequest }
        guard record.isComplete else { throw UploadError.pendingWrites }
        switch record.selectedOutcome {
        case .deleted?:
            try withCatalog { catalog in
                guard let row = try catalog.item(id: record.plan.request.item) else {
                    throw ItemDeletionError.unresolved
                }
                guard row.deleted else { throw SourceFailure.versionChanged }
            }
        case .changed?: throw ItemDeletionError.changed
        case .replaced?: throw ItemDeletionError.replaced
        case .moved?: throw ItemDeletionError.moved
        case .parentChanged?: throw ItemDeletionError.parentChanged
        case .unsupported?: throw ItemDeletionError.unsupported
        case .sharingViolation?: throw ItemDeletionError.sharingViolation
        case .accessDenied?: throw ItemDeletionError.accessDenied
        case .cannotDelete?: throw ItemDeletionError.cannotDelete
        case .directoryNotEmpty?: throw ItemDeletionError.directoryNotEmpty
        case .stopped?: throw TransferError.cancelled
        // A lost reply may have removed it; neither deletion nor survival is proven.
        case .unconfirmed?, nil: throw ItemDeletionError.unresolved
        }
    }

    private func replayedDeletion(_ request: DeletionRequest) throws -> PendingDeletion? {
        try editNamespace.perform {
            try access.withSession { share, _ in
                guard let endpoint = ShareAddress(share.identity.mountFrom) else { throw UploadError.readOnly }
                return try Self.deletionOutbox().replay(endpoint: endpoint, owner: domainID, request: request)
            }
        }
    }

    private func ownedDeletion(_ id: UUID) throws -> PendingDeletion {
        guard let record = try Self.deletionOutbox().records().first(where: { $0.id == id }),
              record.plan.owner == domainID else { throw UploadError.unresolved }
        return record
    }

    private func deletionPath(_ request: DeletionRequest) throws -> RelativePath {
        try withCatalog { catalog in
            guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsEditing,
                  row.contentVersion == request.contentVersion, row.metadataVersion == request.metadataVersion,
                  let relative = try catalog.relativePath(of: row.id), !relative.isRoot,
                  let path = folder.appending(relative) else { throw SourceFailure.versionChanged }
            return path
        }
    }

    private func deletionSources(_ path: RelativePath) throws -> [LocationSource] {
        // Deleting a configured root, or a folder that holds one, would remove that location.
        guard !editNamespace.locationRoots().contains(where: { EditNamespace.contains(path, $0) }) else {
            throw UploadError.readOnly
        }
        let affected = try editNamespace.affectedSources(path: path)
        guard affected.contains(where: { $0 === self }) else { throw UploadError.unresolved }
        return affected
    }

    /// Outside the namespace lock: a transfer finishing its read can still need that lock.
    private func drainDeletion(_ affected: [LocationSource], path: RelativePath) throws {
        var drained: [ObjectIdentifier] = []
        for participant in affected where !drained.contains(ObjectIdentifier(participant.access)) {
            drained.append(ObjectIdentifier(participant.access))
            try participant.access.drainWatches(below: [path])
        }
        try editNamespace.drainReads(below: [path])
    }

    /// Inside the namespace lock, so no listing commits between the catalog views and the plan.
    private func admitDeletion(_ request: DeletionRequest, recursive: Bool, path: RelativePath,
                               planned: [LocationSource], progress: Progress) throws -> PendingDeletion {
        let bookmark = try renameAccess()
        return try withWriteSession(bookmark, progress: progress) { share, _ in
            guard let endpoint = ShareAddress(share.identity.mountFrom) else { throw UploadError.readOnly }
            let outbox = try Self.deletionOutbox()
            if let replayed = try outbox.replay(endpoint: endpoint, owner: domainID, request: request) {
                return replayed
            }
            try editNamespace.requireSettled()
            guard try deletionPath(request).string.utf8.elementsEqual(path.string.utf8) else {
                throw SourceFailure.versionChanged
            }
            // The drain covered these sources' watches; a reopened source may hold new ones.
            let affected = try deletionSources(path)
            guard affected.elementsEqual(planned, by: { $0 === $1 }) else { throw UploadError.unresolved }
            for participant in affected { try participant.requireFolderMovePathsSettled([path]) }
            let claims = try affected.map { try $0.deletionClaims(path, request: $0 === self ? request : nil) }
            let record = try Self.prepareDeletion(request, recursive: recursive, path: path, owner: domainID,
                                                  claims: claims, protectedRoots: editNamespace.locationRoots(),
                                                  outbox: outbox, endpoint: endpoint, root: share.root,
                                                  progress: progress)
            Self.deletionLog.info("""
                deletion_admit id=\(record.id.uuidString, privacy: .public) nodes=\(record.plan.nodes.count) \
                views=\(record.plan.views.count)
                """)
            return record
        }
    }

    // Returning destroys the capture client before a node can acquire the global SMB mutex.
    private static func prepareDeletion(_ request: DeletionRequest, recursive: Bool, path: RelativePath, owner: String,
                                        claims: [(view: DeletionView, expectations: [DeletionExpectation])],
                                        protectedRoots: [RelativePath], outbox: DeletionOutbox,
                                        endpoint: ShareAddress, root: Int32,
                                        progress: Progress) throws -> PendingDeletion {
        let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: root, progress: progress)
        let traversal = try remote.captureDeletionTraversal(of: path, recursive: recursive,
                                                            expecting: claims.flatMap { $0.expectations })
        let record = try outbox.prepare(endpoint: endpoint, owner: owner, request: request, traversal: traversal,
                                        views: claims.map { $0.view }, protectedRoots: protectedRoots,
                                        recursive: recursive)
        // A failed close leaves the plan unrun until the capture session has ended.
        try remote.releaseDeletionTraversal()
        return record
    }

    // The upload lock keeps this view's edit receipts fixed while reading its admission evidence.
    private func deletionClaims(_ path: RelativePath, request: DeletionRequest?) throws
        -> (view: DeletionView, expectations: [DeletionExpectation]) {
        try uploadLock.withLock {
            guard !mutationsSuspended else { throw UploadError.pendingWrites }
            guard let relative = RelativePath(path.components.dropFirst(folder.components.count).joined(separator: "/")),
                  !relative.isRoot else { throw UploadError.unresolved }
            let (rows, view) = try withCatalog { catalog -> ([DeletionRow], DeletionView) in
                let rows = try deletionRows(relative, catalog: catalog)
                if let request {
                    guard let selected = rows.first?.row, selected.id == request.item,
                          selected.contentVersion == request.contentVersion,
                          selected.metadataVersion == request.metadataVersion else { throw SourceFailure.versionChanged }
                }
                let items = rows.map { DeletionViewItem(item: $0.row.id, path: $0.path, contentVersion: $0.row.contentVersion) }
                return (rows, try catalog.deletionView(locationRoot: folder, items: items))
            }
            let edits = try Self.editOutbox(domainID: domainID)
            let expectations = try rows.map { entry -> DeletionExpectation in
                guard let full = folder.appending(entry.path) else { throw UploadError.unresolved }
                let receipt = try entry.row.kind == .file && entry.row.contentVersion.hasPrefix("e1:")
                    ? edits.base(item: entry.row.id, contentVersion: entry.row.contentVersion) : nil
                return try DeletionExpectation(path: full, row: entry.row, nativeID: entry.nativeID, receipt: receipt)
            }
            return (view, expectations)
        }
    }

    /// The row at `relative` first, then its live descendants; empty if this view never listed it.
    private func deletionRows(_ relative: RelativePath, catalog: Catalog) throws -> [DeletionRow] {
        var id = Catalog.rootItemID
        var selected: CatalogRow?
        for component in relative.components {
            guard let child = try catalog.liveChild(parent: id, nameKey: NameKey(component)) else { return [] }
            // Listings record each name exactly, so another spelling is a stale row.
            guard child.name.utf8.elementsEqual(component.utf8) else { throw UploadError.unresolved }
            selected = child
            id = child.id
        }
        guard let selected else { throw UploadError.unresolved }
        var pending = [(path: relative, row: selected)], rows: [DeletionRow] = []
        while let next = pending.popLast() {
            let (path, row) = next
            guard let nativeID = try catalog.remoteIdentity(row.id) else { throw UploadError.unresolved }
            rows.append((path, row, nativeID))
            guard row.kind == .folder else { continue }
            var after: Int64?
            while true {
                let page = try catalog.children(of: row.id, afterRow: after, limit: Self.deletionPage)
                for child in page {
                    guard let childPath = path.appending(child.name) else { throw SourceFailure.pathRejected }
                    pending.append((childPath, child))
                }
                guard rows.count + pending.count <= DeletionPlan.maxNodes else { throw SourceFailure.tooManyEntries }
                guard page.count == Self.deletionPage, let last = page.last else { break }
                after = last.row
            }
        }
        return rows
    }

    // Durable blocking permits node sessions outside the namespace lock used by unrelated reads.
    private func runDeletion(_ record: inout PendingDeletion, progress: Progress) throws {
        let id = record.id
        let bookmark = try editNamespace.perform { () -> Data in
            try editNamespace.requireSettled(excluding: id)
            return try renameAccess()
        }
        try withWriteSession(bookmark, progress: progress) { share, _ in
            guard let endpoint = ShareAddress(share.identity.mountFrom) else { throw UploadError.readOnly }
            try RecursiveDeletionTransaction.run(&record, outbox: Self.deletionOutbox(), endpoint: endpoint,
                                                 owner: domainID) { body in
                try Self.deletionNodeSession(endpoint: endpoint, root: share.root, progress: progress, body)
            }
        }
        let summary = record.summary
        Self.deletionLog.info("""
            deletion_run id=\(record.id.uuidString, privacy: .public) nodes=\(record.plan.nodes.count) \
            deleted=\(summary[.deleted] ?? 0) unconfirmed=\(summary[.unconfirmed] ?? 0) \
            stopped=\(summary[.stopped] ?? 0)
            """)
    }

    /// One connection per node, ended when this returns or throws.
    private static func deletionNodeSession(endpoint: ShareAddress, root: Int32, progress: Progress,
                                            _ body: (DeletionRemote) throws -> Void) throws {
        let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: root, progress: progress)
        try body(remote)
    }
}
