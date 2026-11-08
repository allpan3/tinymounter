import AppKit
import Darwin
import Foundation
import NetFS
import Network
import OSLog

/// The mount table, NetFS mount, remount and eject handling, for Server Volume mode only.
/// macOS mounts the share and signs in with its own Keychain item; the status is mounted or not.
final class ServerVolumeMount: @unchecked Sendable {
    let shareID: UUID
    private let address: ShareAddress
    private let onChange: @Sendable (Bool) -> Void
    private let monitor = DispatchQueue(label: "dev.tinymounter.prototype.volume-monitor", qos: .utility)
    private let poll: DispatchSourceTimer
    private let lock = NSLock()
    private var mounted = false
    private var remount = RemountPolicy()
    private var mountRequest: AsyncRequestID?
    private let network = NWPathMonitor()
    private var observers: [NotificationCenter.ObservationToken] = []
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    /// `onChange` gets the mounted state after each change, on the monitor queue.
    init(shareID: UUID, address: ShareAddress, onChange: @escaping @Sendable (Bool) -> Void) {
        self.shareID = shareID
        self.address = address
        self.onChange = onChange
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
        if let mountRequest { NetFSMountURLCancel(mountRequest) }
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

    /// Add, Connect and Show in Finder: a visible mount, with macOS's own sign-in if it needs one.
    func mount() async -> Int32 {
        guard let url = mountURL else { return EINVAL }
        let started = ContinuousClock.now
        let status = await withCheckedContinuation { continuation in
            Self.mount(url, showsUI: true, queue: .global(qos: .userInitiated)) { continuation.resume(returning: $0) }
        }
        let ms = started.duration(to: .now) / .milliseconds(1)
        Self.logger.info("""
            share=\(self.shareID.uuidString, privacy: .public) volume_mount status=\(status) \
            ms=\(ms, format: .fixed(precision: 1))
            """)
        checkNow()
        return status
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

    private var mountURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.user = address.account
        components.host = address.host
        components.path = "/" + address.share
        return components.url
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

    /// Phase 3 plan §1: macOS mounts the share with its Keychain password and shows no dialog.
    private func mountAgain() {
        guard lock.withLock({ remount.startMount(now: Self.uptime()) }), let url = mountURL else { return }
        let started = ContinuousClock.now
        Self.logger.info("share=\(self.shareID.uuidString, privacy: .public) remount_started")
        let request = Self.mount(url, showsUI: false, queue: monitor) { [weak self] status in
            self?.mountFinished(status: status, started: started)
        }
        if let request { lock.withLock { mountRequest = request } }
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
            share=\(self.shareID.uuidString, privacy: .public) remount_finished status=\(status) \
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

    @discardableResult
    private static func mount(_ url: URL, showsUI: Bool, queue: DispatchQueue,
                              done: @escaping @Sendable (Int32) -> Void) -> AsyncRequestID? {
        let openOptions = NSMutableDictionary()
        if !showsUI { openOptions["UIOption"] = "NoUI" }
        // A Server Volume shows in Finder's sidebar, as Connect to Server mounts it.
        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountFlagsKey] = 0
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &request, queue) {
            status, _, _ in done(status)
        }
        guard status == 0 else {
            queue.async { done(status) }
            return nil
        }
        return request
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
