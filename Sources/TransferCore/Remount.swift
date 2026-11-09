import Darwin
import Foundation

/// When the app asks macOS to mount a share again. Times are monotonic.
public struct RemountPolicy: Sendable {
    public enum Outcome: Equatable, Sendable {
        case mounted
        case retry(after: Duration)
        /// Not a network failure, such as a missing password: sending it again can't help.
        case stopped
    }

    public static let firstDelay = Duration.seconds(10)
    public static let longestDelay = Duration.seconds(300)

    /// Only a share that a location uses is mounted.
    public var wanted = false
    public private(set) var ejected = false
    public private(set) var stopped = false
    private var mounting = false
    private var delay = Duration.zero
    private var notBefore = Duration.zero

    public init() {}

    /// The share is in the mount table: whoever mounted it, the tries start over.
    public mutating func mountListed() {
        ejected = false
        stopped = false
        delay = .zero
        notBefore = .zero
    }

    /// `willUnmount`: the user ejected the share, so it stays unmounted.
    public mutating func ejectStarted() { ejected = true }

    /// Wake or a network change: the next try runs at once, also after a stop.
    public mutating func conditionsChanged() {
        stopped = false
        delay = .zero
        notBefore = .zero
    }

    /// The share is not mounted. True to start a mount now; then `finished` must follow.
    public mutating func startMount(now: Duration) -> Bool {
        guard wanted, !ejected, !stopped, !mounting, now >= notBefore else { return false }
        mounting = true
        return true
    }

    /// `failure` is nil for a mount, as `failure(status:)` gives it.
    public mutating func finished(_ failure: SourceFailure?, now: Duration) -> Outcome {
        mounting = false
        switch failure {
        case nil:
            delay = .zero
            notBefore = .zero
            return .mounted
        case .serverUnreachable?, .notConnected?, .localNetworkDenied?:
            delay = delay == .zero ? Self.firstDelay : min(delay * 2, Self.longestDelay)
            notBefore = now + delay
            return .retry(after: delay)
        default:
            stopped = true
            return .stopped
        }
    }

    /// NetFS's status when the server doesn't answer its server-info request, as when it pauses.
    public static let serverInfoFailed: Int32 = -1

    /// NetFS statuses from NetFS.h and NetAuthErrors.h.
    public static let passwordNeedsChange: Int32 = -5045
    public static let accountRestricted: Int32 = -5999
    public static let noSharesAvailable: Int32 = -5998
    public static let noAuthSharesAvailable: Int32 = -6003

    /// What a NetFS mount status means; nil when the share is mounted, also by an earlier mount.
    /// smbfs also reports a refused password as ENOENT, so the caller signs in before it mounts.
    public static func failure(status: Int32) -> SourceFailure? {
        switch status {
        case 0, EEXIST: nil
        case EAUTH, ENEEDAUTH, passwordNeedsChange: .notAuthenticated
        case EPERM, EACCES, accountRestricted, noSharesAvailable, noAuthSharesAvailable: .noPermission
        case ENOENT: .missing
        case _ where isNetworkFailure(status): .serverUnreachable
        default: .unknown(domain: "NetFS", code: Int(status))
        }
    }

    /// A mount status that can change when the server or the network does.
    private static func isNetworkFailure(_ status: Int32) -> Bool {
        [serverInfoFailed, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, ECONNREFUSED, ECONNRESET,
         ECONNABORTED, ENOTCONN, EADDRNOTAVAIL, EAGAIN, EINTR].contains(status)
    }
}
