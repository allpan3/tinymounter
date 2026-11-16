import Foundation

enum NamespaceDrainError: Error {
    case timedOut
}

/// Coordinates namespace changes across the locations on one share.
final class EditNamespace: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: EditNamespace] = [:]
    private let lock = NSRecursiveLock()
    private var domains: [String: RelativePath] = [:]
    private final class Source {
        weak var value: LocationSource?
        init(_ value: LocationSource) { self.value = value }
    }
    private var sources: [String: Source] = [:]
    private var reservations: [UUID: [RelativePath]] = [:]
    /// A folder of one location to list again.
    private struct Relist: Hashable {
        let domain: String
        let folder: String
    }
    /// Saves and uploads that are writing a server file, with the folders that listings and change
    /// notices skipped meanwhile. Its own lock: a notice never waits for a listing that holds `lock`.
    private let writesLock = NSLock()
    private var writes: [UUID: (path: RelativePath, relist: Set<Relist>)] = [:]
    // Payload transfers run outside `lock`; folder moves must wait for their handles to close.
    private let reads = NSCondition()
    private var activeReads: [UUID: RelativePath] = [:]

    /// The same host and share through any account.
    static func key(_ address: ShareAddress) -> String {
        address.remoteProtocol.rawValue + "://" + NameKey(address.host).value + "/" + NameKey(address.share).value
    }

    static func shared(_ address: ShareAddress) -> EditNamespace {
        registryLock.withLock {
            let key = key(address)
            if let existing = registry[key] { return existing }
            let result = EditNamespace()
            registry[key] = result
            return result
        }
    }

    func register(domain: String, folder: RelativePath) {
        lock.withLock { domains[domain] = folder }
    }

    func register(_ source: LocationSource) {
        lock.withLock {
            domains[source.domainID] = source.folder
            sources[source.domainID] = Source(source)
        }
    }

    func unregister(_ domain: String) {
        lock.withLock {
            sources[domain] = nil
            domains[domain] = nil
        }
    }

    func detach(_ domain: String) { lock.withLock { sources[domain] = nil } }

    func source(_ domain: String) throws -> LocationSource {
        guard let source = sources[domain]?.value else { throw LocationError.catalogClosed }
        return source
    }

    func affectedSources(path: RelativePath) throws -> [LocationSource] {
        try domains.sorted { $0.key < $1.key }.compactMap { domain, folder in
            guard path.components.count > folder.components.count,
                  path.components.prefix(folder.components.count).map(NameKey.init) == folder.components.map(NameKey.init)
            else { return nil }
            return try source(domain)
        }
    }

    func affectedSources(source: RelativePath, destination: RelativePath) throws -> [LocationSource] {
        let old = try affectedSources(path: source), new = try affectedSources(path: destination)
        guard old.map(\.domainID) == new.map(\.domainID) else { throw UploadError.readOnly }
        return old
    }

    func perform<T>(_ operation: () throws -> T) rethrows -> T { try lock.withLock(operation) }

    func readForStatus<T>(_ read: () throws -> T) rethrows -> T { try lock.readForStatus(read) }

    /// Every configured location root in this namespace, including locations without an open source.
    func locationRoots() -> [RelativePath] { lock.withLock { Array(domains.values) } }

    static func contains(_ ancestor: RelativePath, _ path: RelativePath) -> Bool {
        path.components.count >= ancestor.components.count
            && path.components.prefix(ancestor.components.count).map(NameKey.init) == ancestor.components.map(NameKey.init)
    }

    /// An unsettled rename or deletion here blocks listing and writes, except the one named by `id`.
    func requireSettled(excluding id: UUID? = nil, deletionBusyError: Error = UploadError.pendingWrites) throws {
        let pendingRenames = try LocationSource.renameOutbox().intents().filter {
            $0.isPending && $0.id != id && $0.domains.contains { domains[$0] != nil }
        }
        guard pendingRenames.isEmpty else { throw UploadError.pendingWrites }
        guard try blockingDeletions(excluding: id).isEmpty else { throw deletionBusyError }
    }

    func requireUncontested(path: RelativePath, excluding id: UUID) throws {
        guard !isReserved(path) else { throw UploadError.pendingWrites }
        for record in try blockingDeletions(excluding: id) {
            guard let selected = RelativePath(record.plan.selected.path), !Self.contains(selected, path) else {
                throw UploadError.pendingWrites
            }
        }
        for intent in try LocationSource.renameOutbox().intents() where intent.isPending && intent.id != id {
            guard intent.domains.contains(where: { domains[$0] != nil }) else { continue }
            switch intent {
            case .file(let record):
                guard NameKey(record.source) != NameKey(path.string),
                      NameKey(record.destination) != NameKey(path.string) else { throw UploadError.pendingWrites }
            case .folder(let record):
                guard let source = RelativePath(record.source), let destination = RelativePath(record.destination),
                      !Self.contains(source, path), !Self.contains(destination, path) else {
                    throw UploadError.pendingWrites
                }
            }
        }
    }

    /// Deletions whose views are not all settled; an unreadable inventory throws, so it blocks writes.
    private func blockingDeletions(excluding id: UUID?) throws -> [PendingDeletion] {
        try LocationSource.deletionOutbox().records().filter {
            $0.blocksWrites && $0.id != id && $0.plan.domains.contains { domains[$0] != nil }
        }
    }

    // A folder move reserves both endpoints before draining, so no new read or watch starts below them.
    func reserve(_ id: UUID, paths: [RelativePath]) { lock.withLock { reservations[id] = paths } }

    func release(_ id: UUID) { lock.withLock { reservations[id] = nil } }

    func isReserved(_ path: RelativePath) -> Bool {
        lock.withLock { reservations.values.contains { $0.contains { Self.contains($0, path) } } }
    }

    /// Call inside `perform` before the server file changes. A listing beside the lane keeps the
    /// file's row as it is until `endWrite`, so it never takes a half-written file for a change.
    func beginWrite(_ path: RelativePath) -> UUID {
        writesLock.withLock {
            let id = UUID()
            writes[id] = (path, [])
            return id
        }
    }

    /// Call inside `perform`, with the catalog update that records the write's result. Returns the
    /// folders that listings and change notices skipped while it ran, to list again.
    func endWrite(_ id: UUID) -> [(source: LocationSource, folder: String)] {
        lock.withLock {
            let relist = writesLock.withLock { writes.removeValue(forKey: id)?.relist ?? [] }
            return relist.compactMap { relist in sources[relist.domain]?.value.map { ($0, relist.folder) } }
        }
    }

    /// True while an upload or save writes the file at `path`.
    func isWriting(_ path: RelativePath) -> Bool {
        writesLock.withLock { writes.values.contains { $0.path.components.count == path.components.count
            && Self.contains($0.path, path) } }
    }

    /// Call inside `perform`: the name keys of the files in the folder at `path` that this Mac is
    /// writing. The listing of `folder` in `source` is repeated when each of those writes ends.
    func writing(in path: RelativePath, source: LocationSource, folder: String) -> Set<String> {
        writesLock.withLock {
            var keys: Set<String> = []
            for (id, write) in writes where write.path.components.count == path.components.count + 1
                && Self.contains(path, write.path) {
                guard let name = write.path.components.last else { continue }
                keys.insert(NameKey(name).value)
                writes[id]?.relist.insert(Relist(domain: source.domainID, folder: folder))
            }
            return keys
        }
    }

    /// A change notice of the watched folder at `folder` that names `names`: true when this Mac is
    /// writing each named file. The notice then needs no listing now; those writes list `routes`
    /// when they end.
    func deferNotice(folder: RelativePath, names: [String],
                     routes: [(domainID: String, folderIDs: [String])]) -> Bool {
        writesLock.withLock {
            guard !names.isEmpty else { return false }
            var covering: Set<UUID> = []
            for name in names {
                guard let path = RelativePath(name).flatMap({ folder.appending($0) }),
                      let id = writes.first(where: { $0.value.path.components.count == path.components.count
                          && Self.contains($0.value.path, path) })?.key else { return false }
                covering.insert(id)
            }
            let relist = routes.flatMap { route in route.folderIDs.map { Relist(domain: route.domainID, folder: $0) } }
            for id in covering { writes[id]?.relist.formUnion(relist) }
            return true
        }
    }

    /// Call inside `perform`; end it with `endRead` only after the descriptor has closed.
    func beginRead(_ path: RelativePath) throws -> UUID {
        guard !isReserved(path) else { throw UploadError.pendingWrites }
        let id = UUID()
        reads.withLock { activeReads[id] = path }
        return id
    }

    func endRead(_ id: UUID) {
        reads.withLock {
            activeReads[id] = nil
            reads.broadcast()
        }
    }

    /// Waits without the namespace lock: a running transfer can still need it to record a change.
    func drainReads(below paths: [RelativePath], timeout: Duration = .seconds(10)) throws {
        let deadline = Date.now.addingTimeInterval(Double(timeout.components.seconds))
        try reads.withLock {
            while activeReads.values.contains(where: { path in paths.contains { Self.contains($0, path) } }) {
                guard reads.wait(until: deadline) else { throw NamespaceDrainError.timedOut }
            }
        }
    }
}
