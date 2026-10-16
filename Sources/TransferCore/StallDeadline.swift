import Foundation

/// D2: from the app's `started`, a wait ends after `limit` with neither progress nor a reply.
public struct StallDeadline: Sendable {
    public static let limit = Duration.seconds(60)

    private let now: @Sendable () -> Duration
    /// Nil until `started()`.
    private var lastProgress: Duration?
    private var completedBytes: Int64 = 0

    /// `now` is a monotonic time. The default is uptime, which stops while the Mac sleeps.
    public init(now: @escaping @Sendable () -> Duration = { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }) {
        self.now = now
    }

    /// Arms the deadline. A repeat doesn't restart it, so it can't keep a stall alive.
    public mutating func started() {
        if lastProgress == nil { lastProgress = now() }
    }

    /// Returns false if `bytes` is not beyond the last report: a repeat can't keep a stall alive.
    @discardableResult
    public mutating func progressed(completedBytes bytes: Int64) -> Bool {
        guard bytes > completedBytes else { return false }
        completedBytes = bytes
        if lastProgress != nil { lastProgress = now() }
        return true
    }

    public var hasExpired: Bool { lastProgress.map { now() - $0 > Self.limit } ?? false }
}
