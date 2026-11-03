import Darwin
import Foundation
import SQLite3

/// Catalog reconciliation only; an unconfirmed remote outcome stays unconfirmed.
public struct CatalogDeletionSettlement: Equatable, Sendable {
    public let record: UUID
    public let domain: String
    /// Rows this call tombstoned, children first.
    public let tombstoned: [String]
    /// Admitted rows still needing fresh catalog evidence, children first.
    public let blocked: [String]
    /// Live catalog folders to read through `reconcileDeletion`, ancestors first.
    public let listings: [String]
    public let refresh: [String]
    /// Fixed for this attempt; losing the result requires a new reconciliation attempt.
    fileprivate let barrier: DeletionCatalogAdmission
    fileprivate let state: DeletionCatalogAdmission
    fileprivate let observations: [String: Int64]

    // A live selected row still prevents provider success, even after catalog reconciliation ends.
    public var isSettled: Bool { blocked.isEmpty && listings.isEmpty }
}

extension Catalog {
    /// Capture before protected admission, after draining older listing work on the catalog queue.
    public func deletionView(locationRoot: RelativePath, items admitted: [DeletionViewItem]) throws -> DeletionView {
        try database.read {
            guard admitted.count <= DeletionPlan.maxNodes, Set(admitted.map(\.item)).count == admitted.count else {
                throw ItemDeletionError.invalidRequest
            }
            for entry in admitted {
                guard let row = try item(id: entry.item), !row.deleted, row.id != Self.rootItemID,
                      row.contentVersion == entry.contentVersion,
                      let path = try relativePath(of: row.id), path.string.utf8.elementsEqual(entry.path.utf8) else {
                    throw ItemDeletionError.invalidRequest
                }
            }
            return DeletionView(domain: domainID, folder: locationRoot, items: admitted,
                                catalogAdmission: try deletionCatalogState())
        }
    }

    /// Pass the actual configured endpoint/root, never values copied from the pending record.
    /// Serialize catalog work through finishDomain and discard older listing completions.
    public func settleDeletion(_ record: PendingDeletion, endpoint: ShareAddress, locationRoot: RelativePath,
                               previous: CatalogDeletionSettlement? = nil) throws -> CatalogDeletionSettlement {
        let view = try deletionView(record, endpoint: endpoint, locationRoot: locationRoot, previous: previous)
        let indices = Dictionary(uniqueKeysWithValues: record.plan.nodes.enumerated().map {
            (SMBName.key($1.path), $0)
        })
        let admitted = try record.results(domain: domainID).map { result -> (DeletionViewResult, Int) in
            guard let relative = RelativePath(result.item.path), let path = locationRoot.appending(relative),
                  let index = indices[SMBName.key(path.string)] else { throw ItemDeletionError.invalidRequest }
            return (result, index)
        }.sorted { $0.1 < $1.1 }
        return try write { seq in
            let state = try deletionCatalogState()
            let continuing = previous.flatMap { $0.state == state ? $0 : nil }
            let observations = continuing?.observations ?? [:]
            let previouslyBlocked = Set(continuing?.blocked ?? [])
            // Any intervening listing can retain a replacement's ID and fingerprint, even its native ID.
            let unchanged = view.catalogAdmission == state
            var tombstoned: [String] = [], blocked: [String] = [], listings: [String] = [], refresh: [String] = []
            var mapped = Set<Int>()
            for (result, index) in admitted {
                mapped.insert(index)
                guard let row = try item(id: result.item.item),
                      let parent = row.parentID, try item(id: parent) != nil,
                      let path = RelativePath(result.item.path) else { throw ItemDeletionError.invalidRequest }
                switch result.outcome {
                case .deleted:
                    if row.deleted, continuing != nil, !previouslyBlocked.contains(row.id) {
                        refresh.append(parent)
                        continue
                    }
                    if !row.deleted, unchanged, row.kind == record.plan.nodes[index].evidence.kind,
                       try relativePath(of: row.id)?.string.utf8.elementsEqual(path.string.utf8) == true,
                       row.contentVersion == result.item.contentVersion, try liveChildCount(of: row.id) == 0 {
                        seq += 1
                        try database.prepare("UPDATE items SET deleted = 1, change_seq = ? WHERE row = ?") {
                            try $0.bind(1, seq)
                            try $0.bind(2, row.row)
                            try $0.run()
                        }
                        tombstoned.append(row.id)
                        refresh.append(parent)
                        continue
                    }
                case .unconfirmed, .changed, .replaced, .moved, .parentChanged, .directoryNotEmpty:
                    break
                case .stopped, .unsupported, .sharingViolation, .accessDenied, .cannotDelete:
                    continue
                }
                var paths = [deletionParent(path)]
                if let current = try relativePath(of: row.id) {
                    paths.append(deletionParent(current))
                    if row.kind == .folder {
                        let hasChildren = try liveChildCount(of: row.id) > 0
                        if result.outcome == .directoryNotEmpty || (result.outcome == .deleted && hasChildren) {
                            paths.append(current)
                        }
                    }
                }
                let required = try paths.compactMap { try deletionListingRequired($0, observations: observations) }
                if !required.isEmpty { blocked.append(row.id); listings += required }
                refresh.append(parent)
            }
            // An unlisted node can still leave a known ancestor stale after a lost reply.
            for exception in record.progress.exceptions where exception.outcome == .unconfirmed && !mapped.contains(exception.node) {
                guard let path = LocationRecord.path(record.plan.nodes[exception.node].path, inside: locationRoot) else {
                    throw ItemDeletionError.invalidRequest
                }
                if let folder = try deletionListingRequired(deletionParent(path), observations: observations) {
                    listings.append(folder)
                }
            }
            let folders = try deletionListingOrder(listings)
            let live = try deletionUnique(refresh + folders + observations.keys.sorted())
                .filter { try item(id: $0)?.deleted == false }
            return CatalogDeletionSettlement(record: record.id, domain: domainID, tombstoned: tombstoned,
                blocked: blocked, listings: folders, refresh: live, barrier: previous?.barrier ?? state,
                state: DeletionCatalogAdmission(epoch: epoch, sequence: seq, listingGeneration: state.listingGeneration),
                observations: observations)
        }
    }

    /// Start a fresh read here; cached listings and already-started reads are not evidence.
    /// Use the same mount for confirmMissing and retain the normal confirmation policy in accept.
    public func reconcileDeletion(_ record: PendingDeletion, endpoint: ShareAddress, locationRoot: RelativePath,
                                  previous: CatalogDeletionSettlement,
                                  listing: (RelativePath) throws -> DirectoryListing,
                                  confirmMissing: (RelativePath, [MissingChild]) throws -> Void,
                                  accept: (ReconcilePlan) -> Bool) throws -> CatalogDeletionSettlement {
        let pending = try settleDeletion(record, endpoint: endpoint, locationRoot: locationRoot, previous: previous)
        guard var folder = pending.listings.first else { return pending }
        let requested = folder
        var observed: DirectoryListing
        var path: RelativePath
        while true {
            guard let current = try relativePath(of: folder) else { throw ItemDeletionError.unresolved }
            path = current
            do {
                observed = try listing(path)
                break
            } catch {
                let failure = error as NSError
                let missing = error as? SourceFailure == .missing
                    || (failure.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(failure.code))
                guard missing,
                      let parent = try item(id: folder)?.parentID else { throw error }
                // A missing folder supplies no listing; only a reachable ancestor can establish absence.
                folder = parent
            }
        }
        guard observed.unreadable.isEmpty, observed.skipped.otherKinds == 0,
              observed.skipped.invalidNames == 0, observed.skipped.collisions == 0 else {
            throw SourceFailure.listingIncomplete
        }
        guard try deletionCatalogState() == pending.state else { throw ItemDeletionError.unresolved }
        try confirmMissing(path, missingChildren(of: folder, listing: observed))
        guard try deletionCatalogState() == pending.state else { throw ItemDeletionError.unresolved }
        guard try reconcile(folder: folder, listing: observed, accept: accept) != nil else { return pending }
        if folder != requested, try item(id: requested)?.deleted == false {
            throw ItemDeletionError.unresolved
        }
        guard let listed = try item(id: folder), listed.listingComplete, let generation = listed.listGen,
              generation > pending.barrier.listingGeneration else {
            throw ItemDeletionError.unresolved
        }
        var observations = pending.observations
        observations[folder] = generation
        let next = CatalogDeletionSettlement(record: pending.record, domain: domainID,
            tombstoned: pending.tombstoned, blocked: pending.blocked, listings: pending.listings,
            refresh: pending.refresh, barrier: pending.barrier, state: try deletionCatalogState(), observations: observations)
        return try settleDeletion(record, endpoint: endpoint, locationRoot: locationRoot, previous: next)
    }

    private func deletionView(_ record: PendingDeletion, endpoint: ShareAddress, locationRoot: RelativePath,
                              previous: CatalogDeletionSettlement?) throws -> DeletionView {
        guard record.isSettled, record.plan.endpoint.matches(endpoint),
              let view = record.plan.views.first(where: { $0.domain == domainID }),
              locationRoot.string.utf8.elementsEqual(view.folder.utf8),
              view.catalogAdmission.map({ $0.epoch == epoch }) ?? true,
              previous.map({ $0.record == record.id && $0.domain == domainID && $0.barrier.epoch == epoch }) ?? true else {
            throw ItemDeletionError.invalidRequest
        }
        if let admission = view.catalogAdmission {
            let current = try deletionCatalogState()
            guard current.sequence >= admission.sequence, current.listingGeneration >= admission.listingGeneration else {
                throw ItemDeletionError.invalidRequest
            }
        }
        return view
    }

    private func deletionListingRequired(_ path: RelativePath, observations: [String: Int64]) throws -> String? {
        guard var folder = try item(id: Self.rootItemID) else { throw ItemDeletionError.invalidRequest }
        for component in path.components {
            guard let child = try liveChild(parent: folder.id, nameKey: NameKey(component)), child.kind == .folder,
                  child.name.utf8.elementsEqual(component.utf8) else {
                return deletionObserved(folder, observations) ? nil : folder.id
            }
            folder = child
        }
        return deletionObserved(folder, observations) ? nil : folder.id
    }

    private func deletionObserved(_ row: CatalogRow, _ observations: [String: Int64]) -> Bool {
        row.listingComplete && row.listGen != nil && observations[row.id] == row.listGen
    }

    private func deletionListingOrder(_ ids: [String]) throws -> [String] {
        var paths: [(String, RelativePath)] = try deletionUnique(ids).map { id in
            guard let path = try relativePath(of: id) else { throw ItemDeletionError.unresolved }
            return (id, path)
        }
        paths.sort { left, right in
            let leftDepth = left.1.components.count
            let rightDepth = right.1.components.count
            return leftDepth == rightDepth ? left.0 < right.0 : leftDepth < rightDepth
        }
        var selected: [(String, RelativePath)] = []
        for candidate in paths where !selected.contains(where: {
            LocationRecord.path(candidate.1.string, inside: $0.1) != nil
        }) {
            selected.append(candidate)
        }
        return selected.map { $0.0 }
    }

    private func deletionParent(_ path: RelativePath) -> RelativePath {
        RelativePath(path.components.dropLast().joined(separator: "/"))!
    }

    private func deletionUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func deletionCatalogState() throws -> DeletionCatalogAdmission {
        try database.prepare("SELECT last_seq, listing_gen FROM meta WHERE id = 1") { statement in
            guard try statement.step() else { throw SQLiteError(code: SQLITE_CORRUPT, operation: "read deletion fence") }
            return DeletionCatalogAdmission(epoch: epoch, sequence: statement.int64(0), listingGeneration: statement.int64(1))
        }
    }
}
