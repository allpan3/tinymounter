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

/// One location's connection failures and writes waiting for namespace settlement.
public struct UploadRetrySchedule: Sendable {
    public static let first = Duration.seconds(2)
    public static let longest = Duration.seconds(300)
    private var failing: Set<String> = []
    private var blocked: Set<String> = []
    private var backoff = RetryBackoff(first: first, longest: longest)
    public private(set) var isWaiting = false

    public init() {}

    public var hasTransientFailures: Bool { !failing.subtracting(blocked).isEmpty }

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

    public mutating func failed(_ upload: String, waitingForNamespace: Bool = false) -> Duration? {
        failing.insert(upload)
        if waitingForNamespace { blocked.insert(upload) } else { blocked.remove(upload) }
        guard !isWaiting else { return nil }
        isWaiting = true
        return backoff.delay()
    }

    /// True when finishing this item leaves no retry needed.
    public mutating func settled(_ upload: String) -> Bool {
        failing.remove(upload)
        blocked.remove(upload)
        guard failing.isEmpty else { return false }
        backoff.reset()
        defer { isWaiting = false }
        return isWaiting
    }

    // A signal can precede macOS recording the error; only a resend acknowledges its delivery.
    public mutating func started(_ upload: String) -> Bool {
        guard blocked.remove(upload) != nil else { return false }
        failing.remove(upload)
        guard failing.isEmpty else { return false }
        defer { isWaiting = false }
        return isWaiting
    }

    @discardableResult
    public mutating func fired() -> Duration? {
        isWaiting = !blocked.isEmpty
        return isWaiting ? backoff.delay() : nil
    }

    // Reconnection also signals once; it cannot acknowledge a blocked item's resend.
    @discardableResult
    public mutating func connected() -> Bool {
        failing = blocked
        backoff.reset()
        guard blocked.isEmpty else { return false }
        let cancel = isWaiting
        isWaiting = false
        return cancel
    }
}
