import Foundation

// Keep only on the owner's lane; a restart supplies nil and obtains new observations.
struct LocationDeletionSettlementAttempt: Sendable {
    fileprivate var record: PendingDeletion
    fileprivate let sources: [LocationSource]
    fileprivate var settlements: [String: CatalogDeletionSettlement] = [:]
    fileprivate var heldSince: [String: [Data: ContinuousClock.Instant]] = [:]
    fileprivate var roots: [String: RemoteFileIdentity] = [:]

    var isSettled: Bool {
        record.plan.views.allSatisfy {
            record.progress.finishedDomains.contains($0.domain) || settlements[$0.domain]?.isSettled == true
        }
    }

    var refresh: [String: [String]] { settlements.mapValues(\.refresh) }
}

extension LocationSource {
    // Nil means ready for Settings; zero means enqueue another bounded pass, never loop here.
    func settleDeletionOnLane(_ record: PendingDeletion,
                              attempt: inout LocationDeletionSettlementAttempt?) throws -> Duration? {
        try editNamespace.perform {
            try requireDeletionSettlementRecord(record)
            let participants = try deletionSettlementSources(record)
            var next = attempt ?? LocationDeletionSettlementAttempt(record: record, sources: participants)
            try requireDeletionSettlementAttempt(next, record: record, sources: participants)
            defer { attempt = next }
            var retryAt: ContinuousClock.Instant?
            for source in participants where !record.progress.finishedDomains.contains(source.domainID) {
                let deadline = try source.settleDeletionView(record, attempt: &next)
                if let deadline { retryAt = max(retryAt ?? deadline, deadline) }
            }
            guard !next.isSettled else { return nil }
            return retryAt.map { max(.zero, ContinuousClock.now.duration(to: $0)) } ?? .zero
        }
    }

    // Call on the owner lane only after confirmed-deletion keep-path cleanup is durably saved.
    func finishDeletionSettlementOnLane(_ record: inout PendingDeletion,
                                       afterKeepPathCleanup attempt: inout LocationDeletionSettlementAttempt) throws {
        try editNamespace.perform {
            try requireDeletionSettlementRecord(record)
            let participants = try deletionSettlementSources(record)
            try requireDeletionSettlementAttempt(attempt, record: record, sources: participants)
            guard attempt.isSettled else { throw UploadError.pendingWrites }
            let pending = participants.filter { !record.progress.finishedDomains.contains($0.domainID) }
            let outbox = try Self.deletionOutbox()
            var current = record
            var next = attempt
            defer {
                next.record = current
                record = current
                attempt = next
            }

            // Keep every writer locked until all observations are checked and domains are finished.
            func finish(_ index: Int) throws {
                guard index < pending.count else {
                    for source in pending { try outbox.finishDomain(source.domainID, record: &current) }
                    return
                }
                let source = pending[index]
                try source.withDeletionSettlementRoot(current) { _, endpoint, root, _ in
                    guard next.roots[source.domainID] != nil,
                          let previous = next.settlements[source.domainID] else {
                        throw UploadError.unresolved
                    }
                    try source.requireDeletionSettlementRoot(next, root: root)
                    try source.withCatalog { catalog in
                        let checked = try catalog.settleDeletion(current, endpoint: endpoint,
                            locationRoot: source.folder, previous: previous)
                        next.settlements[source.domainID] = checked
                        guard checked.isSettled else { throw UploadError.pendingWrites }
                        try finish(index + 1)
                    }
                }
            }
            try finish(0)
        }
    }

    private func settleDeletionView(_ record: PendingDeletion,
                                   attempt: inout LocationDeletionSettlementAttempt) throws
        -> ContinuousClock.Instant? {
        try withDeletionSettlementRoot(record) { remote, endpoint, root, progressed in
            try requireDeletionSettlementRoot(attempt, root: root)
            attempt.roots[domainID] = root
            return try withCatalog { catalog in
                let pending = try catalog.settleDeletion(record, endpoint: endpoint, locationRoot: folder,
                                                         previous: attempt.settlements[domainID])
                attempt.settlements[domainID] = pending
                guard !pending.isSettled else { return nil }
                guard !pending.listings.isEmpty else { throw UploadError.unresolved }
                var holds = attempt.heldSince[domainID] ?? [:]
                defer { attempt.heldSince[domainID] = holds }
                var observed: (path: Data, started: ContinuousClock.Instant)?
                var retryAt: ContinuousClock.Instant?
                let next = try catalog.reconcileDeletion(record, endpoint: endpoint, locationRoot: folder,
                    previous: pending, listing: { path in
                        // Ancestor fallback replaces this timestamp with the read that actually succeeds.
                        observed = (Data(path.string.utf8), .now)
                        return try remote.list(path, progressed: progressed)
                    }, confirmMissing: { path, missing in
                        try remote.confirmMissing(missing, in: path, progressed: progressed)
                    }, accept: { plan in
                        guard let observed else { return false }
                        if !Catalog.needsConfirmation(plan)
                            || holds[observed.path].map({ $0 + Catalog.confirmationDelay <= observed.started }) == true {
                            holds[observed.path] = nil
                            return true
                        }
                        let first = holds[observed.path] ?? observed.started
                        holds[observed.path] = first
                        retryAt = first + Catalog.confirmationDelay
                        return false
                    })
                attempt.settlements[domainID] = next
                return retryAt
            }
        }
    }

    private func requireDeletionSettlementRecord(_ record: PendingDeletion) throws {
        guard record.plan.owner == domainID, record.isSettled,
              let current = try Self.deletionOutbox().records().first(where: { $0.id == record.id }),
              current == record else { throw UploadError.unresolved }
        try editNamespace.requireSettled(excluding: record.id)
    }

    private func deletionSettlementSources(_ record: PendingDeletion) throws -> [LocationSource] {
        guard let path = RelativePath(record.plan.selected.path),
              try editNamespace.source(domainID) === self,
              !editNamespace.locationRoots().contains(where: { EditNamespace.contains(path, $0) }) else {
            throw UploadError.unresolved
        }
        let participants = try editNamespace.affectedSources(path: path)
        guard Set(participants.map(\.domainID)) == Set(record.plan.views.map(\.domain)) else {
            throw UploadError.unresolved
        }
        for source in participants {
            guard source.editNamespace === editNamespace,
                  let view = record.plan.views.first(where: { $0.domain == source.domainID }),
                  source.folder.string.utf8.elementsEqual(view.folder.utf8) else { throw UploadError.unresolved }
        }
        return participants
    }

    private func requireDeletionSettlementAttempt(_ attempt: LocationDeletionSettlementAttempt,
                                                  record: PendingDeletion, sources: [LocationSource]) throws {
        guard attempt.record == record, attempt.sources.elementsEqual(sources, by: { $0 === $1 }) else {
            throw UploadError.unresolved
        }
    }

    private func requireDeletionSettlementRoot(_ attempt: LocationDeletionSettlementAttempt,
                                               root: RemoteFileIdentity) throws {
        if let previous = attempt.roots[domainID], previous != root { throw SourceFailure.versionChanged }
    }

    private func withDeletionSettlementRoot<T>(_ record: PendingDeletion,
        _ body: (any RemoteSession, ShareAddress, RemoteFileIdentity, @escaping Progressed) throws -> T) throws -> T {
        let endpoint = connection.address
        guard record.plan.endpoint.matches(endpoint),
              let view = record.plan.views.first(where: { $0.domain == domainID }),
              folder.string.utf8.elementsEqual(view.folder.utf8) else { throw UploadError.unresolved }
        // Each session opens the configured path again, so a moved location folder shows as a new identity.
        return try connection.withSession(folder: folder) { remote, progressed in
            try body(remote, endpoint, remote.directoryIdentity(.root), progressed)
        }
    }
}
