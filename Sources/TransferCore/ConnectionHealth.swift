import Foundation

/// One share's `ConnectionState`, from the results of its SMB calls. A blocked call can't be
/// cancelled: check `refusal()` per request and `evaluate()` on a timer.
public struct ConnectionHealth: Sendable {
    public struct Activity: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    /// Each request times out by itself; this catches a call that neither returns nor progresses.
    public static let stallLimit = Duration.seconds(60)
    public static let firstProbeDelay = Duration.seconds(5)
    public static let longestProbeDelay = Duration.seconds(60)

    public private(set) var state = ConnectionState.notConnected
    private let now: @Sendable () -> Duration
    private var lastProgress: [UInt64: Duration] = [:]
    private var nextID: UInt64 = 0
    private var probing = false
    private var lastProbe = Duration.zero
    private var probeDelay = firstProbeDelay
    private var pathSatisfied = true
    // A new process can't know what an earlier one returned, so its first recovery resolves both.
    private var notAuthenticatedUsed = true

    /// `now` is a monotonic time. The default is uptime, which stops while the Mac sleeps.
    public init(now: @escaping @Sendable () -> Duration = { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }) {
        self.now = now
    }

    public mutating func evaluate() -> ConnectionState {
        let time = now()
        if state == .connected, lastProgress.values.contains(where: { time - $0 > Self.stallLimit }) {
            enter(.unresponsive)
        }
        return state
    }

    /// The failure to return at once, with no I/O; nil to try the request.
    public mutating func refusal() -> SourceFailure? {
        switch evaluate() {
        case .needsSignIn: .notAuthenticated
        case _ where !pathSatisfied: .notConnected
        case .connected, .notConnected: nil
        case .unresponsive: .serverUnreachable
        }
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

    /// A session opened or a call returned. Returns the errors to signal resolved; none unless the
    /// share was not connected or unresponsive.
    public mutating func succeeded() -> [SourceFailure] {
        guard state == .notConnected || state == .unresponsive else { return [] }
        enter(.connected)
        return recovered()
    }

    /// Only a refused sign-in ends in `needsSignIn`; only a new password leaves it.
    public mutating func failed(_ failure: SourceFailure) {
        switch failure {
        case .serverUnreachable, .localNetworkDenied:
            if state == .connected || state == .notConnected { enter(.unresponsive) }
        case .notConnected:
            if state == .connected || state == .unresponsive { enter(.notConnected) }
        case .notAuthenticated:
            notAuthenticatedUsed = true
            if state != .needsSignIn { enter(.needsSignIn) }
        default: break
        }
    }

    /// A new password was saved: the next request signs in with it.
    public mutating func signedIn() {
        if state == .needsSignIn { enter(.notConnected) }
    }

    /// Without a network path every request fails at once; a path that returns probes at once.
    public mutating func networkChanged(satisfied: Bool) {
        pathSatisfied = satisfied
        if !satisfied, state == .connected || state == .unresponsive { enter(.notConnected) }
        if satisfied { conditionsChanged() }
    }

    /// Wake or a new network path: the next probe runs at once, and the delays start again.
    public mutating func conditionsChanged() {
        probeDelay = Self.firstProbeDelay
        lastProbe = now() - Self.longestProbeDelay
    }

    /// On true, probe once, then call `probeFinished(succeeded:)`, or no probe runs again.
    public mutating func startProbe() -> Bool {
        guard evaluate() == .unresponsive, pathSatisfied, !probing, now() - lastProbe >= probeDelay else {
            return false
        }
        probing = true
        return true
    }

    /// Returns the errors to signal resolved; none unless the probe recovered the share.
    /// A failed probe doubles the delay before the next one, up to `longestProbeDelay`.
    public mutating func probeFinished(succeeded: Bool) -> [SourceFailure] {
        guard probing else { return [] }
        probing = false
        lastProbe = now()
        guard succeeded else {
            probeDelay = min(probeDelay * 2, Self.longestProbeDelay)
            return []
        }
        guard state == .unresponsive else { return [] }
        enter(.connected)
        return recovered()
    }

    private mutating func recovered() -> [SourceFailure] {
        defer { notAuthenticatedUsed = false }
        return notAuthenticatedUsed ? [.serverUnreachable, .notAuthenticated] : [.serverUnreachable]
    }

    // Forget activities from before a transition, so a call still blocked can't count twice.
    private mutating func enter(_ next: ConnectionState) {
        state = next
        lastProgress.removeAll()
        lastProbe = now()
        probeDelay = Self.firstProbeDelay
    }
}
