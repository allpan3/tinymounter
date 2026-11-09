import Darwin
import Foundation

/// Delays that start at `first` and double up to `longest` while a retry keeps failing.
public struct RetryBackoff: Sendable {
    public let first: Duration
    public let longest: Duration
    private var next: Duration

    public init(first: Duration, longest: Duration) {
        self.first = first
        self.longest = longest
        next = first
    }

    /// The delay before this retry; the next one waits twice as long, up to `longest`.
    public mutating func delay() -> Duration {
        defer { next = min(next * 2, longest) }
        return next
    }

    public mutating func reset() { next = first }
}

/// The uploads of one location that failed with a transient error, and the retry that waits for
/// them. One retry waits at a time; it retries every such upload, as Retry Pending Changes does.
public struct UploadRetrySchedule: Sendable {
    public static let first = Duration.seconds(2)
    public static let longest = Duration.seconds(300)
    private var failing: Set<String> = []
    private var backoff = RetryBackoff(first: first, longest: longest)
    public private(set) var isWaiting = false

    public init() {}

    /// A lost connection, a timeout or a sharing violation, which a later attempt can get past.
    /// A sharing violation lasts while a dropped session, or another client, holds the file open.
    public static func isTransient(_ error: Error) -> Bool {
        let posix = error as NSError
        if posix.domain == NSPOSIXErrorDomain, posix.code == Int(ETXTBSY) { return true }
        switch SourceFailure.classify(error, context: .fetch) {
        case .serverUnreachable, .notConnected: return true
        default: return false
        }
    }

    /// `upload` failed transiently. Returns the delay of a new retry; nil while one waits.
    public mutating func failed(_ upload: String) -> Duration? {
        failing.insert(upload)
        guard !isWaiting else { return nil }
        isWaiting = true
        return backoff.delay()
    }

    /// `upload` finished, or failed in a way that waits for the user. Returns true when the
    /// waiting retry is no longer needed: no upload is left failing transiently.
    public mutating func settled(_ upload: String) -> Bool {
        failing.remove(upload)
        guard failing.isEmpty else { return false }
        backoff.reset()
        defer { isWaiting = false }
        return isWaiting
    }

    /// The waiting retry runs. Uploads that fail again schedule the next, after a longer delay.
    public mutating func fired() { isWaiting = false }

    /// The share connected again, and its recovery retries every upload at once.
    public mutating func connected() {
        failing.removeAll()
        backoff.reset()
        isWaiting = false
    }
}
