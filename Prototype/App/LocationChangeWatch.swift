import Foundation
import OSLog

/// Change watching for the locations on one share: one watcher of at most 64 discovery folders,
/// its reconnection with backoff, and the listings that each notice asks for.
/// Not wired yet: step 3's `ShareConnection` creates it (docs/connection-layer-plan.md, step 4).
final class LocationChangeWatch: @unchecked Sendable {
    /// Signs in and opens a watcher; nil when the server can't watch.
    typealias Open = @Sendable (_ notice: @escaping @Sendable (ChangeNotice) -> Void) throws -> (any RemoteWatcher)?
    /// Folders of one location to list again; nil for every folder that it watches.
    typealias Refresh = @Sendable (_ domainID: String, _ folderIDs: [String]?) -> Void

    private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "watch")
    private let open: Open
    private let limit: Int
    private let refresh: Refresh
    private let excluded: @Sendable (RelativePath) -> Bool
    private let queue = DispatchQueue(label: "dev.tinymounter.change-watch", qos: .utility)
    // Only on `queue`.
    private var plan = ChangeWatchPlan()
    private var watcher: (any RemoteWatcher)?
    private var generation = 0
    private var retry = WatchRetry()
    private var retryWork: DispatchWorkItem?
    /// A refused sign-in: no further attempt until `reconnect()`.
    private var parked = false
    private var unsupported = false
    private var relistOnOpen = false
    private var cancelled = false

    /// `excluded` keeps watches off folders that a move or deletion reserves.
    init(limit: Int, open: @escaping Open, excluded: @escaping @Sendable (RelativePath) -> Bool,
         refresh: @escaping Refresh) {
        self.limit = limit
        self.open = open
        self.excluded = excluded
        self.refresh = refresh
    }

    /// `root` is the location folder from the share root; folder paths are below it.
    func setFolders(_ folders: [WatchedFolder], domainID: String, root: RelativePath) {
        queue.async { [self] in
            plan.setFolders(folders, domainID: domainID, root: root)
            apply()
        }
    }

    func removeLocation(_ domainID: String) {
        queue.async { [self] in
            plan.removeLocation(domainID)
            apply()
        }
    }

    /// Closes every watch at or below `paths` and waits until the server has closed them, so that
    /// a move or deletion meets no watch handle. Reserve the paths first: `excluded` then keeps
    /// them unwatched until the next `setFolders` after the reservation ends.
    func drain(below paths: [RelativePath]) {
        queue.sync { apply(drained: paths) }
    }

    /// A new password, a recovered connection or a wake: open a watcher now if none is open.
    func reconnect() {
        queue.async { [self] in
            parked = false
            unsupported = false
            retry.reset()
            retryWork?.cancel()
            retryWork = nil
            apply()
        }
    }

    func cancel() {
        queue.sync {
            cancelled = true
            retryWork?.cancel()
            retryWork = nil
            watcher?.cancel()
            watcher = nil
        }
    }

    private static var now: Duration { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }

    private func apply(drained: [RelativePath] = []) {
        guard !cancelled else { return }
        let paths = plan.paths(limit: limit) { [excluded] path in
            excluded(path) || drained.contains { Self.contains($0, path) }
        }
        if let watcher {
            watcher.watch(paths)
        } else if !paths.isEmpty, retryWork == nil, !parked, !unsupported {
            connect(paths)
        }
        if paths.isEmpty, plan.isEmpty, let watcher {
            watcher.cancel()
            self.watcher = nil
        }
    }

    private func connect(_ paths: Set<RelativePath>) {
        generation += 1
        let generation = generation
        do {
            guard let opened = try open({ [weak self] notice in self?.received(notice, generation: generation) }) else {
                unsupported = true
                Self.log.info("watch_unsupported")
                return
            }
            watcher = opened
            retry.opened(now: Self.now)
            opened.watch(paths)
            // Changes made while no watcher was open are lost; list every watched folder once.
            if relistOnOpen {
                relistOnOpen = false
                for domainID in plan.domainIDs { refresh(domainID, nil) }
            }
        } catch {
            let failure = SourceFailure.classify(error, context: .listing)
            if failure == .notAuthenticated || failure == .noPermission {
                parked = true
                Self.log.error("watch_parked \(logFields(failure), privacy: .public)")
            } else {
                scheduleRetry()
            }
        }
    }

    private func received(_ notice: ChangeNotice, generation: Int) {
        queue.async { [self] in
            guard generation == self.generation, !cancelled else { return }
            if case .ended = notice {
                watcher?.cancel()
                watcher = nil
                relistOnOpen = true
                scheduleRetry()
                return
            }
            for route in plan.routes(for: notice) { refresh(route.domainID, route.folderIDs) }
        }
    }

    private func scheduleRetry() {
        let delay = retry.nextDelay(now: Self.now)
        Self.log.info("watch_retry seconds=\(delay.components.seconds)")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            retryWork = nil
            apply()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + Double(delay.components.seconds), execute: work)
    }

    /// As `EditNamespace.contains`: the server compares names without case.
    private static func contains(_ ancestor: RelativePath, _ path: RelativePath) -> Bool {
        path.components.count >= ancestor.components.count
            && path.components.prefix(ancestor.components.count).map(NameKey.init) == ancestor.components.map(NameKey.init)
    }
}
