import FileProvider
import OSLog

/// Read-ahead bounds; one speculative fetch at a time limits how long a seek can queue.
private enum ReadAheadPolicy {
    static let demandExtent: Int64 = 16 << 20
    static let chunk: Int64 = 16 << 20
    /// Deeper windows let fast readers fault on ranges fileproviderd was still applying.
    static let window: Int64 = 16 << 20
    /// fileproviderd dispatched a waiting seek only once back-to-back speculative requests paused.
    static let chainGap: DispatchTimeInterval = .milliseconds(30)
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching, NSFileProviderServicing,
                                    NSFileProviderCustomAction {
    /// First read by the first init, before this process can stage anything.
    private static let processStart = Date()

    private let domain: NSFileProviderDomain
    private let sourceReader: SourceReaderService
    private let catalog: CatalogReader
    private let finderDownloads = FinderDownloadProgress()
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q
    }()
    private let lock = NSLock()
    private var active: [UUID: Progress] = [:]
    private var invalidated = false
    private var readAhead = ReadAheadRegistry(chunk: ReadAheadPolicy.chunk, window: ReadAheadPolicy.window, maxInFlight: 1)
    /// Speculative fetches in flight and their items, so a seek cancels only its own item's.
    private var speculative: [UUID: (item: String, version: String, progress: Progress)] = [:]
    /// System and speculative fetches in `active`: the ones that Pause Downloads stops.
    private var background: Set<UUID> = []
    private var mutations: [String: Int] = [:]
    private let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "fetch")
    private let actionLogger = Logger(subsystem: "dev.tinymounter.prototype", category: "actions")
    private let catalogLogger = Logger(subsystem: "dev.tinymounter.prototype", category: "catalog")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        sourceReader = SourceReaderService(domainID: domain.identifier.rawValue)
        catalog = CatalogReader(domainID: domain.identifier.rawValue)
        super.init()
        sourceReader.onPauseDownloads { [weak self] in self?.cancelBackgroundFetches(reason: "pause_downloads") }
        // A fetch that waited for the reader missed the cancel that Pause sent before it connected.
        sourceReader.onConnect { [weak self] in self?.cancelBackgroundFetchesIfPaused() }
        // Resolving an app's recent-file bookmarks would otherwise download each whole file.
        UserDefaults.standard.set(["ScopedBookmarkAgent"], forKey: "NSFileProviderExtensionNonMaterializingProcessNames")
        let cutoff = Self.processStart
        // The temporary directory can fail while the domain is still initializing.
        DispatchQueue.global(qos: .utility).async { [self] in removeLeftoverStageFiles(createdBefore: cutoff) }
    }

    func invalidate() {
        lock.lock(); invalidated = true; let current = Array(active.values); lock.unlock()
        current.forEach { $0.cancel() }
        finderDownloads.invalidate()
        sourceReader.invalidate()
        // Do not cancel queued Operations: every queued callback still needs its completion.
    }

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler(itemIdentifier == .rootContainer ? [sourceReader] : [], nil)
        return Progress()
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            completionHandler(CatalogItem(try catalog.liveRow(identifier.rawValue)), nil)
        } catch {
            let failure = providerError(error) as NSError
            catalogLogger.error("""
                item=\(Self.logID(identifier.rawValue), privacy: .public) failed \
                error_domain=\(failure.domain, privacy: .public) code=\(failure.code)
                """)
            completionHandler(nil, failure)
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        try CatalogEnumerator.make(for: containerItemIdentifier, catalog: catalog, reader: sourceReader, domain: domain)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        fetch(identifier: itemIdentifier, version: requestedVersion, range: nil, alignment: 1, request: request) { url, item, _, error in
            completionHandler(url, item, error)
        }
    }

    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        fetch(identifier: itemIdentifier, version: requestedVersion, range: minimalRange, alignment: alignment,
              request: request) { url, item, range, error in
            completionHandler(url, item, range, [], error)
        }
    }

    private func fetch(identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, range requested: NSRange?,
                       alignment: Int, request: NSFileProviderRequest,
                       completion: @escaping (URL?, NSFileProviderItem?, NSRange, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        let requestID = UUID()
        let item = identifier.rawValue
        let row: CatalogRow
        do {
            row = try catalog.liveRow(item)
            guard row.kind == .file else { throw CocoaError(.fileReadUnknown) }
            if let version, version.contentVersion != Data(row.contentVersion.utf8) {
                throw NSFileProviderError(.versionNoLongerAvailable)
            }
        } catch {
            let failure = providerError(error) as NSError
            logger.error("""
                request=\(requestID.uuidString, privacy: .public) item=\(Self.logID(item), privacy: .public) failed \
                stage=catalog domain=\(failure.domain, privacy: .public) code=\(failure.code)
                """)
            completion(nil, nil, NSRange(location: 0, length: 0), failure)
            return progress
        }
        let partial = requested?.location == NSNotFound ? nil : requested
        let start = partial.map { Int64($0.location) - Int64($0.location) % Int64(max(alignment, 1)) }
        let (kind, seekCancels, cancelled) = lock.withLock { () -> (ReadAheadPlanner.Kind?, [Progress], Bool) in
            var kind: ReadAheadPlanner.Kind?
            var seekCancels: [Progress] = []
            if let partial, let start {
                kind = readAhead.classify(item: row.id, version: row.contentVersion, fileSize: row.size, offset: start,
                                          length: Int64(partial.location + partial.length) - start)
                // Old speculation of this item is now useless; macOS may have delivered the seek early.
                if kind == .demand(sequential: false) {
                    seekCancels = speculative.values.filter { $0.item == row.id }.map(\.progress)
                }
            }
            active[requestID] = progress
            if kind == .speculative(current: true) { speculative[requestID] = (row.id, row.contentVersion, progress) }
            if request.isSystemRequest || kind == .speculative(current: true) { background.insert(requestID) }
            return (kind, seekCancels, invalidated)
        }
        seekCancels.forEach { $0.cancel() }
        if cancelled { progress.cancel() }
        if case .speculative(current: false) = kind {
            logger.info("""
                request=\(requestID.uuidString, privacy: .public) item=\(row.id, privacy: .public) \
                kind=stale-speculative offset=\(start ?? 0)
                """)
            completion(nil, nil, NSRange(location: 0, length: 0), CocoaError(.userCancelled))
            lock.withLock { active[requestID] = nil; background.remove(requestID) }
            return progress
        }
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        queue.addOperation { [self] in
            defer {
                lock.withLock { active[requestID] = nil; speculative[requestID] = nil; background.remove(requestID) }
            }
            let startedAt = DispatchTime.now().uptimeNanoseconds
            var staging: URL?
            var stage = "range"
            do {
                guard !progress.isCancelled else { throw TransferError.cancelled }
                // Read after joining `active`: a Pause that commits later also cancels this fetch.
                if lock.withLock({ background.contains(requestID) }), (try? catalog.liveRow(item))?.paused == true {
                    stage = "paused"
                    throw TransferError.cancelled
                }
                let range: ByteRange
                if let partial {
                    let required = try ByteRange.clampedToEOF(offset: Int64(partial.location), length: Int64(partial.length),
                                                              fileSize: row.size)
                    let preferred = kind == .speculative(current: true) ? required.length : ReadAheadPolicy.demandExtent
                    range = try lock.withLock {
                        try readAhead.extent(item: row.id, version: row.contentVersion, covering: required,
                                             alignment: Int64(alignment), fileSize: row.size, preferredLength: preferred)
                    }
                } else {
                    range = try ByteRange(offset: 0, length: row.size, fileSize: row.size)
                }
                stage = "app-reader"
                guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileReadUnknown) }
                let directory = try manager.temporaryDirectoryURL()
                progress.totalUnitCount = range.length
                let stopProgress = partial == nil && row.keep
                    ? finderDownloads.track(item: row, progress: progress, catalog: catalog, manager: manager)
                    : {}
                defer { stopProgress() }
                let isBackground = lock.withLock { background.contains(requestID) }
                let result = try sourceReader.fetch(SourceReadRequest(id: requestID, item: row.id, version: row.contentVersion,
                                                                      range: range, background: isBackground),
                                                    directory: directory, progress: progress)
                staging = result.0
                progress.completedUnitCount = range.length
                guard !progress.isCancelled else { throw TransferError.cancelled }
                let mode = partial == nil ? "full" : "partial"
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
                let queueSeconds = Double(startedAt - queuedAt) / 1e9
                let planners = lock.withLock { readAhead.count }
                logger.info("request=\(requestID.uuidString, privacy: .public) item=\(row.id, privacy: .public) mode=\(mode, privacy: .public) kind=\(kind.map(Self.label) ?? "full", privacy: .public) viewer=\(request.isFileViewerRequest) system=\(request.isSystemRequest) offset=\(range.offset) bytes=\(range.length) queue_seconds=\(queueSeconds) callback_seconds=\(elapsed) transfer_seconds=\(result.1.transferSeconds) planners=\(planners)")
                completion(staging, CatalogItem(row), NSRange(location: Int(range.offset), length: Int(range.length)), nil)
                // Ownership now belongs to File Provider; never modify or unlink after handoff.
                staging = nil
                if let kind {
                    readAheadCompleted(kind, row: row, range: range)
                } else {
                    let cancellations = lock.withLock {
                        readAhead.fullCompleted(item: row.id, version: row.contentVersion)
                        return speculative.values.filter { $0.item == row.id && $0.version == row.contentVersion }
                            .map(\.progress)
                    }
                    cancellations.forEach { $0.cancel() }
                }
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                let failure = error as NSError
                logger.error("request=\(requestID.uuidString, privacy: .public) item=\(row.id, privacy: .public) failed stage=\(stage, privacy: .public) kind=\(kind.map(Self.label) ?? "full", privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                if case .speculative = kind, let start {
                    lock.withLock { readAhead.speculativeFailed(item: row.id, version: row.contentVersion, offset: start) }
                }
                completion(nil, nil, NSRange(location: 0, length: 0), providerError(error))
            }
        }
        return progress
    }

    private static func label(_ kind: ReadAheadPlanner.Kind) -> String {
        switch kind {
        case .demand(sequential: let sequential): return sequential ? "sequential" : "demand"
        case .speculative: return "speculative"
        }
    }

    private func readAheadCompleted(_ kind: ReadAheadPlanner.Kind, row: CatalogRow, range: ByteRange) {
        let (ranges, stopped) = lock.withLock { () -> ([ByteRange], Bool) in
            switch kind {
            case .demand(sequential: let sequential):
                return (readAhead.demandCompleted(item: row.id, version: row.contentVersion, range: range,
                                                  sequential: sequential), invalidated)
            case .speculative:
                return (readAhead.speculativeFinished(item: row.id, version: row.contentVersion, range: range),
                        invalidated)
            }
        }
        guard !stopped, !ranges.isEmpty else { return }
        if case .speculative = kind {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ReadAheadPolicy.chainGap) { [self] in
                requestDownloads(ranges, row: row)
            }
        } else {
            requestDownloads(ranges, row: row)
        }
    }

    private func requestDownloads(_ ranges: [ByteRange], row: CatalogRow) {
        lock.lock(); let stopped = invalidated; lock.unlock()
        guard !stopped, let manager = NSFileProviderManager(for: domain) else { return }
        let paused = (try? catalog.liveRow(row.id))?.paused
        guard paused == false else {
            // Pause Downloads, or the row is gone: retire the plan so a later miss plans again.
            lock.withLock {
                for range in ranges { readAhead.requestFailed(item: row.id, version: row.contentVersion, range: range) }
            }
            logger.info("""
                readahead item=\(row.id, privacy: .public) ranges=\(ranges.count) skipped=1 paused=\(paused == true)
                """)
            return
        }
        for range in ranges {
            // Completion only acknowledges scheduling; the bytes arrive later as a partial fetch.
            manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(row.id),
                requestedRange: NSRange(location: Int(range.offset), length: Int(range.length))) { [self] error in
                guard let error else { return }
                lock.withLock { readAhead.requestFailed(item: row.id, version: row.contentVersion, range: range) }
                logger.error("readahead item=\(row.id, privacy: .public) offset=\(range.offset) not scheduled code=\((error as NSError).code)")
            }
            logger.info("readahead item=\(row.id, privacy: .public) offset=\(range.offset) bytes=\(range.length) requested")
        }
    }

    /// Plan §7: only files from an earlier process, so none of this process's handoffs.
    private func removeLeftoverStageFiles(createdBefore cutoff: Date) {
        do {
            guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileReadUnknown) }
            let directory = try manager.temporaryDirectoryURL()
            let removed = try Staging.removeLeftoverStageFiles(in: directory, createdBefore: cutoff)
            let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
                .count(where: Staging.isStageFileName)
            logger.info("temp_removed=\(removed) temp_stage_files=\(left)")
        } catch {
            let failure = error as NSError
            logger.error("temp_sweep failed error_domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        }
    }

    /// Plan §6: the app set `paused` before it sent this, so fetches that start later stop too.
    private func cancelBackgroundFetches(reason: String) {
        let cancels = lock.withLock { background.compactMap { active[$0] } }
        cancels.forEach { $0.cancel() }
        logger.info("\(reason, privacy: .public) cancelled=\(cancels.count)")
    }

    private func cancelBackgroundFetchesIfPaused() {
        guard (try? catalog.liveRow(Catalog.rootItemID))?.paused == true else { return }
        cancelBackgroundFetches(reason: "reader_connected_paused")
    }

    /// Keep Downloaded and Allow Removal record a request through the app (plan §8).
    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let once = Once()
        let action = actionIdentifier.rawValue
        let finish = { [actionLogger] (changed: Int, error: Error?) in
            guard once.claim() else { return }
            let code = (error as NSError?)?.code ?? 0
            actionLogger.log(level: error == nil ? .info : .error, """
                action=\(action, privacy: .public) items=\(itemIdentifiers.count) changed=\(changed) code=\(code)
                """)
            completionHandler(error)
        }
        // The header asks for userCancelled at once, from the cancellation handler.
        progress.cancellationHandler = { finish(0, CocoaError(.userCancelled)) }
        let keep: Bool
        switch action {
        case "dev.tinymounter.action.keep-downloaded": keep = true
        case "dev.tinymounter.action.allow-removal": keep = false
        default:
            finish(0, CocoaError(.featureUnsupported))
            return progress
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var changed = 0
            do {
                for batch in try KeepRequest.batches(itemIdentifiers.map(\.rawValue), keep: keep) {
                    changed += try sourceReader.keep(batch, progress: progress).changed
                    progress.completedUnitCount += Int64(batch.items.count)
                }
                finish(changed, nil)
            } catch {
                finish(changed, providerError(error))
            }
        }
        return progress
    }

    /// Reimport keeps read-only matching; new ordinary items require explicit write access.
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        if !options.contains(.mayAlreadyExist), !options.contains(.deletionConflicted) {
            countMutation("create", "new=1 phase=received")
            let progress = Progress(totalUnitCount: 1)
            let once = Once()
            let finish = { (item: NSFileProviderItem?, error: Error?) in
                if once.claim() { completionHandler(item, [], false, error) }
            }
            progress.cancellationHandler = { finish(nil, CocoaError(.userCancelled)) }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var staged: URL?
                defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
                do {
                    guard try catalog.liveRow(itemTemplate.parentItemIdentifier.rawValue).allowsCreation,
                          let type = itemTemplate.contentType, !type.conforms(to: .symbolicLink),
                          !type.conforms(to: .package),
                          let kind = Self.kind(of: itemTemplate),
                          kind != .file || url != nil else { throw CocoaError(.fileWriteNoPermission) }
                    let stagingID = url.map { _ in UUID() }
                    if let url, let stagingID {
                        let target = try SharedContainer.uploadInbox(stagingID)
                        let size = try ReadOnlyFile(url: url, allowMaterialization: true).snapshot.size
                        guard Int128(try DownloadSpace.available(at: target.deletingLastPathComponent()))
                            >= Int128(DownloadSpace.reserveBytes) + Int128(size) * 2 else {
                            throw CocoaError(.fileWriteOutOfSpace)
                        }
                        try FileManager.default.copyItem(at: url, to: target)
                        staged = target
                    }
                    let message = try CreateRequest(template: itemTemplate.itemIdentifier.rawValue,
                                                    parent: itemTemplate.parentItemIdentifier.rawValue,
                                                    name: itemTemplate.filename, kind: kind, staging: stagingID)
                    let receipt = try sourceReader.create(message, progress: progress)
                    let row = try catalog.liveRow(receipt.item)
                    progress.completedUnitCount = progress.totalUnitCount
                    finish(CatalogItem(row), nil)
                } catch {
                    let failure = providerError(error) as NSError
                    countMutation("create", "new=1 phase=failed domain=\(failure.domain) code=\(failure.code)")
                    finish(nil, failure)
                }
            }
            return progress
        }
        let decision: ReimportDecision
        if options.contains(.mayAlreadyExist) {
            decision = (try? catalog.read { catalog in
                try catalog.reimportDecision(parent: itemTemplate.parentItemIdentifier.rawValue, name: itemTemplate.filename,
                                             kind: Self.kind(of: itemTemplate), hasContents: url != nil,
                                             size: (itemTemplate.documentSize ?? nil)?.int64Value,
                                             modified: itemTemplate.contentModificationDate ?? nil)
            }) ?? .reject
        } else {
            decision = .reject
        }
        let reimport = options.contains(.mayAlreadyExist) ? 1 : 0
        switch decision {
        case .existing(let row, let fetchContent):
            countMutation("create", "reimport=\(reimport) result=existing fetch=\(fetchContent ? 1 : 0)")
            completionHandler(CatalogItem(row), [], fetchContent, nil)
        case .discard:
            countMutation("create", "reimport=\(reimport) result=discarded")
            completionHandler(nil, [], false, nil)
        case .reject:
            countMutation("create", "reimport=\(reimport) result=rejected")
            completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        countMutation("modify", "result=rejected")
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission)); return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        countMutation("delete", "result=rejected")
        completionHandler(CocoaError(.fileWriteNoPermission)); return Progress()
    }

    /// Rejected mutations are counted without recording names.
    private func countMutation(_ mutation: String, _ fields: String) {
        let count = lock.withLock { () -> Int in
            mutations[mutation, default: 0] += 1
            return mutations[mutation, default: 0]
        }
        catalogLogger.info("mutation=\(mutation, privacy: .public) \(fields, privacy: .public) count=\(count)")
    }

    /// nil for a template that is neither a file nor a folder, such as a symbolic link.
    private static func kind(of template: NSFileProviderItem) -> CatalogRow.Kind? {
        guard let type = template.contentType else { return nil }
        if type.conforms(to: .directory) { return .folder }
        return type.conforms(to: .data) ? .file : nil
    }

    /// The system's own identifiers are not item IDs; logging only those keeps names out.
    private static func logID(_ id: String) -> String { ReaderMessage.isItemID(id) ? id : "other" }
}

/// Every error leaves in the Cocoa or File Provider domain, and none of them describes a path.
func providerError(_ error: Error) -> Error {
    if DownloadSpace.isFull(error) { return CocoaError(.fileWriteOutOfSpace) }
    switch error {
    case let failure as SourceFailure:
        let mapped = SourceReaderBridge.providerError(failure)
        return mapped.domain == NSCocoaErrorDomain || mapped.domain == NSFileProviderErrorDomain
            ? mapped : NSFileProviderError(.serverUnreachable)
    case let transfer as TransferError:
        switch transfer {
        case .cancelled: return CocoaError(.userCancelled)
        case .sourceChanged: return NSFileProviderError(.versionNoLongerAvailable)
        default: return CocoaError(.fileReadUnknown)
        }
    default:
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain {
            return NSError(domain: ns.domain, code: ns.code)
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return CocoaError(.fileReadNoPermission)
        }
        // A missing mount or path is not evidence that an item was deleted remotely.
        return NSFileProviderError(.serverUnreachable)
    }
}
