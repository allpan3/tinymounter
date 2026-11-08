import Foundation

/// libsmb2 with a password: NTLMSSP, SMB 3 only, signing and encryption required, no guest.
struct SMBClient: RemoteClient {
    var remoteProtocol: RemoteProtocol { .smb }

    func shareNames(on server: ServerAccount, password: Data) throws -> [String] {
        final class Listing {
            var shares: [(name: String, type: UInt32)] = []
        }
        let listing = Listing()
        var status: UInt32 = 0
        let code = Self.withLogin(host: server.host, account: server.account, password: password) { login in
            tm_smb_share_names(login, { context, name, type in
                guard let context, let name else { return EINVAL }
                let listing = Unmanaged<Listing>.fromOpaque(context).takeUnretainedValue()
                listing.shares.append((String(cString: name), type))
                return 0
            }, Unmanaged.passUnretained(listing).toOpaque(), &status)
        }
        guard code == 0 else { throw SMBSignIn.failure(status: status, errno: code) }
        return SMBSignIn.diskShareNames(listing.shares)
    }

    func openSession(_ share: ShareAddress, password: Data, folder: RelativePath,
                     progress: Progress) throws -> any RemoteSession {
        try SMBEdit(share: share, password: password, folder: folder, progress: progress)
    }

    /// Change watching arrives with SMBNotify; until then discovery relists periodically.
    func openWatcher(_ share: ShareAddress, password: Data,
                     notice: @escaping @Sendable (ChangeNotice) -> Void) throws -> (any RemoteWatcher)? {
        nil
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
