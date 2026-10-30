import Foundation

/// A blocked SMB call can't be cancelled: check `refusal()` per request, `evaluate()` on a timer.
public struct ShareHealth: Sendable {
    public enum State: Equatable, Sendable {
        case connected, unresponsive, notConnected
        /// The grant failed. Only `mountDisappeared()`, for a new mount or a new grant, clears it.
        case needsGrant
    }

    public struct Activity: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    public static let stallLimit = Duration.seconds(15)
    public static let probeInterval = Duration.seconds(5)

    public private(set) var state = State.notConnected
    private let now: @Sendable () -> Duration
    private var lastProgress: [UInt64: Duration] = [:]
    private var nextID: UInt64 = 0
    private var probing = false
    private var lastProbe = Duration.zero
    // A new process can't know what an earlier one returned, so its first recovery resolves both.
    private var notAuthenticatedUsed = true

    /// `now` is a monotonic time. The default is uptime, which stops while the Mac sleeps.
    public init(now: @escaping @Sendable () -> Duration = { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }) {
        self.now = now
    }

    public mutating func evaluate() -> State {
        let time = now()
        if state == .connected, lastProgress.values.contains(where: { time - $0 > Self.stallLimit }) {
            enter(.unresponsive)
        }
        return state
    }

    /// The failure to return at once, with no share I/O; nil to try the request.
    public mutating func refusal() -> SourceFailure? {
        switch evaluate() {
        case .connected, .notConnected: nil
        case .unresponsive: .serverUnreachable
        case .needsGrant: .notAuthenticated
        }
    }

    /// A session started. Returns the errors to signal resolved; none unless it was not connected.
    public mutating func mountAppeared() -> [SourceFailure] {
        guard state == .notConnected else { return [] }
        enter(.connected)
        return recovered()
    }

    /// The session ended: the mount went away or the grant changed. The next request starts one.
    public mutating func mountDisappeared() {
        if state != .notConnected { enter(.notConnected) }
    }

    public mutating func begin() -> Activity {
        nextID += 1
        lastProgress[nextID] = now()
        return Activity(id: nextID)
    }

    public mutating func progressed(_ activity: Activity) {
        if lastProgress[activity.id] != nil { lastProgress[activity.id] = now() }
    }

    public mutating func end(_ activity: Activity) {
        lastProgress[activity.id] = nil
    }

    public mutating func operationSucceeded() -> [SourceFailure] {
        guard state == .unresponsive else { return [] }
        enter(.connected)
        return recovered()
    }

    /// A probe can bring back a share that times out, but not one whose mount or grant failed.
    public mutating func failed(_ failure: SourceFailure) {
        switch failure {
        case .serverUnreachable: if state == .connected { enter(.unresponsive) }
        case .notConnected: mountDisappeared()
        case .notAuthenticated:
            notAuthenticatedUsed = true
            if state != .needsGrant { enter(.needsGrant) }
        default: break
        }
    }

    /// A session start found the mount, but its server did not answer: probes start the session.
    public mutating func startFailed() {
        if state == .notConnected { enter(.unresponsive) }
    }

    /// On true, probe once, then call `probeFinished(succeeded:)`, or no probe runs again.
    public mutating func startProbe() -> Bool {
        guard evaluate() == .unresponsive, !probing, now() - lastProbe >= Self.probeInterval else { return false }
        probing = true
        return true
    }

    /// Returns the errors to signal resolved; none unless the probe recovered the share.
    public mutating func probeFinished(succeeded: Bool) -> [SourceFailure] {
        guard probing else { return [] }
        probing = false
        lastProbe = now()
        guard succeeded, state == .unresponsive else { return [] }
        enter(.connected)
        return recovered()
    }

    private mutating func recovered() -> [SourceFailure] {
        defer { notAuthenticatedUsed = false }
        return notAuthenticatedUsed ? [.serverUnreachable, .notAuthenticated] : [.serverUnreachable]
    }

    // Forget activities from before a transition, so a call still blocked can't count twice.
    private mutating func enter(_ next: State) {
        state = next
        lastProgress.removeAll()
        lastProbe = now()
    }
}
