import Foundation
import OSLog

extension PendingDeletion {
    var confirmedDeletedKeepPaths: [KeepPath] {
        let excluded = Set(progress.exceptions.map(\.node))
        let stopped = progress.stopped ?? plan.nodes.count
        return plan.nodes.enumerated().compactMap { index, node in
            guard index < progress.next, index < stopped, !excluded.contains(index) else { return nil }
            return KeepPath(path: node.path, kind: node.evidence.kind)
        }
    }
}

// Mutable settlement state belongs only to the owner's share lane.
final class LocationDeletionRecovery: @unchecked Sendable {
    var record: PendingDeletion
    let progress: Progress
    var attempt: LocationDeletionSettlementAttempt?
    var replies: [LocationSource.DeletionReply] = []
    var scheduled: UUID?
    var settingsPending = false
    var failures = 0
    var refresh: [String: Set<String>] = [:]

    init(_ record: PendingDeletion, progress: Progress) {
        self.record = record
        self.progress = progress
    }

    func rememberRefresh() {
        for (domain, folders) in attempt?.refresh ?? [:] {
            refresh[domain, default: []].formUnion(folders)
        }
    }
}

extension LocationSource {
    typealias DeletionReply = @Sendable (Result<PendingDeletion, Error>) -> Void
    // Success acknowledges durable, idempotent cleanup of exactly these confirmed-deleted paths.
    typealias DeletionSettings = @Sendable (PendingDeletion, [KeepPath]) async throws -> Void

    func deleteItem(_ request: DeletionRequest, recursive: Bool, progress: Progress,
                    started: @escaping @Sendable () -> Void, reply: @escaping DeletionReply) {
        access.enqueue { [self] in
            started()
            var admitted: UUID?
            defer {
                if let admitted { deletionRecoveryLock.withLock { deletionProgress[admitted] = nil } }
            }
            do {
                try requireDeletionRecoverySource()
                guard deletionSettings != nil else { throw UploadError.readOnly }
                if let running = deletionRecoveries.values.first(where: { $0.record.plan.request == request }) {
                    running.replies.append(reply)
                    return
                }
                let record = try prepareDeletionOnLane(request, recursive: recursive, progress: progress) { record in
                    admitted = record.id
                    registerDeletionProgress(progress, id: record.id)
                }
                let recovery = LocationDeletionRecovery(record, progress: progress)
                recovery.replies.append(reply)
                deletionRecoveries[record.id] = recovery
                deletionStateChanged()
                continueDeletionOnLane(recovery)
            } catch {
                deletionStateChanged()
                reply(.failure(error))
            }
        }
    }

    // Only explicit caller wiring starts recovery; construction and callback installation do not.
    func retryDeletions() {
        access.enqueue { [self] in
            do {
                try requireDeletionRecoverySource()
                let records = try editNamespace.perform { try Self.deletionOutbox().records() }
                for record in records where record.plan.owner == domainID && record.isPending {
                    retryDeletionOnLane(record.id, reply: nil)
                }
            } catch {
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .error("deletion_retry failed \(logFields(error), privacy: .public)")
            }
        }
    }

    func retryDeletion(_ id: UUID, reply: @escaping DeletionReply) {
        access.enqueue { [self] in retryDeletionOnLane(id, reply: reply) }
    }

    // Cancellation must reach a node before Stop waits behind that node on the lane.
    func stopDeletion(_ id: UUID, reply: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let progress = deletionRecoveryLock.withLock {
            deletionStops.insert(id)
            return deletionProgress[id]
        }
        progress?.cancel()
        access.enqueue { [self] in
            defer { deletionRecoveryLock.withLock { _ = deletionStops.remove(id) } }
            do {
                try requireDeletionRecoverySource()
                let record = try stopDeletionOnLane(id)
                let recovery = deletionRecoveries[id] ?? LocationDeletionRecovery(record, progress: Progress())
                recovery.rememberRefresh()
                recovery.record = record
                recovery.attempt = nil
                recovery.failures = 0
                deletionRecoveries[id] = recovery
                if !recovery.settingsPending { enqueueDeletionPass(recovery, after: .zero) }
                deletionStateChanged()
                reply(.success(()))
            } catch {
                if let recovery = deletionRecoveries[id] { failDeletionRecovery(recovery, error: error) }
                reply(.failure(error))
            }
        }
    }

    func dismissDeletion(_ id: UUID, reply: @escaping @Sendable (Result<Void, Error>) -> Void) {
        access.enqueue { [self] in
            let result = Result {
                try requireDeletionRecoverySource()
                try editNamespace.perform {
                    var record = try ownedDeletion(id)
                    try Self.deletionOutbox().dismiss(&record)
                }
            }
            deletionStateChanged()
            reply(result)
        }
    }

    func closeDeletionRecovery() {
        let active = deletionRecoveryLock.withLock {
            deletionClosed = true
            return Array(deletionProgress.values)
        }
        for progress in active { progress.cancel() }
        access.enqueue { [self] in
            for recovery in Array(deletionRecoveries.values) {
                completeDeletionRecovery(recovery, result: .failure(LocationError.catalogClosed))
            }
        }
    }

    private func requireDeletionRecoverySource() throws {
        guard !deletionRecoveryLock.withLock({ deletionClosed }) else { throw LocationError.catalogClosed }
        try editNamespace.perform {
            guard try editNamespace.source(domainID) === self else { throw LocationError.catalogClosed }
            try uploadLock.withLock {
                guard !mutationsSuspended else { throw UploadError.pendingWrites }
                try withCatalog { _ in }
            }
        }
    }

    private func registerDeletionProgress(_ progress: Progress, id: UUID) {
        let cancelled = deletionRecoveryLock.withLock {
            deletionProgress[id] = progress
            return deletionClosed || deletionStops.contains(id)
        }
        if cancelled { progress.cancel() }
    }

    private func retryDeletionOnLane(_ id: UUID, reply: DeletionReply?) {
        do {
            try requireDeletionRecoverySource()
            guard deletionSettings != nil else { throw UploadError.readOnly }
            let record = try editNamespace.perform { try ownedDeletion(id) }
            let recovery = deletionRecoveries[id] ?? LocationDeletionRecovery(record, progress: Progress())
            recovery.rememberRefresh()
            recovery.record = record
            recovery.attempt = nil
            recovery.failures = 0
            if let reply { recovery.replies.append(reply) }
            deletionRecoveries[id] = recovery
            if !recovery.settingsPending { enqueueDeletionPass(recovery, after: .zero) }
        } catch {
            reply?(.failure(error))
            Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                .error("deletion_retry id=\(id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
        }
    }

    private func continueDeletionOnLane(_ recovery: LocationDeletionRecovery) {
        guard deletionRecoveries[recovery.record.id] === recovery else { return }
        do {
            try requireDeletionRecoverySource()
            let current = try editNamespace.perform { try ownedDeletion(recovery.record.id) }
            if current != recovery.record {
                recovery.rememberRefresh()
                recovery.attempt = nil
                recovery.record = current
            }
            if !current.isSettled {
                registerDeletionProgress(recovery.progress, id: current.id)
                defer { deletionRecoveryLock.withLock { deletionProgress[current.id] = nil } }
                guard !recovery.progress.isCancelled else { throw TransferError.cancelled }
                recovery.record = try resumeDeletionOnLane(current.id, progress: recovery.progress)
            }
            if recovery.record.isComplete {
                try editNamespace.perform {
                    try Self.deletionOutbox().reconcileGuards(domains: recovery.record.plan.views.map(\.domain))
                }
                finishDeletionReply(recovery)
                return
            }
            guard let update = deletionSettings else { throw UploadError.readOnly }
            let delay = try settleDeletionOnLane(recovery.record, attempt: &recovery.attempt)
            recovery.rememberRefresh()
            if let delay {
                enqueueDeletionPass(recovery, after: delay)
                return
            }
            let record = recovery.record
            let keeps = record.confirmedDeletedKeepPaths
            recovery.settingsPending = true
            Task { [self] in
                let result: Result<Void, Error>
                do {
                    guard !deletionRecoveryLock.withLock({ deletionClosed }) else { throw LocationError.catalogClosed }
                    try await update(record, keeps)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                access.enqueue { [self] in finishDeletionSettings(recovery, record: record, result: result) }
            }
        } catch {
            failDeletionRecovery(recovery, error: error)
        }
    }

    private func finishDeletionSettings(_ recovery: LocationDeletionRecovery, record: PendingDeletion,
                                         result: Result<Void, Error>) {
        guard deletionRecoveries[record.id] === recovery else { return }
        recovery.settingsPending = false
        guard recovery.record == record, var attempt = recovery.attempt else {
            enqueueDeletionPass(recovery, after: .zero)
            return
        }
        do {
            try requireDeletionRecoverySource()
            try result.get()
            do {
                try finishDeletionSettlementOnLane(&recovery.record, afterKeepPathCleanup: &attempt)
            } catch {
                recovery.attempt = attempt
                failDeletionRecovery(recovery, error: error,
                                     preserveAttempt: error as? UploadError == .pendingWrites)
                return
            }
            recovery.attempt = attempt
            recovery.rememberRefresh()
            finishDeletionReply(recovery)
        } catch {
            failDeletionRecovery(recovery, error: error)
        }
    }

    private func enqueueDeletionPass(_ recovery: LocationDeletionRecovery, after delay: Duration) {
        let token = UUID(), id = recovery.record.id
        recovery.scheduled = token
        let seconds = max(0, delay / .seconds(1))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self, weak recovery] in
            guard let self, let recovery else { return }
            self.access.enqueue { [self] in
                guard self.deletionRecoveries[id] === recovery, recovery.scheduled == token else { return }
                recovery.scheduled = nil
                self.continueDeletionOnLane(recovery)
            }
        }
    }

    private func failDeletionRecovery(_ recovery: LocationDeletionRecovery, error: Error,
                                      preserveAttempt: Bool = false) {
        recovery.rememberRefresh()
        let attempt = recovery.attempt
        recovery.attempt = nil
        do {
            let current = try editNamespace.perform { try ownedDeletion(recovery.record.id) }
            if preserveAttempt, current == recovery.record { recovery.attempt = attempt }
            recovery.record = current
        } catch {
            completeDeletionRecovery(recovery, result: .failure(error))
            return
        }
        // Automatic passes only reconcile settled outcomes; remote retries need an explicit caller.
        if recovery.record.isSettled, recovery.failures < 3, canRetryDeletionSettlement(error) {
            let delay = Duration.seconds(1 << recovery.failures)
            recovery.failures += 1
            enqueueDeletionPass(recovery, after: delay)
        } else {
            completeDeletionRecovery(recovery, result: .failure(error))
        }
    }

    private func canRetryDeletionSettlement(_ error: Error) -> Bool {
        if error is LocationError { return false }
        if let error = error as? ItemDeletionError { return error == .unresolved }
        if let error = error as? UploadError { return error == .pendingWrites || error == .unresolved }
        if let error = error as? SourceFailure {
            return [.notConnected, .serverUnreachable, .versionChanged, .listingIncomplete].contains(error)
        }
        return error as? TransferError != .cancelled
    }

    private func finishDeletionReply(_ recovery: LocationDeletionRecovery) {
        let result = Result {
            try requireDeletionRecoverySource()
            try requireDeleted(recovery.record)
            return recovery.record
        }
        let sources = editNamespace.perform {
            recovery.record.plan.views.compactMap { view -> LocationSource? in
                guard let source = try? editNamespace.source(view.domain),
                      source.folder.string.utf8.elementsEqual(view.folder.utf8) else { return nil }
                return source
            }
        }
        for source in sources {
            source.signalFolders(Array(recovery.refresh[source.domainID] ?? []))
            source.deletionStateChanged()
        }
        completeDeletionRecovery(recovery, result: result)
    }

    private func completeDeletionRecovery(_ recovery: LocationDeletionRecovery,
                                          result: Result<PendingDeletion, Error>) {
        guard deletionRecoveries[recovery.record.id] === recovery else { return }
        deletionRecoveries[recovery.record.id] = nil
        recovery.scheduled = nil
        let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
        logger.info("deletion id=\(recovery.record.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
        if case .failure(let error) = result {
            logger.error("deletion id=\(recovery.record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
        }
        deletionStateChanged()
        for reply in recovery.replies { reply(result) }
    }
}
