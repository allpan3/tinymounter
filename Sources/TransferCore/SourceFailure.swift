import Darwin
import Foundation

/// Share I/O failures only: the extension maps catalog and SQLite errors itself.
public enum SourceFailure: Error, Equatable, Sendable {
    case serverUnreachable
    /// The mount went away. Unlike `serverUnreachable`, a probe can't recover it; a new mount can.
    case notConnected
    case notAuthenticated
    case noPermission
    case pathRejected
    case missing
    case versionChanged
    case cancelled
    case tooManyEntries
    /// A name that a complete listing lacked is still there. Transient: list again later.
    case listingIncomplete
    /// The domain keeps an errno apart from another domain's code with the same value.
    case unknown(domain: String, code: Int)

    public enum Context: Sendable {
        case shareRoot, locationRoot, listing, fetch
    }

    public static func classify(errno code: Int32, context: Context) -> SourceFailure {
        switch code {
        case ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH, ECONNRESET, ENXIO, ESTALE:
            return .serverUnreachable
        case EAUTH, ENEEDAUTH:
            return .notAuthenticated
        case EPERM:
            // Without a valid grant the sandbox returns EPERM, so at a root EPERM means the grant.
            return context == .shareRoot || context == .locationRoot ? .notAuthenticated : .noPermission
        case EACCES:
            return .noPermission
        case ELOOP, ENOTCAPABLE:
            return .pathRejected
        case ENOENT, ENOTDIR:
            // A share root that is gone means the mount went away, not the location's files.
            return context == .shareRoot ? .notConnected : .missing
        default:
            return .unknown(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    public static func classify(_ error: Error, context: Context) -> SourceFailure {
        switch error {
        case let failure as SourceFailure: return failure
        case TransferError.sourceChanged: return .versionChanged
        case TransferError.cancelled: return .cancelled
        // The row says file but the share now has another kind; a relist of the parent fixes it.
        case TransferError.notRegularFile: return .missing
        default:
            let error = error as NSError
            guard error.domain == NSPOSIXErrorDomain else { return .unknown(domain: error.domain, code: error.code) }
            return classify(errno: Int32(error.code), context: context)
        }
    }
}

/// A `SourceFailure` case, or a domain and code; never a description, which can hold a path.
public func logFields(_ error: Error) -> String {
    switch error as? SourceFailure {
    case .unknown(let domain, let code)?: return "domain=\(domain) code=\(code)"
    case let failure?: return "failure=\(failure)"
    case nil:
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code)"
    }
}
