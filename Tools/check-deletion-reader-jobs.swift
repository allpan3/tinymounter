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
