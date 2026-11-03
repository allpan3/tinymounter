import Foundation

public enum ItemDeletionError: Error, Equatable, Sendable {
    case invalidRequest, changed, replaced, parentChanged, moved, absentUnconfirmed
    case deletePending, pathNotFound, sharingViolation, directoryNotEmpty, accessDenied, cannotDelete
    case unsupported, unresolved, busy, stopped
}

public enum DeletionFailure: Equatable, Sendable {
    case changed, replaced, moved, parentChanged, unsupported, sharingViolation, accessDenied, cannotDelete
    case directoryNotEmpty, unconfirmed, connection, authentication, pendingChanges, busy, readOnly
    case cancelled, stopped, storage, unknown

    public static func classify(_ error: Error) -> Self {
        if let error = error as? ItemDeletionError {
            switch error {
            case .changed: return .changed
            case .replaced: return .replaced
            case .moved: return .moved
            case .parentChanged: return .parentChanged
            case .unsupported, .invalidRequest: return .unsupported
            case .sharingViolation: return .sharingViolation
            case .accessDenied: return .accessDenied
            case .cannotDelete: return .cannotDelete
            case .directoryNotEmpty: return .directoryNotEmpty
            case .busy: return .busy
            case .stopped: return .stopped
            case .absentUnconfirmed, .deletePending, .pathNotFound, .unresolved: return .unconfirmed
            }
        }
        if let error = error as? UploadError {
            switch error {
            case .readOnly: return .readOnly
            case .pendingWrites: return .pendingChanges
            case .invalidRequest: return .unsupported
            default: return .unconfirmed
            }
        }
        if DownloadSpace.isFull(error) { return .storage }
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == CocoaError.userCancelled.rawValue { return .cancelled }
        switch SourceFailure.classify(error, context: .listing) {
        case .versionChanged: return .changed
        case .serverUnreachable, .notConnected: return .connection
        case .notAuthenticated: return .authentication
        case .noPermission: return .accessDenied
        case .pathRejected, .tooManyEntries: return .unsupported
        case .cancelled: return .cancelled
        case .missing, .listingIncomplete: return .unconfirmed
        case .unknown: return .unknown
        }
    }
}

public enum ItemDeletionEvidence: Codable, Equatable, Sendable {
    case file(EditFileVersion)
    case directory(EditFileIdentity)

    public var identity: EditFileIdentity {
        switch self {
        case .file(let version): version.identity
        case .directory(let identity): identity
        }
    }

    public var kind: CatalogRow.Kind {
        switch self {
        case .file: .file
        case .directory: .folder
        }
    }

    func validate() throws {
        if case .file(let version) = self, version.attributes & 0x410 != 0 {
            throw ItemDeletionError.unsupported
        }
    }

    func hasSameContents(as other: Self) -> Bool {
        switch (self, other) {
        case let (.file(expected), .file(actual)): expected.hasSameContents(as: actual)
        case let (.directory(expected), .directory(actual)): expected == actual
        default: false
        }
    }
}

public struct ItemDeletionParent: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let identity: EditFileIdentity

    public init(path: String, name: String, identity: EditFileIdentity) {
        self.path = path
        self.name = name
        self.identity = identity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.identity == rhs.identity
    }
}

public struct ItemDeletionEntry: Sendable {
    public let name: String
    public let identity: EditFileIdentity

    public init(name: String, identity: EditFileIdentity) {
        self.name = name
        self.identity = identity
    }
}

public struct ItemDeletionListing: Sendable {
    public let entries: [ItemDeletionEntry]
    public let isComplete: Bool

    public init(entries: [ItemDeletionEntry], isComplete: Bool) {
        self.entries = entries
        self.isComplete = isComplete
    }

    func validatedEntries() throws -> [ItemDeletionEntry] {
        guard isComplete, entries.allSatisfy({ RelativePath.isValidComponent($0.name) }),
              Set(entries.map { NameKey($0.name) }).count == entries.count else {
            throw ItemDeletionError.unresolved
        }
        return entries
    }
}

/// Absence cases require exact SMB replies; errno mapping and transport failures cannot supply them.
public enum ItemDeletionLookup: Sendable {
    case present(ItemDeletionEvidence)
    case nameNotFound, pathNotFound, deletePending
}

public struct PendingItemDeletion: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case prepared, attempting, closeAcknowledged, absentUnconfirmed, deleted
    }

    public let id: UUID
    public let path: String
    public let selected: ItemDeletionEvidence
    public let parents: [ItemDeletionParent]
    public private(set) var state: State = .prepared

    public init(id: UUID = UUID(), path: RelativePath, selected: ItemDeletionEvidence,
                parents: [ItemDeletionParent]) throws {
        self.id = id
        self.path = path.string
        self.selected = selected
        self.parents = parents
        try validate()
    }

    init(id: UUID, path: RelativePath, selected: ItemDeletionEvidence, parents: [ItemDeletionParent],
         state: State) throws {
        try self.init(id: id, path: path, selected: selected, parents: parents)
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedPath = try values.decode(String.self, forKey: .path)
        guard let path = RelativePath(storedPath) else {
            throw ItemDeletionError.invalidRequest
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), path: path,
                      selected: values.decode(ItemDeletionEvidence.self, forKey: .selected),
                      parents: values.decode([ItemDeletionParent].self, forKey: .parents))
        state = try values.decode(State.self, forKey: .state)
    }

    public var isPending: Bool { state != .deleted }
    public var parentPath: String { RelativePath(path)!.components.dropLast().joined(separator: "/") }
    public var name: String { RelativePath(path)!.components.last! }

    public func validate() throws {
        guard let target = RelativePath(path), !target.isRoot,
              target.components.allSatisfy(FileRenameRequest.supportsName),
              parents.count == target.components.count else { throw ItemDeletionError.invalidRequest }
        for (depth, parent) in parents.enumerated() {
            let expected = target.components.prefix(depth).joined(separator: "/")
            guard parent.path.utf8.elementsEqual(expected.utf8),
                  parent.name.utf8.elementsEqual((depth == 0 ? "" : target.components[depth - 1]).utf8) else {
                throw ItemDeletionError.invalidRequest
            }
        }
        try selected.validate()
    }

    func hasSameTarget(as other: Self) -> Bool {
        id == other.id && path.utf8.elementsEqual(other.path.utf8)
            && selected == other.selected && parents == other.parents
    }

    fileprivate func advancing(to state: State) -> Self {
        var next = self
        next.state = state
        return next
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasSameTarget(as: rhs) && lhs.state == rhs.state
    }
}

/// Each invocation needs a fresh session; the caller ends it on both success and failure.
public protocol DeletionRemote {
    /// Hold the root-to-parent chain against replacement, verifying identities and exact names.
    func protectParents(of path: String) throws -> [ItemDeletionParent]
    /// Present holds a deny-all handle; files need full contents and one link, with no reparse points.
    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup
    /// Restart the held directory's full listing; missing or malformed pages are never complete.
    func list(path: String) throws -> ItemDeletionListing
    /// Both calls act only on the same protected handle returned by inspect.
    func markDeletion(path: String) throws
    /// Success requires the close reply and no other owned handles that can defer removal.
    func closeTarget(path: String) throws
}

/// Unintegrated core; admission, durable storage and catalog commits remain caller responsibilities.
public enum ItemDeletionTransaction {
    /// Serialize calls; load reads durable state and checkpoint must persist it before returning.
    public static func remove(_ record: inout PendingItemDeletion, remote: DeletionRemote,
                              load: () throws -> PendingItemDeletion,
                              checkpoint: (PendingItemDeletion) throws -> Void) throws {
        let stored = try load()
        try stored.validate()
        guard record.hasSameTarget(as: stored) else { throw ItemDeletionError.invalidRequest }
        record = stored
        if record.state == .deleted { return }
        guard try remote.protectParents(of: record.path) == record.parents else {
            throw ItemDeletionError.parentChanged
        }
        if record.state == .closeAcknowledged {
            try confirm(&record, remote: remote, checkpoint: checkpoint)
            return
        }
        switch try remote.inspect(path: record.path, kind: record.selected.kind) {
        case .present(let actual):
            try actual.validate()
            guard actual.identity == record.selected.identity else { throw ItemDeletionError.replaced }
            guard record.selected.hasSameContents(as: actual) else { throw ItemDeletionError.changed }
            let entries = try remote.list(path: record.parentPath).validatedEntries()
            let matches = entries.filter { $0.identity == record.selected.identity }
            guard matches.count == 1, matches[0].name.utf8.elementsEqual(record.name.utf8) else {
                if matches.contains(where: { !$0.name.utf8.elementsEqual(record.name.utf8) }) {
                    throw ItemDeletionError.moved
                }
                throw ItemDeletionError.unresolved
            }
            if record.selected.kind == .folder {
                guard try remote.list(path: record.path).validatedEntries().isEmpty else {
                    throw ItemDeletionError.directoryNotEmpty
                }
            }
        case .nameNotFound:
            try requireAbsent(record, remote: remote)
            try advance(&record, to: .absentUnconfirmed, checkpoint: checkpoint)
            throw ItemDeletionError.absentUnconfirmed
        case .pathNotFound: throw ItemDeletionError.pathNotFound
        case .deletePending: throw ItemDeletionError.deletePending
        }
        try advance(&record, to: .attempting, checkpoint: checkpoint)
        try remote.markDeletion(path: record.path)
        try remote.closeTarget(path: record.path)
        try advance(&record, to: .closeAcknowledged, checkpoint: checkpoint)
        try confirm(&record, remote: remote, checkpoint: checkpoint)
    }

    private static func confirm(_ record: inout PendingItemDeletion, remote: DeletionRemote,
                                checkpoint: (PendingItemDeletion) throws -> Void) throws {
        guard record.state == .closeAcknowledged else { throw ItemDeletionError.unresolved }
        switch try remote.inspect(path: record.path, kind: record.selected.kind) {
        case .present(let actual):
            throw actual.identity == record.selected.identity ? ItemDeletionError.unresolved : .replaced
        case .nameNotFound:
            try requireAbsent(record, remote: remote)
            try advance(&record, to: .deleted, checkpoint: checkpoint)
        case .pathNotFound: throw ItemDeletionError.pathNotFound
        case .deletePending: throw ItemDeletionError.deletePending
        }
    }

    private static func requireAbsent(_ record: PendingItemDeletion, remote: DeletionRemote) throws {
        let entries = try remote.list(path: record.parentPath).validatedEntries()
        guard !entries.contains(where: { $0.identity == record.selected.identity }) else {
            throw ItemDeletionError.moved
        }
        guard !entries.contains(where: { NameKey($0.name) == NameKey(record.name) }) else {
            throw ItemDeletionError.replaced
        }
    }

    private static func advance(_ record: inout PendingItemDeletion, to state: PendingItemDeletion.State,
                                checkpoint: (PendingItemDeletion) throws -> Void) throws {
        let next = record.advancing(to: state)
        try checkpoint(next)
        record = next
    }
}
