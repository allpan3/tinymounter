import Foundation

// The caller serializes these decisions; Progress reads and KVO callbacks run outside its lock.
public struct DeletionCancellationState: Sendable {
    public enum Completion: Equatable, Sendable {
        case ready, waiting, stop([UUID])
    }

    public private(set) var isClosed = false
    private var requests: [UUID: UUID] = [:]
    private var stops: [UUID: Int] = [:]

    public init() {}

    public mutating func register(_ token: UUID, operation: UUID) { requests[token] = operation }
    public mutating func close() { isClosed = true }
    public func isStopping(_ operation: UUID) -> Bool { stops[operation] != nil }

    public mutating func requestStop(_ operation: UUID, cancellation token: UUID? = nil) -> Bool {
        if let token {
            guard !isClosed, requests[token] == operation else { return false }
            requests[token] = nil
        }
        stops[operation, default: 0] += 1
        return true
    }

    public mutating func finishedStop(_ operation: UUID) {
        let remaining = (stops[operation] ?? 1) - 1
        stops[operation] = remaining > 0 ? remaining : nil
    }

    public mutating func complete(_ operation: UUID, tokens: [UUID], cancelled: [UUID]) -> Completion {
        let pending = isClosed ? [] : cancelled.filter { requests[$0] == operation }
        if !pending.isEmpty { return .stop(pending) }
        if isStopping(operation) { return .waiting }
        for token in tokens { requests[token] = nil }
        return .ready
    }
}

/// Fresh, protected evidence for one request. The catalog cannot show that a remote tree is complete,
/// so every directory needs a complete listing and every listed entry needs its own evidence.
public struct DeletionTraversal: Sendable {
    public struct Object: Sendable {
        public let path: RelativePath
        public let evidence: ItemDeletionEvidence

        public init(path: RelativePath, evidence: ItemDeletionEvidence) {
            self.path = path
            self.evidence = evidence
        }
    }

    public struct Listing: Sendable {
        public let path: RelativePath
        public let listing: ItemDeletionListing

        public init(path: RelativePath, listing: ItemDeletionListing) {
            self.path = path
            self.listing = listing
        }
    }

    /// Paths are relative to the share root.
    public let selected: RelativePath
    /// The chain protectParents returned for the selected item.
    public let parents: [ItemDeletionParent]
    public let objects: [Object]
    public let listings: [Listing]

    public init(selected: RelativePath, parents: [ItemDeletionParent], objects: [Object], listings: [Listing]) {
        self.selected = selected
        self.parents = parents
        self.objects = objects
        self.listings = listings
    }

    /// Child-before-parent order, with siblings in byte order, ending with the selected item.
    func nodes(recursive: Bool, protectedRoots: [RelativePath]) throws -> [DeletionNode] {
        guard !selected.isRoot else { throw ItemDeletionError.invalidRequest }
        guard objects.count <= DeletionPlan.maxNodes else { throw SourceFailure.tooManyEntries }
        let key = selected.components.map(NameKey.init)
        guard !protectedRoots.contains(where: { root in
            root.components.count >= key.count && root.components.prefix(key.count).map(NameKey.init) == key
        }) else { throw ItemDeletionError.invalidRequest }
        var evidence: [Data: ItemDeletionEvidence] = [:], listed: [Data: ItemDeletionListing] = [:]
        for object in objects {
            guard evidence.updateValue(object.evidence, forKey: Data(object.path.string.utf8)) == nil else {
                throw ItemDeletionError.invalidRequest
            }
        }
        for listing in listings {
            guard listed.updateValue(listing.listing, forKey: Data(listing.path.string.utf8)) == nil else {
                throw ItemDeletionError.invalidRequest
            }
        }
        let root = Data(selected.string.utf8)
        if !recursive, case .directory? = evidence[root], let listing = listed[root],
           !(try listing.validatedEntries()).isEmpty { throw ItemDeletionError.directoryNotEmpty }
        var nodes: [DeletionNode] = [], used = 0
        func visit(_ path: RelativePath) throws {
            let key = Data(path.string.utf8)
            guard let found = evidence[key] else { throw ItemDeletionError.unresolved }
            if case .directory = found {
                guard let listing = listed[key] else { throw ItemDeletionError.unresolved }
                used += 1
                let entries = try listing.validatedEntries().sorted {
                    $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
                }
                for entry in entries {
                    // Recovery artifacts, databases and disk images are never deleted as a side effect.
                    guard FileRenameRequest.supportsName(entry.name), let child = path.appending(entry.name) else {
                        throw ItemDeletionError.unsupported
                    }
                    guard evidence[Data(child.string.utf8)]?.identity == entry.identity else {
                        throw ItemDeletionError.unresolved
                    }
                    try visit(child)
                }
            } else if listed[key] != nil {
                throw ItemDeletionError.invalidRequest
            }
            nodes.append(DeletionNode(path: path.string, evidence: found))
            guard nodes.count <= DeletionPlan.maxNodes else { throw SourceFailure.tooManyEntries }
        }
        try visit(selected)
        guard nodes.count == objects.count, used == listings.count else { throw ItemDeletionError.invalidRequest }
        // A second name for one object would be deleted through the first.
        guard Set(nodes.map { DeletionIdentityKey($0.evidence.identity) }).count == nodes.count else {
            throw ItemDeletionError.unsupported
        }
        return nodes
    }
}

/// Deletes an admitted tree one object at a time, child before parent, never adding a new child.
/// It is not atomic: each node finishes with its own outcome, and the operation reports them all.
public enum RecursiveDeletionTransaction {
    /// Serialize calls per namespace. `session` runs its body exactly once with a fresh DeletionRemote
    /// and ends that session whether the body returns or throws. A thrown error leaves the operation
    /// active for a later retry or stop; node outcomes never throw.
    public static func run(_ record: inout PendingDeletion, outbox: DeletionOutbox, endpoint: ShareAddress,
                           owner: String,
                           session: (_ body: (DeletionRemote) throws -> Void) throws -> Void) throws {
        record = try outbox.reload(record)
        guard record.plan.owner == owner, record.plan.endpoint.matches(endpoint) else {
            throw ItemDeletionError.invalidRequest
        }
        let plan = record.plan
        // Folders whose protected chain failed in this run; their remaining descendants would fail too.
        var broken: [String] = []
        while true {
            let durable = try outbox.durableProgress(of: plan)
            record.progress = durable
            if record.isSettled { return }
            let index = durable.next
            let directories = plan.directoryIdentities(updates: durable.parentUpdates ?? [])
            if durable.current == .prepared {
                let skipped = skips(from: index, plan: plan, progress: durable, broken: broken)
                if !skipped.isEmpty {
                    let next = durable.finishing(skipped)
                    try outbox.advance(plan, from: durable, to: next)
                    record.progress = next
                    continue
                }
            }
            let node = plan.nodes[index]
            var item = try plan.item(at: index, state: durable.current, directories: directories)
            var stored = durable, failure: Error?, proved = false
            do {
                try session { remote in
                    let observed = ObservedRemote(remote, identity: item.selected.identity)
                    do {
                        try ItemDeletionTransaction.remove(&item, remote: observed, load: {
                            let current = try outbox.durableProgress(of: plan)
                            guard current.next == index else { throw ItemDeletionError.invalidRequest }
                            stored = current
                            return try plan.item(at: index, state: current.current, directories: directories)
                        }, checkpoint: { next in
                            var updated = stored.recording(next.state)
                            if next.state == .deleted {
                                let parents = try observed.parentsAfterDeletion(next.parents)
                                guard parents.count == next.parents.count,
                                      zip(parents, next.parents).allSatisfy({ actual, expected in
                                          actual.path.utf8.elementsEqual(expected.path.utf8)
                                              && actual.name.utf8.elementsEqual(expected.name.utf8)
                                              && actual.identity.fileID == expected.identity.fileID
                                      }) else { throw ItemDeletionError.unresolved }
                                updated = updated.recordingParents(parents)
                            }
                            try outbox.advance(plan, from: stored, to: updated)
                            stored = updated
                            record.progress = updated
                        })
                    } catch {
                        failure = error
                        proved = observed.proved
                        throw error
                    }
                }
                guard stored.next > index else { throw ItemDeletionError.unresolved }
            } catch {
                guard let failure else { throw error }
                // Its checkpoint already finished the node as unconfirmed.
                if failure as? ItemDeletionError == .absentUnconfirmed, stored.next == index + 1 { continue }
                guard let outcome = outcome(for: failure, requested: item.state != .prepared, proved: proved) else {
                    throw failure
                }
                if failure as? ItemDeletionError == .parentChanged, index < plan.nodes.count - 1 {
                    broken.append(RelativePath(node.path)!.components.dropLast().joined(separator: "/"))
                }
                let next = stored.finishing([outcome])
                try outbox.advance(plan, from: stored, to: next)
                record.progress = next
            }
        }
    }

    /// Consecutive nodes that can finish without a session: below a broken chain, or a folder that
    /// still holds a descendant this request did not delete. A changed chain proves neither.
    private static func skips(from start: Int, plan: DeletionPlan, progress: DeletionProgress,
                              broken: [String]) -> [DeletionNodeOutcome] {
        var outcomes: [DeletionNodeOutcome] = []
        var remaining = progress.exceptions.filter { ![.unconfirmed, .parentChanged].contains($0.outcome) }
            .map { plan.nodes[$0.node].path }
        for node in plan.nodes[start...] {
            if broken.contains(where: { node.path.utf8.starts(with: ($0 + "/").utf8) }) {
                outcomes.append(.parentChanged)
            } else if case .directory = node.evidence,
                      remaining.contains(where: { $0.utf8.starts(with: (node.path + "/").utf8) }) {
                outcomes.append(.directoryNotEmpty)
                remaining.append(node.path)
            } else {
                break
            }
        }
        return outcomes
    }

    /// Nil leaves the node in flight. After a possible request, only proof that the admitted object
    /// is still present can show that it was not deleted.
    private static func outcome(for error: Error, requested: Bool, proved: Bool) -> DeletionNodeOutcome? {
        guard let error = error as? ItemDeletionError else { return nil }
        switch error {
        case .absentUnconfirmed: return .unconfirmed
        case .changed: return .changed
        case .moved: return .moved
        case .replaced: return requested ? .unconfirmed : .replaced
        case .parentChanged: return requested ? .unconfirmed : .parentChanged
        case .unsupported: return requested && !proved ? .unconfirmed : .unsupported
        case .sharingViolation: return requested && !proved ? .unconfirmed : .sharingViolation
        case .accessDenied: return requested && !proved ? .unconfirmed : .accessDenied
        case .cannotDelete: return requested && !proved ? .unconfirmed : .cannotDelete
        case .directoryNotEmpty: return requested && !proved ? .unconfirmed : .directoryNotEmpty
        case .deletePending, .pathNotFound, .unresolved, .invalidRequest, .busy, .stopped: return nil
        }
    }
}

/// Presence evidence expires when deletion is marked; a later refusal cannot prove survival.
private final class ObservedRemote: DeletionRemote {
    private let remote: DeletionRemote
    private let identity: EditFileIdentity
    private(set) var proved = false

    init(_ remote: DeletionRemote, identity: EditFileIdentity) {
        self.remote = remote
        self.identity = identity
    }

    func protectParents(of path: String) throws -> [ItemDeletionParent] { try remote.protectParents(of: path) }

    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
        proved = false
        let lookup = try remote.inspect(path: path, kind: kind)
        if case .present(let actual) = lookup, actual.identity == identity { proved = true }
        return lookup
    }

    func list(path: String) throws -> ItemDeletionListing { try remote.list(path: path) }

    func markDeletion(path: String) throws {
        try remote.markDeletion(path: path)
        proved = false
    }

    func closeTarget(path: String) throws { try remote.closeTarget(path: path) }
    func parentsAfterDeletion(_ parents: [ItemDeletionParent]) throws -> [ItemDeletionParent] {
        try remote.parentsAfterDeletion(parents)
    }
}
