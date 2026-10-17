import FileProvider
import Darwin
import OSLog

final class SourceReaderService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    let serviceName = SourceReaderBridge.serviceName
    let isRestricted = true
    private let domainID: String
    private let lock = NSCondition()
    private let startupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    private var hasConnected = false
    private var listener: NSXPCListener?
    private var connection: NSXPCConnection?
    private var closed = false
    /// Fetches that wait for a reply, by request ID; started and progress messages find them here.
    private var waiting: [String: Response] = [:]
    private var pauseHandler: (() -> Void)?
    private var connectHandler: (() -> Void)?
    /// A catalog write takes milliseconds; a stopped app must not hold a Finder action open.
    static let keepDeadline = Duration.seconds(10)
    private let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")

    init(domainID: String) { self.domainID = domainID }

    /// Called on the connection's queue when the app pauses downloads.
    func onPauseDownloads(_ handler: @escaping () -> Void) { lock.withLock { pauseHandler = handler } }

    /// Called on the connection's queue each time the app's reader attaches.
    func onConnect(_ handler: @escaping () -> Void) { lock.withLock { connectHandler = handler } }

    /// The app's reader took this domain; without it, only listed folders can be served.
    var isConnected: Bool { lock.withLock { connection != nil } }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CocoaError(.userCancelled) }
        if let listener { return listener.endpoint }
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(try SourceReaderBridge.requirement(forProvider: false))
        listener.delegate = self
        listener.activate()
        self.listener = listener
        return listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        lock.lock(); let available = !closed; lock.unlock()
        guard available else { return false }
        connection.exportedInterface = NSXPCInterface(with: SourceReaderRegistration.self)
        connection.exportedObject = Registration(owner: self, connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: SourceReaderProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.lock()
            if self.connection === connection { self.connection = nil }
            self.lock.unlock()
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.activate()
        return true
    }

    private func attach(_ incoming: NSXPCConnection, domainID: String) throws {
        lock.lock()
        guard !closed, domainID == self.domainID else { lock.unlock(); throw CocoaError(.fileReadNoPermission) }
        let old = connection
        connection = incoming
        hasConnected = true
        let connected = connectHandler
        lock.broadcast()
        lock.unlock()
        if old !== incoming { old?.invalidate() }
        connected?()
    }

    func invalidate() {
        lock.lock()
        closed = true
        let current = connection
        connection = nil
        let listener = listener
        lock.broadcast()
        lock.unlock()
        current?.invalidate()
        listener?.invalidate()
    }

    /// Replies once the app committed the listing; the caller bounds the wait.
    func list(_ folderID: String, requestID: UUID, reply: @escaping (Result<ListReceipt, Error>) -> Void) {
        let once = Once()
        let finish = { (result: Result<ListReceipt, Error>) in if once.claim() { reply(result) } }
        do {
            let request = try ReaderMessage.encode(ListRequest(id: requestID, folder: folderID))
            try proxy { finish(.failure($0)) }.list(request) { data, error in
                finish(Result { try ReaderMessage.decode(ListReceipt.self, from: Self.payload(data, error)) })
            }
        } catch {
            finish(.failure(error))
        }
    }

    /// D2: until the app's `started`, only a reply, a lost connection or cancellation ends the wait.
    func fetch(_ request: SourceReadRequest, directory: URL, progress: Progress) throws -> (URL, TransferMetrics) {
        let id = request.id.uuidString
        let response = Response(progress: progress)
        let proxy = try proxy(startupProgress: progress) { response.finish(.failure($0)) }
        lock.withLock { waiting[id] = response }
        defer {
            lock.withLock { waiting[id] = nil }
            proxy.release(id)
        }
        proxy.fetch(try ReaderMessage.encode(request)) { data, error in
            response.finish(Result { try Self.payload(data, error) })
        }
        while response.ready.wait(timeout: .now() + 0.1) == .timedOut {
            guard !progress.isCancelled else { throw TransferError.cancelled }
            guard !response.hasStalled else {
                logger.error("request=\(id, privacy: .public) stalled=1 completed_bytes=\(progress.completedUnitCount)")
                throw NSFileProviderError(.serverUnreachable)
            }
        }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        let receipt = try ReaderMessage.decode(SourceReadReceipt.self, from: response.value())
        guard receipt.metrics.bytes == request.range.length else { throw CocoaError(.fileReadCorruptFile) }
        let source = try SourceReaderBridge.stagingURL(named: receipt.stagingName)
        let file = try ReadOnlyFile(url: source)
        guard file.filesystem.isLocal, file.snapshot.size == request.range.end else { throw CocoaError(.fileReadCorruptFile) }
        let destination = directory.appending(path: "tinymounter-\(UUID().uuidString).stage", directoryHint: .notDirectory)
        // Same-volume rename transfers ownership before the app releases its old staging pathname.
        guard renamex_np(source.path(percentEncoded: false), destination.path(percentEncoded: false),
                         UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (destination, receipt.metrics)
    }

    /// Waits for the app's commit, as a fetch waits before `started`, but never past `keepDeadline`.
    func keep(_ request: KeepRequest, progress: Progress) throws -> KeepReceipt {
        let response = Response(progress: progress)
        let proxy = try proxy(startupProgress: progress) { response.finish(.failure($0)) }
        proxy.keep(try ReaderMessage.encode(request)) { data, error in
            response.finish(Result { try Self.payload(data, error) })
        }
        let deadline = ContinuousClock.now.advanced(by: Self.keepDeadline)
        while response.ready.wait(timeout: .now() + 0.1) == .timedOut {
            guard !progress.isCancelled else { throw TransferError.cancelled }
            guard ContinuousClock.now < deadline else {
                logger.error("keep request=\(request.id.uuidString, privacy: .public) deadline=1")
                throw NSFileProviderError(.serverUnreachable)
            }
        }
        return try ReaderMessage.decode(KeepReceipt.self, from: response.value())
    }

    private func proxy(startupProgress: Progress? = nil,
                       _ failed: @escaping (Error) -> Void) throws -> SourceReaderProtocol {
        let connection = try lock.withLock {
            let started = ContinuousClock.now
            var waited = false
            defer {
                if waited {
                    logger.info("reader_startup wait_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1)) connected=\(self.connection != nil)")
                }
            }
            // Only a new extension waits; losing an established reader still fails at once.
            while let progress = startupProgress, !closed, !hasConnected, connection == nil,
                  ContinuousClock.now < startupDeadline {
                guard !progress.isCancelled else { throw TransferError.cancelled }
                waited = true
                _ = lock.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
            guard startupProgress?.isCancelled != true, !closed else { throw TransferError.cancelled }
            guard let connection else { throw NSFileProviderError(.serverUnreachable) }
            return connection
        }
        // A lost connection means the app's reader is gone, not a Cocoa error for the system.
        return connection.remoteObjectProxyWithErrorHandler { _ in
            failed(NSFileProviderError(.serverUnreachable))
        } as! SourceReaderProtocol
    }

    private static func payload(_ data: Data?, _ error: NSError?) throws -> Data {
        if let error {
            // Only the extension's own tombstone lookup may give noSuchItem, which deletes local copies.
            if error.domain == NSFileProviderErrorDomain, error.code == NSFileProviderError.noSuchItem.rawValue {
                throw CocoaError(.fileReadUnknown)
            }
            throw error
        }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private func started(_ message: Data) {
        guard let started = try? ReaderMessage.decode(SourceReadStarted.self, from: message) else {
            logger.error("started rejected bytes=\(message.count)")
            return
        }
        lock.withLock { waiting[started.id.uuidString] }?.started()
    }

    private func progressed(_ id: String, completedBytes: Int64) {
        lock.withLock { waiting[id] }?.progressed(completedBytes)
    }

    private func pauseDownloads() { lock.withLock { pauseHandler }?() }

    private final class Registration: NSObject, SourceReaderRegistration {
        weak var owner: SourceReaderService?
        weak var connection: NSXPCConnection?
        init(owner: SourceReaderService, connection: NSXPCConnection) { self.owner = owner; self.connection = connection }
        func connect(_ domainID: String, reply: @escaping (NSError?) -> Void) {
            do {
                guard let owner, let connection else { throw CocoaError(.userCancelled) }
                try owner.attach(connection, domainID: domainID)
                reply(nil)
            } catch { reply(SourceReaderBridge.error(error)) }
        }

        func started(_ message: Data) { owner?.started(message) }

        func progress(_ requestID: String, completedBytes: Int64) {
            owner?.progressed(requestID, completedBytes: completedBytes)
        }

        func pauseDownloads() { owner?.pauseDownloads() }
    }

    private final class Response: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let progress: Progress
        private let lock = NSLock()
        private var result: Result<Data, Error>?
        private var deadline = StallDeadline()

        init(progress: Progress) { self.progress = progress }

        func finish(_ result: Result<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard self.result == nil else { return }
            self.result = result
            ready.signal()
        }

        func started() { lock.withLock { deadline.started() } }

        /// Under the lock, so no message can lower the count that the caller sets after the reply.
        func progressed(_ bytes: Int64) {
            lock.lock(); defer { lock.unlock() }
            guard result == nil, deadline.progressed(completedBytes: bytes) else { return }
            progress.completedUnitCount = min(bytes, progress.totalUnitCount)
        }

        var hasStalled: Bool { lock.withLock { deadline.hasExpired } }

        func value() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            return try result!.get()
        }
    }
}
