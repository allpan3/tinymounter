import FileProvider
import OSLog

@MainActor
final class SourceReaderHost {
    /// The domain's location when its session starts; nil fails every request of that session.
    var source: (String) -> LocationSource? = { _ in nil }
    private var domains: [String: NSFileProviderDomain] = [:]
    private var connections: [String: NSXPCConnection] = [:]
    private var connecting: Set<String> = []
    private var retryDelay: [String: Double] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    var onStatus: ((String) -> Void)?
    /// A domain's extension took this app's reader (plan §3 flow 4).
    var onConnected: ((String) -> Void)?

    func update(_ current: [NSFileProviderDomain]) {
        domains = Dictionary(uniqueKeysWithValues: current.map { ($0.identifier.rawValue, $0) })
        for id in Array(connections.keys) where domains[id] == nil {
            connections.removeValue(forKey: id)?.invalidate()
        }
        for domain in current { connect(domain) }
    }

    private func connect(_ domain: NSFileProviderDomain) {
        let id = domain.identifier.rawValue
        guard connections[id] == nil, connecting.insert(id).inserted else { return }
        Task { [self] in
            do {
                guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileReadUnknown) }
                guard let service = try await manager.service(named: SourceReaderBridge.serviceName, for: .rootContainer) else {
                    throw NSFileProviderError(.serverUnreachable)
                }
                let connection = try await service.fileProviderConnection()
                guard domains[id] != nil else { connection.invalidate(); connecting.remove(id); return }
                let session = SourceReaderSession(domainID: id, source: source(id), queue: queue)
                session.connection = connection
                connection.setCodeSigningRequirement(try SourceReaderBridge.requirement(forProvider: true))
                connection.exportedInterface = NSXPCInterface(with: SourceReaderProtocol.self)
                connection.exportedObject = session
                connection.remoteObjectInterface = NSXPCInterface(with: SourceReaderRegistration.self)
                connection.invalidationHandler = { [weak self, weak connection] in
                    session.cancelAll()
                    Task { @MainActor in
                        guard let self, let connection, self.connections[id] === connection else { return }
                        self.connections.removeValue(forKey: id)
                        self.retry(domain)
                    }
                }
                connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
                connections[id] = connection
                connecting.remove(id)
                connection.activate()
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak connection] _ in
                    connection?.invalidate()
                } as! SourceReaderRegistration
                proxy.connect(id) { [weak self, weak connection] error in
                    if error != nil { connection?.invalidate(); return }
                    Task { @MainActor in
                        self?.retryDelay[id] = 1
                        self?.onStatus?("Source reader connected. Keep this prototype app running during downloads.")
                        self?.onConnected?(id)
                    }
                }
            } catch {
                connecting.remove(id)
                onStatus?("Source reader connection unavailable (\((error as NSError).code)). Retrying while the app is open.")
                retry(domain)
            }
        }
    }

    private func retry(_ domain: NSFileProviderDomain) {
        let id = domain.identifier.rawValue
        guard domains[id] != nil else { return }
        let delay = retryDelay[id] ?? 1
        retryDelay[id] = min(30, delay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.domains[id] != nil else { return }
            self.connect(domain)
        }
    }
}

private final class SourceReaderSession: NSObject, SourceReaderProtocol, @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let progress = Progress()
        var staging: URL?
        /// Bytes last sent to the extension; only the progress queue touches it.
        var reported: Int64 = 0
    }
    static let maxJobs = 4
    private let domainID: String
    private let source: LocationSource?
    private let queue: OperationQueue
    private let progressQueue = DispatchQueue(label: "dev.tinymounter.prototype.reader-progress", qos: .utility)
    /// Set before the connection activates; progress messages go through it.
    weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private var closed = false
    private let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")

    init(domainID: String, source: LocationSource?, queue: OperationQueue) {
        self.domainID = domainID
        self.source = source
        self.queue = queue
    }

    func list(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(ListRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            source.list(request.folder, requestID: request.id) { result in
                do { reply(try ReaderMessage.encode(result.get()), nil) } catch { reply(nil, Self.replyError(error)) }
            }
        } catch {
            logger.error("list failed \(logFields(error), privacy: .public)")
            reply(nil, Self.replyError(error))
        }
    }

    func fetch(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(SourceReadRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            queue.addOperation { [self] in run(request, job: job, source: source, reply: reply) }
        } catch {
            logger.error("fetch failed \(logFields(error), privacy: .public)")
            reply(nil, Self.replyError(error))
        }
    }

    func release(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let job = lock.withLock { jobs.removeValue(forKey: id) }
        job?.progress.cancel()
        if let url = job?.staging { try? FileManager.default.removeItem(at: url) }
    }

    func cancelAll() {
        let ids = lock.withLock {
            closed = true
            return Array(jobs.keys)
        }
        ids.forEach { release($0.uuidString) }
    }

    private func run(_ request: SourceReadRequest, job: Job, source: LocationSource,
                     reply: @escaping (Data?, NSError?) -> Void) {
        let timer = progressTimer(request.id, job)
        defer { timer.cancel() }
        var staged: URL?
        do {
            // D2: the extension's deadline starts here, so time queued for a shared worker is no stall.
            try registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            let output = try source.transfer(request, progress: job.progress,
                                             stagingDirectory: SharedContainer.stagingDirectory())
            staged = output.stagingURL
            guard let staged else { throw CocoaError(.fileReadUnknown) }
            let receipt = try ReaderMessage.encode(SourceReadReceipt(stagingName: staged.lastPathComponent,
                                                                     metrics: output.metrics))
            let retained = lock.withLock {
                guard !closed, jobs[request.id] === job, !job.progress.isCancelled else { return false }
                job.staging = staged
                return true
            }
            guard retained else { throw TransferError.cancelled }
            logger.info("""
                request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                item=\(request.item, privacy: .public) bytes=\(request.range.length) \
                transfer_seconds=\(output.metrics.transferSeconds) source_nocache=true
                """)
            reply(receipt, nil)
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            release(request.id.uuidString)
            let failure = Self.replyError(error)
            logger.error("""
                request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                item=\(request.item, privacy: .public) failed \(logFields(error), privacy: .public) \
                reply_domain=\(failure.domain, privacy: .public) reply_code=\(failure.code)
                """)
            reply(nil, failure)
        }
    }

    /// D2: each message restarts the extension's 60 s deadline, so a long healthy download goes on.
    private func progressTimer(_ id: UUID, _ job: Job) -> DispatchSourceTimer {
        let interval = DispatchTimeInterval.nanoseconds(Int(SourceReaderBridge.progressInterval / .nanoseconds(1)))
        let timer = DispatchSource.makeTimerSource(queue: progressQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            let done = job.progress.completedUnitCount
            guard done > job.reported else { return }
            job.reported = done
            self?.registration()?.progress(id.uuidString, completedBytes: done)
        }
        timer.activate()
        return timer
    }

    /// A lost connection fails the extension's waits by itself, so send errors are ignored.
    private func registration() -> SourceReaderRegistration? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? SourceReaderRegistration
    }

    /// Only domain and code cross XPC. Catalog failures are "catalog unavailable" (plan §7).
    private static func replyError(_ error: Error) -> NSError {
        switch error {
        case CatalogError.notALiveFolder, CatalogError.notALiveFile: CocoaError(.fileReadUnknown) as NSError
        case is CatalogError, is SQLiteError, is LocationError: NSFileProviderError(.serverUnreachable) as NSError
        default: SourceReaderBridge.error(error)
        }
    }
}
