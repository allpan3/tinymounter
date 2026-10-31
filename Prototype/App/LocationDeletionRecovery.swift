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
    var cancellations: [UUID: (progress: Progress, observation: NSKeyValueObservation)] = [:]
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

    func update(_ record: PendingDeletion) {
        guard self.record != record else { return }
        rememberRefresh()
        self.record = record
        attempt = nil
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
            var recovery: LocationDeletionRecovery?
            defer {
                if let recovery { deletionRecoveryLock.withLock { deletionProgress[recovery.record.id] = nil } }
            }
            do {
                try requireDeletionRecoverySource()
                guard deletionSettings != nil else { throw UploadError.readOnly }
                if let running = deletionRecoveries.values.first(where: { $0.record.plan.request == request }) {
                    joinDeletionRecovery(running, progress: progress, reply: reply)
                    return
                }
                _ = try prepareDeletionOnLane(request, recursive: recursive, progress: progress) { record in
                    recovery = beginDeletionRecovery(record, progress: progress, reply: reply)
                }
                guard let recovery else { throw UploadError.unresolved }
                deletionStateChanged()
                continueDeletionOnLane(recovery, resume: true)
            } catch {
                // Admission can be visible even when its final directory sync or capture close failed.
                if recovery == nil {
                    do {
                        let record = try editNamespace.perform {
                            try Self.deletionOutbox().records().first {
                                $0.plan.owner == domainID && $0.plan.request == request
                            }
                        }
                        if let record { recovery = beginDeletionRecovery(record, progress: progress, reply: reply) }
                    } catch {
                        deletionStateChanged()
                        reply(.failure(error))
                        return
                    }
                }
                deletionStateChanged()
                if let recovery { failDeletionRecovery(recovery, error: error) }
                else { reply(.failure(error)) }
            }
        }
    }

    // Launch and share recovery settle outcomes without issuing another remote deletion request.
    func retryDeletions() {
        access.enqueue { [self] in
            do {
                try requireDeletionRecoverySource()
                let records = try editNamespace.perform { try Self.deletionOutbox().records() }
                for record in records where record.plan.owner == domainID && record.isPending && record.isSettled {
                    retryDeletionOnLane(record.id, resume: false, reply: nil)
                }
            } catch {
                Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                    .error("deletion_retry failed \(logFields(error), privacy: .public)")
            }
        }
    }

    func retryDeletion(_ id: UUID, reply: @escaping DeletionReply) {
        access.enqueue { [self] in retryDeletionOnLane(id, resume: true, reply: reply) }
    }

    // Cancellation must reach a node before Stop waits behind that node on the lane.
    func stopDeletion(_ id: UUID, reply: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queueDeletionStop(id, reply: reply)
    }

    private func queueDeletionStop(_ id: UUID, cancellation: UUID? = nil,
                                   reply: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let (accepted, progress) = deletionRecoveryLock.withLock { () -> (Bool, Progress?) in
            if let cancellation {
                guard deletionCancellations.removeValue(forKey: cancellation) == id else { return (false, nil) }
            }
            deletionStops[id, default: 0] += 1
            return (true, deletionProgress[id])
        }
        guard accepted else { return }
        access.enqueue { [self] in
            deletionRecoveryLock.withLock {
                let remaining = (deletionStops[id] ?? 1) - 1
                deletionStops[id] = remaining > 0 ? remaining : nil
            }
            do {
                // Closing a source must not prevent an already requested durable Stop.
                let record = try stopDeletionOnLane(id)
                let recovery = deletionRecoveries[id] ?? LocationDeletionRecovery(record, progress: Progress())
                recovery.update(record)
                recovery.failures = 0
                deletionRecoveries[id] = recovery
                if deletionRecoveryLock.withLock({ deletionClosed }) {
                    completeDeletionRecovery(recovery, result: .failure(LocationError.catalogClosed))
                } else if !recovery.settingsPending {
                    enqueueDeletionPass(recovery, after: .zero)
                }
                deletionStateChanged()
                reply(.success(()))
            } catch {
                let stopError = error
                do {
                    let record = try editNamespace.perform { try ownedDeletion(id) }
                    let recovery = deletionRecoveries[id] ?? LocationDeletionRecovery(record, progress: Progress())
                    recovery.update(record)
                    deletionRecoveries[id] = recovery
                    retryDeletionSettlement(recovery, error: stopError)
                } catch {
                    if let recovery = deletionRecoveries[id] {
                        completeDeletionRecovery(recovery, result: .failure(error))
                    }
                }
                deletionStateChanged()
                reply(.failure(stopError))
            }
        }
        if let progress, !progress.isCancelled { progress.cancel() }
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
            return deletionClosed || deletionStops[id] != nil
        }
        if cancelled, !progress.isCancelled { progress.cancel() }
    }

    private func beginDeletionRecovery(_ record: PendingDeletion, progress: Progress,
                                       reply: @escaping DeletionReply) -> LocationDeletionRecovery {
        if let recovery = deletionRecoveries[record.id] {
            recovery.update(record)
            joinDeletionRecovery(recovery, progress: progress, reply: reply)
            return recovery
        }
        let recovery = LocationDeletionRecovery(record, progress: progress)
        deletionRecoveries[record.id] = recovery
        registerDeletionProgress(progress, id: record.id)
        joinDeletionRecovery(recovery, progress: progress, reply: reply)
        return recovery
    }

    private func joinDeletionRecovery(_ recovery: LocationDeletionRecovery, progress: Progress,
                                      reply: @escaping DeletionReply) {
        let token = UUID(), id = recovery.record.id
        recovery.replies.append(reply)
        deletionRecoveryLock.withLock { deletionCancellations[token] = id }
        let observation = progress.observe(\.isCancelled, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.isCancelled else { return }
            self?.queueDeletionStop(id, cancellation: token) { _ in }
        }
        recovery.cancellations[token] = (progress, observation)
    }

    private func retryDeletionOnLane(_ id: UUID, resume: Bool, reply: DeletionReply?) {
        do {
            try requireDeletionRecoverySource()
            guard deletionSettings != nil else { throw UploadError.readOnly }
            let record = try editNamespace.perform { try ownedDeletion(id) }
            guard resume || (record.isPending && record.isSettled) else { return }
            let recovery = deletionRecoveries[id] ?? LocationDeletionRecovery(record, progress: Progress())
            recovery.update(record)
            recovery.failures = 0
            if let reply { recovery.replies.append(reply) }
            deletionRecoveries[id] = recovery
            if !recovery.settingsPending { enqueueDeletionPass(recovery, after: .zero, resume: resume) }
        } catch {
            reply?(.failure(error))
            Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
                .error("deletion_retry id=\(id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
        }
    }

    private func continueDeletionOnLane(_ recovery: LocationDeletionRecovery, resume: Bool = false) {
        guard deletionRecoveries[recovery.record.id] === recovery else { return }
        do {
            try requireDeletionRecoverySource()
            guard !deletionRecoveryLock.withLock({ deletionStops[recovery.record.id] != nil }) else { return }
            let current = try editNamespace.perform { try ownedDeletion(recovery.record.id) }
            recovery.update(current)
            if !current.isSettled {
                guard resume else { throw UploadError.pendingWrites }
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

    private func enqueueDeletionPass(_ recovery: LocationDeletionRecovery, after delay: Duration,
                                     resume: Bool = false) {
        let token = UUID(), id = recovery.record.id
        recovery.scheduled = token
        let seconds = max(0, delay / .seconds(1))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self, weak recovery] in
            guard let self, let recovery else { return }
            self.access.enqueue { [self] in
                guard self.deletionRecoveries[id] === recovery, recovery.scheduled == token else { return }
                recovery.scheduled = nil
                self.continueDeletionOnLane(recovery, resume: resume)
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
        retryDeletionSettlement(recovery, error: error)
    }

    private func retryDeletionSettlement(_ recovery: LocationDeletionRecovery, error: Error) {
        if deletionRecoveryLock.withLock({ deletionStops[recovery.record.id] != nil }) { return }
        if deletionRecoveryLock.withLock({ deletionClosed }) {
            completeDeletionRecovery(recovery, result: .failure(LocationError.catalogClosed))
            return
        }
        // Automatic passes only reconcile settled outcomes; remote retries need an explicit caller.
        if recovery.record.isSettled, recovery.failures < 3, canRetryDeletionSettlement(error) {
            let delay = Duration.seconds(1 << recovery.failures)
            recovery.failures += 1
            if !recovery.settingsPending { enqueueDeletionPass(recovery, after: delay) }
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
        completeDeletionRecovery(recovery, result: result)
    }

    private func completeDeletionRecovery(_ recovery: LocationDeletionRecovery,
                                          result: Result<PendingDeletion, Error>) {
        guard deletionRecoveries[recovery.record.id] === recovery else { return }
        let id = recovery.record.id
        let (stopping, cancelled) = deletionRecoveryLock.withLock { () -> (Bool, [UUID]) in
            // Cancellation can become visible before its KVO callback acquires this lock.
            let cancelled = recovery.cancellations.compactMap { token, cancellation in
                deletionCancellations[token] == id && cancellation.progress.isCancelled ? token : nil
            }
            guard deletionStops[id] == nil, cancelled.isEmpty else { return (true, cancelled) }
            for token in recovery.cancellations.keys { deletionCancellations[token] = nil }
            return (false, [])
        }
        for token in cancelled { queueDeletionStop(id, cancellation: token) { _ in } }
        guard !stopping else { return }
        deletionRecoveries[recovery.record.id] = nil
        recovery.scheduled = nil
        for cancellation in recovery.cancellations.values { cancellation.observation.invalidate() }
        recovery.cancellations.removeAll()
        recovery.rememberRefresh()
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
        let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")
        logger.info("deletion id=\(recovery.record.id.uuidString, privacy: .public) ok=\((try? result.get()) != nil)")
        if case .failure(let error) = result {
            logger.error("deletion id=\(recovery.record.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
        }
        deletionStateChanged()
        let replies = recovery.replies
        recovery.replies.removeAll()
        for reply in replies { reply(result) }
    }
}
