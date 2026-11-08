import Foundation
import OSLog

/// The SMB `RemoteWatcher`: one CHANGE_NOTIFY connection with its own thread (SMBNotify.c) and
/// one watch without WATCH_TREE per folder, which also reports content writes in that folder.
final class SMBWatch: RemoteWatcher, @unchecked Sendable {
    /// 4,000 watches exhausted the Samba fixture's notify daemon; 1,024 worked.
    static let folderLimit = 64
    static let echoSeconds: Int32 = 60
    /// How long `watch(_:)` waits for the server to close removed watches before ending.
    static let closeMilliseconds: Int32 = 10_000
    private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "watch")

    private let receiver: Receiver
    private let context: Unmanaged<Receiver>
    private let handle: OpaquePointer
    // watch(_:) and cancel() use the handle; tm_notify_close frees it.
    private let calls = NSLock()
    private var closed = false

    /// Signs in on the calling thread. `password` is the Keychain item's bytes; C zeroes its copies.
    init(share: ShareAddress, password: UnsafeRawBufferPointer,
         notice: @escaping @Sendable (ChangeNotice) -> Void) throws {
        let receiver = Receiver(notice: notice)
        let context = Unmanaged.passRetained(receiver)
        var error: Int32 = 0, status: UInt32 = 0
        let bytes = password.bindMemory(to: UInt8.self)
        guard let handle = tm_notify_open(share.host, share.share, share.account, bytes.baseAddress, bytes.count,
                                          Self.echoSeconds, notifyCallback, context.toOpaque(),
                                          &error, &status) else {
            context.release()
            let failure = Self.connectFailure(error: error, status: status)
            Self.log.error("watch_open status=\(status) \(logFields(failure), privacy: .public)")
            throw failure
        }
        self.receiver = receiver
        self.context = context
        self.handle = handle
        Self.log.info("watch_open")
    }

    deinit { cancel() }

    func watch(_ folders: Set<RelativePath>) {
        calls.withLock {
            guard !closed, let change = receiver.replace(with: folders) else { return }
            for token in change.close { _ = tm_notify_unwatch(handle, token) }
            for (token, path) in change.open where tm_notify_watch(handle, token, path.string) != 0 {
                receiver.end(token)
            }
            Self.log.info("watch_set watched=\(folders.count) opened=\(change.open.count) closed=\(change.close.count)")
            // Folder moves and deletions need these handles closed before they start.
            guard !change.close.isEmpty else { return }
            if tm_notify_settle(handle, Self.closeMilliseconds) != 0 {
                Self.log.error("watch_close timed_out=1")
            }
        }
    }

    func cancel() {
        calls.withLock {
            guard !closed else { return }
            closed = true
            receiver.cancel()
            tm_notify_close(handle)
            context.release()
        }
    }

    /// Echo replies so far, for checks.
    var echoes: Int { calls.withLock { closed ? 0 : Int(tm_notify_echoes(handle)) } }

    // Keep in step with the SMB client's sign-in classification (connection-layer plan, step 2).
    static func connectFailure(error: Int32, status: UInt32) -> SourceFailure {
        switch status {
        case 0xC000_006D: .notAuthenticated // STATUS_LOGON_FAILURE
        case 0xC000_0234, 0xC000_0072, 0xC000_006E, 0xC000_0071, 0xC000_0022: .noPermission
        case 0xC000_00CC: .missing // STATUS_BAD_NETWORK_NAME
        default: SourceFailure.classify(errno: error, context: .listing)
        }
    }

    fileprivate final class Receiver: @unchecked Sendable {
        private let lock = NSLock()
        private var table = WatchTable()
        private var stopped = false
        private let notice: @Sendable (ChangeNotice) -> Void

        init(notice: @escaping @Sendable (ChangeNotice) -> Void) { self.notice = notice }

        func replace(with folders: Set<RelativePath>) -> (open: [(token: UInt64, path: RelativePath)], close: [UInt64])? {
            lock.withLock { stopped ? nil : table.replace(with: folders, limit: SMBWatch.folderLimit) }
        }

        func end(_ token: UInt64) { lock.withLock { _ = table.end(token) } }

        func cancel() { lock.withLock { stopped = true } }

        /// On the notify thread.
        func received(_ event: Int32, token: UInt64, status: UInt32, buffer: [UInt8]) {
            let notice = lock.withLock { () -> ChangeNotice? in
                guard !stopped else { return nil }
                switch event {
                case Int32(TM_NOTIFY_COMPLETED.rawValue):
                    guard let folder = table.path(of: token) else { return nil }
                    let completion = SMBNotifyCompletion(status: status, buffer: buffer)
                    switch completion {
                    case .changed, .overflow: break
                    case .folderGone: table.end(token)
                    // Changes during the gap are lost; the owner opens a new watcher and lists again.
                    case .failed: stopped = true
                    }
                    if case .overflow = completion { SMBWatch.log.info("watch_overflow token=\(token)") }
                    if case .failed = completion { SMBWatch.log.error("watch_failed token=\(token) status=\(status)") }
                    return completion.notice(for: folder)
                case Int32(TM_NOTIFY_OPEN_FAILED.rawValue):
                    guard let folder = table.end(token) else { return nil }
                    SMBWatch.log.info("watch_unavailable token=\(token) status=\(status)")
                    return SMBNotifyCompletion.openFailure(status, folder: folder)
                default:
                    stopped = true
                    SMBWatch.log.error("watch_ended status=\(status)")
                    return .ended(SMBNotifyCompletion.failure(status))
                }
            }
            if let notice { self.notice(notice) }
        }
    }
}

private let notifyCallback: tm_notify_callback = { context, event, token, status, buffer, length in
    guard let context else { return }
    let bytes = buffer.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
    Unmanaged<SMBWatch.Receiver>.fromOpaque(context).takeUnretainedValue()
        .received(event, token: token, status: status, buffer: bytes)
}
