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

    func perform<T>(_ operation: () throws -> T) rethrows -> T { try lock.withLock(operation) }

    func requireSettled(excluding rename: UUID? = nil) throws {
        let pendingRenames = try LocationSource.renameOutbox().records().filter {
            $0.isPending && $0.id != rename && $0.views.contains { domains[$0.domain] != nil }
        }
        guard pendingRenames.isEmpty else { throw UploadError.pendingWrites }
        for domain in domains.keys {
            let outbox = try LocationSource.editOutbox(domainID: domain)
            let pending = try outbox.records().filter(\.isPending)
            guard try outbox.pendingCount == pending.count,
                  pending.allSatisfy({ [.preparing, .prepared].contains($0.state) }) else {
                throw UploadError.pendingWrites
            }
        }
    }

    func requireUncontested(path: RelativePath, excluding id: UUID) throws {
        for record in try LocationSource.renameOutbox().records() where record.isPending && record.id != id {
            guard !record.views.contains(where: { domains[$0.domain] != nil }) ||
                (NameKey(record.source) != NameKey(path.string) && NameKey(record.destination) != NameKey(path.string)) else {
                throw UploadError.pendingWrites
            }
        }
        for (domain, folder) in domains {
            for record in try LocationSource.editOutbox(domainID: domain).records()
                where record.id != id && record.mayHaveChangedOriginal {
                guard let relative = RelativePath(record.path), folder.appending(relative) != path else {
                    throw UploadError.pendingWrites
                }
            }
        }
    }
}
