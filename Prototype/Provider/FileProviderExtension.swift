import FileProvider
import OSLog

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderPartialContentFetching {
    private let domain: NSFileProviderDomain
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q
    }()
    private let lock = NSLock()
    private var active: [UUID: Progress] = [:]
    private var invalidated = false
    private let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "fetch")

    required init(domain: NSFileProviderDomain) { self.domain = domain; super.init() }

    func invalidate() {
        lock.lock(); invalidated = true; let current = Array(active.values); lock.unlock()
        current.forEach { $0.cancel() }
        // Do not cancel queued Operations: every queued callback still needs its completion.
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress()
        do {
            guard identifier == .rootContainer || identifier.rawValue == FixtureConfiguration.itemID else {
                throw NSFileProviderError(.noSuchItem)
            }
            let config = try FixtureConfiguration.load(domainID: domain.identifier.rawValue)
            completionHandler(FixtureItem(config: config, isRoot: identifier == .rootContainer), nil)
        } catch { completionHandler(nil, providerError(error)) }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard [.rootContainer, .workingSet, .trashContainer].contains(containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FixtureEnumerator(domainID: domain.identifier.rawValue, empty: containerItemIdentifier == .trashContainer)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        fetch(identifier: itemIdentifier, version: requestedVersion, range: nil, alignment: 1) { url, item, _, error in
            completionHandler(url, item, error)
        }
    }

    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        fetch(identifier: itemIdentifier, version: requestedVersion, range: minimalRange, alignment: alignment) { url, item, range, error in
            completionHandler(url, item, range, [], error)
        }
    }

    private func fetch(identifier: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, range requested: NSRange?,
                       alignment: Int, completion: @escaping (URL?, NSFileProviderItem?, NSRange, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        let requestID = UUID()
        lock.lock(); active[requestID] = progress; let cancelled = invalidated; lock.unlock()
        if cancelled { progress.cancel() }
        let queuedAt = DispatchTime.now().uptimeNanoseconds
        queue.addOperation { [self] in
            defer { lock.lock(); active.removeValue(forKey: requestID); lock.unlock() }
            let startedAt = DispatchTime.now().uptimeNanoseconds
            var staging: URL?
            do {
                guard !progress.isCancelled else { throw TransferError.cancelled }
                guard identifier.rawValue == FixtureConfiguration.itemID else { throw NSFileProviderError(.noSuchItem) }
                let config = try FixtureConfiguration.load(domainID: domain.identifier.rawValue)
                if let version, version.contentVersion != config.snapshot.versionData {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                let url = try config.resolveSource()
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                let source = try ReadOnlyFile(url: url)
                guard source.snapshot == config.snapshot else { throw TransferError.sourceChanged }
                let range: ByteRange
                if let minimum = requested, minimum.location != NSNotFound {
                    let required = try ByteRange(offset: Int64(minimum.location), length: Int64(minimum.length), fileSize: source.snapshot.size)
                    range = try ByteRange.aligned(minimum: required, alignment: Int64(alignment), fileSize: source.snapshot.size)
                } else {
                    range = try ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size)
                }
                guard let manager = NSFileProviderManager(for: domain) else { throw CocoaError(.fileReadUnknown) }
                let directory = try manager.temporaryDirectoryURL()
                let result = try Transfer.run(source: source, range: range, stagingDirectory: directory, progress: progress)
                staging = result.stagingURL
                guard !progress.isCancelled else { throw TransferError.cancelled }
                let mode = requested == nil ? "full" : "partial"
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
                let queueSeconds = Double(startedAt - queuedAt) / 1e9
                logger.info("request=\(requestID.uuidString, privacy: .public) mode=\(mode, privacy: .public) offset=\(range.offset) bytes=\(range.length) queue_seconds=\(queueSeconds) callback_seconds=\(elapsed) transfer_seconds=\(result.metrics.transferSeconds)")
                completion(staging, FixtureItem(config: config), NSRange(location: Int(range.offset), length: Int(range.length)), nil)
                // Ownership now belongs to File Provider; never modify or unlink after handoff.
                staging = nil
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                logger.error("request=\(requestID.uuidString, privacy: .public) failed code=\((error as NSError).code)")
                completion(nil, nil, NSRange(location: 0, length: 0), providerError(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission)); return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission)); return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(CocoaError(.fileWriteNoPermission)); return Progress()
    }
}
