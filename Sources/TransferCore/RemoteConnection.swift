import Foundation

// The connection layer (docs/architecture.md §5, "Sign-in and connection"). Declarations only.

/// The file-sharing protocol of a saved server. SMB is the only implementation.
public enum RemoteProtocol: String, Codable, CaseIterable, Sendable {
    case smb
}

/// One account on one server, and the key of its saved password. Host and account are private.
public struct ServerAccount: Hashable, Codable, Sendable {
    public let remoteProtocol: RemoteProtocol
    public let host: String
    public let account: String

    public init(remoteProtocol: RemoteProtocol, host: String, account: String) {
        self.remoteProtocol = remoteProtocol
        self.host = host
        self.account = account
    }

    /// The same sign-in: SMB host and account names don't depend on case.
    public func matches(_ other: ServerAccount) -> Bool {
        remoteProtocol == other.remoteProtocol && host.caseInsensitiveCompare(other.host) == .orderedSame
            && account.caseInsensitiveCompare(other.account) == .orderedSame
    }
}

/// Saves passwords outside Settings.json. The app keeps them in its own Keychain items.
/// Passwords are UTF-8 bytes, never a `String`, so callers can pass them to C and clear them.
public protocol CredentialStore: Sendable {
    /// Nil when no password is saved.
    func password(for account: ServerAccount) throws -> Data?
    func savePassword(_ password: Data, for account: ServerAccount) throws
    /// Succeeds when no password is saved.
    func deletePassword(for account: ServerAccount) throws
}

/// A share's connection state. `needsSignIn` follows `SourceFailure.notAuthenticated`.
public enum ConnectionState: Equatable, Sendable {
    /// Nothing has connected yet, or the network path is down. The next request tries.
    case notConnected
    case connected
    /// A request stalled or timed out. Probes retry until one succeeds.
    case unresponsive
    /// The server refused the saved password, or none is saved. Only a new password clears it.
    case needsSignIn
}

/// One protocol's client. Calls block the calling thread, time out per request and throw
/// `SourceFailure`: `notAuthenticated` when the server refuses the account or password.
/// A password is UTF-8 bytes, passed on to the protocol without a `String` copy.
public protocol RemoteClient: Sendable {
    var remoteProtocol: RemoteProtocol { get }

    /// Signs in and returns the names of the file shares that the account can see.
    func shareNames(on server: ServerAccount, password: Data) throws -> [String]

    /// Signs in and connects to the share. Relative paths start at `folder`, from the share root.
    /// `previousSession` is a dropped session's `droppedSessionID`; the server ends that session.
    func openSession(_ share: ShareAddress, password: Data, folder: RelativePath, previousSession: UInt64?,
                     progress: Progress) throws -> any RemoteSession

    /// Signs in on a connection of its own for change notices. It watches no folder until
    /// `watch(_:)` names some. Nil if the server can't watch.
    func openWatcher(_ share: ShareAddress, password: Data,
                     notice: @escaping @Sendable (ChangeNotice) -> Void) throws -> (any RemoteWatcher)?
}

/// One authenticated connection to a share, for one operation on one thread.
/// Handles it holds close when it is released.
public protocol RemoteSession: AnyObject, UploadRemote, FileRenameRemote, FolderMoveRemote, DeletionRemote {
    /// Payload bytes read so far, for the fetch log.
    var readBytes: Int64 { get }
    /// The server's ID for this session, also after a drop.
    var sessionID: UInt64 { get }
    /// Set when a request failed with the connection, which the session then closed for good.
    var droppedSessionID: UInt64? { get }

    // Listing
    func directoryIdentity(_ path: RelativePath) throws -> RemoteFileIdentity
    func list(_ path: RelativePath, progressed: () -> Void) throws -> DirectoryListing
    func confirmMissing(_ children: [MissingChild], in path: RelativePath, progressed: () -> Void) throws

    // Reading
    /// Holds the parent folders of `path` open until the session ends.
    func protectAncestors(of path: String) throws
    func readMetadata(path: String) throws -> (identity: RemoteFileIdentity, fingerprint: ContentFingerprint)
    /// Reads `range` of a file that `readMetadata` opened into a new file in `stagingDirectory`.
    func transfer(path: String, range: ByteRange, stagingDirectory: URL, progress: Progress,
                  checkSpace: ((Int64) throws -> Void)?) throws -> TransferOutput

    // Writing, beside the TransferCore seams
    /// `modified` is the save time the server keeps, as in `UploadRemote`.
    func overwrite(path: String, contents: URL, expected: ContentFingerprint?, modified: Date?) throws
        -> (fileID: UInt64, fingerprint: ContentFingerprint)
    /// Exclusive creation; `receipt` saves the new identity before the call returns its file ID.
    func createFolder(_ path: RelativePath, expected: RemoteFolderIdentity?,
                      receipt: (RemoteFolderIdentity) throws -> Void) throws -> UInt64
    /// The initial name of a new folder, without replacing a destination.
    func nameFolder(from source: RelativePath, to destination: RelativePath, expected: RemoteFolderIdentity,
                    recoveryOnly: Bool) throws -> UInt64
    func renameSourceEntry(path: String) throws -> RenameDirectoryEntry?
    func allowPublishedReads(path: String, expected: RemoteFileVersion) throws
    func captureFolderMoveProofs(move: CatalogFolderMove, folder: RelativePath) throws -> [CatalogFolderMoveProof]
    /// Holds the parent chain, every directory and every file until `releaseDeletionTraversal`.
    func captureDeletionTraversal(of selected: RelativePath, recursive: Bool,
                                  expecting expectations: [DeletionExpectation]) throws -> DeletionTraversal
    func releaseDeletionTraversal() throws
}

/// What a watcher reports. Each notice is a hint: a listing decides what changed.
/// Paths start at the share root.
public enum ChangeNotice: Equatable, Sendable {
    /// Entries in this watched folder changed.
    case changed(RelativePath)
    /// The server dropped notices for this watched folder; it needs a full listing.
    case lost(RelativePath)
    /// The watcher stopped, for example on a lost connection. Every watched folder needs a
    /// listing, and its owner opens a new watcher later.
    case ended(SourceFailure)
    /// The server does not support change notification. The watcher stopped, and the periodic
    /// listings cover the folders until the connection changes.
    case unsupported
}

/// One connection that holds one watch for each folder it was last given. A watch covers only
/// the folder's own entries, not deeper folders.
public protocol RemoteWatcher: AnyObject, Sendable {
    /// At most this many folders per watcher.
    static var folderLimit: Int { get }
    /// Replaces the watched folders. Removed folders stop at once; added folders start watching.
    func watch(_ folders: Set<RelativePath>)
    /// After it returns, no notice is delivered.
    func cancel()
}
