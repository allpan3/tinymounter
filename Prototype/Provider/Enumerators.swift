import FileProvider
import OSLog

/// Folders, single files and the working set, all paged from the catalog (plan §5).
final class CatalogEnumerator: NSObject, NSFileProviderEnumerator {
    enum Target {
        case folder(String), item(String), workingSet
    }

    /// One primary-key lookup and no share I/O.
    static func make(for identifier: NSFileProviderItemIdentifier, catalog: CatalogReader,
                     reader: SourceReaderService, domain: NSFileProviderDomain) throws -> NSFileProviderEnumerator {
        switch identifier {
        case .workingSet:
            return CatalogEnumerator(.workingSet, catalog: catalog, reader: reader, domain: domain)
        case .trashContainer:
            return FixedEnumerator(failure: nil)
        default:
            guard let row = try catalog.read({ try $0.item(id: identifier.rawValue) }) else {
                return FixedEnumerator(failure: CocoaError(.fileReadUnknown))
            }
            guard !row.deleted else { throw NSFileProviderError(.noSuchItem) }
            return CatalogEnumerator(row.kind == .folder ? .folder(row.id) : .item(row.id), catalog: catalog,
                                     reader: reader, domain: domain)
        }
    }

    private let target: Target
    private let catalog: CatalogReader
    private let reader: SourceReaderService
    private let domain: NSFileProviderDomain
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")

    private init(_ target: Target, catalog: CatalogReader, reader: SourceReaderService, domain: NSFileProviderDomain) {
        self.target = target
        self.catalog = catalog
        self.reader = reader
        self.domain = domain
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let size = CatalogPage.size(suggested: observer.suggestedPageSize)
        let initial = [NSFileProviderPage.initialPageSortedByName as Data, NSFileProviderPage.initialPageSortedByDate as Data]
        let token = initial.contains(page.rawValue) ? nil : page.rawValue
        do {
            switch target {
            case .workingSet:
                serve(try catalog.read { try $0.workingSetPage(token: token, size: size) }, to: observer)
            case .item(let id):
                guard token == nil else { throw NSFileProviderError(.pageExpired) }
                observer.didEnumerate([CatalogItem(try catalog.liveRow(id))])
                observer.finishEnumerating(upTo: nil)
            case .folder(let id):
                if let token {
                    serve(try catalog.read { try $0.folderPage(id, token: token, size: size) }, to: observer)
                } else {
                    try firstPage(of: id, size: size, observer: observer)
                }
            }
        } catch {
            fail(error) { observer.finishEnumeratingWithError($0) }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let scope: ChangeScope
        switch target {
        case .folder(let id): scope = .parent(id)
        case .item(let id): scope = .item(id)
        case .workingSet: scope = .all
        }
        do {
            let batch = try catalog.read {
                try $0.changes(after: anchor.rawValue, limit: CatalogPage.size(suggested: observer.suggestedBatchSize),
                               scope: scope)
            }
            if !batch.updated.isEmpty { observer.didUpdate(batch.updated.map { CatalogItem($0) }) }
            if !batch.deletedIDs.isEmpty {
                observer.didDeleteItems(withIdentifiers: batch.deletedIDs.map { NSFileProviderItemIdentifier($0) })
            }
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(batch.anchor), moreComing: batch.moreComing)
        } catch {
            fail(error) { observer.finishEnumeratingWithError($0) }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler((try? catalog.read { try $0.currentAnchor() }).map { NSFileProviderSyncAnchor($0) })
    }

    private func firstPage(of folderID: String, size: Int, observer: NSFileProviderEnumerationObserver) throws {
        let folder = try catalog.liveRow(folderID)
        let action = FirstPage.action(listGen: folder.listGen, listedAt: folder.listedAt,
                                      readerConnected: reader.isConnected, now: Date())
        switch action {
        case .serve(let relist):
            // Differences from this listing reach the system through the working set.
            if relist { reader.list(folderID, requestID: UUID()) { _ in } }
            let page = try catalog.read { try $0.folderPage(folderID, token: nil, size: size) }
            Self.logger.info("""
                first_page folder=\(folderID, privacy: .public) action=serve relist=\(relist ? 1 : 0) \
                rows=\(page.rows.count)
                """)
            serve(page, to: observer)
        case .fail(let failure):
            Self.logger.info("first_page folder=\(folderID, privacy: .public) action=fail reader=0")
            throw failure
        case .listFirst:
            listFirst(folderID, size: size, observer: observer)
        }
    }

    private func listFirst(_ folderID: String, size: Int, observer: NSFileProviderEnumerationObserver) {
        let once = Once()
        let requestID = UUID()
        let started = ContinuousClock.now
        let log = { (outcome: String) in
            Self.logger.info("""
                first_page folder=\(folderID, privacy: .public) action=list_first \
                request=\(requestID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) \
                wait_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
                """)
        }
        reader.list(folderID, requestID: requestID) { [self] result in
            guard once.claim() else {
                log(result.isSuccess ? "late_listed" : "late_failed")
                // Resolving the error lifts throttling; Finder may still require Try Again.
                if result.isSuccess { resolveServerUnreachable() }
                return
            }
            log(result.isSuccess ? "listed" : "failed")
            switch result {
            case .success(let receipt): answer(folderID, .listed, receipt: receipt, size: size, observer: observer)
            case .failure(let error): answer(folderID, .failed(error), receipt: nil, size: size, observer: observer)
            }
        }
        let wait = DispatchTimeInterval.milliseconds(Int(FirstPage.listingWait / .milliseconds(1)))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { [self] in
            guard once.claim() else { return }
            log("deadline")
            answer(folderID, .deadline, receipt: nil, size: size, observer: observer)
        }
    }

    /// The reply follows the app's commit; a folder row behind it means this connection can't see it.
    private func answer(_ folderID: String, _ outcome: FirstPage.Outcome, receipt: ListReceipt?, size: Int,
                        observer: NSFileProviderEnumerationObserver) {
        do {
            if let error = FirstPage.afterListing(outcome) { throw error }
            let (folder, page) = try catalog.read { catalog in
                (try catalog.item(id: folderID), try catalog.folderPage(folderID, token: nil, size: size))
            }
            guard let receipt, let listed = folder?.listGen, listed >= receipt.generation else {
                Self.logger.error("""
                    first_page folder=\(folderID, privacy: .public) list_unseen=1 \
                    generation=\(receipt?.generation ?? -1) seen=\(folder?.listGen ?? -1)
                    """)
                throw NSFileProviderError(.serverUnreachable)
            }
            serve(page, to: observer)
        } catch {
            fail(error) { observer.finishEnumeratingWithError($0) }
        }
    }

    private func serve(_ page: CatalogPage, to observer: NSFileProviderEnumerationObserver) {
        if !page.rows.isEmpty { observer.didEnumerate(page.rows.map { CatalogItem($0) }) }
        observer.finishEnumerating(upTo: page.next.map { NSFileProviderPage($0) })
    }

    private func resolveServerUnreachable() {
        NSFileProviderManager(for: domain)?.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { error in
            guard let error = error as NSError? else { return }
            Self.logger.error("signal_resolved failed error_domain=\(error.domain, privacy: .public) code=\(error.code)")
        }
    }

    private func fail(_ error: Error, _ finish: (Error) -> Void) {
        let mapped = providerError(error) as NSError
        let label: String
        switch target {
        case .folder(let id): label = "folder=" + id
        case .item(let id): label = "item=" + id
        case .workingSet: label = "working_set=1"
        }
        Self.logger.error("""
            enumerate \(label, privacy: .public) failed error_domain=\(mapped.domain, privacy: .public) \
            code=\(mapped.code)
            """)
        finish(mapped)
    }
}

/// The trash, which stays empty, and unknown IDs, whose calls all fail with the same error.
final class FixedEnumerator: NSObject, NSFileProviderEnumerator {
    private let failure: Error?
    init(failure: Error?) { self.failure = failure }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if let failure { observer.finishEnumeratingWithError(failure) } else { observer.finishEnumerating(upTo: nil) }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if let failure {
            observer.finishEnumeratingWithError(failure)
        } else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(failure == nil ? NSFileProviderSyncAnchor(Data([0])) : nil)
    }
}

/// Lets the first of several racing answers through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
