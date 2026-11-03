import Darwin
import Foundation

/// The connection that admitted a deletion; server identities mean nothing on another share.
public struct DeletionEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let account: String
    public let share: String

    public init(_ address: ShareAddress) {
        host = address.host
        account = address.account
        share = address.share
    }

    public func matches(_ address: ShareAddress) -> Bool {
        NameKey(host) == NameKey(address.host) && NameKey(account) == NameKey(address.account)
            && NameKey(share) == NameKey(address.share)
    }

    func validate() throws {
        guard !host.isEmpty, !account.isEmpty, RelativePath.isValidComponent(share) else {
            throw ItemDeletionError.invalidRequest
        }
    }
}

/// The provider request that admitted an operation; a repeated callback replays it.
public struct DeletionRequest: Codable, Equatable, Sendable {
    public let item: String
    public let contentVersion: String
    public let metadataVersion: String
    public let eventVersion: Data

    public init(item: String, contentVersion: String, metadataVersion: String, eventVersion: Data) {
        self.item = item
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.eventVersion = eventVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(item: try values.decode(String.self, forKey: .item),
                  contentVersion: try values.decode(String.self, forKey: .contentVersion),
                  metadataVersion: try values.decode(String.self, forKey: .metadataVersion),
                  eventVersion: try values.decode(Data.self, forKey: .eventVersion))
        try validate()
    }

    func validate() throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID, Self.isVersion(contentVersion),
              metadataVersion.utf8.count <= 20, Int64(metadataVersion).map({ $0 >= 0 }) == true,
              !eventVersion.isEmpty, eventVersion.count <= Catalog.maxProviderDomainVersionBytes else {
            throw ItemDeletionError.invalidRequest
        }
    }

    static func isVersion(_ version: String) -> Bool { !version.isEmpty && version.utf8.count <= 128 }
}

public struct DeletionViewItem: Codable, Equatable, Sendable {
    public let item: String
    /// Relative to the view's folder.
    public let path: String
    public let contentVersion: String

    public init(item: String, path: RelativePath, contentVersion: String) {
        self.item = item
        self.path = path.string
        self.contentVersion = contentVersion
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.contentVersion == rhs.contentVersion
    }
}

/// Immutable catalog state captured with the admitted view, before any remote deletion.
public struct DeletionCatalogAdmission: Codable, Equatable, Sendable {
    public let epoch: Data
    public let sequence: Int64
    public let listingGeneration: Int64

    func validate() throws {
        guard epoch.count == 16, sequence >= 0, sequence <= Catalog.maxLastSeq, listingGeneration >= 0 else {
            throw ItemDeletionError.invalidRequest
        }
    }
}

/// One location that shows the target; each catalog applies the settled result separately.
public struct DeletionView: Codable, Equatable, Sendable {
    public let domain: String
    public let folder: String
    /// Catalog rows at admission. A node this location never listed has no row to change.
    public let items: [DeletionViewItem]
    /// Missing in older isolated records: settlement must obtain fresh listing evidence.
    public let catalogAdmission: DeletionCatalogAdmission?

    public init(domain: String, folder: RelativePath, items: [DeletionViewItem],
                catalogAdmission: DeletionCatalogAdmission? = nil) {
        self.domain = domain
        self.folder = folder.string
        self.items = items
        self.catalogAdmission = catalogAdmission
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.domain == rhs.domain && lhs.folder.utf8.elementsEqual(rhs.folder.utf8) && lhs.items == rhs.items
            && lhs.catalogAdmission == rhs.catalogAdmission
    }
}

public struct DeletionNode: Codable, Equatable, Sendable {
    /// Relative to the share root, like every DeletionRemote path.
    public let path: String
    public let evidence: ItemDeletionEvidence

    init(path: String, evidence: ItemDeletionEvidence) {
        self.path = path
        self.evidence = evidence
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.evidence == rhs.evidence
    }
}

/// Every case except `deleted` and `unconfirmed` means this request did not delete the node.
public enum DeletionNodeOutcome: String, Codable, Sendable {
    case deleted
    /// A request may have removed the object, but neither its deletion nor its survival is proven.
    case unconfirmed
    case changed, replaced, moved, parentChanged, unsupported
    case sharingViolation, accessDenied, cannotDelete, directoryNotEmpty
    /// The user stopped the operation before this node was attempted.
    case stopped
}

/// Admission evidence, written once. Nodes are child-before-parent and end with the selected item.
public struct DeletionPlan: Codable, Equatable, Sendable {
    /// Every checkpoint rewrites the exception list, and admission digests every file.
    public static let maxNodes = 10_000

    public let id: UUID
    public let endpoint: DeletionEndpoint
    public let owner: String
    public let request: DeletionRequest
    /// The chain from the share root to the selected item's parent, as protected at admission.
    public let parents: [ItemDeletionParent]
    public let nodes: [DeletionNode]
    public let views: [DeletionView]

    public var selected: DeletionNode { nodes[nodes.count - 1] }
    var domains: [String] { views.map(\.domain) }

    init(id: UUID, endpoint: DeletionEndpoint, owner: String, request: DeletionRequest,
         parents: [ItemDeletionParent], nodes: [DeletionNode], views: [DeletionView]) throws {
        self.id = id
        self.endpoint = endpoint
        self.owner = owner
        self.request = request
        self.parents = parents
        self.nodes = nodes
        self.views = views
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      endpoint: values.decode(DeletionEndpoint.self, forKey: .endpoint),
                      owner: values.decode(String.self, forKey: .owner),
                      request: values.decode(DeletionRequest.self, forKey: .request),
                      parents: values.decode([ItemDeletionParent].self, forKey: .parents),
                      nodes: values.decode([DeletionNode].self, forKey: .nodes),
                      views: values.decode([DeletionView].self, forKey: .views))
    }

    func validate() throws {
        guard UUID(uuidString: owner)?.uuidString == owner, !nodes.isEmpty, nodes.count <= Self.maxNodes,
              !views.isEmpty, Set(domains).count == views.count, domains.contains(owner),
              let root = RelativePath(selected.path), !root.isRoot, parents.count == root.components.count else {
            throw ItemDeletionError.invalidRequest
        }
        try endpoint.validate()
        try request.validate()
        let below = Array((selected.path + "/").utf8)
        var indices: [Data: Int] = [:], keys = Set<[NameKey]>(), identities = Set<DeletionIdentityKey>()
        for (index, node) in nodes.enumerated() {
            guard let path = RelativePath(node.path), index == nodes.count - 1 || node.path.utf8.starts(with: below),
                  indices.updateValue(index, forKey: SMBName.key(node.path)) == nil,
                  keys.insert(path.components.map(NameKey.init)).inserted,
                  identities.insert(DeletionIdentityKey(node.evidence.identity)).inserted else {
                throw ItemDeletionError.invalidRequest
            }
        }
        for (index, node) in nodes.enumerated().dropLast() {
            let parent = RelativePath(node.path)!.components.dropLast().joined(separator: "/")
            guard let container = indices[SMBName.key(parent)], container > index,
                  case .directory = nodes[container].evidence else { throw ItemDeletionError.invalidRequest }
        }
        let directories = directoryIdentities()
        for index in nodes.indices { _ = try item(at: index, state: .prepared, directories: directories) }
        for view in views {
            try view.catalogAdmission?.validate()
            guard UUID(uuidString: view.domain)?.uuidString == view.domain, let folder = RelativePath(view.folder),
                  root.components.count > folder.components.count,
                  root.components.prefix(folder.components.count).map(NameKey.init) == folder.components.map(NameKey.init),
                  Set(view.items.map(\.item)).count == view.items.count else { throw ItemDeletionError.invalidRequest }
            var mapped = Set<Int>()
            for item in view.items {
                guard ReaderMessage.isItemID(item.item), item.item != Catalog.rootItemID,
                      DeletionRequest.isVersion(item.contentVersion),
                      let relative = RelativePath(item.path), !relative.isRoot,
                      let path = folder.appending(relative), let node = indices[SMBName.key(path.string)],
                      mapped.insert(node).inserted else { throw ItemDeletionError.invalidRequest }
                if view.domain == owner, node == nodes.count - 1 {
                    guard item.item == request.item, item.contentVersion == request.contentVersion else {
                        throw ItemDeletionError.invalidRequest
                    }
                }
            }
            if view.domain == owner, !mapped.contains(nodes.count - 1) { throw ItemDeletionError.invalidRequest }
        }
    }

    func directoryIdentities(updates: [ItemDeletionParent] = []) -> [Data: EditFileIdentity] {
        var result: [Data: EditFileIdentity] = [:]
        for parent in parents { result[Data(parent.path.utf8)] = parent.identity }
        for node in nodes {
            if case .directory(let identity) = node.evidence { result[Data(node.path.utf8)] = identity }
        }
        for parent in updates { result[Data(parent.path.utf8)] = parent.identity }
        return result
    }

    /// The node as a one-object request; its chain adds the admitted tree folders above it.
    func item(at index: Int, state: PendingItemDeletion.State,
              directories: [Data: EditFileIdentity]) throws -> PendingItemDeletion {
        let node = nodes[index]
        guard let path = RelativePath(node.path), path.components.count >= parents.count else {
            throw ItemDeletionError.invalidRequest
        }
        let components = path.components
        var chain = try parents.map { parent in
            guard let identity = directories[Data(parent.path.utf8)] else { throw ItemDeletionError.invalidRequest }
            return ItemDeletionParent(path: parent.path, name: parent.name, identity: identity)
        }
        for depth in parents.count..<components.count {
            let prefix = components.prefix(depth).joined(separator: "/")
            guard let identity = directories[Data(prefix.utf8)] else { throw ItemDeletionError.invalidRequest }
            chain.append(ItemDeletionParent(path: prefix, name: components[depth - 1], identity: identity))
        }
        let evidence: ItemDeletionEvidence
        if case .directory = node.evidence, let identity = directories[Data(node.path.utf8)] {
            evidence = .directory(identity)
        } else {
            evidence = node.evidence
        }
        return try PendingItemDeletion(id: id, path: path, selected: evidence, parents: chain, state: state)
    }
}

struct DeletionIdentityKey: Hashable {
    let fileID: UInt64
    let birthMicroseconds: UInt64

    init(_ identity: EditFileIdentity) {
        fileID = identity.fileID
        birthMicroseconds = identity.birthMicroseconds
    }
}

public struct DeletionProgress: Codable, Equatable, Sendable {
    public struct Exception: Codable, Equatable, Sendable {
        public let node: Int
        public let outcome: DeletionNodeOutcome
    }

    /// Nodes before `next` are finished; those without an exception were deleted.
    public internal(set) var next = 0
    /// The one-object state of `nodes[next]`; terminal states finish the node in the same write.
    public internal(set) var current = PendingItemDeletion.State.prepared
    public internal(set) var exceptions: [Exception] = []
    /// The user stopped here; no node from this index was attempted.
    public internal(set) var stopped: Int?
    public internal(set) var finishedDomains: [String] = []
    public internal(set) var dismissed = false
    /// Present after a confirmed child deletion checkpoints its still-protected parent identities.
    public internal(set) var parentUpdates: [ItemDeletionParent]?

    func validate(for plan: DeletionPlan) throws {
        let count = plan.nodes.count, end = stopped ?? next
        let domains = Set(plan.domains), finished = Set(finishedDomains)
        guard next >= 0, next <= count, next < count || current == .prepared,
              [.prepared, .attempting, .closeAcknowledged].contains(current),
              stopped.map({ $0 >= 0 && $0 <= count && next == count }) ?? true,
              zip(exceptions, exceptions.dropFirst()).allSatisfy({ $0.node < $1.node }),
              exceptions.allSatisfy({ $0.node >= 0 && $0.node < end && ![.deleted, .stopped].contains($0.outcome) }),
              finished.count == finishedDomains.count, finished.isSubset(of: domains),
              finishedDomains.isEmpty || next == count,
              !dismissed || (finished == domains && (!exceptions.isEmpty || stopped != nil)) else {
            throw ItemDeletionError.invalidRequest
        }
        let originals = plan.directoryIdentities(), updates = parentUpdates ?? []
        guard updates.count <= originals.count,
              Set(updates.map { Data($0.path.utf8) }).count == updates.count,
              updates.allSatisfy({ parent in
                  let name = plan.parents.first { $0.path.utf8.elementsEqual(parent.path.utf8) }?.name
                      ?? RelativePath(parent.path)?.components.last ?? ""
                  return originals[Data(parent.path.utf8)]?.fileID == parent.identity.fileID
                      && parent.name.utf8.elementsEqual(name.utf8)
              }) else { throw ItemDeletionError.invalidRequest }
    }

    func validateUpdate(from previous: Self, plan: DeletionPlan) throws {
        guard exceptions.starts(with: previous.exceptions), next >= previous.next,
              next == previous.next || current == .prepared,
              finishedDomains.starts(with: previous.finishedDomains), !previous.dismissed || dismissed,
              previous.stopped == nil || previous.stopped == stopped else { throw ItemDeletionError.invalidRequest }
        let added = Array(exceptions.dropFirst(previous.exceptions.count))
        if parentUpdates != previous.parentUpdates {
            guard previous.next < plan.nodes.count, next == previous.next + 1, previous.current == .closeAcknowledged,
                  added.isEmpty, stopped == nil else { throw ItemDeletionError.invalidRequest }
            let directories = plan.directoryIdentities(updates: previous.parentUpdates ?? [])
            let item = try plan.item(at: previous.next, state: previous.current, directories: directories)
            let allowed = Set(item.parents.map { Data($0.path.utf8) })
            let updated = Dictionary(uniqueKeysWithValues: (parentUpdates ?? []).map { (Data($0.path.utf8), $0) })
            let old = Dictionary(uniqueKeysWithValues: (previous.parentUpdates ?? []).map { (Data($0.path.utf8), $0) })
            guard old.allSatisfy({ updated[$0.key] != nil }),
                  updated.allSatisfy({ allowed.contains($0.key) || old[$0.key] == $0.value }) else {
                throw ItemDeletionError.invalidRequest
            }
        }
        if previous.next == plan.nodes.count {
            guard next == previous.next, added.isEmpty, stopped == previous.stopped else {
                throw ItemDeletionError.invalidRequest
            }
            return
        }
        guard finishedDomains.isEmpty, !dismissed else { throw ItemDeletionError.invalidRequest }
        if let stopped {
            // A request may already be on the wire for the node in flight.
            let inFlight = previous.current != .prepared
            guard previous.stopped == nil, next == plan.nodes.count, stopped == previous.next + (inFlight ? 1 : 0),
                  added == (inFlight ? [Exception(node: previous.next, outcome: .unconfirmed)] : []) else {
                throw ItemDeletionError.invalidRequest
            }
        } else if next == previous.next {
            let allowed: [PendingItemDeletion.State: Set<PendingItemDeletion.State>] = [
                .prepared: [.prepared, .attempting], .attempting: [.attempting, .closeAcknowledged],
                .closeAcknowledged: [.closeAcknowledged]
            ]
            guard added.isEmpty, allowed[previous.current]?.contains(current) == true else {
                throw ItemDeletionError.invalidRequest
            }
        } else if added.count == next - previous.next {
            // Only the node in flight can have sent a request, so only it can be unconfirmed.
            guard added.map(\.node) == Array(previous.next..<next),
                  added.dropFirst().allSatisfy({ $0.outcome != .unconfirmed }) else {
                throw ItemDeletionError.invalidRequest
            }
        } else {
            // Deletion is confirmed only after a durably acknowledged close.
            guard next == previous.next + 1, added.isEmpty, previous.current == .closeAcknowledged else {
                throw ItemDeletionError.invalidRequest
            }
        }
    }

    func recording(_ state: PendingItemDeletion.State) -> Self {
        var result = self
        switch state {
        case .prepared, .attempting, .closeAcknowledged:
            result.current = state
            return result
        case .absentUnconfirmed:
            result.exceptions.append(Exception(node: next, outcome: .unconfirmed))
        case .deleted:
            break
        }
        result.next += 1
        result.current = .prepared
        return result
    }

    func recordingParents(_ parents: [ItemDeletionParent]) -> Self {
        var result = self
        var updated = Dictionary(uniqueKeysWithValues: (parentUpdates ?? []).map { (Data($0.path.utf8), $0) })
        for parent in parents { updated[Data(parent.path.utf8)] = parent }
        result.parentUpdates = updated.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return result
    }

    func finishing(_ outcomes: [DeletionNodeOutcome]) -> Self {
        var result = self
        result.exceptions += outcomes.enumerated().map { Exception(node: next + $0, outcome: $1) }
        result.next += outcomes.count
        result.current = .prepared
        return result
    }
}

public struct DeletionViewResult: Equatable, Sendable {
    public let item: DeletionViewItem
    public let outcome: DeletionNodeOutcome
}

public struct DeletionItemProgress: Equatable, Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let outcome: DeletionNodeOutcome?
    public let mayHaveBeenRequested: Bool
}

public struct PendingDeletion: Equatable, Sendable {
    public let plan: DeletionPlan
    public internal(set) var progress: DeletionProgress

    public var id: UUID { plan.id }
    /// No request for this operation can still be sent.
    public var isSettled: Bool { progress.next == plan.nodes.count }
    public var isComplete: Bool { isSettled && progress.finishedDomains.count == plan.views.count }
    public var hasUnconfirmed: Bool { progress.exceptions.contains { $0.outcome == .unconfirmed } }
    /// Overlapping writes wait until every view's catalog shows the settled result.
    public var blocksWrites: Bool { !isComplete }
    /// Keeps the record until any uncertainty has been dismissed.
    public var isPending: Bool { !isComplete || (hasUnconfirmed && !progress.dismissed) }
    public var needsAttention: Bool { !isComplete || (hasNotice && !progress.dismissed) }
    public var canDismiss: Bool { isComplete && hasNotice && !progress.dismissed }
    private var hasNotice: Bool { !progress.exceptions.isEmpty || progress.stopped != nil }

    public func selectedPath(in domain: String) throws -> String {
        guard let view = plan.views.first(where: { $0.domain == domain }),
              let folder = RelativePath(view.folder) else { throw ItemDeletionError.invalidRequest }
        return RelativePath(plan.selected.path)!.components.dropFirst(folder.components.count).joined(separator: "/")
    }

    public func itemProgress(in domain: String) throws -> [DeletionItemProgress] {
        guard let view = plan.views.first(where: { $0.domain == domain }),
              let folder = RelativePath(view.folder) else { throw ItemDeletionError.invalidRequest }
        let known = outcomes()
        return plan.nodes.enumerated().map { index, node in
            DeletionItemProgress(id: index,
                path: RelativePath(node.path)!.components.dropFirst(folder.components.count).joined(separator: "/"),
                outcome: known[index], mayHaveBeenRequested: index == progress.next && progress.current != .prepared)
        }
    }

    // Catalog confirmation is also required before a provider can report success.
    public func requireConfirmedDeletion() throws {
        guard isComplete else { throw UploadError.pendingWrites }
        switch selectedOutcome {
        case .deleted?: return
        case .changed?: throw ItemDeletionError.changed
        case .replaced?: throw ItemDeletionError.replaced
        case .moved?: throw ItemDeletionError.moved
        case .parentChanged?: throw ItemDeletionError.parentChanged
        case .unsupported?: throw ItemDeletionError.unsupported
        case .sharingViolation?: throw ItemDeletionError.sharingViolation
        case .accessDenied?: throw ItemDeletionError.accessDenied
        case .cannotDelete?: throw ItemDeletionError.cannotDelete
        case .directoryNotEmpty?: throw ItemDeletionError.directoryNotEmpty
        case .stopped?: throw ItemDeletionError.stopped
        case .unconfirmed?, nil: throw ItemDeletionError.unresolved
        }
    }

    // A terminal refusal must not restore Finder's item from an unfinished catalog settlement.
    public func completionError(_ error: Error) -> Error {
        guard !isComplete else { return error }
        if error as? ItemDeletionError == .unconfirmedSurvivor { return ItemDeletionError.unresolved }
        switch DeletionFailure.classify(error) {
        case .changed, .replaced, .moved, .parentChanged, .unsupported, .sharingViolation,
             .accessDenied, .cannotDelete, .readOnly, .directoryNotEmpty, .stopped:
            return ItemDeletionError.unresolved
        default: return error
        }
    }

    /// Nil for nodes that have not finished.
    public func outcome(at index: Int) -> DeletionNodeOutcome? {
        plan.nodes.indices.contains(index) ? outcomes()[index] : nil
    }

    public var selectedOutcome: DeletionNodeOutcome? { outcomes()[plan.nodes.count - 1] }

    public var summary: [DeletionNodeOutcome: Int] {
        outcomes().compactMap { $0 }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// The settled outcome for each catalog row this view knew at admission.
    public func results(domain: String) throws -> [DeletionViewResult] {
        guard isSettled, let view = plan.views.first(where: { $0.domain == domain }),
              let folder = RelativePath(view.folder) else { throw ItemDeletionError.invalidRequest }
        let indices = Dictionary(uniqueKeysWithValues: plan.nodes.enumerated().map { (SMBName.key($1.path), $0) })
        let known = outcomes()
        return try view.items.map { item in
            guard let relative = RelativePath(item.path), let path = folder.appending(relative),
                  let index = indices[SMBName.key(path.string)], let outcome = known[index] else {
                throw ItemDeletionError.invalidRequest
            }
            return DeletionViewResult(item: item, outcome: outcome)
        }
    }

    private func outcomes() -> [DeletionNodeOutcome?] {
        var result = plan.nodes.indices.map { $0 < progress.next ? DeletionNodeOutcome.deleted : nil }
        if let stopped = progress.stopped {
            for index in stopped..<plan.nodes.count { result[index] = .stopped }
        }
        for exception in progress.exceptions { result[exception.node] = exception.outcome }
        return result
    }
}

/// One inventory for every share; records bind their endpoint and domains.
/// Callers serialize each namespace; local storage serializes process-wide.
public final class DeletionOutbox {
    private static let storageLock = NSRecursiveLock()
    private let directory: URL
    private let directorySync: (Int32) throws -> Void

    public convenience init(directory: URL) throws {
        try self.init(directory: directory, directorySync: { fd in
            guard fsync(fd) == 0 else { throw posixError("sync deletion directory") }
        })
    }

    init(directory: URL, directorySync: @escaping (Int32) throws -> Void) throws {
        self.directory = directory
        self.directorySync = directorySync
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open deletion outbox") }
        defer { close(fd) }
        guard try FileSystemInfo(fd: fd).isLocal else { throw UploadError.invalidRequest }
    }

    public func records() throws -> [PendingDeletion] {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "deletion" }.map { url in
                let plan = try JSONDecoder().decode(DeletionPlan.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == plan.id.uuidString else {
                    throw ItemDeletionError.invalidRequest
                }
                return PendingDeletion(plan: plan, progress: try storedProgress(plan))
            }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func pendingCount(domain: String) throws -> Int {
        try records().filter { $0.isPending && $0.plan.domains.contains(domain) }.count
    }

    public func replay(endpoint: ShareAddress, owner: String, request: DeletionRequest,
                       sameEvent: (Data, Data) throws -> Bool = { $0 == $1 }) throws -> PendingDeletion? {
        try request.validate()
        var matched: PendingDeletion?
        for record in try records() where record.plan.owner == owner
            && record.plan.request.item == request.item && record.plan.endpoint.matches(endpoint) {
            if try sameEvent(record.plan.request.eventVersion, request.eventVersion) {
                guard matched == nil else { throw ItemDeletionError.unresolved }
                matched = record
            }
        }
        return matched
    }

    /// The traversal must be fresh and protected; `protectedRoots` lists every configured location root.
    public func prepare(endpoint: ShareAddress, owner: String, request: DeletionRequest,
                        traversal: DeletionTraversal, views: [DeletionView], protectedRoots: [RelativePath],
                        recursive: Bool) throws -> PendingDeletion {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        if let existing = try replay(endpoint: endpoint, owner: owner, request: request) { return existing }
        let plan = try DeletionPlan(id: UUID(), endpoint: DeletionEndpoint(endpoint), owner: owner, request: request,
                                    parents: traversal.parents,
                                    nodes: traversal.nodes(recursive: recursive, protectedRoots: protectedRoots),
                                    views: views)
        let domains = Set(plan.domains)
        guard !(try records()).contains(where: { $0.blocksWrites && !domains.isDisjoint(with: $0.plan.domains) }) else {
            throw ItemDeletionError.busy
        }
        let record = PendingDeletion(plan: plan, progress: DeletionProgress())
        // Progress first: a plan without progress is damage, while progress without a plan is inert.
        try persist(JSONEncoder().encode(record.progress), to: url(plan.id, "progress"), exclusive: true)
        try persist(JSONEncoder().encode(plan), to: url(plan.id, "deletion"), exclusive: true)
        return record
    }

    /// Call after this domain's catalog shows every settled outcome.
    public func finishDomain(_ domain: String, record: inout PendingDeletion) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        var current = try reload(record)
        guard current.isSettled, current.plan.domains.contains(domain) else { throw ItemDeletionError.invalidRequest }
        if !current.progress.finishedDomains.contains(domain) {
            var next = current.progress
            next.finishedDomains.append(domain)
            try advance(current.plan, from: current.progress, to: next)
            current.progress = next
        }
        record = current
    }

    /// Settles an operation that cannot proceed. A node that may have been requested stays unconfirmed.
    public func stop(_ record: inout PendingDeletion) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        var current = try reload(record)
        if !current.isSettled {
            var next = current.progress
            if next.current != .prepared {
                next.exceptions.append(DeletionProgress.Exception(node: next.next, outcome: .unconfirmed))
                next.next += 1
            }
            next.stopped = next.next
            next.next = current.plan.nodes.count
            next.current = .prepared
            try advance(current.plan, from: current.progress, to: next)
            current.progress = next
        }
        record = current
    }

    /// Hide a settled notice without removing its outcomes or its replay ownership.
    public func dismiss(_ record: inout PendingDeletion) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        var current = try reload(record)
        guard current.isComplete,
              !current.progress.exceptions.isEmpty || current.progress.stopped != nil else {
            throw ItemDeletionError.invalidRequest
        }
        if !current.progress.dismissed {
            var next = current.progress
            next.dismissed = true
            try advance(current.plan, from: current.progress, to: next)
            current.progress = next
        }
        record = current
    }

    /// Removes a replay record only after its owner domain has been removed.
    public func remove(_ record: PendingDeletion, removedOwner domain: String) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let current = try reload(record)
        guard current.plan.owner == domain else { throw ItemDeletionError.invalidRequest }
        guard !current.isPending else { throw UploadError.pendingWrites }
        try removeFiles(current.id)
    }

    /// Call after domain removal succeeds; pendingCount supplies the earlier preflight.
    public func removeSettled(domain: String) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let affected = try records().filter { $0.plan.domains.contains(domain) }
        guard !affected.contains(where: \.isPending) else { throw UploadError.pendingWrites }
        // Other owners can still receive delayed callbacks and need their replay records.
        for record in affected where record.plan.owner == domain { try removeFiles(record.id) }
    }

    func reload(_ record: PendingDeletion) throws -> PendingDeletion {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let plan = try JSONDecoder().decode(DeletionPlan.self, from: Data(contentsOf: url(record.id, "deletion")))
        guard plan == record.plan else { throw ItemDeletionError.invalidRequest }
        return PendingDeletion(plan: plan, progress: try durableProgress(of: plan))
    }

    func durableProgress(of plan: DeletionPlan) throws -> DeletionProgress {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let progress = try storedProgress(plan)
        // An earlier write may be visible even though syncing its directory failed.
        try syncDirectory(directory)
        return progress
    }

    /// Rejects a caller whose view of the durable progress is stale.
    func advance(_ plan: DeletionPlan, from previous: DeletionProgress, to next: DeletionProgress) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        guard try storedProgress(plan) == previous else { throw ItemDeletionError.invalidRequest }
        try next.validate(for: plan)
        try next.validateUpdate(from: previous, plan: plan)
        try persist(JSONEncoder().encode(next), to: url(plan.id, "progress"), exclusive: false)
    }

    private func storedProgress(_ plan: DeletionPlan) throws -> DeletionProgress {
        let progress = try JSONDecoder().decode(DeletionProgress.self,
                                                from: Data(contentsOf: url(plan.id, "progress")))
        try progress.validate(for: plan)
        return progress
    }

    private func url(_ id: UUID, _ suffix: String) -> URL {
        directory.appending(path: id.uuidString + "." + suffix)
    }

    private func removeFiles(_ id: UUID) throws {
        for suffix in ["deletion", "progress"] {
            guard unlink(url(id, suffix).path) == 0 || errno == ENOENT else { throw posixError("remove deletion record") }
            try syncDirectory(directory)
        }
    }

    private func persist(_ data: Data, to final: URL, exclusive: Bool) throws {
        let temporary = directory.appending(path: UUID().uuidString + ".new")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create deletion record") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write deletion record") }
                offset += written
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("sync deletion record") }
        let result = exclusive ? renamex_np(temporary.path, final.path, UInt32(RENAME_EXCL))
            : rename(temporary.path, final.path)
        guard result == 0 else { throw posixError("publish deletion record") }
        try syncDirectory(directory)
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open deletion directory") }
        defer { close(fd) }
        try directorySync(fd)
    }
}
