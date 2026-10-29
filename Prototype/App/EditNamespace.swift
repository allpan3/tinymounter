import Foundation

/// Shared grants to one SMB source must observe a save transaction as one catalog change.
final class EditNamespace: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: EditNamespace] = [:]
    private let lock = NSRecursiveLock()
    private var domains: [String: RelativePath] = [:]

    static func shared(_ mountFrom: String) -> EditNamespace {
        registryLock.withLock {
            let key = mountFrom.lowercased()
            if let existing = registry[key] { return existing }
            let result = EditNamespace()
            registry[key] = result
            return result
        }
    }

    func register(domain: String, folder: RelativePath) {
        lock.withLock { domains[domain] = folder }
    }

    func perform<T>(_ operation: () throws -> T) rethrows -> T { try lock.withLock(operation) }

    func requireSettled() throws {
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
