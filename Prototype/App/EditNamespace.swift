import Foundation

/// Shared grants to one SMB source must observe a save transaction as one catalog change.
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
    // Native range reads run outside `lock`, so their lifetimes are tracked under a separate condition.
    private let reads = NSCondition()
    private var activeReads: [UUID: RelativePath] = [:]

    static func key(_ mountFrom: String) -> String {
        guard let address = ShareAddress(mountFrom) else { return mountFrom.lowercased() }
        return NameKey(address.host).value + "/" + NameKey(address.share).value
    }

    static func shared(_ mountFrom: String) -> EditNamespace {
        registryLock.withLock {
            let key = key(mountFrom)
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
                guard reads.wait(until: deadline) else { throw UploadError.pendingWrites }
            }
        }
    }
}
