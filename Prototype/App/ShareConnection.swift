import AppKit
import Foundation
import Network
import OSLog

/// Tells `ConnectionHealth` that a share operation made progress, such as one listing batch.
typealias Progressed = @Sendable () -> Void

/// One server's saved password, shared by the connections to its shares. Sign-ins run one at a
/// time, so a refused password reaches the server once; then none runs until the password changes.
final class ServerSignIn: @unchecked Sendable {
    let login: ServerAccount
    private let credentials: any CredentialStore
    // Held for one sign-in, which can wait for the server's reply.
    private let signingIn = NSLock()
    private let lock = NSLock()
    private var password: Data?
    private var refused = false

    init(login: ServerAccount, credentials: any CredentialStore) {
        self.login = login
        self.credentials = credentials
    }

    /// True after a refused password, a missing one or an unreadable item, until the next change.
    var isRefused: Bool { lock.withLock { refused } }

    /// Runs `connect` with the saved password; a `notAuthenticated` failure refuses the server.
    func signIn<T>(_ connect: (Data) throws -> T) throws -> T {
        try signingIn.withLock {
            let password = try lock.withLock { () throws -> Data in
                guard !refused else { throw SourceFailure.notAuthenticated }
                if let password { return password }
                let saved: Data?
                do { saved = try credentials.password(for: login) } catch {
                    Self.logger.error("password_read \(logFields(error), privacy: .public)")
                    saved = nil
                }
                guard let saved else {
                    refused = true
                    throw SourceFailure.notAuthenticated
                }
                password = saved
                return saved
            }
            do {
                return try connect(password)
            } catch {
                if SourceFailure.classify(error, context: .listing) == .notAuthenticated { refuse() }
                throw error
            }
        }
    }

    /// No connection to this server signs in again until `credentialsChanged()`.
    func refuse() {
        lock.withLock {
            refused = true
            password = nil
        }
    }

    /// Sign In Again… saved a new password: the next sign-in reads it.
    func credentialsChanged() {
        lock.withLock {
            refused = false
            password = nil
        }
    }

    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")
}

/// One per saved share that a location uses. Each operation opens its own session through the
/// protocol's client; metadata work runs on one serial lane, transfers on their own threads.
final class ShareConnection: @unchecked Sendable {
    let shareID: UUID
    let editNamespace: EditNamespace
    let address: ShareAddress
    private let client: any RemoteClient
    private let signIn: ServerSignIn
    /// The errors to signal resolved, from a session or a probe that recovered the share.
    private let onRecovery: @Sendable ([SourceFailure]) -> Void
    private let lane = DispatchQueue(label: "dev.tinymounter.prototype.share", qos: .userInitiated)
    private let monitor = DispatchQueue(label: "dev.tinymounter.prototype.share-monitor", qos: .utility)
    // A probe can block for the request timeout, so it never runs on the lane or the monitor.
    private let prober = DispatchQueue(label: "dev.tinymounter.prototype.share-probe", qos: .utility)
    private let tick: DispatchSourceTimer
    private let lock = NSLock()
    private var health = ConnectionHealth()
    private let previousSessions: PreviousSessionStore
    private var stateHandler: (@Sendable (ConnectionState) -> Void)?
    private var connecting = false
    /// Set by the first `connect()`: a returning network path or wake then connects again.
    private var wanted = false
    private let network = NWPathMonitor()
    private var observers: [NotificationCenter.ObservationToken] = []
    private let watchLimit: Int
    private let refresh: LocationChangeWatch.Refresh
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    /// The change notices of this share's discovery folders, on one watcher connection.
    private(set) lazy var changeWatch = LocationChangeWatch(limit: watchLimit, open: { [weak self] notice in
        guard let self else { return nil }
        if let refusal = refusal() { throw refusal }
        return try signIn.signIn { password in
            try self.client.openWatcher(self.address, password: password, notice: notice)
        }
    }, excluded: { [editNamespace] in editNamespace.isReserved($0) }, deferred: { [editNamespace] in
        // This Mac's own uploads and saves: each lists their folders once when it ends.
        editNamespace.deferNotice(folder: $0, names: $1, routes: $2)
    }, refresh: refresh)

    /// `watchLimit` is the protocol's watcher limit; `refresh` gets each notice's folders to list.
    init(shareID: UUID, address: ShareAddress, client: any RemoteClient, signIn: ServerSignIn,
         previousSessions: PreviousSessionStore, watchLimit: Int, refresh: @escaping LocationChangeWatch.Refresh,
         onRecovery: @escaping @Sendable ([SourceFailure]) -> Void) {
        self.shareID = shareID
        self.address = address
        self.client = client
        self.signIn = signIn
        self.previousSessions = previousSessions
        self.watchLimit = watchLimit
        self.refresh = refresh
        self.onRecovery = onRecovery
        editNamespace = EditNamespace.shared(address)
        tick = DispatchSource.makeTimerSource(queue: monitor)
        tick.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
        tick.setEventHandler { [weak self] in self?.checkHealth() }
        tick.activate()
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(of: NSWorkspace.self, for: .didWake) { [weak self] _ in
                self?.conditionsChanged(satisfied: nil)
            },
        ]
        network.pathUpdateHandler = { [weak self] update in
            self?.conditionsChanged(satisfied: update.status == .satisfied)
        }
        network.start(queue: monitor)
        _ = changeWatch
    }

    deinit {
        tick.cancel()
        network.cancel()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    var state: ConnectionState { lock.withLock { health.state } }

    /// Called after each state change, on the thread that made it.
    func onStateChange(_ handler: @escaping @Sendable (ConnectionState) -> Void) {
        lock.withLock { stateHandler = handler }
    }

    /// The failure to return at once, with no I/O; nil to try the request.
    func refusal() -> SourceFailure? { changeHealth { $0.refusal() } }

    /// Opens a session, runs `body` on the caller's thread, records the result in the health.
    /// Progress counts on `progress` keep a long transfer from looking stalled.
    func withSession<T>(folder: RelativePath, progress: Progress = Progress(),
                        _ body: (any RemoteSession, @escaping Progressed) throws -> T) throws -> T {
        if let refusal = refusal() { throw refusal }
        let connecting = changeHealth { $0.begin() }
        let session: any RemoteSession
        do {
            session = try signIn.signIn { password in
                try openSession(password: password, folder: folder, progress: progress)
            }
            changeHealth { $0.end(connecting) }
        } catch {
            changeHealth { $0.end(connecting) }
            failed(error)
            throw error
        }
        // After the recovery, which forgets the activities that began before it.
        succeeded()
        let activity = changeHealth { $0.begin() }
        defer { changeHealth { $0.end(activity) } }
        let progressed: Progressed = { [weak self] in self?.changeHealth { $0.progressed(activity) } }
        let observation = progress.observe(\.completedUnitCount) { _, _ in progressed() }
        defer { observation.invalidate() }
        do {
            let result = try body(session, progressed)
            ended(session)
            return result
        } catch {
            // Before the failure changes the health, which can open the next session.
            ended(session)
            failed(error)
            throw error
        }
    }

    /// Runs `work` on the lane, after every metadata operation queued before it.
    func enqueue(_ work: @escaping @Sendable () -> Void) { lane.async(execute: work) }

    /// Folder Select…: the subfolder names of a folder in the share, from a complete listing.
    func folderNames(in path: RelativePath) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            enqueue { [self] in
                continuation.resume(with: Result {
                    try withSession(folder: .root) { session, progressed in
                        try session.list(path, progressed: progressed)
                    }.entries.filter { $0.kind == .folder }.map(\.name)
                })
            }
        }
    }

    /// Opens a session, so that the recovery signals and relisting run.
    func connect() {
        let start = lock.withLock {
            wanted = true
            defer { connecting = true }
            return !connecting
        }
        guard start else { return }
        lane.async { [self] in
            defer { lock.withLock { connecting = false } }
            _ = try? withSession(folder: .root) { session, _ in try session.directoryIdentity(.root) }
        }
    }

    /// Sign In Again… saved a new password: needsSignIn ends and a session starts.
    func credentialsChanged() {
        signIn.credentialsChanged()
        changeHealth { $0.signedIn() }
        connect()
        changeWatch.reconnect()
    }

    /// The share is forgotten: its watcher connection ends. Off the caller's thread, because
    /// `cancel()` waits for a watcher sign-in that may be running.
    func close() {
        DispatchQueue.global(qos: .utility).async { [changeWatch] in changeWatch.cancel() }
    }

    /// Names one dropped session as the previous session, so the server releases its open files.
    private func openSession(password: Data, folder: RelativePath, progress: Progress) throws -> any RemoteSession {
        let previous = previousSessions.take(shareID)
        do {
            let session = try client.openSession(address, password: password, folder: folder,
                                                 previousSession: previous, progress: progress)
            previousSessions.signedIn(shareID, session: session.sessionID, previous: previous)
            if let previous {
                Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) previous_session=\(Self.hex(previous), privacy: .public)")
            }
            return session
        } catch {
            if let previous { previousSessions.unsent(shareID, previous) }
            throw error
        }
    }

    /// A session that lost its connection is never used again, so the next one can end it.
    private func ended(_ session: any RemoteSession) {
        let dropped = session.droppedSessionID
        previousSessions.ended(shareID, session: dropped ?? session.sessionID, dropped: dropped != nil)
        guard let id = dropped else { return }
        Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) session_dropped=\(Self.hex(id), privacy: .public)")
    }

    private static func hex(_ id: UInt64) -> String { "0x" + String(id, radix: 16) }

    private func succeeded() {
        let recovered = changeHealth { $0.succeeded() }
        if !recovered.isEmpty { onRecovery(recovered) }
    }

    private func failed(_ error: Error) {
        let failure = SourceFailure.classify(error, context: .listing)
        if failure == .notAuthenticated { signIn.refuse() }
        changeHealth { $0.failed(failure) }
    }

    /// Wake (`satisfied` nil) or a network path change: a share that was wanted connects again.
    private func conditionsChanged(satisfied: Bool?) {
        let reconnect = changeHealth { health -> Bool in
            if let satisfied { health.networkChanged(satisfied: satisfied) } else { health.conditionsChanged() }
            return wanted && health.state == .notConnected && satisfied != false
        }
        if reconnect { connect() }
        if satisfied == nil { changeWatch.reconnect() }
    }

    private func checkHealth() {
        // Another share on this server was refused, or Sign In Again… saved a password there.
        let refused = signIn.isRefused
        let signedIn = changeHealth { health -> Bool in
            if refused, health.state != .needsSignIn { health.failed(.notAuthenticated) }
            guard !refused, health.state == .needsSignIn else { return false }
            health.signedIn()
            return true
        }
        if signedIn { connect() }
        guard changeHealth({ $0.startProbe() }) else { return }
        prober.async { [self] in
            var succeeded = false
            do {
                let session = try signIn.signIn { password in
                    try openSession(password: password, folder: .root, progress: Progress())
                }
                defer { ended(session) }
                _ = try session.directoryIdentity(.root)
                succeeded = true
            } catch {
                if SourceFailure.classify(error, context: .listing) == .notAuthenticated {
                    changeHealth { $0.failed(.notAuthenticated) }
                }
            }
            let recovered = changeHealth { $0.probeFinished(succeeded: succeeded) }
            Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) probe ok=\(succeeded ? 1 : 0)")
            if !recovered.isEmpty { onRecovery(recovered) }
        }
    }

    /// Every `ConnectionHealth` change goes through here, so each state change is logged once.
    private func changeHealth<T>(_ body: (inout ConnectionHealth) -> T) -> T {
        let (result, before, after, handler) = lock.withLock {
            let before = health.state
            let result = body(&health)
            return (result, before, health.state, stateHandler)
        }
        if before != after {
            Self.logger.info("""
                share=\(self.shareID.uuidString, privacy: .public) state=\(String(describing: after), privacy: .public)
                """)
            handler?(after)
            if after == .connected { changeWatch.reconnect() }
        }
        return result
    }
}
