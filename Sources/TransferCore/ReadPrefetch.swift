import Foundation
import OSLog

/// Reads the extent after a sequential fetch, so its transfer overlaps the system's handoff.
/// One candidate at a time; only a fetch of exactly its item, version and range claims it.
public final class ReadPrefetch: @unchecked Sendable {
    public typealias Transfer = @Sendable (SourceReadRequest, Progress) throws -> TransferOutput

    private final class Candidate: @unchecked Sendable {
        let request: SourceReadRequest
        let progress = Progress()
        /// Left when the read ends, whether or not it ran.
        let finished = DispatchGroup()
        /// These two change under the prefetch lock.
        var started = false
        var output: TransferOutput?

        init(request: SourceReadRequest) {
            self.request = request
            finished.enter()
        }
    }

    private let space: DownloadSpace
    /// Unclaimed prefetched bytes are this old at most when handed over, then discarded.
    private let lifetime: DispatchTimeInterval
    private let lock = NSLock()
    private var candidate: Candidate?
    private var closed = false
    /// The end of the last completed fetch; a fetch starting there continues a sequential reader.
    private var lastEnd: (item: String, version: String, end: Int64)?
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")

    public init(space: DownloadSpace, lifetime: DispatchTimeInterval = .seconds(2)) {
        self.space = space
        self.lifetime = lifetime
    }

    /// The finished read of exactly this range, or nil after cancelling any other candidate.
    /// The caller then owns the staging file; the candidate's space reservation is released.
    public func claim(_ request: SourceReadRequest, isCancelled: () -> Bool) -> TransferOutput? {
        guard let candidate = lock.withLock({ () -> Candidate? in
            defer { self.candidate = nil }
            return self.candidate
        }) else { return nil }
        let wanted = candidate.request
        guard lock.withLock({ candidate.started }), wanted.item == request.item, wanted.version == request.version,
              wanted.range == request.range else {
            discard(candidate)
            return nil
        }
        while candidate.finished.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if isCancelled() { discard(candidate); return nil }
        }
        guard let output = lock.withLock({ candidate.output }) else { discard(candidate); return nil }
        space.end(wanted.id)
        Self.logger.info("""
            prefetch request=\(wanted.id.uuidString, privacy: .public) \
            claimed_by=\(request.id.uuidString, privacy: .public)
            """)
        return output
    }

    /// Records a completed fetch. When it continued the previous one, starts reading `next()`
    /// through `enqueue`, unless a candidate is already pending or the prefetch is closed.
    public func completed(_ request: SourceReadRequest, next: () -> ByteRange?,
                          enqueue: (@escaping @Sendable () -> Void) -> Void, transfer: @escaping Transfer) {
        let continues = lock.withLock { () -> Bool in
            defer { lastEnd = (request.item, request.version, request.range.end) }
            guard let lastEnd else { return false }
            return lastEnd.item == request.item && lastEnd.version == request.version
                && lastEnd.end == request.range.offset
        }
        guard continues, let range = next(),
              let following = try? SourceReadRequest(id: UUID(), item: request.item, version: request.version,
                                                     range: range, background: true) else { return }
        let candidate = Candidate(request: following)
        let accepted = lock.withLock { () -> Bool in
            guard !closed, self.candidate == nil else { return false }
            self.candidate = candidate
            return true
        }
        guard accepted else { candidate.finished.leave(); return }
        enqueue { [self] in run(candidate, transfer: transfer) }
    }

    /// Discards any candidate and accepts no new one.
    public func close() {
        let pending = lock.withLock {
            closed = true
            defer { candidate = nil }
            return candidate
        }
        if let pending { discard(pending) }
    }

    private func run(_ candidate: Candidate, transfer: Transfer) {
        defer { candidate.finished.leave() }
        let request = candidate.request
        guard lock.withLock({ () -> Bool in
            guard self.candidate === candidate, !candidate.progress.isCancelled else { return false }
            candidate.started = true
            return true
        }) else { return }
        do {
            try space.begin(request.id, bytes: request.range.length)
            let output = try transfer(request, candidate.progress)
            lock.withLock { candidate.output = output }
            Self.logger.info("""
                prefetch request=\(request.id.uuidString, privacy: .public) item=\(request.item, privacy: .public) \
                offset=\(request.range.offset) bytes=\(request.range.length) \
                transfer_seconds=\(output.metrics.transferSeconds)
                """)
        } catch {
            Self.logger.info("""
                prefetch request=\(request.id.uuidString, privacy: .public) item=\(request.item, privacy: .public) \
                offset=\(request.range.offset) stopped \(logFields(error), privacy: .public)
                """)
            drop(candidate)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [self] in drop(candidate) }
    }

    /// Discards the candidate unless a fetch or `close` already took it.
    private func drop(_ candidate: Candidate) {
        let current = lock.withLock { () -> Bool in
            guard self.candidate === candidate else { return false }
            self.candidate = nil
            return true
        }
        if current { discard(candidate) }
    }

    /// Cancels the read; once it ends, removes its staging file and releases its reservation.
    private func discard(_ candidate: Candidate) {
        candidate.progress.cancel()
        candidate.finished.notify(queue: .global(qos: .utility)) { [self] in
            let url = lock.withLock { candidate.output?.stagingURL }
            let removed = url.map { (try? FileManager.default.removeItem(at: $0)) != nil }
            space.end(candidate.request.id)
            Self.logger.info("""
                prefetch request=\(candidate.request.id.uuidString, privacy: .public) discarded \
                started=\(self.lock.withLock { candidate.started }) \
                staging_removed=\(removed.map(String.init) ?? "none", privacy: .public)
                """)
        }
    }
}
