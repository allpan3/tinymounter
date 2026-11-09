import AppKit
import Darwin
import Foundation
import NetFS
import Network
import OSLog

/// The mount table, NetFS mount, remount and eject handling, for Server Volume mode only.
/// NetFS signs in with the server's saved name and password; the status is mounted or not.
final class ServerVolumeMount: @unchecked Sendable {
    let shareID: UUID
    private let address: ShareAddress
    private let client: any RemoteClient
    private let signIn: ServerSignIn
    private let onChange: @Sendable (Bool) -> Void
    private let onRemountRefused: @Sendable () -> Void
    private let monitor = DispatchQueue(label: "dev.tinymounter.prototype.volume-monitor", qos: .utility)
    // A mount blocks until NetFS answers, so it never runs on the monitor.
    private let mounter = DispatchQueue(label: "dev.tinymounter.prototype.volume-mount", qos: .userInitiated)
    private let poll: DispatchSourceTimer
    private let lock = NSLock()
    private var mounted = false
    private var remount = RemountPolicy()
    private let network = NWPathMonitor()
    private var observers: [NotificationCenter.ObservationToken] = []
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    /// `onChange` gets the mounted state after each change, on the monitor queue.
    /// `onRemountRefused` follows a mount again that the server refused the saved password for.
    init(shareID: UUID, address: ShareAddress, client: any RemoteClient, signIn: ServerSignIn,
         onChange: @escaping @Sendable (Bool) -> Void, onRemountRefused: @escaping @Sendable () -> Void) {
        self.shareID = shareID
        self.address = address
        self.client = client
        self.signIn = signIn
        self.onChange = onChange
        self.onRemountRefused = onRemountRefused
        poll = DispatchSource.makeTimerSource(queue: monitor)
        poll.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(1))
        poll.setEventHandler { [weak self] in self?.checkMountTable() }
        poll.activate()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(of: NSWorkspace.self, for: .willUnmountVolume) { [weak self] message in
                self?.volumeUnmounting(message.volumeURL, ejected: true)
            },
            center.addObserver(of: NSWorkspace.self, for: .didUnmountVolume) { [weak self] message in
                self?.volumeUnmounting(message.volumeURL, ejected: false)
            },
            center.addObserver(of: NSWorkspace.self, for: .didWake) { [weak self] _ in self?.conditionsChanged() },
        ]
        network.pathUpdateHandler = { [weak self] update in
            if update.status == .satisfied { self?.conditionsChanged() }
        }
        network.start(queue: monitor)
    }

    deinit {
        poll.cancel()
        network.cancel()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    /// Where the share is mounted, from the mount table with no I/O; nil if it isn't.
    var mountPath: String? { (try? MountEntry.current())?.first(where: isThisShare)?.mountOn }

    /// Only a share with a Server Volume is mounted again after macOS unmounts it.
    func setRemountWanted(_ wanted: Bool) {
        let changed = lock.withLock {
            defer { remount.wanted = wanted }
            return remount.wanted != wanted
        }
        if changed && wanted { checkNow() }
    }

    func checkNow() { monitor.async { [self] in checkMountTable() } }

    /// Sign In Again… saved a new password: a wanted share that is not ejected mounts again now.
    func credentialsChanged() { conditionsChanged() }

    /// Add, Connect and Show in Finder: a visible mount. Nil once the share is mounted.
    func mount() async -> SourceFailure? {
        let failure = await withCheckedContinuation { continuation in
            mounter.async { [self] in continuation.resume(returning: mountSignedIn(reason: "user")) }
        }
        checkNow()
        return failure
    }

    /// Ejects every mount of this share.
    func unmount(reason: String) async throws {
        lock.withLock { remount.ejectStarted() }
        let paths = ((try? MountEntry.current()) ?? []).filter(isThisShare).map(\.mountOn)
        do {
            for path in paths {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    FileManager.default.unmountVolume(at: URL(filePath: path, directoryHint: .isDirectory),
                                                      options: [.withoutUI]) { error in
                        let code = (error as NSError?)?.code ?? 0
                        Self.logger.info("""
                            share=\(self.shareID.uuidString, privacy: .public) volume_unmount \
                            reason=\(reason, privacy: .public) ok=\(error == nil ? 1 : 0) error=\(code)
                            """)
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
        } catch {
            checkNow()
            throw error
        }
        checkNow()
    }

    /// The share's `smb://` URL. It names the account but never the password, which NetFS gets
    /// on its own. Finder opens an already mounted share for it.
    var shareURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.user = address.account
        components.host = address.host
        components.path = "/" + address.share
        return components.url
    }

    /// One NetFS mount with the server's saved password, on the mounter queue. A refused password
    /// refuses the server, so no other mount or session of the server signs in until it changes.
    /// smbfs reports a refused password as a missing share (ENOENT), so a session through the
    /// protocol's client signs in first: a refusal then reaches the server once, and is named.
    private func mountSignedIn(reason: String) -> SourceFailure? {
        guard let url = shareURL else { return .pathRejected }
        let started = ContinuousClock.now
        var status: Int32?
        let failure: SourceFailure?
        do {
            try signIn.signIn { password in
                _ = try client.openSession(address, password: password, folder: .root, progress: Progress())
                let result = Self.mount(url, user: address.account, password: password)
                status = result
                if let failure = RemountPolicy.failure(status: result) { throw failure }
            }
            failure = nil
        } catch {
            failure = SourceFailure.classify(error, context: .listing)
        }
        let ms = started.duration(to: .now) / .milliseconds(1)
        // No status: NetFS did not run, because the sign-in failed or was refused earlier.
        Self.logger.info("""
            share=\(self.shareID.uuidString, privacy: .public) volume_mount reason=\(reason, privacy: .public) \
            status=\(status.map { "\($0)" } ?? "none", privacy: .public) \
            \(failure.map(logFields) ?? "ok=1", privacy: .public) ms=\(ms, format: .fixed(precision: 1))
            """)
        return failure
    }

    private func isThisShare(_ mount: MountEntry) -> Bool {
        guard mount.isRemoteSMB, let mounted = ShareAddress(mount.mountFrom) else { return false }
        return mounted.isSameShare(host: address.host, share: address.share)
            && mounted.account.caseInsensitiveCompare(address.account) == .orderedSame
    }

    private func volumeUnmounting(_ url: URL, ejected: Bool) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        monitor.async { [self] in
            let mount = (try? MountEntry.current())?.first { path.hasPrefix($0.mountOn) && isThisShare($0) }
            // Only an eject posts willUnmount; macOS's unmount after an outage doesn't (M9).
            if ejected, mount != nil {
                lock.withLock { remount.ejectStarted() }
                Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) remount_held")
            }
            if !ejected { checkMountTable() }
        }
    }

    private func checkMountTable() {
        guard let mounts = try? MountEntry.current() else { return }
        let listed = mounts.contains(where: isThisShare)
        let changed = lock.withLock {
            defer { mounted = listed }
            if listed { remount.mountListed() }
            return mounted != listed
        }
        if changed { onChange(listed) }
        if !listed { mountAgain() }
    }

    /// The share mounts again with the saved password and shows no dialog.
    private func mountAgain() {
        guard lock.withLock({ remount.startMount(now: Self.uptime()) }) else { return }
        mounter.async { [self] in
            let failure = mountSignedIn(reason: "remount")
            monitor.async { [self] in mountFinished(failure) }
        }
    }

    private func mountFinished(_ failure: SourceFailure?) {
        let outcome = lock.withLock { remount.finished(failure, now: Self.uptime()) }
        let next = switch outcome {
        case .mounted: "mounted"
        case .retry(let delay): "retry_s=\(delay.components.seconds)"
        case .stopped: "stopped"
        }
        Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) remount_finished \(next, privacy: .public)")
        if outcome == .mounted { checkMountTable() }
        if failure == .notAuthenticated { onRemountRefused() }
    }

    /// Wake or a network change: the next mount try runs at once.
    private func conditionsChanged() {
        monitor.async { [self] in
            lock.withLock { remount.conditionsChanged() }
            checkMountTable()
        }
    }

    /// NetFS takes the password only as a CFString: this copy lives until the call returns.
    /// No dialog, so a refusal comes back as a status instead of a macOS sign-in window.
    private static func mount(_ url: URL, user: String, password: Data) -> Int32 {
        let secret = password.withUnsafeBytes { bytes in
            CFStringCreateWithBytes(nil, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                    CFStringBuiltInEncodings.UTF8.rawValue, false)
        }
        guard let secret else { return EINVAL }
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"
        // A Server Volume shows in Finder's sidebar, as Connect to Server mounts it.
        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountFlagsKey] = 0
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, user as CFString, secret, openOptions, mountOptions,
                                       &mountpoints)
        mountpoints?.release()
        return status
    }

    private static func uptime() -> Duration { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }
}

/// A mount-table row. `mountFrom` holds the SMB account, so never log it.
private struct MountEntry {
    let typeName: String
    let mountFrom: String
    let mountOn: String
    let isLocal: Bool

    init(_ info: statfs) {
        typeName = Self.string(info.f_fstypename)
        mountFrom = Self.string(info.f_mntfromname)
        mountOn = Self.string(info.f_mntonname)
        isLocal = info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    var isRemoteSMB: Bool { typeName == "smbfs" && !isLocal }

    /// `getmntinfo(MNT_NOWAIT)` without the shared buffer: no I/O, and safe on any thread.
    static func current() throws -> [MountEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { throw posixError("getmntinfo_r_np") }
        defer { free(buffer) }
        return UnsafeBufferPointer(start: buffer, count: Int(count)).map { MountEntry($0) }
    }

    private static func string<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
