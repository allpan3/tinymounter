import Foundation
import Network

/// libsmb2 with a password: NTLMSSP, SMB 3 only, signing and encryption required, no guest.
struct SMBClient: RemoteClient {
    var remoteProtocol: RemoteProtocol { .smb }

    func shareNames(on server: ServerAccount, password: Data) throws -> [String] {
        final class Listing {
            var shares: [(name: String, type: UInt32)] = []
        }
        let listing = Listing()
        var status: UInt32 = 0
        try Self.connecting(server.host) {
            listing.shares = []
            let code = Self.withLogin(host: server.host, account: server.account, password: password) { login in
                tm_smb_share_names(login, { context, name, type in
                    guard let context, let name else { return EINVAL }
                    let listing = Unmanaged<Listing>.fromOpaque(context).takeUnretainedValue()
                    listing.shares.append((String(cString: name), type))
                    return 0
                }, Unmanaged.passUnretained(listing).toOpaque(), &status)
            }
            guard code == 0 else { throw SMBSignIn.failure(status: status, errno: code) }
        }
        return SMBSignIn.diskShareNames(listing.shares)
    }

    func openSession(_ share: ShareAddress, password: Data, folder: RelativePath, previousSession: UInt64?,
                     progress: Progress) throws -> any RemoteSession {
        try Self.connecting(share.host) {
            try SMBEdit(share: share, password: password, folder: folder, previousSession: previousSession,
                        progress: progress)
        }
    }

    func openWatcher(_ share: ShareAddress, password: Data,
                     notice: @escaping @Sendable (ChangeNotice) -> Void) throws -> (any RemoteWatcher)? {
        try Self.connecting(share.host) {
            try password.withUnsafeBytes { try SMBWatch(share: share, password: $0, notice: notice) }
        }
    }

    /// The first connect after macOS asks for Local Network access fails at once; this one connects
    /// again when the user allows it, so the app doesn't need a relaunch.
    private static func connecting<T>(_ host: String, _ connect: () throws -> T) throws -> T {
        do {
            return try connect()
        } catch SourceFailure.serverUnreachable {
            guard try LocalNetworkAccess.waitForAccess(host: host, port: 445) else {
                throw SourceFailure.serverUnreachable
            }
            return try connect()
        }
    }

    /// Lends `password`'s bytes to C for the call; they are never copied into a `String`.
    static func withLogin<T>(host: String, account: String, password: Data,
                             _ body: (UnsafePointer<tm_smb_login>) throws -> T) rethrows -> T {
        try host.withCString { host in
            try account.withCString { account in
                try password.withUnsafeBytes { bytes in
                    var empty: UInt8 = 0
                    return try withUnsafePointer(to: &empty) { emptyPointer in
                        var login = tm_smb_login(server: host, account: account,
                                                 password: bytes.bindMemory(to: UInt8.self).baseAddress ?? emptyPointer,
                                                 password_length: bytes.count)
                        return try body(&login)
                    }
                }
            }
        }
    }
}

/// macOS asks once per app signature before the first local-network connection. Until the user
/// allows it, a socket connect fails with `EHOSTUNREACH`; Network framework tells why it waits.
enum LocalNetworkAccess {
    /// After a connect to `host` failed as unreachable. True when the path waited for Local Network
    /// access and opened within `timeout`; false when access isn't the cause. Throws
    /// `localNetworkDenied` when access stays off.
    static func waitForAccess(host: String, port: UInt16, timeout: Duration = .seconds(30)) throws -> Bool {
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            let decided = DispatchSemaphore(value: 0)
            var denied = false
            var opened: Bool?

            func evaluate(_ path: NWPath?) {
                guard let path else { return }
                lock.withLock {
                    guard opened == nil else { return }
                    if path.status == .satisfied {
                        opened = denied
                    } else if path.unsatisfiedReason == .localNetworkDenied {
                        denied = true
                        return
                    } else {
                        opened = false
                    }
                    decided.signal()
                }
            }
        }
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let outcome = Outcome()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection.pathUpdateHandler = { outcome.evaluate($0) }
        connection.stateUpdateHandler = { _ in outcome.evaluate(connection.currentPath) }
        connection.start(queue: .global())
        let waited = outcome.decided.wait(timeout: .now() + .nanoseconds(Int(timeout / .nanoseconds(1))))
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        if waited == .success { return outcome.lock.withLock { outcome.opened == true } }
        if outcome.lock.withLock({ outcome.denied }) { throw SourceFailure.localNetworkDenied }
        return false
    }
}
