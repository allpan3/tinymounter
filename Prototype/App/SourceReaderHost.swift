import Darwin
import FileProvider
import OSLog

/// An upload or a complete-file download that the menu bar panel lists.
struct ActiveTransfer: Identifiable, Equatable, Sendable {
    enum Direction: Sendable { case upload, download }
    let id: UUID
    let domain: String
    let direction: Direction
    let name: String
    let total: Int64
    var completed: Int64 = 0
    /// A failed upload that macOS sends again by itself.
    var waiting = false
}

/// A finished transfer: the item (an upload's template or an item ID), its name and the outcome.
struct ReaderActivity: Sendable {
    enum Outcome: Sendable {
        case uploaded, downloaded
        /// `UploadRecovery` says macOS sends it again, so it is not a failure yet.
        case uploadWaiting
        case uploadFailed(reason: String)
        case conflict
        case downloadFailed(SourceFailure)
    }

    let item: String
    let name: String
    let size: Int64
    let outcome: Outcome
}

@MainActor
final class SourceReaderHost {
    /// The domain's location when its session starts; nil fails every request of that session.
    var source: (String) -> LocationSource? = { _ in nil }
    var confirmDeletion: ((String, DeleteItemRequest, Progress) async throws -> Void)?
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
    /// A domain's extension took this app's reader (docs/architecture.md §3, flow 4).
    var onConnected: ((String) -> Void)?
    /// A transfer finished, or a fetch that a user waits for failed because the share is down.
    var onActivity: ((String, ReaderActivity) -> Void)?
    /// The current transfers, at most twice a second while there are any.
    var onTransfers: (([ActiveTransfer]) -> Void)?
    private var sessions: [String: SourceReaderSession] = [:]
    /// Failed uploads that macOS sends again, by domain and item.
    private var waiting: [String: [String: ActiveTransfer]] = [:]
    private var polling: Task<Void, Never>?
    let downloadSpace = DownloadSpace {
        try DownloadSpace.available(at: SharedContainer.stagingDirectory())
    }
    /// The domain, the request, whether it is blocked now, and the file's name when it is.
    var onSpaceChange: ((String, SourceReadRequest, Bool, String?) -> Void)?

    func update(_ current: [NSFileProviderDomain]) {
        domains = Dictionary(uniqueKeysWithValues: current.map { ($0.identifier.rawValue, $0) })
        for id in Array(connections.keys) where domains[id] == nil {
            connections.removeValue(forKey: id)?.invalidate()
            sessions[id] = nil
        }
        for id in Array(waiting.keys) where domains[id] == nil { waiting[id] = nil }
        for domain in current { connect(domain) }
        pollTransfers()
    }

    /// Stop Uploading, or a reconnect that has macOS send every failed upload again. An item that
    /// macOS no longer has, because it was deleted or moved, would keep its row until quit.
    func dropWaiting(domain: String, item: String? = nil) {
        if let item { waiting[domain]?[item] = nil } else { waiting[domain] = nil }
        pollTransfers()
    }

    /// `upload` is the item of an upload, which replaces its waiting row.
    private func transferStarted(_ domain: String, upload: String?) {
        if let upload { waiting[domain]?[upload] = nil }
        pollTransfers()
    }

    private func finished(_ domain: String, _ activity: ReaderActivity) {
        switch activity.outcome {
        case .uploadWaiting:
            waiting[domain, default: [:]][activity.item] = ActiveTransfer(
                id: UUID(), domain: domain, direction: .upload, name: activity.name, total: activity.size, waiting: true)
        case .uploaded, .uploadFailed, .conflict:
            waiting[domain]?[activity.item] = nil
            onActivity?(domain, activity)
        case .downloaded, .downloadFailed:
            onActivity?(domain, activity)
        }
        pollTransfers()
    }

    /// Progress changes many times each second, so the panel reads it on a timer.
    private func pollTransfers() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while let self {
                let current = sessions.values.flatMap { $0.transfers() } + waiting.values.flatMap(\.values)
                onTransfers?(current.sorted { ($0.waiting ? 1 : 0, $0.name) < ($1.waiting ? 1 : 0, $1.name) })
                guard !current.contains(where: { !$0.waiting }) else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                polling = nil
                return
            }
        }
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
                                                  space: downloadSpace, confirmDeletion: { [weak self] request, progress in
                    guard let confirm = await self?.confirmDeletion else { throw UploadError.readOnly }
                    try await confirm(id, request, progress)
                }, spaceChanged: { [weak self] request, blocked, name in
                    Task { @MainActor in self?.onSpaceChange?(id, request, blocked, name) }
                }, started: { [weak self] upload in
                    Task { @MainActor in self?.transferStarted(id, upload: upload) }
                }) { [weak self] activity in
                    Task { @MainActor in self?.finished(id, activity) }
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
                        self.sessions[id] = nil
                        self.retry(domain)
                    }
                }
                connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
                connections[id] = connection
                sessions[id] = session
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
        let isDeletion: Bool
        var awaitingConfirmation = false
        var staging: URL?
        /// Bytes last sent to the extension; only the progress queue touches it.
        var reported: Int64 = 0
        /// Set under the session's lock while the panel lists this job.
        var transfer: ActiveTransfer?

        init(isDeletion: Bool = false) { self.isDeletion = isDeletion }
    }
    static let maxJobs = 4
    private let domainID: String
    private let source: LocationSource?
    private let queue: OperationQueue
    private let finished: @Sendable (ReaderActivity) -> Void
    private let started: @Sendable (String?) -> Void
    private let space: DownloadSpace
    private let confirmDeletion: @Sendable (DeleteItemRequest, Progress) async throws -> Void
    private let spaceChanged: @Sendable (SourceReadRequest, Bool, String?) -> Void
    private let progressQueue = DispatchQueue(label: "dev.tinymounter.prototype.reader-progress", qos: .utility)
    /// Set before the connection activates; progress messages go through it.
    weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private var closed = false
    private let prefetch: ReadPrefetch
    static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")
    private var logger: Logger { Self.logger }

    init(domainID: String, source: LocationSource?, queue: OperationQueue, space: DownloadSpace,
         confirmDeletion: @escaping @Sendable (DeleteItemRequest, Progress) async throws -> Void,
         spaceChanged: @escaping @Sendable (SourceReadRequest, Bool, String?) -> Void,
         started: @escaping @Sendable (String?) -> Void,
         finished: @escaping @Sendable (ReaderActivity) -> Void) {
        self.domainID = domainID
        self.source = source
        self.queue = queue
        self.started = started
        self.finished = finished
        self.space = space
        prefetch = ReadPrefetch(space: space)
        self.confirmDeletion = confirmDeletion
        self.spaceChanged = spaceChanged
    }

    func transfers() -> [ActiveTransfer] {
        lock.withLock {
            jobs.values.compactMap { job in
                guard var transfer = job.transfer else { return nil }
                // Upload progress counts more than the file's bytes, so only its fraction is used.
                transfer.completed = Int64(Double(transfer.total) * min(1, max(0, job.progress.fractionCompleted)))
                return transfer
            }
        }
    }

    /// Lists the job in the panel; an upload's item replaces its waiting row.
    private func show(_ job: Job, _ transfer: ActiveTransfer, upload: String? = nil) {
        lock.withLock { job.transfer = transfer }
        started(upload)
    }

    // Namespace settlement resends refused writes; connection failures use the waiting row.
    private static func uploadOutcome(_ error: Error) -> ReaderActivity.Outcome? {
        if error as? TransferError == .cancelled || error as? UploadError == .excluded { return nil }
        if error as? UploadError == .pendingWrites { return nil }
        if error as? UploadError == .editConflict { return .conflict }
        return UploadRecovery.retriesByItself(error) ? .uploadWaiting : .uploadFailed(reason: UIText.uploadFailure(error))
    }

    private func uploadFinished<T>(item: String, name: String, size: Int64, _ result: Result<T, Error>) {
        switch result {
        case .success: finished(ReaderActivity(item: item, name: name, size: size, outcome: .uploaded))
        case .failure(let error):
            guard let outcome = Self.uploadOutcome(error) else { return }
            finished(ReaderActivity(item: item, name: name, size: size, outcome: outcome))
        }
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
            try source.checkReimport(request)
            let job = Job()
            let accepted = lock.withLock {
                guard !closed, jobs.count < Self.maxJobs, jobs[request.id] == nil else { return false }
                jobs[request.id] = job
                return true
            }
            guard accepted else { throw CocoaError(.fileReadUnknown) }
            let contents: URL?
            let size: Int64
            do {
                contents = try request.staging.map { try SharedContainer.uploadInbox($0) }
                size = try contents.map { try ReadOnlyFile(url: $0).snapshot.size } ?? 0
                try space.begin(request.id, bytes: size)
            } catch {
                release(request.id.uuidString)
                throw error
            }
            let isFile = request.kind == .file
            if isFile {
                show(job, ActiveTransfer(id: request.id, domain: domainID, direction: .upload, name: request.name, total: size),
                     upload: request.template)
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
                if isFile { uploadFinished(item: request.template, name: request.name, size: size, result) }
                do { reply(try ReaderMessage.encode(result.get()), nil) }
                catch {
                    reply(nil, Self.mutationError(error))
                }
            }
        } catch { reply(nil, Self.mutationError(error)) }
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
            let size: Int64
            do {
                contents = try SharedContainer.uploadInbox(request.staging)
                size = try ReadOnlyFile(url: contents).snapshot.size
            } catch {
                release(request.id.uuidString)
                throw error
            }
            show(job, ActiveTransfer(id: request.id, domain: domainID, direction: .upload, name: request.name, total: size),
                 upload: request.item)
            let timer = progressTimer(request.id, job)
            source.edit(request, contents: contents, progress: job.progress, started: { [weak self] in
                try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            }) { [self] result in
                timer.cancel()
                lock.withLock { jobs[request.id] = nil }
                uploadFinished(item: request.item, name: request.name, size: size, result)
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
                catch {
                    reply(nil, error as? SourceFailure == .versionChanged
                          ? SourceReaderBridge.refusedOrganizationError : Self.mutationError(error))
                }
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
        delete(data, confirmedAction: false, reply: reply)
    }

    func deletePermanently(_ data: Data, reply: @escaping (Data?, NSError?) -> Void) {
        guard SourceReaderBridge.permanentDeletionEnabled else {
            reply(nil, NSFileProviderError(.deletionRejected) as NSError)
            return
        }
        delete(data, confirmedAction: true, reply: reply)
    }

    private func delete(_ data: Data, confirmedAction: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let request = try ReaderMessage.decode(DeleteItemRequest.self, from: data)
            guard let source else { throw LocationError.catalogClosed }
            let job = Job(isDeletion: true)
            job.awaitingConfirmation = confirmedAction
            job.progress.totalUnitCount = Int64.max
            try lock.withLock {
                guard !closed, jobs[request.id] == nil else { throw UploadError.pendingWrites }
                guard jobs.count < Self.maxJobs else { throw ItemDeletionError.busy }
                jobs[request.id] = job
            }
            let timer = progressTimer(request.id, job)
            let deletion = DeletionRequest(item: request.item, contentVersion: request.contentVersion,
                                           metadataVersion: request.metadataVersion, eventVersion: request.eventVersion)
            let finish: LocationSource.DeletionReply = { [self] result in
                timer.cancel()
                lock.withLock { jobs[request.id] = nil }
                do {
                    let record = try result.get()
                    guard record.plan.request.item == deletion.item,
                          try ProviderDomainVersion.matches(record.plan.request.eventVersion,
                                                            deletion.eventVersion) else {
                        throw ItemDeletionError.unresolved
                    }
                    reply(try ReaderMessage.encode(DeleteItemReceipt(id: request.id, item: request.item)), nil)
                } catch {
                    logger.error("deletion request=\(request.id.uuidString, privacy: .public) failed \(logFields(error), privacy: .public)")
                    reply(nil, Self.deletionError(error))
                }
            }
            let run = { [self] in
                source.deleteItem(deletion, recursive: request.recursive, progress: job.progress, started: { [weak self] in
                    try? self?.registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
                }, reply: finish)
            }
            if confirmedAction {
                Task { [self] in
                    do {
                        try await confirmDeletion(request, job.progress)
                        try lock.withLock {
                            guard !closed, jobs[request.id] === job, !job.progress.isCancelled else {
                                throw TransferError.cancelled
                            }
                            job.awaitingConfirmation = false
                        }
                        run()
                    } catch { finish(.failure(error)) }
                }
            } else { run() }
        } catch { reply(nil, Self.deletionError(error)) }
    }

    private static func deletionError(_ error: Error) -> NSError {
        if error is NamespaceDrainError { return CocoaError(.xpcConnectionReplyInvalid) as NSError }
        // Refusal restores the reconciled survivor without confirming its recorded deletion outcome.
        if error as? ItemDeletionError == .unconfirmedSurvivor {
            return NSFileProviderError(.deletionRejected) as NSError
        }
        if error is LocationError || error is CatalogError || error is SQLiteError {
            return NSFileProviderError(.serverUnreachable) as NSError
        }
        switch DeletionFailure.classify(error) {
        case .changed, .replaced, .moved, .parentChanged, .unsupported, .sharingViolation,
             .accessDenied, .cannotDelete, .readOnly, .stopped:
            return NSFileProviderError(.deletionRejected) as NSError
        case .directoryNotEmpty: return NSFileProviderError(.directoryNotEmpty) as NSError
        case .busy: return CocoaError(.xpcConnectionReplyInvalid) as NSError
        case .connection: return NSFileProviderError(.serverUnreachable) as NSError
        case .authentication: return NSFileProviderError(.notAuthenticated) as NSError
        case .cancelled: return CocoaError(.userCancelled) as NSError
        case .storage: return CocoaError(.fileWriteOutOfSpace) as NSError
        case .unconfirmed, .pendingChanges, .unknown: return NSFileProviderError(.cannotSynchronize) as NSError
        }
    }

    private static func mutationError(_ error: Error) -> NSError {
        if error is NamespaceDrainError { return CocoaError(.xpcConnectionReplyInvalid) as NSError }
        if let failure = error as? FolderMutationFailure {
            switch failure.code {
            case EAUTH: return NSFileProviderError(.notAuthenticated) as NSError
            case EACCES, EPERM: return CocoaError(.fileWriteNoPermission) as NSError
            case EINVAL: return CocoaError(.fileWriteInvalidFileName) as NSError
            default: return NSFileProviderError(.cannotSynchronize) as NSError
            }
        }
        switch error as? UploadError {
        case .reimportRecovery: return SourceReaderBridge.reimportRecoveryError
        case .pendingWrites: return SourceReaderBridge.pendingWritesError
        case .editConflict: return NSFileProviderError(.localVersionConflictingWithServer) as NSError
        case .excluded: return NSFileProviderError(.excludedFromSync) as NSError
        case .collision: return NSFileProviderError(.filenameCollision) as NSError
        case .readOnly: return CocoaError(.fileWriteNoPermission) as NSError
        case .invalidRequest: return CocoaError(.fileWriteInvalidFileName) as NSError
        default:
            if DownloadSpace.isFull(error) { return CocoaError(.fileWriteOutOfSpace) as NSError }
            if error as? TransferError == .cancelled { return CocoaError(.userCancelled) as NSError }
            switch SourceFailure.classify(error, context: .fetch) {
            case .serverUnreachable, .notConnected, .localNetworkDenied:
                return NSFileProviderError(.serverUnreachable) as NSError
            case .notAuthenticated: return NSFileProviderError(.notAuthenticated) as NSError
            case .noPermission, .pathRejected: return CocoaError(.fileWriteNoPermission) as NSError
            default: break
            }
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

    func cancelDeletion(_ requestID: String) {
        guard let id = UUID(uuidString: requestID),
              let job = lock.withLock({ jobs[id] }), job.isDeletion else { return }
        job.progress.cancel()
    }

    func release(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let (job, cancel) = lock.withLock {
            let job = jobs.removeValue(forKey: id)
            return (job, job.map { !$0.isDeletion || $0.awaitingConfirmation } ?? false)
        }
        // Losing an XPC waiter must not turn a durable deletion into a user-requested Stop.
        if cancel { job?.progress.cancel() }
        space.end(id)
        if let url = job?.staging { try? FileManager.default.removeItem(at: url) }
    }

    func cancelAll() {
        let ids = lock.withLock {
            closed = true
            return Array(jobs.keys)
        }
        ids.forEach { release($0.uuidString) }
        prefetch.close()
    }

    private func run(_ request: SourceReadRequest, job: Job, source: LocationSource,
                     reply: @escaping (Data?, NSError?) -> Void) {
        let timer = progressTimer(request.id, job)
        defer { timer.cancel() }
        var staged: URL?
        // Playback and Quick Look read ranges; only a complete-file download is listed and reported.
        let target = try? source.readTarget(request).0
        let file = target.flatMap { $0.size == request.range.length && request.range.offset == 0 ? $0 : nil }
        do {
            // D2: the extension's deadline starts here, so time queued for a shared worker is no stall.
            try registration()?.started(ReaderMessage.encode(SourceReadStarted(id: request.id)))
            guard !job.progress.isCancelled else { throw TransferError.cancelled }
            try space.begin(request.id, bytes: request.range.length)
            spaceChanged(request, false, nil)
            if let file {
                show(job, ActiveTransfer(id: request.id, domain: domainID, direction: .download, name: file.name,
                                         total: file.size))
            }
            let prefetched = prefetch.claim(request, isCancelled: { job.progress.isCancelled })
            let output = try prefetched ?? source.transfer(request, progress: job.progress,
                                             stagingDirectory: SharedContainer.stagingDirectory()) { [space] completed in
                try space.check(request.id, completedBytes: completed)
            }
            staged = output.stagingURL
            guard let staged else { throw CocoaError(.fileReadUnknown) }
            let receipt = try ReaderMessage.encode(SourceReadReceipt(stagingName: staged.lastPathComponent,
                                                                     metrics: output.metrics))
            let retained = lock.withLock {
                guard !closed, jobs[request.id] === job, !job.progress.isCancelled else { return false }
                job.staging = staged
                // The job stays until the extension takes the staged file; the transfer is done.
                job.transfer = nil
                return true
            }
            guard retained else { throw TransferError.cancelled }
            logger.info("""
                request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                item=\(request.item, privacy: .public) bytes=\(request.range.length) \
                transfer_seconds=\(output.metrics.transferSeconds) transport=direct_smb \
                prefetched=\(prefetched != nil)
                """)
            reply(receipt, nil)
            // Keep Downloaded reports a kept file when it is verified available offline instead.
            if let file, !file.keep {
                finished(ReaderActivity(item: file.id, name: file.name, size: file.size, outcome: .downloaded))
            }
            prefetch.completed(request, next: { source.nextExtent(after: request) },
                               enqueue: { [queue] in queue.addOperation($0) }) { [space] next, progress in
                try source.transfer(next, progress: progress, stagingDirectory: SharedContainer.stagingDirectory()) {
                    try space.check(next.id, completedBytes: $0)
                }
            }
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            release(request.id.uuidString)
            if DownloadSpace.isFull(error) { spaceChanged(request, true, target?.name) }
            let failure = Self.replyError(error)
            logger.error("""
                request=\(request.id.uuidString, privacy: .public) domain=\(self.domainID, privacy: .public) \
                item=\(request.item, privacy: .public) failed \(logFields(error), privacy: .public) \
                reply_domain=\(failure.domain, privacy: .public) reply_code=\(failure.code)
                """)
            if !request.background, let target, let share = error as? SourceFailure,
               [.notConnected, .serverUnreachable, .localNetworkDenied].contains(share) {
                finished(ReaderActivity(item: target.id, name: target.name, size: target.size,
                                        outcome: .downloadFailed(share)))
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

    /// Only domain and code cross XPC. Catalog failures are "catalog unavailable".
    private static func replyError(_ error: Error) -> NSError {
        switch error {
        case CatalogError.notALiveFolder, CatalogError.notALiveFile: CocoaError(.fileReadUnknown) as NSError
        case is CatalogError, is SQLiteError, is LocationError: NSFileProviderError(.serverUnreachable) as NSError
        default: SourceReaderBridge.error(error)
        }
    }
}
