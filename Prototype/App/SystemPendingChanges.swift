import FileProvider
import Foundation

struct SystemPendingChange: Identifiable, Sendable {
    let change: PendingChange
    let error: NSError?
    var id: String { change.id }
}

struct SystemPendingChanges: Sendable {
    var items: [SystemPendingChange] = []
    var incomplete = false
}

final class SystemPendingObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    struct Item: Sendable {
        let id: String
        let name: String
        let parent: String
        let trashed: Bool
        let error: NSError?
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var waiting: CheckedContinuation<NSFileProviderPage?, Error>?

    static func read(_ manager: NSFileProviderManager) async throws -> (items: [Item], incomplete: Bool) {
        let enumerator = manager.enumeratorForPendingItems()
        defer { enumerator.invalidate() }
        let observer = SystemPendingObserver()
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        var pages = 0
        while let current = page, pages < 1024 {
            try Task.checkCancellation()
            pages += 1
            page = try await observer.next(enumerator, page: current)
        }
        return (observer.lock.withLock { observer.items },
                page != nil || enumerator.isMaximumSizeReached || enumerator.domainVersion == nil)
    }

    private func next(_ enumerator: NSFileProviderEnumerator, page: NSFileProviderPage) async throws
        -> NSFileProviderPage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ updated: [NSFileProviderItem]) {
        let found = updated.map {
            Item(id: $0.itemIdentifier.rawValue, name: $0.filename,
                 parent: $0.parentItemIdentifier.rawValue, trashed: $0.parentItemIdentifier == .trashContainer,
                 error: ($0.uploadingError ?? nil).map { $0 as NSError })
        }
        lock.withLock { items += found }
    }

    func finishEnumerating(upTo page: NSFileProviderPage?) { take()?.resume(returning: page) }
    func finishEnumeratingWithError(_ error: Error) { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<NSFileProviderPage?, Error>? {
        lock.withLock { defer { waiting = nil }; return waiting }
    }
}
