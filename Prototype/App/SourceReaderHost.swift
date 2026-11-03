import Darwin
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
    /// A domain's extension took this app's reader (plan §3 flow 4).
    var onConnected: ((String) -> Void)?
    /// A fetch that a user waits for failed because the share is down: the domain and the failure.
    var onUserFetchFailed: ((String, SourceFailure) -> Void)?
    let downloadSpace = DownloadSpace {
        try DownloadSpace.available(at: SharedContainer.stagingDirectory())
    }
    var onSpaceChange: ((String, SourceReadRequest, Bool) -> Void)?

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
                let session = SourceReaderSession(domainID: id, source: source(id), queue: queue,
                                                  space: downloadSpace, spaceChanged: { [weak self] request, blocked in
                    Task { @MainActor in self?.onSpaceChange?(id, request, blocked) }
                }) { [weak self] failure in
                    Task { @MainActor in self?.onUserFetchFailed?(id, failure) }
                }
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
                        self?.onConnected?(id)
                    }
                }
            } catch {
                connecting.remove(id)
                SourceReaderSession.logger.error("""
                    connect domain=\(id, privacy: .public) failed \(logFields(error), privacy: .public)
                    """)
                retry(domain)
            }
        }
    }

    /// Call after every catalog has `paused` set, so the extensions' later checks see it.
    func pauseDownloads() {
        for connection in connections.values {
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? SourceReaderRegistration)?.pauseDownloads()
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
    private let userFetchFailed: @Sendable (SourceFailure) -> Void
    private let space: DownloadSpace
    private let spaceChanged: @Sendable (SourceReadRequest, Bool) -> Void
    private let progressQueue = DispatchQueue(label: "dev.tinymounter.prototype.reader-progress", qos: .utility)
    /// Set before the connection activates; progress messages go through it.
    weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private var closed = false
    static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")
    private var logger: Logger { Self.logger }

    init(domainID: String, source: LocationSource?, queue: OperationQueue, space: DownloadSpace,
         spaceChanged: @escaping @Sendable (SourceReadRequest, Bool) -> Void,
         userFetchFailed: @escaping @Sendable (SourceFailure) -> Void) {
        self.domainID = domainID
        self.source = source
        self.queue = queue
        self.userFetchFailed = userFetchFailed
        self.space = space
        self.spaceChanged = spaceChanged
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

    func create(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(CreateRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            let contents: URL?
            do {
                contents = try request.staging.map { try SharedContainer.uploadInbox($0) }
                let size = try contents.map { try ReadOnlyFile(url: $0).snapshot.size } ?? 0
                try space.begin(request.id, bytes: size)
            } catch {
                release(request.id.uuidString)
                throw error
            }
            let timer = progressTimer(request.id, job)
            source.create(request, contents: contents, progress: job.progress, started: { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }, checkSpace: { [space] completed in
                try space.check(request.id, completedBytes: completed)
            }) { [self] result in
                timer.cancel()
                space.end(request.id)
                lock.withLock { jobs[request.id] = nil }
                do { reply(try ReaderMessage.encode(result.get()), nil) }
                catch {
                    reply(nil, Self.mutationError(error))
                }
            }
        } catch { reply(nil, Self.replyError(error)) }
    }

    func edit(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(EditRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            let contents: URL
            do {
                contents = try SharedContainer.uploadInbox(request.staging)
                let size = try ReadOnlyFile(url: contents).snapshot.size
                try space.begin(request.id, bytes: size)
            } catch {
                release(request.id.uuidString)
                throw error
            }
            let timer = progressTimer(request.id, job)
            source.edit(request, contents: contents, progress: job.progress, started: { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }, checkSpace: { [space] completed in
                try space.check(request.id, completedBytes: completed)
            }) { [self] result in
                timer.cancel()
                space.end(request.id)
                lock.withLock { jobs[request.id] = nil }
                do { reply(try ReaderMessage.encode(result.get()), nil) }
                catch {
                    reply(nil, Self.mutationError(error))
                }
            }
        } catch { reply(nil, Self.replyError(error)) }
    }

    func nameFolder(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(FolderNameRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            job.progress.totalUnitCount = 1
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            let timer = progressTimer(request.id, job)
            source.nameFolder(request, progress: job.progress, started: { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }) { [self] result in
                timer.cancel()
                lock.withLock { jobs[request.id] = nil }
                do { reply(try ReaderMessage.encode(result.get()), nil) }
                catch { reply(nil, Self.mutationError(error)) }
            }
        } catch { reply(nil, Self.mutationError(error)) }
    }
    func renameFile(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        organize(data, folder: false, reply: reply)
    }

    func moveFolder(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        guard SourceReaderBridge.folderOrganizationEnabled else {
            reply(nil, CocoaError(.fileWriteNoPermission) as NSError)
            return
        }
        organize(data, folder: true, reply: reply)
    }

    private func organize(_ data: Data, folder: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(FileRenameRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            job.progress.totalUnitCount = Int64.max
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            let timer = progressTimer(request.id, job)
            let started: @Sendable () -> Void = { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }
            let finish: @Sendable (Result<CreateReceipt, Error>) -> Void = { [self] result in
                timer.cancel()
                lock.withLock { jobs[request.id] = nil }
                do { reply(try ReaderMessage.encode(result.get()), nil) }
                catch { reply(nil, Self.mutationError(error)) }
            }
            if folder { source.moveFolder(request, progress: job.progress, started: started, reply: finish) }
            else { source.renameFile(request, progress: job.progress, started: started, reply: finish) }
        } catch { reply(nil, Self.mutationError(error)) }
    }

    func deleteItem(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        guard SourceReaderBridge.deletionEnabled else {
            reply(nil, NSFileProviderError(.deletionRejected) as NSError)
            return
        }
        do {
            let request = try ReaderMessage.decode(DeleteItemRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job()
            job.progress.totalUnitCount = Int64.max
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw UploadError.pendingWrites }
            let timer = progressTimer(request.id, job)
            let deletion = DeletionRequest(item: request.item, contentVersion: request.contentVersion,
                                           metadataVersion: request.metadataVersion)
            source.deleteItem(deletion, recursive: request.recursive, progress: job.progress, started: { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }) { [self] result in
                timer.cancel()
                lock.withLock { jobs[request.id] = nil }
                do {
                    let record = try result.get()
                    guard record.plan.request == deletion else { throw ItemDeletionError.unresolved }
                    reply(try ReaderMessage.encode(DeleteItemReceipt(id: request.id, item: request.item)), nil)
                } catch { reply(nil, Self.deletionError(error)) }
            }
        } catch { reply(nil, Self.deletionError(error)) }
    }

    private static func deletionError(_ error: Error) -> NSError {
        if error is LocationError || error is CatalogError || error is SQLiteError {
            return NSFileProviderError(.serverUnreachable) as NSError
        }
        switch DeletionFailure.classify(error) {
        case .changed, .replaced, .moved, .parentChanged, .unsupported, .sharingViolation,
             .accessDenied, .cannotDelete, .readOnly:
            return NSFileProviderError(.deletionRejected) as NSError
        case .directoryNotEmpty: return NSFileProviderError(.directoryNotEmpty) as NSError
        case .connection: return NSFileProviderError(.serverUnreachable) as NSError
        case .authentication: return NSFileProviderError(.notAuthenticated) as NSError
        case .cancelled: return CocoaError(.userCancelled) as NSError
        case .storage: return CocoaError(.fileWriteOutOfSpace) as NSError
        case .unconfirmed, .pendingChanges, .unknown: return NSFileProviderError(.cannotSynchronize) as NSError
        }
    }

    private static func mutationError(_ error: Error) -> NSError {
        if let failure = error as? FolderMutationFailure {
            switch failure.code {
            case EAUTH: return NSFileProviderError(.notAuthenticated) as NSError
            case EACCES, EPERM: return CocoaError(.fileWriteNoPermission) as NSError
            case EINVAL: return CocoaError(.fileWriteInvalidFileName) as NSError
            default: return NSFileProviderError(.cannotSynchronize) as NSError
            }
        }
        switch error as? UploadError {
        case .editConflict: return NSFileProviderError(.localVersionConflictingWithServer) as NSError
        case .excluded: return NSFileProviderError(.excludedFromSync) as NSError
        case .collision: return NSFileProviderError(.filenameCollision) as NSError
        case .readOnly: return CocoaError(.fileWriteNoPermission) as NSError
        case .invalidRequest: return CocoaError(.fileWriteInvalidFileName) as NSError
        default:
            if DownloadSpace.isFull(error) { return CocoaError(.fileWriteOutOfSpace) as NSError }
            if error as? TransferError == .cancelled { return CocoaError(.userCancelled) as NSError }
            return NSFileProviderError(.cannotSynchronize) as NSError
        }
    }

    func keep(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(KeepRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            // The write can wait for a listing's commit; this connection's other messages don't.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let changed = try source.keep(request.items, value: request.keep)
                    logger.info("""
                        keep request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                        items=\(request.items.count) value=\(request.keep) changed=\(changed)
                        """)
                    reply(try ReaderMessage.encode(KeepReceipt(changed: changed)), nil)
                } catch {
                    logger.error("""
                        keep request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                        failed \(logFields(error), privacy: .public)
                        """)
                    reply(nil, Self.replyError(error))
                }
            }
        } catch {
            logger.error("keep failed \(logFields(error), privacy: .public)")
            reply(nil, Self.replyError(error))
        }
    }

    func release(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let job = lock.withLock { jobs.removeValue(forKey: id) }
        job?.progress.cancel()
        space.end(id)
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
            guard !job.progress.isCancelled else { throw TransferError.cancelled }
            try space.begin(request.id, bytes: request.range.length)
            spaceChanged(request, false)
            let output = try source.transfer(request, progress: job.progress,
                                             stagingDirectory: SharedContainer.stagingDirectory()) { [space] completed in
                try space.check(request.id, completedBytes: completed)
            }
            staged = output.stagingURL
            guard let staged else { throw CocoaError(.fileReadUnknown) }
            let receipt = try ReaderMessage.encode(SourceReadReceipt(stagingName: staged.lastPathComponent,
                                                                     metrics: output.metrics, contentVersion: output.contentVersion))
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
            if DownloadSpace.isFull(error) { spaceChanged(request, true) }
            let failure = Self.replyError(error)
            logger.error("""
                request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                item=\(request.item, privacy: .public) failed \(logFields(error), privacy: .public) \
                reply_domain=\(failure.domain, privacy: .public) reply_code=\(failure.code)
                """)
            if !request.background, let share = error as? SourceFailure, [.notConnected, .serverUnreachable].contains(share) {
                userFetchFailed(share)
            }
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
