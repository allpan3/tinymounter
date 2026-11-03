import AppKit
import Darwin
import Foundation
import NetFS
import Network
import OSLog

/// Why `ShareAccess.makeGrant` refused a selected folder.
enum ShareGrantError: Error {
    /// The folder is not the root of a mounted volume.
    case notVolumeRoot
    /// The volume is not an SMB share on another computer.
    case notSMBShare
    /// The address has no account, has a password, or is not an SMB address.
    case addressRejected
}

/// Tells `ShareHealth` that a share operation made progress, such as one listing batch.
typealias Progressed = @Sendable () -> Void

/// One mount session's share root. Use it only inside `ShareAccess.withSession`; never keep it.
final class ShareSession: @unchecked Sendable {
    /// `O_EVTONLY`, so it never blocks an eject.
    let root: Int32
    let identity: MountIdentity
    fileprivate let mountOn: String
    private let url: URL
    private let lock = NSLock()
    private var locationRoots: [RelativePath: Int32] = [:]
    private var watches: [String: [String: DirectoryWatch]] = [:]
    private var watchClosures: [UUID: (path: RelativePath, closed: DispatchGroup)] = [:]
    private static let maximumWatches = 64

    fileprivate init(root: Int32, mount: MountEntry, url: URL) {
        self.root = root
        identity = mount.identity
        mountOn = mount.mountOn
        self.url = url
    }

    deinit {
        watches.removeAll()
        for fd in locationRoots.values { close(fd) }
        close(root)
        url.stopAccessingSecurityScopedResource()
    }

    /// Opens a folder beneath the share root, `O_EVTONLY`. The caller closes the descriptor.
    func openFolder(_ path: RelativePath) throws -> Int32 {
        try identity.guarding(root: root) {
            var fd: Int32
            repeat {
                fd = openat(root, path.isRoot ? "." : path.string,
                            O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)
            } while fd < 0 && errno == EINTR
            guard fd >= 0 else { throw posixError("openat folder") }
            do { try identity.requireSameMount(fd, root: root) } catch { close(fd); throw error }
            return fd
        }
    }

    /// A location folder's root, opened once per session; the session closes it.
    func locationRoot(_ folder: RelativePath) throws -> Int32 {
        if let fd = lock.withLock({ locationRoots[folder] }) { return fd }
        let fd: Int32
        do { fd = try openFolder(folder) } catch { throw SourceFailure.classify(error, context: .locationRoot) }
        return lock.withLock {
            if let existing = locationRoots[folder] {
                close(fd)
                return existing
            }
            locationRoots[folder] = fd
            return fd
        }
    }

    func keepWatches(domainID: String, folders: Set<String>) {
        lock.withLock {
            watches[domainID] = watches[domainID]?.filter { folders.contains($0.key) }
            if watches[domainID]?.isEmpty == true { watches[domainID] = nil }
        }
    }

    func watch(domainID: String, folderID: String, path: RelativePath,
               changed: @escaping @Sendable () -> Void) throws {
        let needed = lock.withLock {
            watches[domainID]?[folderID] == nil && watches.values.reduce(0) { $0 + $1.count } < Self.maximumWatches
        }
        guard needed else { return }
        let descriptor = try openFolder(path)
        let id = UUID(), closed = DispatchGroup()
        closed.enter()
        lock.withLock { watchClosures[id] = (path, closed) }
        let watch = DirectoryWatch(descriptor: descriptor, path: path, changed: { [weak self] events in
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self?.lock.withLock { self?.watches[domainID]?[folderID] = nil }
            }
            changed()
        }, closed: { [weak self] in
            closed.leave()
            guard let self else { return }
            self.lock.withLock { self.watchClosures[id] = nil }
        })
        lock.withLock {
            if watches[domainID]?[folderID] == nil,
               watches.values.reduce(0, { $0 + $1.count }) < Self.maximumWatches {
                watches[domainID, default: [:]][folderID] = watch
            }
        }
    }

    /// Removes every watch at or below `paths` and waits until its descriptor has closed.
    func drainWatches(below paths: [RelativePath]) throws {
        let (removed, closing) = lock.withLock { () -> ([DirectoryWatch], [DispatchGroup]) in
            var removed: [DirectoryWatch] = []
            for (domain, folders) in watches {
                for (folder, watch) in folders where paths.contains(where: { EditNamespace.contains($0, watch.path) }) {
                    removed.append(watch)
                    watches[domain]?[folder] = nil
                }
            }
            watches = watches.filter { !$0.value.isEmpty }
            // Dropped watches stay tracked until their cancel handler closes the descriptor.
            let closing = watchClosures.values.filter { entry in
                paths.contains { EditNamespace.contains($0, entry.path) }
            }.map(\.closed)
            return (removed, closing)
        }
        for watch in removed { watch.cancel() }
        let deadline = DispatchTime.now() + .seconds(10)
        var closed = true
        for group in closing where group.wait(timeout: deadline) != .success { closed = false }
        guard closed else { throw UploadError.pendingWrites }
    }

    fileprivate func isListed(in mounts: [MountEntry]) -> Bool {
        mounts.contains { $0.identity == identity && $0.mountOn == mountOn }
    }
}

/// One per server grant. Metadata work runs on one serial lane; transfers use their own threads.
final class ShareAccess: @unchecked Sendable {
    let grantID: UUID
    let editNamespace: EditNamespace
    private let mountFrom: String
    private let store: SettingsStore
    /// The errors to signal resolved, from a session start or a probe that recovered the share.
    private let onRecovery: @Sendable ([SourceFailure]) -> Void
    private let lane = DispatchQueue(label: "dev.tinymounter.prototype.share", qos: .userInitiated)
    private let monitor = DispatchQueue(label: "dev.tinymounter.prototype.share-monitor", qos: .utility)
    // A probe can block for the mount's timeout, so it never runs on the lane or the monitor.
    private let prober = DispatchQueue(label: "dev.tinymounter.prototype.share-probe", qos: .utility)
    private let poll: DispatchSourceTimer
    private let tick: DispatchSourceTimer
    private let lock = NSLock()
    // Held while a session starts, which can wait for the server, so only one starts at a time.
    private let startLock = NSLock()
    private var bookmark: Data
    private var session: ShareSession?
    private var health = ShareHealth()
    /// The grant's mounts when it failed; needsGrant ends when they change.
    private var refusedMounts: Set<MountIdentity> = []
    /// Mounts from willUnmount, listed for seconds more: no session starts on one until it goes.
    private var unmounting: [MountIdentity: ContinuousClock.Instant] = [:]
    private static let unmountWait: Duration = .seconds(60)
    private var connecting = false
    private var remount = RemountPolicy()
    private var mountRequest: AsyncRequestID?
    private let network = NWPathMonitor()
    private var stateHandler: (@Sendable (ShareHealth.State) -> Void)?
    private var observers: [NotificationCenter.ObservationToken] = []
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    init(grant: ServerGrant, store: SettingsStore, onRecovery: @escaping @Sendable ([SourceFailure]) -> Void) {
        grantID = grant.id
        editNamespace = EditNamespace.shared(grant.mountFrom)
        mountFrom = grant.mountFrom
        bookmark = grant.bookmark
        self.store = store
        self.onRecovery = onRecovery
        poll = DispatchSource.makeTimerSource(queue: monitor)
        poll.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10), leeway: .seconds(1))
        tick = DispatchSource.makeTimerSource(queue: monitor)
        tick.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
        poll.setEventHandler { [weak self] in self?.checkMountTable() }
        tick.setEventHandler { [weak self] in self?.checkHealth() }
        poll.activate()
        tick.activate()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(of: NSWorkspace.self, for: .willUnmountVolume) { [weak self] message in
                self?.volumeUnmounting(message.volumeURL, reason: "will_unmount")
            },
            center.addObserver(of: NSWorkspace.self, for: .didUnmountVolume) { [weak self] message in
                self?.volumeUnmounting(message.volumeURL, reason: "did_unmount")
            },
            center.addObserver(of: NSWorkspace.self, for: .didWake) { [weak self] _ in
                self?.conditionsChanged()
            },
        ]
        network.pathUpdateHandler = { [weak self] update in
            if update.status == .satisfied { self?.conditionsChanged() }
        }
        network.start(queue: monitor)
    }

    deinit {
        poll.cancel()
        tick.cancel()
        network.cancel()
        if let mountRequest { NetFSMountURLCancel(mountRequest) }
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    /// Checks that `url`, from `NSOpenPanel`, is an SMB volume root, and makes its app-scoped grant.
    static func makeGrant(for url: URL, serverID: UUID) async throws -> ServerGrant {
        try await withCheckedThrowingContinuation { continuation in
            // Reading the volume's values can wait for the server, so never on the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try grant(for: url, serverID: serverID) }
                switch result {
                case .success(let grant):
                    logger.info("share=\(grant.id.uuidString, privacy: .public) grant_created")
                case .failure(let error):
                    let error = error as NSError
                    logger.error("grant_refused domain=\(error.domain, privacy: .public) code=\(error.code)")
                }
                continuation.resume(with: result)
            }
        }
    }

    var hasSession: Bool { lock.withLock { session != nil } }

    func keepWatches(domainID: String, folders: Set<String>) {
        lock.withLock { session }?.keepWatches(domainID: domainID, folders: folders)
    }

    func drainWatches(below paths: [RelativePath]) throws {
        try lock.withLock { session }?.drainWatches(below: paths)
    }

    var state: ShareHealth.State { lock.withLock { health.state } }

    /// Called after each state change, on the thread that made it.
    func onStateChange(_ handler: @escaping @Sendable (ShareHealth.State) -> Void) {
        lock.withLock { stateHandler = handler }
    }

    /// Where the share is mounted, from the mount table with no I/O; nil if it isn't.
    func mountPath() -> String? { (try? MountEntry.current()).flatMap { candidates(in: $0).first }?.mountOn }

    /// The failure to return at once, with no share I/O; nil to try the request.
    func refusal() -> SourceFailure? { changeHealth { $0.refusal() } }

    /// Runs `body` on the caller's thread with the current session, and starts one if there is none.
    func withSession<T>(_ body: (ShareSession, @escaping Progressed) throws -> T) throws -> T {
        if let refusal = refusal() { throw refusal }
        let session = try currentSession()
        let activity = changeHealth { $0.begin() }
        defer { changeHealth { $0.end(activity) } }
        do {
            let result = try Self.$current.withValue(CurrentActivity(access: self, activity: activity)) {
                try body(session) { [weak self] in self?.changeHealth { $0.progressed(activity) } }
            }
            let recovered = changeHealth { health in
                self.session === session ? health.operationSucceeded() : []
            }
            if !recovered.isEmpty { onRecovery(recovered) }
            return result
        } catch {
            noteFailure(SourceFailure.classify(error, context: .listing), session: session)
            throw error
        }
    }

    private struct CurrentActivity: Sendable {
        let access: ShareAccess
        let activity: ShareHealth.Activity
    }

    /// The activity of the `withSession` call running on this thread.
    @TaskLocal private static var current: CurrentActivity?

    /// Runs a call over tinymounter's own SMB connection, which has its own request timeouts.
    static func withDirectSMB<T>(_ call: () throws -> T) rethrows -> T {
        guard let current else { return try call() }
        current.access.changeHealth { $0.beginDirectCall(current.activity) }
        defer { current.access.changeHealth { $0.endDirectCall(current.activity) } }
        return try call()
    }

    /// Runs `work` on the lane, after every metadata operation queued before it.
    func enqueue(_ work: @escaping @Sendable () -> Void) { lane.async(execute: work) }

    /// Folder completion: the subfolder names of a folder in the share, listed on the lane.
    func folderNames(in path: RelativePath) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            enqueue { [self] in
                continuation.resume(with: Result {
                    try withSession { session, progressed in
                        guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                        let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: session.root, progress: Progress())
                        return try remote.list(path, progressed: progressed)
                    }.entries.filter { $0.kind == .folder }.map(\.name)
                })
            }
        }
    }

    /// Starts a session if the share is mounted, so that its recovery signals and relisting run.
    func connect() {
        let start = lock.withLock {
            defer { connecting = true }
            return !connecting
        }
        guard start else { return }
        lane.async { [self] in
            defer { lock.withLock { connecting = false } }
            guard refusal() == nil else { return }
            _ = try? currentSession()
        }
    }

    /// Phase 3 plan §1: only a share that a location uses is mounted again.
    func setRemountWanted(_ wanted: Bool) {
        let changed = lock.withLock {
            defer { remount.wanted = wanted }
            return remount.wanted != wanted
        }
        if changed && wanted { monitor.async { [self] in checkMountTable() } }
    }

    /// A new grant for this share: the next request starts a session with it.
    func replaceBookmark(_ data: Data) {
        lock.withLock { bookmark = data }
        lane.async { [self] in
            if let session = lock.withLock({ self.session }) { ended(session, reason: "grant_replaced") }
            changeHealth { $0.mountDisappeared() }
            connect()
        }
    }

    private func currentSession() throws -> ShareSession {
        try startLock.withLock {
            let mounts = try MountEntry.current()
            if let session = lock.withLock({ self.session }) {
                if session.isListed(in: mounts) { return session }
                ended(session, reason: "mount_gone")
            }
            // Resolution waits about 30 s for an absent server, so it runs only for a mounted share.
            let candidates = self.candidates(in: mounts)
            guard !candidates.isEmpty else { throw SourceFailure.notConnected }
            let session: ShareSession
            do {
                session = try start(candidates)
            } catch SourceFailure.notAuthenticated {
                needGrant(ending: nil)
                throw SourceFailure.notAuthenticated
            } catch SourceFailure.serverUnreachable {
                changeHealth { $0.startFailed() }
                throw SourceFailure.serverUnreachable
            }
            let recovered = changeHealth { health in
                self.session = session
                return health.mountAppeared()
            }
            if !recovered.isEmpty { onRecovery(recovered) }
            return session
        }
    }

    /// The grant's SMB mounts, except those that macOS is unmounting.
    private func candidates(in mounts: [MountEntry]) -> [MountEntry] {
        let unmounting = lock.withLock { self.unmounting }
        return mounts.filter { mount in
            mount.identity.mountFrom == mountFrom && mount.isRemoteSMB && unmounting[mount.identity] == nil
        }
    }

    private func start(_ candidates: [MountEntry]) throws -> ShareSession {
        let clock = ContinuousClock()
        let started = clock.now
        var stale = false
        let url: URL
        do {
            let data = lock.withLock { bookmark }
            url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            failed("resolve", error)
            let mounts = (try? MountEntry.current()) ?? []
            let mounted = candidates.contains { candidate in mounts.contains { $0.identity == candidate.identity } }
            // A listed mount whose server doesn't answer fails resolution, after about 30 s.
            throw mounted ? SourceFailure.serverUnreachable : SourceFailure.notConnected
        }
        let resolved = clock.now
        let path = Self.filePath(url)
        guard let mount = candidates.first(where: { $0.mountOn == path }) else {
            failed("match", nil)
            throw SourceFailure.notAuthenticated
        }
        guard url.startAccessingSecurityScopedResource() else {
            failed("scope", nil)
            throw SourceFailure.notAuthenticated
        }
        let root: Int32
        do {
            root = try Self.openRoot(path, matching: mount)
        } catch {
            url.stopAccessingSecurityScopedResource()
            failed("open", error)
            throw error
        }
        let session = ShareSession(root: root, mount: mount, url: url)
        let opened = clock.now
        if stale { refreshBookmark(from: url) }
        Self.logger.info("""
            share=\(self.grantID.uuidString, privacy: .public) session_started \
            resolve_ms=\(started.duration(to: resolved) / .milliseconds(1), format: .fixed(precision: 1)) \
            open_ms=\(resolved.duration(to: opened) / .milliseconds(1), format: .fixed(precision: 1)) \
            stale=\(stale ? 1 : 0)
            """)
        return session
    }

    /// `fstatfs` must show the matched mount: smbfs, its `f_fsid` and `f_mntfromname`, and this path.
    private static func openRoot(_ path: String, matching mount: MountEntry) throws -> Int32 {
        var fd: Int32
        repeat {
            fd = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        } while fd < 0 && errno == EINTR
        guard fd >= 0 else { throw SourceFailure.classify(errno: errno, context: .shareRoot) }
        do {
            let opened = try MountEntry(descriptor: fd)
            guard opened.identity == mount.identity, opened.mountOn == path else { throw SourceFailure.notConnected }
            return fd
        } catch {
            close(fd)
            throw SourceFailure.classify(error, context: .shareRoot)
        }
    }

    /// Only for a bookmark that still resolved to the matching mount.
    private func refreshBookmark(from url: URL) {
        let fresh: Data
        do {
            fresh = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            failed("refresh", error)
            return
        }
        lock.withLock { bookmark = fresh }
        Task { @MainActor [store, grantID] in
            do {
                try store.update { settings in
                    guard let index = settings.shares.firstIndex(where: { $0.id == grantID }) else { return }
                    settings.shares[index].bookmark = fresh
                }
                Self.logger.info("share=\(grantID.uuidString, privacy: .public) bookmark_saved=1")
            } catch {
                let error = error as NSError
                Self.logger.error("""
                    share=\(grantID.uuidString, privacy: .public) bookmark_saved=0 \
                    domain=\(error.domain, privacy: .public) code=\(error.code)
                    """)
            }
        }
    }

    private func noteFailure(_ failure: SourceFailure, session: ShareSession) {
        switch failure {
        case .notConnected: ended(session, reason: "not_connected")
        case .notAuthenticated: needGrant(ending: session)
        case .serverUnreachable: changeHealth { $0.failed(.serverUnreachable) }
        default: break
        }
    }

    /// No request reaches the share until its mounts change or the grant is replaced.
    private func needGrant(ending ended: ShareSession?) {
        let refused = Set(candidates(in: (try? MountEntry.current()) ?? []).map(\.identity))
        let removed = changeHealth { health -> Bool in
            refusedMounts = refused
            health.failed(.notAuthenticated)
            guard let ended, session === ended else { return false }
            session = nil
            return true
        }
        if removed {
            Self.logger.info("share=\(self.grantID.uuidString, privacy: .public) session_ended reason=needs_grant")
        }
    }

    private func volumeUnmounting(_ url: URL, reason: String) {
        let path = Self.filePath(url)
        // Off the main thread: the last release closes the root, which can wait for the server.
        monitor.async { [self] in
            if let mount = (try? MountEntry.current())?.first(where: { $0.mountOn == path }) {
                // Only an eject posts willUnmount; macOS's unmount after an outage doesn't (M9).
                let ejected = reason == "will_unmount" && mount.identity.mountFrom == mountFrom
                lock.withLock {
                    unmounting[mount.identity] = .now
                    if ejected { remount.ejectStarted() }
                }
                if ejected {
                    Self.logger.info("share=\(self.grantID.uuidString, privacy: .public) remount_held")
                }
            }
            if let session = lock.withLock({ self.session }), session.mountOn == path { ended(session, reason: reason) }
            // Without an eject, mount again now rather than at the next poll.
            if reason == "did_unmount" { checkMountTable() }
        }
    }

    private func checkMountTable() {
        guard let mounts = try? MountEntry.current() else { return }
        let listed = Set(mounts.map(\.identity))
        let now = ContinuousClock.now
        let (session, state, refused) = lock.withLock {
            unmounting = unmounting.filter { listed.contains($0.key) && $0.value.duration(to: now) < Self.unmountWait }
            return (self.session, health.state, refusedMounts)
        }
        if let session {
            guard !session.isListed(in: mounts) else {
                lock.withLock { remount.mountListed() }
                return
            }
            ended(session, reason: "poll")
        }
        let present = Set(candidates(in: mounts).map(\.identity))
        if !present.isEmpty {
            lock.withLock { remount.mountListed() }
        } else if !mounts.contains(where: { $0.identity.mountFrom == mountFrom }) {
            // A mount that is still unmounting is listed, so it isn't mounted a second time.
            mountAgain()
        }
        if state == .needsGrant {
            guard present != refused else { return }
            changeHealth { $0.mountDisappeared() }
        }
        if !present.isEmpty { connect() }
    }

    /// Phase 3 plan §1: macOS mounts the share with the Keychain password, and shows no dialog.
    private func mountAgain() {
        guard lock.withLock({ remount.startMount(now: Self.uptime()) }) else { return }
        let started = ContinuousClock.now
        // The grant's address has an account and no password (makeGrant).
        guard let url = URL(string: "smb:" + mountFrom) else {
            mountFinished(status: EINVAL, started: started)
            return
        }
        Self.logger.info("share=\(self.grantID.uuidString, privacy: .public) remount_started")
        let request = Self.mount(url, showsUI: false, queue: monitor) { [weak self] status, _ in
            self?.mountFinished(status: status, started: started)
        }
        if let request { lock.withLock { mountRequest = request } }
    }

    /// M12: the mount is hidden from Finder, which then shows only the locations. With `showsUI`,
    /// macOS asks for a missing password or share itself, so the app never sees either.
    @discardableResult
    private static func mount(_ url: URL, showsUI: Bool, queue: DispatchQueue,
                              done: @escaping @Sendable (Int32, [String]) -> Void) -> AsyncRequestID? {
        let openOptions = NSMutableDictionary()
        if !showsUI { openOptions["UIOption"] = "NoUI" }
        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountFlagsKey] = MNT_DONTBROWSE
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &request, queue) {
            status, _, points in done(status, (points as? [String]) ?? [])
        }
        guard status == 0 else {
            queue.async { done(status, []) }
            return nil
        }
        return request
    }

    /// Add Share… and Connect: the status, and the mount points if macOS mounted the share.
    static func mount(_ url: URL) async -> (status: Int32, paths: [String]) {
        let started = ContinuousClock.now
        let (status, paths) = await withCheckedContinuation { continuation in
            mount(url, showsUI: true, queue: .global(qos: .userInitiated)) { continuation.resume(returning: ($0, $1)) }
        }
        let ms = started.duration(to: .now) / .milliseconds(1)
        logger.info("share_mount status=\(status) mountpoints=\(paths.count) ms=\(ms, format: .fixed(precision: 1))")
        return (status, paths)
    }

    /// Where a share that is already mounted is (EEXIST gives no mount point); nil if it isn't.
    static func mountPath(of address: ServerAddress) -> String? {
        (try? MountEntry.current())?.first { mount in
            mount.isRemoteSMB && ShareAddress(mount.identity.mountFrom).map(address.matches) == true
        }?.mountOn
    }

    struct ConnectedShare: Identifiable, Equatable, Sendable {
        let identity: MountIdentity
        let path: String
        let address: ShareAddress
        let isHidden: Bool

        var id: MountIdentity { identity }
    }

    static func connectedShares() throws -> [ConnectedShare] {
        try MountEntry.current().compactMap { mount in
            guard mount.isRemoteSMB, let address = ShareAddress(mount.identity.mountFrom) else { return nil }
            return ConnectedShare(identity: mount.identity, path: mount.mountOn, address: address,
                                  isHidden: mount.isHidden)
        }
    }

    static func unmount(_ mount: ConnectedShare, reason: String) async throws {
        let current = try MountEntry.current()
        guard current.contains(where: { $0.identity == mount.identity && $0.mountOn == mount.path }) else {
            guard !current.contains(where: { $0.mountOn == mount.path }) else { throw SourceFailure.pathRejected }
            return
        }
        let url = URL(filePath: mount.path, directoryHint: .isDirectory)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FileManager.default.unmountVolume(at: url, options: [.withoutUI]) { error in
                let code = (error as NSError?)?.code ?? 0
                logger.info("share_unmount reason=\(reason, privacy: .public) ok=\(error == nil ? 1 : 0) error=\(code)")
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// After Connect: the mount table now, rather than at the next poll.
    func checkNow() { monitor.async { [self] in checkMountTable() } }

    /// Disconnect failed, so the share is still mounted: a session can start on it again.
    func unmountFailed() {
        monitor.async { [self] in
            lock.withLock { unmounting = unmounting.filter { $0.key.mountFrom != mountFrom } }
            checkMountTable()
        }
    }

    private func mountFinished(status: Int32, started: ContinuousClock.Instant) {
        let outcome = lock.withLock {
            mountRequest = nil
            return remount.finished(status: status, now: Self.uptime())
        }
        let next = switch outcome {
        case .mounted: "mounted"
        case .retry(let delay): "retry_s=\(delay.components.seconds)"
        case .stopped: "stopped"
        }
        let ms = started.duration(to: .now) / .milliseconds(1)
        Self.logger.info("""
            share=\(self.grantID.uuidString, privacy: .public) remount_finished status=\(status) \
            ms=\(ms, format: .fixed(precision: 1)) \(next, privacy: .public)
            """)
        if outcome == .mounted { checkMountTable() }
    }

    /// Wake or a network change: the next mount try runs at once.
    private func conditionsChanged() {
        monitor.async { [self] in
            lock.withLock { remount.conditionsChanged() }
            checkMountTable()
        }
    }

    private static func uptime() -> Duration { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }

    private func checkHealth() {
        let (probe, session) = changeHealth { health in (health.startProbe(), self.session) }
        guard probe else { return }
        prober.async { [self] in
            var succeeded = false
            if let session {
                var info = stat()
                var result: Int32
                repeat {
                    result = fstatat(session.root, ".", &info, 0)
                } while result != 0 && errno == EINTR
                succeeded = result == 0
            } else {
                // Unresponsive with no session: a session start timed out, so the probe starts one.
                do {
                    _ = try currentSession()
                    succeeded = true
                } catch SourceFailure.notConnected {
                    changeHealth { $0.mountDisappeared() }
                } catch {}
            }
            let recovered = changeHealth { $0.probeFinished(succeeded: succeeded) }
            Self.logger.info("share=\(self.grantID.uuidString, privacy: .public) probe ok=\(succeeded ? 1 : 0)")
            if !recovered.isEmpty { onRecovery(recovered) }
        }
    }

    /// The root closes and access stops when the last operation that uses `ended` returns.
    private func ended(_ ended: ShareSession, reason: String) {
        let removed = changeHealth { health -> Bool in
            guard session === ended else { return false }
            session = nil
            health.mountDisappeared()
            return true
        }
        guard removed else { return }
        Self.logger.info("""
            share=\(self.grantID.uuidString, privacy: .public) session_ended reason=\(reason, privacy: .public)
            """)
    }

    /// Every `ShareHealth` change goes through here, so each state change is logged once.
    private func changeHealth<T>(_ body: (inout ShareHealth) -> T) -> T {
        let (result, before, after, handler) = lock.withLock {
            let before = health.state
            let result = body(&health)
            return (result, before, health.state, stateHandler)
        }
        if before != after {
            Self.logger.info("""
                share=\(self.grantID.uuidString, privacy: .public) state=\(String(describing: after), privacy: .public)
                """)
            handler?(after)
        }
        return result
    }

    private func failed(_ step: String, _ error: Error?) {
        let error = error.map { $0 as NSError }
        Self.logger.error("""
            share=\(self.grantID.uuidString, privacy: .public) session_failed step=\(step, privacy: .public) \
            domain=\(error?.domain ?? "none", privacy: .public) code=\(error?.code ?? 0)
            """)
    }

    private static func grant(for url: URL, serverID: UUID) throws -> ServerGrant {
        let path = filePath(url)
        guard let mount = try MountEntry.current().first(where: { $0.mountOn == path }) else {
            throw ShareGrantError.notVolumeRoot
        }
        guard mount.isRemoteSMB else { throw ShareGrantError.notSMBShare }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isVolumeKey])
        guard values.isVolume == true else { throw ShareGrantError.notVolumeRoot }
        guard let address = ShareAddress(mount.identity.mountFrom) else { throw ShareGrantError.addressRejected }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        return ServerGrant(serverID: serverID, bookmark: bookmark, mountFrom: mount.identity.mountFrom, address: address)
    }

    /// Without a trailing slash, as in `f_mntonname`.
    static func filePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// The location's catalog was closed for Remove Location; the extension treats it as unavailable.
enum LocationError: Error {
    case catalogClosed
}

/// One per added location: its writer catalog, listings and reads on the share (plan §5, §6).
final class LocationSource: @unchecked Sendable {
    typealias Reply = @Sendable (Result<ListReceipt, Error>) -> Void
    typealias RenameReply = @Sendable (Result<CreateReceipt, Error>) -> Void

    static let maxPendingListings = 16
    static let signalDelay = DispatchTimeInterval.milliseconds(200)

    let domainID: String
    let access: ShareAccess
    let folder: RelativePath
    /// Signals the domain's working set; `scheduleSignal` debounces it.
    private let signal: @Sendable ([String]) -> Void
    let renameSettings: @Sendable (RenameIntent) async throws -> Void
    let deletionSettings: DeletionSettings?
    // The share lane owns these replies while settings completion awaits the main actor.
    var renameCompletions: [UUID: [RenameReply]] = [:]
    var deletionRecoveries: [UUID: LocationDeletionRecovery] = [:]
    // Stop and close must cancel remote work without waiting for the owner's lane.
    let deletionRecoveryLock = NSLock()
    var deletionProgress: [UUID: Progress] = [:]
    var deletionCancellation = DeletionCancellationState()
    var deletionAttempts: [UUID: DeletionAttemptStatus] = [:]
    // The system SQLite can't share a connection between threads, so every use takes this lock.
    private let catalogLock = NSLock()
    private var catalog: Catalog?
    let uploadLock = NSLock()
    var writeBookmark: Data?
    /// The last failure of each new item, by its macOS template, for Settings; kept in memory only.
    var failedCreates: [String: FailedCreate] = [:]
    // Settings reads the failures while the lane can hold the upload lock for a whole create.
    let failedCreatesLock = NSLock()
    var editNamespace: EditNamespace { access.editNamespace }
    var mutationsSuspended = false
    // Namespace and upload locks protect the memory copy; disk evidence needs fresh server checks.
    var verifiedRead: (receipt: EditBaseReceipt, path: RelativePath, proof: VerifiedRead)?
    weak var verifiedReadSession: ShareSession?
    private let lock = NSLock()
    /// Folders with a listing queued or running, and the replies that wait for it.
    private var waiting: [String: [Reply]] = [:]
    /// D5: when a listing first held each folder's plan.
    private var heldSince: [String: ContinuousClock.Instant] = [:]
    private var confirmations: Set<String> = []
    private var signalScheduled = false
    /// The last root listing found no location folder (plan §7, "This folder is not on the share").
    private var rootMissing = false
    private var changeHandler: (@Sendable () -> Void)?
    private var directoryHandler: (@Sendable ([String]) -> Void)?
    private var watchedFolders: Set<String> = []
    private static let listingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")
    private static let fetchLog = Logger(subsystem: "dev.tinymounter.prototype", category: "fetch")

    init(domainID: String, folder: RelativePath, catalog: Catalog, access: ShareAccess,
         renameSettings: @escaping @Sendable (RenameIntent) async throws -> Void,
         deletionSettings: DeletionSettings? = nil,
         signal: @escaping @Sendable ([String]) -> Void) {
        self.domainID = domainID
        self.folder = folder
        self.catalog = catalog
        self.access = access
        self.signal = signal
        self.renameSettings = renameSettings
        self.deletionSettings = deletionSettings
        editNamespace.register(self)
    }

    /// Closes the writer connection; later calls fail with `catalogClosed`.
    func close() {
        closeDeletionRecovery()
        editNamespace.perform {
            verifiedRead = nil
            verifiedReadSession = nil
            try? readProofCache().remove()
            catalogLock.withLock { catalog = nil }
            editNamespace.detach(domainID)
        }
        setDiscoveryFolders([])
    }

    var isRootMissing: Bool { lock.withLock { rootMissing } }

    /// Called when `isRootMissing` or the kept files change, on the queue that changed them.
    func onChange(_ handler: @escaping @Sendable () -> Void) { lock.withLock { changeHandler = handler } }

    func deletionStateChanged() {
        scheduleSignal()
        lock.withLock { changeHandler }?()
    }

    func onDirectoryChange(_ handler: @escaping @Sendable ([String]) -> Void) {
        lock.withLock { directoryHandler = handler }
    }

    func setDiscoveryFolders(_ folders: Set<String>) {
        lock.withLock { watchedFolders = folders }
        access.keepWatches(domainID: domainID, folders: folders)
    }

    func discoveryFolders(materialized: [String]) throws -> Set<String> {
        try withCatalog { catalog in
            let kept = try catalog.keptItems()
            let ids = Set(materialized + [Catalog.rootItemID] + kept.filter { $0.kind == .folder }.map(\.id)
                          + kept.compactMap(\.parentID))
            return try Set(ids.filter { id in
                guard let row = try catalog.item(id: id) else { return false }
                return !row.deleted && row.kind == .folder && row.listGen != nil
            })
        }
    }

    /// Explicit requests, by item ID, with their paths below the location folder.
    func keptPaths() throws -> [(id: String, path: RelativePath, kind: CatalogRow.Kind)] {
        try withCatalog { catalog in
            try catalog.keepRequests().compactMap { row in
                try catalog.relativePath(of: row.id).map { (row.id, $0, row.kind) }
            }
        }
    }

    func liveChild(of parentID: String, named name: String) throws -> CatalogRow? {
        try withCatalog { try $0.liveChild(parent: parentID, nameKey: NameKey(name)) }
    }

    /// The folders above an item, the root first.
    func parentChain(of id: String) throws -> [String] {
        try withCatalog { catalog in
            var chain: [String] = []
            var next = try catalog.item(id: id)?.parentID
            while let parent = next, chain.count <= Catalog.maxDepth {
                chain.append(parent)
                next = try catalog.item(id: parent)?.parentID
            }
            return chain.reversed()
        }
    }

    /// The location's name in Finder comes from the root row; the system reads it from the working set.
    func setRootName(_ name: String) throws {
        if try withCatalog({ try $0.setRootName(name) }) { scheduleSignal() }
    }

    func counts() throws -> CatalogCounts { try withCatalog { try $0.counts() } }

    func storage(materialized ids: [String]) throws -> StorageUsage {
        try withCatalog { try $0.storage(materialized: ids) }
    }

    func keepSnapshot() throws -> FolderKeepSnapshot { try withCatalog { try $0.keepSnapshot() } }

    func spaceRecoveryItem(_ id: String) throws -> CatalogRow? {
        try withCatalog { try $0.item(id: id) }
    }

    /// `meta.paused`, which every row read carries.
    func isPaused() throws -> Bool { try withCatalog { try $0.item(id: Catalog.rootItemID)?.paused ?? false } }

    /// Keep Downloaded requests need no share I/O; the system downloads after the signal.
    func keep(_ ids: [String], value: Bool) throws -> Int {
        let changed = try withCatalog { try $0.setKeep(ids: ids, value: value) }
        if changed > 0 {
            scheduleSignal()
            lock.withLock { changeHandler }?()
        }
        return changed
    }

    /// Returns the kept rows whose download policy changed.
    @discardableResult
    func setPaused(_ paused: Bool) throws -> Int {
        let changed = try withCatalog { try $0.setPaused(paused) }
        if changed > 0 { scheduleSignal() }
        return changed
    }

    /// Joins a listing of the same folder that is queued or running; a bounded one fails if 16 wait.
    func list(_ folderID: String, requestID: UUID, bounded: Bool = true, reply: Reply? = nil) {
        enum Admission { case joined, started, refused }
        let admission: Admission = lock.withLock {
            if waiting[folderID] != nil {
                if let reply { waiting[folderID]?.append(reply) }
                return .joined
            }
            guard !bounded || waiting.count < Self.maxPendingListings else { return .refused }
            waiting[folderID] = reply.map { [$0] } ?? []
            return .started
        }
        switch admission {
        case .joined:
            Self.listingLog.info("""
                list request=\(requestID.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                folder=\(folderID, privacy: .public) joined=1
                """)
        case .refused:
            Self.listingLog.error("""
                list request=\(requestID.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                folder=\(folderID, privacy: .public) refused pending=\(Self.maxPendingListings)
                """)
            reply?(.failure(SourceFailure.serverUnreachable))
        case .started:
            if let refusal = access.refusal() {
                finish(folderID, .failure(refusal))
                return
            }
            access.enqueue { [self] in finish(folderID, Result { try listOnLane(folderID, requestID: requestID) }) }
        }
    }

    /// The app awaits its own listings one at a time, so a full queue never refuses them.
    func list(_ folderID: String, requestID: UUID) async throws -> ListReceipt {
        try await withCheckedThrowingContinuation { continuation in
            list(folderID, requestID: requestID, bounded: false) { continuation.resume(with: $0) }
        }
    }

    func readTarget(_ request: SourceReadRequest) throws -> (CatalogRow, RelativePath) {
        try withCatalog { catalog -> (CatalogRow, RelativePath) in
            guard let row = try catalog.item(id: request.item) else { throw CocoaError(.fileReadUnknown) }
            guard !row.deleted else { throw SourceFailure.missing }
            guard row.kind == .file else { throw CocoaError(.fileReadUnknown) }
            guard row.contentVersion == request.version else { throw SourceFailure.versionChanged }
            guard let path = try catalog.relativePath(of: row.id) else { throw SourceFailure.missing }
            return (row, path)
        }
    }

    /// Plan §6 step 4: the version, the share state, the catalog path, the file, its fingerprint.
    func transfer(_ request: SourceReadRequest, progress: Progress, stagingDirectory: URL,
                  checkSpace: ((Int64) throws -> Void)? = nil) throws -> TransferOutput {
        try directTransfer(request, progress: progress, stagingDirectory: stagingDirectory, checkSpace: checkSpace)
    }

    func listOnLane(_ folderID: String, requestID: UUID) throws -> ListReceipt {
        try editNamespace.perform {
            try editNamespace.requireSettled()
            return try listSettledOnLane(folderID, requestID: requestID)
        }
    }

    private func listSettledOnLane(_ folderID: String, requestID: UUID) throws -> ListReceipt {
        let started = ContinuousClock.now
        do {
            let (parentID, path) = try withCatalog { catalog -> (String?, RelativePath) in
                guard let row = try catalog.item(id: folderID), row.kind == .folder, !row.deleted,
                      let path = try catalog.relativePath(of: folderID) else { throw CocoaError(.fileReadUnknown) }
                return (row.parentID, path)
            }
            let confirmed = lock.withLock {
                heldSince[folderID].map { $0 + Catalog.confirmationDelay <= started } ?? false
            }
            let located = ContinuousClock.now
            return try access.withSession { session, progressed in
                let connected = ContinuousClock.now
                guard let endpoint = ShareAddress(session.identity.mountFrom) else { throw UploadError.readOnly }
                let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: session.root, progress: Progress())
                let rootOpened = ContinuousClock.now
                let listing = try shareCall(requestID, parent: parentID, context: .listing) {
                    try remote.list(path, progressed: progressed)
                }
                let listed = ContinuousClock.now
                try Self.outbox(domainID: domainID).observeFolderNames(parent: folderID, listing: listing) { record, naming in
                    guard let item = record.item, let identity = record.remoteID else { throw UploadError.invalidRequest }
                    try withCatalog { try $0.nameCreatedFolder(id: item, name: naming.name,
                                                             expectedIdentity: identity, newIdentity: naming.nativeID) }
                }
                let missing = try withCatalog { try $0.missingChildren(of: folderID, listing: listing) }
                try shareCall(requestID, parent: parentID, context: .listing) {
                    try remote.confirmMissing(missing, in: path, progressed: progressed)
                }
                let checked = ContinuousClock.now
                var plan: ReconcilePlan?
                let (applied, generation, entries) = try withCatalog { catalog in
                    let applied = try catalog.reconcile(folder: folderID, listing: listing) { proposed in
                        plan = proposed
                        return confirmed || !Catalog.needsConfirmation(proposed)
                    } != nil
                    return (applied, try catalog.item(id: folderID)?.listGen ?? 0,
                            try catalog.liveChildCount(of: folderID))
                }
                let changed = applied ? plan.map { $0.inserted + $0.updated + $0.tombstoned } ?? 0 : 0
                let skipped = listing.skipped.otherKinds + listing.skipped.invalidNames + listing.skipped.collisions
                    + (plan?.unreadableSkipped ?? 0)
                let receipt = try ListReceipt(generation: generation, entries: entries, changed: changed,
                                              skipped: skipped)
                let confirm = lock.withLock { () -> Bool in
                    guard !applied else {
                        heldSince[folderID] = nil
                        return false
                    }
                    if heldSince[folderID] == nil { heldSince[folderID] = started }
                    return confirmations.insert(folderID).inserted
                }
                if confirm { scheduleConfirmation(folderID) }
                if applied, lock.withLock({ watchedFolders.contains(folderID) }),
                   let fullPath = folder.appending(path), !editNamespace.isReserved(fullPath) {
                    do {
                        try session.watch(domainID: domainID, folderID: folderID, path: fullPath) { [weak self] in
                            guard let self else { return }
                            Self.listingLog.info("directory_hint domain=\(self.domainID, privacy: .public) folder=\(folderID, privacy: .public)")
                            self.lock.withLock { self.directoryHandler }?([folderID] + (parentID.map { [$0] } ?? []))
                        }
                        session.keepWatches(domainID: domainID, folders: lock.withLock { watchedFolders })
                    } catch {
                        Self.listingLog.error("directory_watch folder=\(folderID, privacy: .public) \(logFields(error), privacy: .public)")
                    }
                }
                if changed > 0 { scheduleSignal() }
                if applied { lock.withLock { changeHandler }?() }
                if folderID == Catalog.rootItemID { setRootMissing(false) }
                let done = ContinuousClock.now
                Self.listingLog.info("""
                    list request=\(requestID.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                    folder=\(folderID, privacy: .public) entries=\(entries) changed=\(changed) \
                    inserted=\(plan?.inserted ?? 0) updated=\(plan?.updated ?? 0) \
                    tombstoned=\(plan?.tombstoned ?? 0) skipped=\(skipped) checked=\(missing.count) \
                    held=\(applied ? 0 : 1) confirmed=\(confirmed ? 1 : 0) \
                    lookup_ms=\(started.duration(to: located) / .milliseconds(1), format: .fixed(precision: 1)) \
                    session_ms=\(located.duration(to: connected) / .milliseconds(1), format: .fixed(precision: 1)) \
                    root_ms=\(connected.duration(to: rootOpened) / .milliseconds(1), format: .fixed(precision: 1)) \
                    open_ms=\(listing.openDuration / .milliseconds(1), format: .fixed(precision: 1)) \
                    bulk_ms=\(listing.bulkDuration / .milliseconds(1), format: .fixed(precision: 1)) \
                    bulk_calls=\(listing.bulkCalls) \
                    list_ms=\(started.duration(to: listed) / .milliseconds(1), format: .fixed(precision: 1)) \
                    check_ms=\(listed.duration(to: checked) / .milliseconds(1), format: .fixed(precision: 1)) \
                    total_ms=\(started.duration(to: done) / .milliseconds(1), format: .fixed(precision: 1))
                    """)
                return receipt
            }
        } catch {
            if folderID == Catalog.rootItemID, error as? SourceFailure == .missing { setRootMissing(true) }
            Self.listingLog.error("""
                list request=\(requestID.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                folder=\(folderID, privacy: .public) failed \(logFields(error), privacy: .public) \
                total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
                """)
            throw error
        }
    }

    private func setRootMissing(_ missing: Bool) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard rootMissing != missing else { return nil }
            rootMissing = missing
            return changeHandler
        }
        handler?()
    }

    private func finish(_ folderID: String, _ result: Result<ListReceipt, Error>) {
        let replies = lock.withLock { waiting.removeValue(forKey: folderID) ?? [] }
        for reply in replies { reply(result) }
    }

    /// D5: a listing that starts 15 s after the hold applies what it finds.
    private func scheduleConfirmation(_ folderID: String) {
        let delay = DispatchTimeInterval.seconds(Int(Catalog.confirmationDelay.components.seconds))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            lock.withLock { _ = self.confirmations.remove(folderID) }
            list(folderID, requestID: UUID())
        }
    }

    func scheduleSignal() {
        let first = lock.withLock {
            defer { signalScheduled = true }
            return !signalScheduled
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.signalDelay) { [weak self] in
            guard let self else { return }
            lock.withLock { self.signalScheduled = false }
            signal([])
        }
    }

    func signalFolders(_ folders: [String]) { signal(folders) }

    // A read's absence error needs a checked parent listing before changing the catalog.
    private func shareCall<T>(_ requestID: UUID, parent: String?, context: SourceFailure.Context,
                              _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            let failure = SourceFailure.classify(error, context: context)
            if failure == .missing, let parent { list(parent, requestID: UUID()) }
            if failure == .pathRejected {
                Self.fetchLog.error("""
                    request=\(requestID.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                    path_rejected=1
                    """)
            }
            throw failure
        }
    }

    func withCatalog<T>(_ body: (Catalog) throws -> T) throws -> T {
        try catalogLock.withLock {
            guard let catalog else { throw LocationError.catalogClosed }
            return try body(catalog)
        }
    }
}

/// A `SourceFailure` case, or a domain and code; never a description, which can hold a path.
func logFields(_ error: Error) -> String {
    switch error as? SourceFailure {
    case .unknown(let domain, let code)?: return "domain=\(domain) code=\(code)"
    case let failure?: return "failure=\(failure)"
    case nil:
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code)"
    }
}

/// A mount-table row. `identity.mountFrom` holds the SMB account, so never log it.
private struct MountEntry {
    let identity: MountIdentity
    let mountOn: String
    let isLocal: Bool
    let isHidden: Bool

    init(_ info: statfs) {
        identity = MountIdentity(info)
        mountOn = withUnsafeBytes(of: info.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        isLocal = info.f_flags & UInt32(MNT_LOCAL) != 0
        isHidden = info.f_flags & UInt32(MNT_DONTBROWSE) != 0
    }

    init(descriptor: Int32) throws {
        var info = statfs()
        while fstatfs(descriptor, &info) != 0 {
            guard errno == EINTR else { throw posixError("fstatfs") }
        }
        self.init(info)
    }

    var isRemoteSMB: Bool { identity.typeName == "smbfs" && !isLocal }

    /// `getmntinfo(MNT_NOWAIT)` without the shared buffer: no I/O, and safe on any thread.
    static func current() throws -> [MountEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { throw posixError("getmntinfo_r_np") }
        defer { free(buffer) }
        return UnsafeBufferPointer(start: buffer, count: Int(count)).map { MountEntry($0) }
    }
}
