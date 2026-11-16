import Foundation
import OSLog

/// Which upload failures TinyMounter retries without the user.
enum UploadRecovery {
    /// The panel lists a failure that retries by itself as a waiting transfer, not as failed.
    static func retriesByItself(_ error: Error) -> Bool { UploadRetrySchedule.isTransient(error) }
}

/// Connection recovery retries pending changes; namespace wakeups repeat until macOS resends.
final class UploadRetry: @unchecked Sendable {
    private let domainID: String
    private let retry: @Sendable () -> Void
    private let resumeWrites: @Sendable () -> Void
    private let lock = NSLock()
    private var schedule = UploadRetrySchedule()
    private var waiting: (id: UInt64, work: DispatchWorkItem)?
    private var nextID: UInt64 = 0
    private var closed = false
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    init(domainID: String, retry: @escaping @Sendable () -> Void,
         resumeWrites: @escaping @Sendable () -> Void) {
        self.domainID = domainID
        self.retry = retry
        self.resumeWrites = resumeWrites
    }

    /// The result of one create or save, by a key that stays the same when macOS sends it again.
    func finished<T>(_ upload: String, result: Result<T, Error>) {
        guard case .failure(let error) = result,
              error as? UploadError == .pendingWrites || UploadRecovery.retriesByItself(error) else {
            lock.withLock { if schedule.settled(upload) { cancelWaiting() } }
            return
        }
        lock.withLock {
            guard !closed,
                  let delay = schedule.failed(upload, waitingForNamespace: error as? UploadError == .pendingWrites)
            else { return }
            scheduleNext(after: delay)
        }
    }

    func started(_ upload: String) {
        lock.withLock { if schedule.started(upload) { cancelWaiting() } }
    }

    // A reconnect handles connection errors, but a namespace refusal may still be in flight.
    func connected() {
        lock.withLock {
            if schedule.connected() { cancelWaiting() }
        }
    }

    func close() {
        lock.withLock {
            closed = true
            cancelWaiting()
        }
    }

    private func fire(_ id: UInt64) {
        let recover = lock.withLock { () -> Bool? in
            guard !closed, waiting?.id == id else { return nil }
            waiting = nil
            let recover = schedule.hasTransientFailures
            if let delay = schedule.fired() { scheduleNext(after: delay) }
            return recover
        }
        guard let recover else { return }
        Self.logger.info("upload_retry domain=\(self.domainID, privacy: .public)")
        if recover { retry() } else { resumeWrites() }
    }

    private func scheduleNext(after delay: Duration) {
        nextID += 1
        let id = nextID
        let work = DispatchWorkItem { [weak self] in self?.fire(id) }
        waiting = (id, work)
        let milliseconds = Int(delay / .milliseconds(1))
        Self.logger.info("upload_retry_scheduled domain=\(self.domainID, privacy: .public) delay_ms=\(milliseconds)")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }

    private func cancelWaiting() {
        waiting?.work.cancel()
        waiting = nil
    }
}
