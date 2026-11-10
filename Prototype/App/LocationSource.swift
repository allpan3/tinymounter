import Foundation
import OSLog

/// The location's catalog was closed for Remove Location; the extension treats it as unavailable.
enum LocationError: Error {
    case catalogClosed
}

/// One per added location: its writer catalog, listings and reads on the share
/// (docs/architecture.md §7).
final class LocationSource: @unchecked Sendable {
    typealias Reply = @Sendable (Result<ListReceipt, Error>) -> Void
    typealias RenameReply = @Sendable (Result<CreateReceipt, Error>) -> Void

    static let maxPendingListings = 16
    static let signalDelay = DispatchTimeInterval.milliseconds(200)

    let domainID: String
    let connection: ShareConnection
    let folder: RelativePath
    /// Signals the domain's working set; `scheduleSignal` debounces it.
    private let signal: @Sendable ([String]) -> Void
    let renameSettings: @Sendable (RenameIntent) async throws -> Void
    let renameRecovered: @Sendable () -> Void
    let deletionSettings: DeletionSettings?
    let deletionRecovered: @Sendable () -> Void
    // The share lane owns these replies while settings completion awaits the main actor.
    var renameCompletions: [UUID: [RenameReply]] = [:]
    let renameRetryLock = NSLock()
    var renameRetryWork: (id: UUID, work: DispatchWorkItem)?
    var renameRetryBackoff = RetryBackoff(first: .seconds(2), longest: .seconds(60))
    var renameRetryClosed = false
    let uploadRetry: UploadRetry
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
    /// Read only is off: uploads, renames, moves and deletions may change the share.
    var writable = false
    /// The last failure of each new item, by its macOS template, for Settings; kept in memory only.
    var failedCreates: [String: FailedCreate] = [:]
    // Settings reads the failures while the lane can hold the upload lock for a whole create.
    let failedCreatesLock = NSLock()
    var editNamespace: EditNamespace { connection.editNamespace }
    var mutationsSuspended = false
    private let lock = NSLock()
    /// Folders with a listing queued or running, and the replies that wait for it.
    private var waiting: [String: [Reply]] = [:]
    /// When a listing first held each folder's plan, for the 15 s confirmation.
    private var heldSince: [String: ContinuousClock.Instant] = [:]
    private var confirmations: Set<String> = []
    private var signalScheduled = false
    /// The last root listing found no location folder ("This folder is not on the share").
    private var rootMissing = false
    private var changeHandler: (@Sendable () -> Void)?
    private static let listingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")
    private static let fetchLog = Logger(subsystem: "dev.tinymounter.prototype", category: "fetch")

    init(domainID: String, folder: RelativePath, catalog: Catalog, connection: ShareConnection,
         renameSettings: @escaping @Sendable (RenameIntent) async throws -> Void,
         renameRecovered: @escaping @Sendable () -> Void = {},
         deletionSettings: DeletionSettings? = nil,
         deletionRecovered: @escaping @Sendable () -> Void = {},
         retryPending: @escaping @Sendable () -> Void = {},
         signal: @escaping @Sendable ([String]) -> Void) {
        self.domainID = domainID
        self.folder = folder
        self.catalog = catalog
        self.connection = connection
        self.signal = signal
        self.renameSettings = renameSettings
        self.renameRecovered = renameRecovered
        self.deletionSettings = deletionSettings
        self.deletionRecovered = deletionRecovered
        uploadRetry = UploadRetry(domainID: domainID, retry: retryPending)
        editNamespace.register(self)
    }

    /// Closes the writer connection; later calls fail with `catalogClosed`.
    func close() {
        renameRetryLock.withLock {
            renameRetryClosed = true
            renameRetryWork?.work.cancel()
            renameRetryWork = nil
        }
        uploadRetry.close()
        closeDeletionRecovery()
        editNamespace.perform {
            catalogLock.withLock { catalog = nil }
            editNamespace.detach(domainID)
        }
        connection.changeWatch.removeLocation(domainID)
    }

    var isRootMissing: Bool { lock.withLock { rootMissing } }

    /// Called when `isRootMissing` or the kept files change, on the queue that changed them.
    func onChange(_ handler: @escaping @Sendable () -> Void) { lock.withLock { changeHandler = handler } }

    func deletionStateChanged() {
        scheduleSignal()
        lock.withLock { changeHandler }?()
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

    /// The discovery folders to watch, with their paths below the location folder.
    func watchedFolders(_ ids: Set<String>) throws -> [WatchedFolder] {
        try withCatalog { catalog in
            try ids.sorted().compactMap { id in
                guard let row = try catalog.item(id: id), let path = try catalog.relativePath(of: id) else { return nil }
                return WatchedFolder(id: id, parentID: row.parentID, path: path)
            }
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
            if let refusal = connection.refusal() {
                finish(folderID, .failure(refusal))
                return
            }
            connection.enqueue { [self] in finish(folderID, Result { try listOnLane(folderID, requestID: requestID) }) }
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

    /// The same-length extent after a read of a current, unpaused file; nil at its end.
    func nextExtent(after request: SourceReadRequest) -> ByteRange? {
        guard let (row, _) = try? readTarget(request), !row.paused, request.range.end < row.size else { return nil }
        return try? ByteRange(offset: request.range.end, length: min(request.range.length, row.size - request.range.end),
                              fileSize: row.size)
    }

    /// A fetch checks the version, the share state, the catalog path, the file, its fingerprint.
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
            return try connection.withSession(folder: folder) { remote, progressed in
                let connected = ContinuousClock.now
                let listing = try shareCall(requestID, parent: parentID, context: .listing) {
                    try remote.list(path, progressed: progressed)
                }
                let listed = ContinuousClock.now
                let outbox = try Self.outbox(domainID: domainID)
                try outbox.observeFolderNames(parent: folderID, listing: listing) { record, naming in
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
                    // A partial file of a pending upload would appear beside the local item, and
                    // macOS would give the local item another name.
                    let unfinished = try outbox.unfinishedFiles(parent: folderID)
                    let applied = try catalog.reconcile(folder: folderID, listing: listing, withholding: { entry in
                        entry.kind == .file
                            && unfinished.contains { $0.fileID == entry.fileID && NameKey($0.name) == entry.key }
                    }) { proposed in
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
                // A listing that changed nothing must not report a change: the keep check runs
                // again at each change, and the share's folders are listed again every minute.
                if changed > 0 {
                    scheduleSignal()
                    lock.withLock { changeHandler }?()
                }
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

    /// A listing that starts 15 s after the hold applies what it finds.
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
