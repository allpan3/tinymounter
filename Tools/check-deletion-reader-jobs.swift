import Foundation

private final class M24HeldReaderJobs: @unchecked Sendable {
    @MainActor static var active: M24HeldReaderJobs?
    let session: SourceReaderSession
    let queue: OperationQueue
    let ids = (0..<4).map { _ in UUID() }
    let lock = NSLock()
    var replies: [UUID: [NSError?]] = [:]
    var timedOut = false

    init(session: SourceReaderSession, queue: OperationQueue) {
        self.session = session
        self.queue = queue
    }

    func drain() {
        ids.forEach { session.release($0.uuidString) }
        queue.isSuspended = false
    }
}

extension SourceReaderHost {
    func checkIncompleteDeletion(domain: String) async throws -> [String: String] {
        guard let config = M22FinderProbe.selected(domain), source(domain) != nil,
              let session = connections[domain]?.exportedObject as? SourceReaderSession else {
            throw M22FinderProbe.Failure.check("connected-deletion-session-required")
        }
        let records = try LocationSource.deletionOutbox().records()
        let pending = records.filter {
            $0.plan.owner == domain && !$0.isComplete && $0.isSettled
                && $0.plan.selected.path == config.folder + "/Deletion/CatalogDelay"
        }
        try M22FinderProbe.require(pending.count == 1, "one-incomplete-catalog-record")
        let record = pending[0], original = record.plan.request, id = UUID()
        let request = try ReaderMessage.encode(DeleteItemRequest(id: id, item: original.item,
            contentVersion: original.contentVersion, metadataVersion: original.metadataVersion,
            eventVersion: original.eventVersion, recursive: true))
        let result: (Data?, NSError?) = await withCheckedContinuation { continuation in
            session.deleteItem(request) { data, error in continuation.resume(returning: (data, error)) }
        }
        session.release(id.uuidString)
        try M22FinderProbe.require(result.0 == nil && result.1?.domain == NSFileProviderErrorDomain
            && result.1?.code == NSFileProviderError.cannotSynchronize.rawValue,
            "unfinished-catalog-cannot-synchronize")
        try M22FinderProbe.require(try LocationSource.deletionOutbox().records() == records,
                                  "unfinished-replay-records-unchanged")
        return ["record": record.id.uuidString, "error": "cannotSynchronize", "recordUnchanged": "true"]
    }

    func checkDeletionSession(domain: String, invalidate: Bool) throws -> [String: Int] {
        guard let connection = connections[domain],
              let session = connection.exportedObject as? SourceReaderSession,
              let source = source(domain) else {
            throw M22FinderProbe.Failure.check("connected-deletion-session-required")
        }
        let (progress, stops) = source.deletionRecoveryLock.withLock {
            (Array(source.deletionProgress.values), source.deletionProgress.keys.filter {
                source.deletionCancellation.isStopping($0)
            }.count)
        }
        if invalidate { connection.invalidate() }
        return ["jobs": session.checkJobCount(), "activeProgress": progress.count,
                "cancelledProgress": progress.filter(\.isCancelled).count, "stops": stops]
    }

    func checkDeletionReaderJobs(domain: String, item: String, phase: String) throws -> [String: Int] {
        if phase == "hold" {
            try M22FinderProbe.require(M24HeldReaderJobs.active == nil && queue.operationCount == 0,
                                      "idle-reader-queue-required")
            guard let session = connections[domain]?.exportedObject as? SourceReaderSession,
                  let source = source(domain),
                  let row = try source.withCatalog({ try $0.item(id: item) }),
                  row.kind == .file, !row.deleted, row.size > 0 else {
                throw M22FinderProbe.Failure.check("live-reader-required")
            }
            try M22FinderProbe.require(session.checkJobCount() == 0, "idle-reader-session-required")
            let held = M24HeldReaderJobs(session: session, queue: queue)
            M24HeldReaderJobs.active = held
            queue.isSuspended = true
            do {
                for id in held.ids {
                    let request = try SourceReadRequest(id: id, item: row.id, version: row.contentVersion,
                        range: ByteRange(offset: 0, length: row.size, fileSize: row.size), background: false)
                    session.fetch(try ReaderMessage.encode(request)) { _, error in
                        held.lock.withLock { held.replies[id, default: []].append(error) }
                    }
                }
                try M22FinderProbe.require(session.checkJobCount() == 4, "four-real-fetch-jobs-required")
            } catch {
                held.drain()
                M24HeldReaderJobs.active = nil
                throw error
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                guard M24HeldReaderJobs.active === held, held.queue.isSuspended else { return }
                held.lock.withLock { held.timedOut = true }
                held.drain()
            }
        }
        guard let held = M24HeldReaderJobs.active,
              (connections[domain]?.exportedObject as? SourceReaderSession) === held.session else {
            throw M22FinderProbe.Failure.check("original-reader-session-required")
        }
        if phase == "release-one" { held.session.release(held.ids[0].uuidString) }
        if phase == "drain" { held.drain() }
        let (replies, timedOut) = held.lock.withLock { (held.replies, held.timedOut) }
        try M22FinderProbe.require(!timedOut, "reader-hold-timed-out")
        if phase == "verify" {
            try M22FinderProbe.require(queue.operationCount == 0 && held.session.checkJobCount() == 0,
                                      "reader-jobs-drained")
            try M22FinderProbe.require(replies.count == 4 && replies.values.allSatisfy {
                $0.count == 1 && $0[0]?.domain == NSCocoaErrorDomain
                    && $0[0]?.code == CocoaError.userCancelled.rawValue
            }, "four-single-cancellation-replies")
            M24HeldReaderJobs.active = nil
        }
        return ["jobs": held.session.checkJobCount(), "replies": replies.values.reduce(0) { $0 + $1.count },
                "queuedOperations": queue.operationCount]
    }
}

private extension SourceReaderSession {
    func checkJobCount() -> Int { lock.withLock { jobs.count } }
}

private final class M24JoinedDeletionJobs: @unchecked Sendable {
    @MainActor static var active: M24JoinedDeletionJobs?
    let session: SourceReaderSession
    let source: LocationSource
    let record: PendingDeletion
    let ids = (0..<3).map { _ in UUID() }
    let lock = NSLock()
    var replies: [UUID: [(Data?, NSError?)]] = [:]

    init(session: SourceReaderSession, source: LocationSource, record: PendingDeletion) {
        self.session = session
        self.source = source
        self.record = record
    }

    func request(_ id: UUID) throws -> Data {
        let original = record.plan.request
        return try ReaderMessage.encode(DeleteItemRequest(id: id, item: original.item,
            contentVersion: original.contentVersion, metadataVersion: original.metadataVersion,
            eventVersion: original.eventVersion, recursive: true))
    }
}

extension SourceReaderHost {
    func checkJoinedDeletionJobs(domain: String, phase: String) async throws -> [String: Int] {
        if phase == "hold" {
            guard M24JoinedDeletionJobs.active == nil,
                  let session = connections[domain]?.exportedObject as? SourceReaderSession,
                  let source = source(domain) else {
                throw M22FinderProbe.Failure.check("idle-joined-probe-required")
            }
            let records = try LocationSource.deletionOutbox().records().filter {
                $0.plan.owner == domain && !$0.isComplete
            }
            try M22FinderProbe.require(records.count == 1 && records[0].isSettled
                && session.checkJobCount() == 1, "one-held-finder-deletion-required")
            let held = M24JoinedDeletionJobs(session: session, source: source, record: records[0])
            M24JoinedDeletionJobs.active = held
            for id in held.ids {
                session.deleteItem(try held.request(id)) { data, error in
                    held.lock.withLock { held.replies[id, default: []].append((data, error)) }
                }
            }
            let joined: Int = await withCheckedContinuation { continuation in
                source.access.enqueue {
                    continuation.resume(returning: source.deletionRecoveries[held.record.id]?.replies.count ?? 0)
                }
            }
            try M22FinderProbe.require(joined == 4 && session.checkJobCount() == 4, "four-joined-deletion-jobs")
            let extra = try held.request(UUID())
            let busy: NSError? = await withCheckedContinuation { continuation in
                session.deleteItem(extra) { _, error in continuation.resume(returning: error) }
            }
            try M22FinderProbe.require(busy?.domain == NSCocoaErrorDomain
                && busy?.code == CocoaError.xpcConnectionReplyInvalid.rawValue, "fifth-deletion-job-busy")
        }
        guard let held = M24JoinedDeletionJobs.active else {
            throw M22FinderProbe.Failure.check("held-deletion-jobs-required")
        }
        if phase == "release" {
            held.session.release(held.ids[0].uuidString)
            try M22FinderProbe.require(!held.source.deletionRecoveryLock.withLock {
                held.source.deletionCancellation.isStopping(held.record.id)
            }, "released-waiter-does-not-stop")
        }
        if phase == "cancel" {
            let gate = DispatchSemaphore(value: 0)
            await withCheckedContinuation { continuation in
                held.source.access.enqueue {
                    continuation.resume()
                    _ = gate.wait(timeout: .now() + 30)
                }
            }
            defer { gate.signal() }
            held.session.cancelDeletion(held.ids[1].uuidString)
            try M22FinderProbe.require(held.source.deletionRecoveryLock.withLock {
                held.source.deletionCancellation.isStopping(held.record.id)
            }, "joined-cancellation-queues-stop")
        }
        let replies = held.lock.withLock { held.replies }
        if phase == "verify" {
            try M22FinderProbe.require(replies.count == 3 && replies.values.allSatisfy { $0.count == 1 },
                                      "three-single-joined-replies")
            for id in held.ids {
                let (data, error) = replies[id]![0]
                guard error == nil, let data else { throw M22FinderProbe.Failure.check("joined-deletion-success") }
                let receipt = try ReaderMessage.decode(DeleteItemReceipt.self, from: data)
                try M22FinderProbe.require(receipt.id == id && receipt.item == held.record.plan.request.item,
                                          "joined-receipt-identity")
                held.session.release(id.uuidString)
            }
            try M22FinderProbe.require(held.session.checkJobCount() == 0, "joined-jobs-drained")
            let current = try LocationSource.deletionOutbox().reload(held.record)
            try M22FinderProbe.require(current.isComplete && current.progress.stopped == nil
                && current.progress.exceptions.isEmpty, "completed-outcome-retained")
            M24JoinedDeletionJobs.active = nil
        }
        return ["jobs": held.session.checkJobCount(), "replies": replies.values.reduce(0) { $0 + $1.count }]
    }
}
