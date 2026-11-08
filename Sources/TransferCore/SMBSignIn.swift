import Darwin

/// What a refused SMB sign-in or share connection means, from the server's NTSTATUS.
public enum SMBSignIn {
    /// The server refused the account name or password; only this enters Sign In Again….
    static let logonFailure: UInt32 = 0xC000_006D
    /// The account can't sign in now. Retrying can lock it, and a new password doesn't help.
    static let accountRefused: Set<UInt32> = [
        0xC000_0234, // ACCOUNT_LOCKED_OUT
        0xC000_0072, // ACCOUNT_DISABLED
        0xC000_0193, // ACCOUNT_EXPIRED
        0xC000_006E, // ACCOUNT_RESTRICTION
        0xC000_006F, // INVALID_LOGON_HOURS
        0xC000_0070, // INVALID_WORKSTATION
        0xC000_0071, // PASSWORD_EXPIRED
        0xC000_0224, // PASSWORD_MUST_CHANGE
    ]
    static let shareRefused: Set<UInt32> = [
        0xC000_0022, // ACCESS_DENIED
        0xC000_00CA, // NETWORK_ACCESS_DENIED
    ]
    static let badNetworkName: UInt32 = 0xC000_00CC

    /// `status` is the NTSTATUS of the refused step, or 0 when no server reply decided it.
    /// libsmb2 reports LOGON_FAILURE as ECONNREFUSED, so the status decides first.
    public static func failure(status: UInt32, errno code: Int32) -> SourceFailure {
        if status == logonFailure { return .notAuthenticated }
        if accountRefused.contains(status) || shareRefused.contains(status) { return .noPermission }
        if status == badNetworkName { return .missing }
        return SourceFailure.classify(errno: code, context: .listing)
    }

    /// The names of the disk shares in a srvsvc share listing, in the server's order.
    /// Leaves out IPC$, printers, devices and special or administrative (`$`) shares.
    public static func diskShareNames(_ shares: [(name: String, type: UInt32)]) -> [String] {
        // STYPE_DISKTREE is 0; STYPE_SPECIAL (0x8000_0000) marks IPC$ and administrative shares.
        let temporary: UInt32 = 0x4000_0000
        return shares.filter { share in
            share.type & ~temporary == 0 && !share.name.hasSuffix("$") && RelativePath.isValidComponent(share.name)
        }.map(\.name)
    }
}
