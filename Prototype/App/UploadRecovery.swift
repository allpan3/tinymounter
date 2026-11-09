import Foundation
import OSLog

/// Which upload failures TinyMounter retries without the user.
enum UploadRecovery {
    /// The panel lists a failure that retries by itself as a waiting transfer, not as failed.
    static func retriesByItself(_ error: Error) -> Bool { UploadRetrySchedule.isTransient(error) }
}

/// One location's retry of creates and saves that failed transiently, with `retry` as the action:
/// the location's Retry Pending Changes. A reconnect retries at once through the share's recovery.
final class UploadRetry: @unchecked Sendable {
    private let domainID: String
    private let retry: @Sendable () -> Void
    private let lock = NSLock()
    private var schedule = UploadRetrySchedule()
    private var waiting: (id: UInt64, work: DispatchWorkItem)?
    private var nextID: UInt64 = 0
    private var closed = false
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "upload")

    init(domainID: String, retry: @escaping @Sendable () -> Void) {
        self.domainID = domainID
        self.retry = retry
    }

    /// The result of one create or save, by a key that stays the same when macOS sends it again.
    func finished<T>(_ upload: String, result: Result<T, Error>) {
        guard case .failure(let error) = result, UploadRecovery.retriesByItself(error) else {
            lock.withLock { if schedule.settled(upload) { cancelWaiting() } }
            return
        }
        lock.withLock {
            guard !closed, let delay = schedule.failed(upload) else { return }
            nextID += 1
            let id = nextID
            let work = DispatchWorkItem { [weak self] in self?.fire(id) }
            waiting = (id, work)
            let milliseconds = Int(delay / .milliseconds(1))
            Self.logger.info("upload_retry_scheduled domain=\(self.domainID, privacy: .public) delay_ms=\(milliseconds)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
        }
    }

    /// The share connected again; its recovery retries every upload now.
    func connected() {
        lock.withLock {
            schedule.connected()
            cancelWaiting()
        }
    }

    func close() {
        lock.withLock {
            closed = true
            cancelWaiting()
        }
    }

    private func fire(_ id: UInt64) {
        let active = lock.withLock {
            guard waiting?.id == id else { return false }
            waiting = nil
            schedule.fired()
            return !closed
        }
        guard active else { return }
        Self.logger.info("upload_retry domain=\(self.domainID, privacy: .public)")
        retry()
    }

    private func cancelWaiting() {
        waiting?.work.cancel()
        waiting = nil
    }
}
