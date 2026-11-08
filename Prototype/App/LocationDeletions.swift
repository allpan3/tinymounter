import Foundation
import OSLog
import UniformTypeIdentifiers

struct PermanentDeletionSelection: Equatable, Sendable {
    let name: String
    let isFolder: Bool
    let path: RelativePath
    let domains: [String]
}

// Provider routing remains gated on signed recursive-deletion checks.
extension LocationSource {
    private static let deletionLog = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
    private static let deletionPage = 512
    private typealias DeletionRow = (path: RelativePath, row: CatalogRow, nativeID: UInt64)

    func permanentDeletionSelection(_ request: DeleteItemRequest) throws -> PermanentDeletionSelection {
        try editNamespace.perform {
            try renameAccess()
            let deletion = DeletionRequest(item: request.item, contentVersion: request.contentVersion,
                metadataVersion: request.metadataVersion, eventVersion: request.eventVersion)
            let path = try deletionPath(deletion)
            let row = try withCatalog { catalog in
                guard let row = try catalog.item(id: request.item),
                      let current = try catalog.providerDomainVersion(),
                      try ProviderDomainVersion.matches(current, request.eventVersion),
                      FileRenameRequest.supportsName(row.name), EditRequest.supportsName(row.name),
                      UTType(filenameExtension: (row.name as NSString).pathExtension)?.conforms(to: .package) != true,
                      request.recursive == (row.kind == .folder) else { throw UploadError.readOnly }
                return row
            }
            let affected = try deletionSources(path)
            for source in affected { try source.requireFolderMovePathsSettled([path]) }
            return PermanentDeletionSelection(name: row.name, isFolder: row.kind == .folder, path: path,
                                              domains: affected.map(\.domainID).sorted())
        }
    }

    // The callback only binds recovery and cancellation under capture and namespace protection.
    func prepareDeletionOnLane(_ request: DeletionRequest, recursive: Bool,
                               progress: Progress, admitted: (PendingDeletion) -> Void) throws
        -> PendingDeletion {
        if let replayed = try replayedDeletion(request) {
            admitted(replayed)
            return replayed
        }
        let reservation = UUID()
        let (path, affected) = try editNamespace.perform { () -> (RelativePath, [LocationSource]) in
            try editNamespace.requireSettled(deletionBusyError: ItemDeletionError.busy)
            try renameAccess()
            let path = try deletionPath(request)
            let affected = try deletionSources(path)
            for participant in affected { try participant.prepareRenameFolders(source: path, destination: path) }
            for participant in affected { try participant.requireFolderMovePathsSettled([path]) }
            editNamespace.reserve(reservation, paths: [path])
            return (path, affected)
        }
        defer { editNamespace.release(reservation) }
        try drainChanges(affected, below: [path])
        return try editNamespace.perform {
            try admitDeletion(request, recursive: recursive, path: path, planned: affected,
                              progress: progress, admitted: admitted)
        }
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
        if record.isComplete, record.selectedOutcome == .unconfirmed,
           try withCatalog({ try $0.item(id: record.plan.request.item)?.deleted == false }) {
            throw ItemDeletionError.unconfirmedSurvivor
        }
        try record.requireConfirmedDeletion()
        try withCatalog { catalog in
            guard let row = try catalog.item(id: record.plan.request.item) else {
                throw ItemDeletionError.unresolved
            }
            guard row.deleted else { throw SourceFailure.versionChanged }
        }
    }

    func replayedDeletion(_ request: DeletionRequest) throws -> PendingDeletion? {
        try editNamespace.perform {
            try replayedDeletion(request, endpoint: connection.address, outbox: Self.deletionOutbox())
        }
    }

    private func replayedDeletion(_ request: DeletionRequest, endpoint: ShareAddress,
                                  outbox: DeletionOutbox) throws -> PendingDeletion? {
        let event = try ProviderDomainVersion.decode(request.eventVersion)
        try withCatalog { catalog in
            guard let current = try catalog.providerDomainVersion(),
                  try event <= ProviderDomainVersion.decode(current) else { throw ItemDeletionError.invalidRequest }
        }
        return try outbox.replay(endpoint: endpoint, owner: domainID, request: request,
                                 sameEvent: ProviderDomainVersion.matches)
    }

    func ownedDeletion(_ id: UUID) throws -> PendingDeletion {
        let outbox = try Self.deletionOutbox()
        guard let record = try outbox.records().first(where: { $0.id == id }),
              record.plan.owner == domainID else { throw UploadError.unresolved }
        return try outbox.reload(record)
    }

    private func deletionPath(_ request: DeletionRequest) throws -> RelativePath {
        try withCatalog { catalog in
            guard let row = try catalog.item(id: request.item), !row.deleted, row.allowsWriting,
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

    /// Inside the namespace lock, so no listing commits between the catalog views and the plan.
    private func admitDeletion(_ request: DeletionRequest, recursive: Bool, path: RelativePath,
                               planned: [LocationSource], progress: Progress,
                               admitted: (PendingDeletion) -> Void) throws -> PendingDeletion {
        try renameAccess()
        let endpoint = connection.address
        let outbox = try Self.deletionOutbox()
        if let replayed = try replayedDeletion(request, endpoint: endpoint, outbox: outbox) {
            admitted(replayed)
            return replayed
        }
        try editNamespace.requireSettled(deletionBusyError: ItemDeletionError.busy)
        guard try deletionPath(request).string.utf8.elementsEqual(path.string.utf8) else {
            throw SourceFailure.versionChanged
        }
        let affected = try deletionSources(path)
        guard affected.elementsEqual(planned, by: { $0 === $1 }) else { throw UploadError.unresolved }
        for participant in affected { try participant.requireFolderMovePathsSettled([path]) }
        let claims = try affected.map { try $0.deletionClaims(path, request: $0 === self ? request : nil) }
        // The capture checks every claimed file ID, so a replaced folder fails here.
        return try connection.withSession(folder: .root, progress: progress) { remote, _ in
            let traversal = try remote.captureDeletionTraversal(of: path, recursive: recursive,
                                                                expecting: claims.flatMap { $0.expectations })
            let record = try outbox.prepare(endpoint: endpoint, owner: domainID, request: request, traversal: traversal,
                                            views: claims.map { $0.view }, protectedRoots: editNamespace.locationRoots(),
                                            recursive: recursive)
            admitted(record)
            // A failed close leaves the plan unrun until the capture session has ended.
            try remote.releaseDeletionTraversal()
            Self.deletionLog.info("""
                deletion_admit id=\(record.id.uuidString, privacy: .public) nodes=\(record.plan.nodes.count) \
                views=\(record.plan.views.count)
                """)
            return record
        }
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
                let items = rows.map {
                    DeletionViewItem(item: $0.row.id, path: $0.path, contentVersion: $0.row.contentVersion)
                }
                return (rows, try catalog.deletionView(locationRoot: folder, items: items))
            }
            let expectations = try rows.map { entry -> DeletionExpectation in
                guard let full = folder.appending(entry.path) else { throw UploadError.unresolved }
                return try DeletionExpectation(path: full, row: entry.row, nativeID: entry.nativeID)
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
        let endpoint = connection.address
        try editNamespace.perform {
            try editNamespace.requireSettled(excluding: id)
            try renameAccess()
            guard record.plan.endpoint.matches(endpoint),
                  let path = RelativePath(record.plan.selected.path),
                  try editNamespace.source(domainID) === self else { throw UploadError.unresolved }
            let affected = try deletionSources(path)
            guard Set(affected.map(\.domainID)) == Set(record.plan.views.map(\.domain)) else {
                throw UploadError.unresolved
            }
            for source in affected {
                guard let view = record.plan.views.first(where: { $0.domain == source.domainID }),
                      source.folder.string.utf8.elementsEqual(view.folder.utf8) else { throw UploadError.unresolved }
                try source.uploadLock.withLock {
                    guard !source.mutationsSuspended else { throw UploadError.pendingWrites }
                    try source.withCatalog { _ in }
                }
            }
        }
        try RecursiveDeletionTransaction.run(&record, outbox: Self.deletionOutbox(), endpoint: endpoint,
                                             owner: domainID) { body in
            guard !progress.isCancelled else { throw TransferError.cancelled }
            // One session per node, ended when it returns or throws.
            try connection.withSession(folder: .root, progress: progress) { remote, _ in try body(remote) }
        }
        let summary = record.summary, count = record.plan.nodes.count
        Self.deletionLog.info("""
            deletion_run id=\(id.uuidString, privacy: .public) nodes=\(count) \
            deleted=\(summary[.deleted] ?? 0) unconfirmed=\(summary[.unconfirmed] ?? 0) \
            stopped=\(summary[.stopped] ?? 0)
            """)
    }
}
