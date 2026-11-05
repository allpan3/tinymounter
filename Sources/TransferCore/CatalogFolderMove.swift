import Foundation

public struct CatalogFolderMoveEntry: Codable, Equatable, Sendable {
    public let item: String
    public let parent: String
    public let name: String
    public let path: String
    public let kind: CatalogRow.Kind
    public let contentVersion: String
    public let nativeID: UInt64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let changeSeq: Int64
    public let keep: Bool
    public let keepRequested: Bool
    public let listingComplete: Bool
    public let listGen: Int64?

    public init(row: CatalogRow, path: RelativePath, nativeID: UInt64) throws {
        guard !row.deleted, row.id != Catalog.rootItemID, let parent = row.parentID,
              nativeID != 0, !path.isRoot else { throw UploadError.unresolved }
        item = row.id
        self.parent = parent
        name = row.name
        self.path = path.string
        kind = row.kind
        contentVersion = row.contentVersion
        self.nativeID = nativeID
        size = row.size
        mtimeNs = row.mtimeNs
        ctimeNs = row.ctimeNs
        changeSeq = row.changeSeq
        keep = row.keep
        keepRequested = row.keepRequested
        listingComplete = row.listingComplete
        listGen = row.listGen
    }
}

public struct CatalogFolderMove: Codable, Equatable, Sendable {
    public let item: String
    public let destinationParent: String
    public let destinationName: String
    public let destinationParentPath: String
    public let entries: [CatalogFolderMoveEntry]

    public init(item: String, destinationParent: String, destinationName: String,
                destinationParentPath: RelativePath, entries: [CatalogFolderMoveEntry]) {
        self.item = item
        self.destinationParent = destinationParent
        self.destinationName = destinationName
        self.destinationParentPath = destinationParentPath.string
        self.entries = entries
    }

    public func destinationPath(for entry: CatalogFolderMoveEntry) -> RelativePath? {
        guard let root = entries.first(where: { $0.item == item }),
              let source = RelativePath(root.path), let path = RelativePath(entry.path),
              let target = RelativePath(destinationParentPath)?.appending(destinationName),
              path.components.count >= source.components.count,
              path.components.prefix(source.components.count).joined(separator: "/")
                .utf8.elementsEqual(source.string.utf8),
              let suffix = RelativePath(path.components.dropFirst(source.components.count).joined(separator: "/")) else {
            return nil
        }
        return target.appending(suffix)
    }
}

public struct CatalogFolderMoveObservation: Codable, Equatable, Sendable {
    public let item: String
    public let path: String
    public let kind: CatalogRow.Kind
    public let nativeID: UInt64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let preservesIdentity: Bool
    // True only when the caller observes the same identity and content metadata.
    public let preservesContents: Bool

    public init(item: String, path: RelativePath, kind: CatalogRow.Kind, nativeID: UInt64,
                fingerprint: ContentFingerprint, preservesIdentity: Bool, preservesContents: Bool) {
        self.item = item
        self.path = path.string
        self.kind = kind
        self.nativeID = nativeID
        size = fingerprint.size
        mtimeNs = fingerprint.mtimeNs
        ctimeNs = fingerprint.ctimeNs
        self.preservesIdentity = preservesIdentity
        self.preservesContents = preservesContents
    }
}

public enum CatalogFolderMoveProof: Codable, Equatable, Sendable {
    case directory(item: String, identity: RemoteFileIdentity)
    case file(FileRevision)

    public var item: String {
        switch self {
        case .directory(let item, _): item
        case .file(let receipt): receipt.item
        }
    }

    public var identity: RemoteFileIdentity {
        switch self {
        case .directory(_, let identity): identity
        case .file(let receipt): receipt.version.identity
        }
    }
}

public enum CatalogFolderMoveResolution: Codable, Equatable, Sendable {
    case preserved(CatalogFolderMoveObservation)
    // Mint and persist a fresh receipt; never reuse a version previously handed to File Provider.
    case changed(CatalogFolderMoveObservation, receipt: FileRevision)
    case removed(item: String)

    public var item: String {
        switch self {
        case .preserved(let observation), .changed(let observation, _): observation.item
        case .removed(let item): item
        }
    }
}

public struct CatalogFolderMoveListing: Codable, Equatable, Sendable {
    public struct Child: Codable, Equatable, Sendable {
        public let name: String
        public let identity: RemoteFileIdentity
        // Unsupported kinds must remain in the listing, so they cannot be mistaken for absence.
        public let kind: CatalogRow.Kind?

        public init(name: String, identity: RemoteFileIdentity, kind: CatalogRow.Kind?) {
            self.name = name
            self.identity = identity
            self.kind = kind
        }

        func matches(identity: RemoteFileIdentity, exactName: String) -> Bool {
            self.identity == identity && SMBName.matchesStored(name, requested: exactName)
        }
    }

    public let parent: String
    public let path: String
    public let identity: RemoteFileIdentity
    // Requires every page and name, including unsupported kinds, without unreadable or skipped entries.
    public let complete: Bool
    public let children: [Child]

    public init(parent: String, path: RelativePath, identity: RemoteFileIdentity, complete: Bool, children: [Child]) {
        self.parent = parent
        self.path = path.string
        self.identity = identity
        self.complete = complete
        self.children = children
    }
}

public struct CatalogFolderMoveSettlement: Codable, Equatable, Sendable {
    public let proofs: [CatalogFolderMoveProof]
    public let resolutions: [CatalogFolderMoveResolution]
    public let listings: [CatalogFolderMoveListing]

    public init(proofs: [CatalogFolderMoveProof], resolutions: [CatalogFolderMoveResolution],
                listings: [CatalogFolderMoveListing]) {
        self.proofs = proofs
        self.resolutions = resolutions
        self.listings = listings
    }
}

public enum CatalogFolderMoveRetirement: Codable, Equatable, Sendable {
    case listed(parent: String, identity: RemoteFileIdentity, name: String, occupant: CatalogFolderMoveListing.Child?)
    case parent(item: String)

    static func proved(_ entry: CatalogFolderMoveEntry, identity: RemoteFileIdentity,
                       parentIdentity: RemoteFileIdentity, parentPath: RelativePath,
                       listing: CatalogFolderMoveListing) throws -> Self {
        try proved(parent: entry.parent, name: entry.name, identity: identity,
                   parentIdentity: parentIdentity, parentPath: parentPath, listing: listing)
    }

    static func proved(parent: String, name: String, identity: RemoteFileIdentity,
                       parentIdentity: RemoteFileIdentity, parentPath: RelativePath,
                       listing: CatalogFolderMoveListing) throws -> Self {
        guard listing.parent == parent, listing.identity == parentIdentity, listing.complete,
              listing.path.utf8.elementsEqual(parentPath.string.utf8),
              listing.children.count <= DirectoryListing.defaultLimit,
              listing.children.allSatisfy({ RelativePath.isValidComponent($0.name) }),
              Set(listing.children.map { NameKey($0.name) }).count == listing.children.count else {
            throw UploadError.unresolved
        }
        let occupant = listing.children.first { NameKey($0.name) == NameKey(name) }
        guard occupant?.matches(identity: identity, exactName: name) != true else { throw UploadError.unresolved }
        return .listed(parent: parent, identity: parentIdentity, name: name, occupant: occupant)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.parent(let lhs), .parent(let rhs)): return lhs == rhs
        case (.listed(let lp, let li, let ln, let lo), .listed(let rp, let ri, let rn, let ro)):
            guard lp == rp, li == ri, ln.utf8.elementsEqual(rn.utf8), lo?.identity == ro?.identity,
                  lo?.kind == ro?.kind else { return false }
            if let lo, let ro { return lo.name.utf8.elementsEqual(ro.name.utf8) }
            return lo == nil && ro == nil
        default: return false
        }
    }
}

public struct CatalogFolderMoveState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let item: String
        public let nativeID: UInt64
        public let size: Int64
        public let mtimeNs: Int64
        public let ctimeNs: Int64
        public let contentVersion: String
        public let proof: CatalogFolderMoveProof
        public let retirement: CatalogFolderMoveRetirement?
        public var retired: Bool { retirement != nil }

        public init(item: String, nativeID: UInt64, fingerprint: ContentFingerprint,
                    contentVersion: String, proof: CatalogFolderMoveProof,
                    retirement: CatalogFolderMoveRetirement? = nil) {
            self.item = item
            self.nativeID = nativeID
            size = fingerprint.size
            mtimeNs = fingerprint.mtimeNs
            ctimeNs = fingerprint.ctimeNs
            self.contentVersion = contentVersion
            self.proof = proof
            self.retirement = retirement
        }

        public var fingerprint: ContentFingerprint {
            ContentFingerprint(size: size, mtimeNs: mtimeNs, ctimeNs: ctimeNs)
        }

        func retiring(_ evidence: CatalogFolderMoveRetirement) -> Self {
            Self(item: item, nativeID: nativeID, fingerprint: fingerprint,
                 contentVersion: contentVersion, proof: proof, retirement: evidence)
        }
    }

    public let moved: Bool
    public let entries: [Entry]

    public init(moved: Bool, entries: [Entry]) {
        self.moved = moved
        self.entries = entries
    }

    static func admission(_ move: CatalogFolderMove, proofs: [CatalogFolderMoveProof]) throws -> Self {
        guard proofs.count == move.entries.count, Set(proofs.map(\.item)) == Set(move.entries.map(\.item)),
              Set(move.entries.map(\.item)).count == move.entries.count else { throw UploadError.unresolved }
        let indexed = Dictionary(uniqueKeysWithValues: proofs.map { ($0.item, $0) })
        let state = Self(moved: false, entries: move.entries.map {
            Entry(item: $0.item, nativeID: $0.nativeID,
                  fingerprint: ContentFingerprint(size: $0.size, mtimeNs: $0.mtimeNs, ctimeNs: $0.ctimeNs),
                  contentVersion: $0.contentVersion, proof: indexed[$0.item]!)
        })
        try state.validate(move, admission: state)
        return state
    }

    static func settled(_ move: CatalogFolderMove, settlement: CatalogFolderMoveSettlement) throws -> Self {
        let admission = try admission(move, proofs: settlement.proofs)
        guard settlement.resolutions.count == move.entries.count,
              Set(settlement.resolutions.map(\.item)) == Set(move.entries.map(\.item)) else {
            throw UploadError.unresolved
        }
        let results = Dictionary(uniqueKeysWithValues: settlement.resolutions.map { ($0.item, $0) })
        let original = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        let admitted = Dictionary(uniqueKeysWithValues: admission.entries.map { ($0.item, $0) })
        let entries = try admission.entries.map { before -> Entry in
            let after: CatalogFolderMoveObservation, proof: CatalogFolderMoveProof, version: String
            switch results[before.item]! {
            case .removed:
                let entry = original[before.item]!
                if entry.item == move.item {
                    guard let listing = settlement.listings.first(where: { $0.parent == move.destinationParent }),
                          let path = RelativePath(move.destinationParentPath) else { throw UploadError.unresolved }
                    return before.retiring(try .proved(parent: move.destinationParent, name: move.destinationName,
                        identity: before.proof.identity, parentIdentity: listing.identity, parentPath: path, listing: listing))
                }
                guard let parent = admitted[entry.parent] else { throw UploadError.unresolved }
                if case .removed = results[entry.parent]! { return before.retiring(.parent(item: entry.parent)) }
                guard let listing = settlement.listings.first(where: { $0.parent == entry.parent }),
                      let path = move.destinationPath(for: original[entry.parent]!) else { throw UploadError.unresolved }
                return before.retiring(try CatalogFolderMoveRetirement.proved(entry, identity: before.proof.identity,
                    parentIdentity: parent.proof.identity, parentPath: path, listing: listing))
            case .preserved(let observed):
                after = observed
                proof = before.proof
                version = before.contentVersion
            case .changed(let observed, let receipt):
                after = observed
                proof = .file(receipt)
                version = receipt.contentVersion
            }
            return Entry(item: before.item, nativeID: after.nativeID,
                         fingerprint: ContentFingerprint(size: after.size, mtimeNs: after.mtimeNs, ctimeNs: after.ctimeNs),
                         contentVersion: version, proof: proof)
        }
        let state = Self(moved: true, entries: entries)
        try state.validate(move, admission: admission)
        return state
    }

    func validate(_ move: CatalogFolderMove, admission: Self) throws {
        guard entries.count == move.entries.count, Set(entries.map(\.item)) == Set(move.entries.map(\.item)),
              Set(move.entries.map(\.item)).count == move.entries.count,
              admission.entries.count == entries.count,
              Set(admission.entries.map(\.item)) == Set(entries.map(\.item)),
              moved || self == admission else { throw UploadError.unresolved }
        let original = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        let admitted = Dictionary(uniqueKeysWithValues: admission.entries.map { ($0.item, $0) })
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.item, $0) })
        for entry in entries {
            let before = original[entry.item]!, first = admitted[entry.item]!
            guard entry.proof.item == entry.item, entry.proof.identity == first.proof.identity,
                  entry.nativeID != 0, entry.size >= 0,
                  !entry.contentVersion.isEmpty, entry.contentVersion.utf8.count <= 128 else { throw UploadError.unresolved }
            if entry.item != move.item {
                guard let parent = current[before.parent], !parent.retired || entry.retired else {
                    throw UploadError.unresolved
                }
            }
            if let retirement = entry.retirement {
                switch retirement {
                case .listed(let parent, let identity, let name, let occupant):
                    let isRoot = entry.item == move.item
                    guard parent == (isRoot ? move.destinationParent : before.parent),
                          isRoot ? identity != entry.proof.identity : identity == admitted[parent]?.proof.identity,
                          name.utf8.elementsEqual((isRoot ? move.destinationName : before.name).utf8),
                          occupant?.matches(identity: entry.proof.identity, exactName: name) != true else {
                        throw UploadError.unresolved
                    }
                    if let occupant {
                        guard RelativePath.isValidComponent(occupant.name), NameKey(occupant.name) == NameKey(name) else {
                            throw UploadError.unresolved
                        }
                    }
                case .parent(let parent):
                    guard entry.item != move.item, parent == before.parent,
                          current[parent]?.retired == true else { throw UploadError.unresolved }
                }
            }
            switch entry.proof {
            case .directory:
                guard before.kind == .folder, entry.contentVersion == before.contentVersion else {
                    throw UploadError.unresolved
                }
            case .file(let receipt):
                guard before.kind == .file, receipt.version.size == entry.size, entry.mtimeNs >= 0,
                      UInt64(entry.mtimeNs / 1_000) == receipt.version.modifiedMicroseconds,
                      entry.contentVersion == receipt.contentVersion
                        || (entry.contentVersion == before.contentVersion && entry.proof == first.proof),
                      !entry.contentVersion.hasPrefix("r1:") || entry.contentVersion == receipt.contentVersion else {
                    throw UploadError.unresolved
                }
                if entry.contentVersion == first.contentVersion || receipt.contentVersion == first.contentVersion {
                    guard entry.proof == first.proof else { throw UploadError.unresolved }
                }
                if case .file(let original) = first.proof, receipt.id == original.id {
                    guard receipt == original else { throw UploadError.unresolved }
                }
            }
        }
        for entry in entries where entry.retired {
            var seen: Set<String> = [entry.item], witness = entry.retirement!
            while case .parent(let parent) = witness {
                guard seen.insert(parent).inserted, let next = current[parent]?.retirement else {
                    throw UploadError.unresolved
                }
                witness = next
            }
        }
    }
}

private struct FolderMoveResult {
    let observation: CatalogFolderMoveObservation?
    let contentVersion: String
}

extension Catalog {
    public func classifyFolderMove(_ move: CatalogFolderMove, proofs: [CatalogFolderMoveProof],
                                   allowed: [CatalogFolderMoveState]) throws -> CatalogFolderMoveState {
        let paths = try folderMovePaths(move), admission = try CatalogFolderMoveState.admission(move, proofs: proofs)
        guard !allowed.isEmpty, allowed.count <= 3 else { throw UploadError.unresolved }
        for state in allowed { try state.validate(move, admission: admission) }
        return try database.read {
            for state in allowed where try matchesFolderMoveState(move, state: state, paths: paths) { return state }
            throw UploadError.unresolved
        }
    }

    // The durable recovery plan supplies the freshly proved target; this commit compares local state.
    public func applyFolderMoveRecovery(_ move: CatalogFolderMove, proofs: [CatalogFolderMoveProof],
                                       expected: CatalogFolderMoveState, target: CatalogFolderMoveState) throws {
        let paths = try folderMovePaths(move), admission = try CatalogFolderMoveState.admission(move, proofs: proofs)
        try expected.validate(move, admission: admission)
        try target.validate(move, admission: admission)
        let after = Dictionary(uniqueKeysWithValues: target.entries.map { ($0.item, $0) })
        guard target.moved, expected.entries.allSatisfy({ entry in
            let result = after[entry.item]!
            return (!entry.retired || result == entry)
                && (entry.contentVersion != result.contentVersion || entry.proof == result.proof)
        }) else {
            throw UploadError.unresolved
        }
        try write { seq in
            guard let destination = try item(id: move.destinationParent), !destination.deleted,
                  destination.kind == .folder, destination.listGen != nil,
                  try relativePath(of: destination.id)?.string.utf8
                    .elementsEqual(move.destinationParentPath.utf8) == true else { throw UploadError.unresolved }
            if after[move.item]?.retired != true,
               let collision = try liveChild(parent: destination.id, nameKey: NameKey(move.destinationName)),
               collision.id != move.item { throw UploadError.collision }
            if try matchesFolderMoveState(move, state: target, paths: paths) { return }
            guard try matchesFolderMoveState(move, state: expected, paths: paths) else { throw UploadError.unresolved }
            let ordered = move.entries.sorted { paths[$0.item]!.components.count < paths[$1.item]!.components.count }
            var keeps: [String: Bool] = [:]
            var departure: Int64 = 0
            for before in ordered {
                let result = after[before.item]!, row = try item(id: before.item)!
                let parent = before.item == move.item ? destination.id : before.parent
                let name = before.item == move.item ? move.destinationName : before.name
                let inherited = before.item == move.item ? destination.keep : keeps[before.parent]
                guard result.retired || inherited != nil else { throw UploadError.unresolved }
                let keep = result.retired ? row.keep : row.keepRequested || inherited!
                keeps[before.item] = keep
                let nativeID = try folderMoveNativeID(row.id)
                guard row.deleted != result.retired || row.parentID != parent || !row.name.utf8.elementsEqual(name.utf8)
                    || row.contentVersion != result.contentVersion || row.size != result.size
                    || row.mtimeNs != result.mtimeNs || row.ctimeNs != result.ctimeNs
                    || nativeID != result.nativeID || row.keep != keep
                    || (row.kind == .folder && row.listingComplete) else { continue }
                seq += 1
                if before.item == move.item { departure = seq }
                try database.prepare("""
                    UPDATE items SET parent_id = ?, name = ?, name_key = ?, size = ?, mtime_ns = ?,
                        ctime_ns = ?, file_id = ?, edit_version = CASE WHEN kind = 2 THEN ? ELSE edit_version END,
                        deleted = ?, keep = ?, change_seq = ?,
                        listing_complete = CASE WHEN kind = 1 THEN 0 ELSE listing_complete END WHERE id = ?
                    """) {
                    try $0.bind(1, parent)
                    try $0.bind(2, name)
                    try $0.bind(3, NameKey(name).value)
                    try $0.bind(4, result.size)
                    try $0.bind(5, result.mtimeNs)
                    try $0.bind(6, result.ctimeNs)
                    try $0.bind(7, Int64(bitPattern: result.nativeID))
                    try $0.bind(8, result.contentVersion)
                    try $0.bind(9, result.retired)
                    try $0.bind(10, keep)
                    try $0.bind(11, seq)
                    try $0.bind(12, row.id)
                    try $0.run()
                }
            }
            let root = move.entries.first { $0.item == move.item }!
            if !expected.moved, root.parent != destination.id {
                guard departure != 0 else { throw UploadError.unresolved }
                try database.prepare("INSERT OR REPLACE INTO departures (item, parent, seq) VALUES (?, ?, ?)") {
                    try $0.bind(1, root.item)
                    try $0.bind(2, root.parent)
                    try $0.bind(3, departure)
                    try $0.run()
                }
                try database.prepare("DELETE FROM departures WHERE item = ? AND parent = ?") {
                    try $0.bind(1, root.item)
                    try $0.bind(2, destination.id)
                    try $0.run()
                }
            }
        }
    }

    private func matchesFolderMoveState(_ move: CatalogFolderMove, state: CatalogFolderMoveState,
                                       paths: [String: RelativePath]) throws -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.item, $0) })
        guard Set(try folderMoveRows(move.item).map(\.id)) == Set(state.entries.filter { !$0.retired }.map(\.item)) else {
            return false
        }
        for original in move.entries {
            let entry = expected[original.item]!
            guard let row = try item(id: original.item), row.deleted == entry.retired, row.kind == original.kind,
                  row.parentID == (state.moved && row.id == move.item ? move.destinationParent : original.parent),
                  row.name.utf8.elementsEqual((state.moved && row.id == move.item ? move.destinationName : original.name).utf8),
                  row.contentVersion == entry.contentVersion, row.size == entry.size,
                  row.mtimeNs == entry.mtimeNs, row.ctimeNs == entry.ctimeNs,
                  try folderMoveNativeID(row.id) == entry.nativeID, row.listGen == original.listGen,
                  row.listingComplete == (state.moved && row.kind == .folder ? false : original.listingComplete) else {
                return false
            }
            if !row.deleted {
                let path = state.moved ? paths[row.id]!.string : original.path
                guard try relativePath(of: row.id)?.string.utf8.elementsEqual(path.utf8) == true else { return false }
            }
        }
        return true
    }

    public func prepareFolderMove(item id: String, destinationParent: String,
                                  destinationName: String) throws -> CatalogFolderMove {
        try database.read {
            guard id != Self.rootItemID, try item(id: id)?.kind == .folder,
                  let destination = try item(id: destinationParent), !destination.deleted,
                  destination.kind == .folder, destination.listGen != nil,
                  let parentPath = try relativePath(of: destinationParent) else { throw UploadError.unresolved }
            let entries = try folderMoveRows(id).map { row in
                guard let path = try relativePath(of: row.id), let nativeID = try remoteIdentity(row.id) else {
                    throw UploadError.unresolved
                }
                return try CatalogFolderMoveEntry(row: row, path: path, nativeID: nativeID)
            }
            let move = CatalogFolderMove(item: id, destinationParent: destinationParent,
                                         destinationName: destinationName, destinationParentPath: parentPath,
                                         entries: entries)
            _ = try folderMovePaths(move)
            return move
        }
    }

    // The caller proves every directory identity and each preserved file's complete contents.
    public func commitFolderMove(_ move: CatalogFolderMove,
                                 observations: [CatalogFolderMoveObservation]) throws {
        guard observations.count == move.entries.count,
              Set(observations.map(\.item)) == Set(move.entries.map(\.item)),
              Set(observations.map(\.item)).count == observations.count else { throw UploadError.unresolved }
        let observed = Dictionary(uniqueKeysWithValues: observations.map { ($0.item, $0) })
        var results: [String: FolderMoveResult] = [:]
        for entry in move.entries {
            guard let after = observed[entry.item], entry.kind != .file
                || (after.preservesContents && after.size == entry.size) else { throw UploadError.unresolved }
            results[entry.item] = FolderMoveResult(observation: after, contentVersion: entry.contentVersion)
        }
        try write { seq in
            try applyFolderMove(move, results: results, seq: &seq)
        }
    }

    // Fresh receipts must be durable before their versions become visible in the catalog.
    public func settleFolderMove(_ move: CatalogFolderMove, settlement: CatalogFolderMoveSettlement) throws {
        if settlement.resolutions.contains(.removed(item: move.item)) {
            let target = try CatalogFolderMoveState.settled(move, settlement: settlement)
            guard target.entries.allSatisfy(\.retired), settlement.listings.count == 1 else {
                throw UploadError.unresolved
            }
            try applyFolderMoveRecovery(move, proofs: settlement.proofs,
                expected: CatalogFolderMoveState.admission(move, proofs: settlement.proofs), target: target)
            return
        }
        let results = try folderMoveResults(move, settlement: settlement)
        try write { seq in try applyFolderMove(move, results: results, seq: &seq) }
    }

    private func applyFolderMove(_ move: CatalogFolderMove, results: [String: FolderMoveResult],
                                 seq: inout Int64) throws {
        let paths = try folderMovePaths(move)
        let rows = try move.entries.map { entry -> CatalogRow in
            guard let row = try item(id: entry.item) else { throw UploadError.unresolved }
            return row
        }
        guard Set(results.keys) == Set(move.entries.map(\.item)),
              let root = rows.first(where: { $0.id == move.item }), !root.deleted,
              results[root.id]?.observation != nil,
              let admittedRoot = move.entries.first(where: { $0.item == move.item }),
              let destination = try item(id: move.destinationParent), !destination.deleted,
              destination.kind == .folder, destination.listGen != nil,
              let parentPath = try relativePath(of: destination.id),
              parentPath.string.utf8.elementsEqual(move.destinationParentPath.utf8) else {
            throw UploadError.unresolved
        }
        if let other = try liveChild(parent: destination.id, nameKey: NameKey(move.destinationName)),
           other.id != root.id { throw UploadError.collision }
        let admitted = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        let ordered = rows.sorted {
            let first = paths[$0.id]!.components.count, second = paths[$1.id]!.components.count
            return first == second ? $0.row < $1.row : first < second
        }
        var keeps: [String: Bool] = [:]
        let moved = root.parentID == destination.id && root.name.utf8.elementsEqual(move.destinationName.utf8)
        let expectedLive = moved ? Set(results.filter { $0.value.observation != nil }.keys) : Set(results.keys)
        guard Set(try folderMoveRows(root.id).map(\.id)) == expectedLive else { throw UploadError.unresolved }
        for row in ordered {
            let before = admitted[row.id]!, result = results[row.id]!
            let expectedParent = row.id == root.id ? destination.id : before.parent
            let expectedName = row.id == root.id ? move.destinationName : before.name
            let nativeID = try folderMoveNativeID(row.id)
            guard row.kind == before.kind,
                  row.contentVersion == (moved ? result.contentVersion : before.contentVersion) else {
                throw UploadError.unresolved
            }
            if !moved || result.observation == nil {
                guard row.deleted == (moved && result.observation == nil),
                      row.parentID == before.parent, row.name.utf8.elementsEqual(before.name.utf8),
                      nativeID == before.nativeID, row.size == before.size, row.mtimeNs == before.mtimeNs,
                      row.ctimeNs == before.ctimeNs, row.listGen == before.listGen,
                      row.listingComplete == (moved && row.kind == .folder ? false : before.listingComplete) else {
                    throw UploadError.unresolved
                }
                if !moved {
                    guard let path = try relativePath(of: row.id),
                          path.string.utf8.elementsEqual(before.path.utf8) else { throw UploadError.unresolved }
                }
            }
            guard let after = result.observation else { continue }
            guard !row.deleted, after.kind == before.kind, after.nativeID != 0,
                  after.preservesIdentity,
                  after.size >= 0, after.path.utf8.elementsEqual(paths[row.id]!.string.utf8) else {
                throw UploadError.unresolved
            }
            let inherited = row.id == root.id ? destination.keep : keeps[before.parent]
            guard let inherited else { throw UploadError.unresolved }
            keeps[row.id] = row.keepRequested || inherited
            guard let path = try relativePath(of: row.id) else {
                throw UploadError.unresolved
            }
            if moved {
                guard row.parentID == expectedParent, row.name.utf8.elementsEqual(expectedName.utf8),
                      path.string.utf8.elementsEqual(after.path.utf8), nativeID == after.nativeID,
                      row.size == after.size, row.mtimeNs == after.mtimeNs, row.ctimeNs == after.ctimeNs,
                      row.keep == keeps[row.id],
                      row.listingComplete == (row.kind == .folder ? false : before.listingComplete) else {
                    throw UploadError.unresolved
                }
            }
        }
        if moved { return }
        var departure: Int64 = 0
        for row in ordered {
            let result = results[row.id]!
            seq += 1
            if row.id == root.id { departure = seq }
            guard let after = result.observation else {
                try database.prepare("""
                    UPDATE items SET deleted = 1, change_seq = ?,
                        listing_complete = CASE WHEN kind = 1 THEN 0 ELSE listing_complete END WHERE id = ?
                    """) {
                    try $0.bind(1, seq)
                    try $0.bind(2, row.id)
                    try $0.run()
                }
                continue
            }
            // Known descendants do not prove that no new remote child arrived during the move.
            try database.prepare("""
                UPDATE items SET parent_id = ?, name = ?, name_key = ?, size = ?, mtime_ns = ?,
                    ctime_ns = ?, file_id = ?, edit_version = CASE WHEN kind = 2 THEN ? ELSE edit_version END,
                    keep = ?, change_seq = ?,
                    listing_complete = CASE WHEN kind = 1 THEN 0 ELSE listing_complete END WHERE id = ?
                """) {
                let name = row.id == root.id ? move.destinationName : row.name
                try $0.bind(1, row.id == root.id ? destination.id : admitted[row.id]!.parent)
                try $0.bind(2, name)
                try $0.bind(3, NameKey(name).value)
                try $0.bind(4, after.size)
                try $0.bind(5, after.mtimeNs)
                try $0.bind(6, after.ctimeNs)
                try $0.bind(7, Int64(bitPattern: after.nativeID))
                try $0.bind(8, result.contentVersion)
                try $0.bind(9, keeps[row.id]!)
                try $0.bind(10, seq)
                try $0.bind(11, row.id)
                try $0.run()
            }
        }
        if admittedRoot.parent != destination.id {
            try database.prepare("INSERT OR REPLACE INTO departures (item, parent, seq) VALUES (?, ?, ?)") {
                try $0.bind(1, root.id)
                try $0.bind(2, admittedRoot.parent)
                try $0.bind(3, departure)
                try $0.run()
            }
            try database.prepare("DELETE FROM departures WHERE item = ? AND parent = ?") {
                try $0.bind(1, root.id)
                try $0.bind(2, destination.id)
                try $0.run()
            }
        }
    }

    private func folderMoveNativeID(_ id: String) throws -> UInt64? {
        try database.prepare("SELECT file_id FROM items WHERE id = ?") {
            try $0.bind(1, id)
            guard try $0.step(), !$0.isNull(0) else { return nil }
            return UInt64(bitPattern: $0.int64(0))
        }
    }

    private func folderMoveResults(_ move: CatalogFolderMove,
                                   settlement: CatalogFolderMoveSettlement) throws -> [String: FolderMoveResult] {
        let paths = try folderMovePaths(move)
        guard move.entries.count <= DirectoryListing.defaultLimit,
              settlement.proofs.count == move.entries.count, settlement.resolutions.count == move.entries.count,
              Set(settlement.proofs.map(\.item)) == Set(move.entries.map(\.item)),
              Set(settlement.resolutions.map(\.item)) == Set(move.entries.map(\.item)),
              Set(settlement.listings.map(\.parent)).count == settlement.listings.count else {
            throw UploadError.unresolved
        }
        let admitted = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        let proofs = Dictionary(uniqueKeysWithValues: settlement.proofs.map { ($0.item, $0) })
        let resolutions = Dictionary(uniqueKeysWithValues: settlement.resolutions.map { ($0.item, $0) })
        let knownChildren = Dictionary(grouping: move.entries, by: \.parent)
        var usedVersions = Set(move.entries.map(\.contentVersion))
        for entry in move.entries {
            switch proofs[entry.item]! {
            case .directory:
                guard entry.kind == .folder else { throw UploadError.unresolved }
            case .file(let receipt):
                guard entry.kind == .file, receipt.version.size == entry.size,
                      !entry.contentVersion.hasPrefix("r1:") || entry.contentVersion == receipt.contentVersion else {
                    throw UploadError.unresolved
                }
                usedVersions.insert(receipt.contentVersion)
            }
        }
        var results: [String: FolderMoveResult] = [:]
        for entry in move.entries {
            switch resolutions[entry.item]! {
            case .preserved(let after):
                guard entry.kind != .file || (after.preservesContents && after.size == entry.size) else {
                    throw UploadError.unresolved
                }
                if case .file(let receipt) = proofs[entry.item]! {
                    guard after.mtimeNs >= 0,
                          UInt64(after.mtimeNs / 1_000) == receipt.version.modifiedMicroseconds else {
                        throw UploadError.unresolved
                    }
                }
                results[entry.item] = FolderMoveResult(observation: after, contentVersion: entry.contentVersion)
            case .changed(let after, let receipt):
                guard entry.kind == .file, case .file(let original) = proofs[entry.item]!,
                      receipt.item == entry.item, receipt.version.identity == original.version.identity,
                      !receipt.version.hasSameDataVersion(as: original.version)
                        || receipt.version.modifiedMicroseconds != original.version.modifiedMicroseconds,
                      usedVersions.insert(receipt.contentVersion).inserted,
                      after.preservesContents == receipt.version.hasSameDataVersion(as: original.version),
                      after.size == receipt.version.size,
                      after.mtimeNs >= 0, after.ctimeNs >= 0,
                      UInt64(after.mtimeNs / 1_000) == receipt.version.modifiedMicroseconds,
                      UInt64(after.ctimeNs / 1_000) == receipt.version.changedMicroseconds else {
                    throw UploadError.unresolved
                }
                results[entry.item] = FolderMoveResult(observation: after, contentVersion: receipt.contentVersion)
            case .removed:
                guard entry.item != move.item else { throw UploadError.unresolved }
                results[entry.item] = FolderMoveResult(observation: nil, contentVersion: entry.contentVersion)
            }
        }
        var remaining = DirectoryListing.defaultLimit
        for listing in settlement.listings {
            guard let parent = admitted[listing.parent], parent.kind == .folder,
                  results[parent.item]?.observation != nil, listing.complete,
                  listing.identity == proofs[parent.item]?.identity,
                  listing.path.utf8.elementsEqual(paths[parent.item]!.string.utf8),
                  listing.children.count <= remaining,
                  listing.children.allSatisfy({ RelativePath.isValidComponent($0.name) }),
                  Set(listing.children.map { NameKey($0.name) }).count == listing.children.count else {
                throw UploadError.unresolved
            }
            remaining -= listing.children.count
            let children = Dictionary(uniqueKeysWithValues: listing.children.map { (NameKey($0.name), $0) })
            for entry in knownChildren[listing.parent] ?? [] {
                let child = children[NameKey(entry.name)]
                if results[entry.item]!.observation == nil {
                    // Removal ends the old name binding; it never asserts deletion of the server object.
                    guard child?.matches(identity: proofs[entry.item]!.identity, exactName: entry.name) != true else {
                        throw UploadError.unresolved
                    }
                } else {
                    guard let child, child.identity == proofs[entry.item]!.identity, child.kind == entry.kind,
                          SMBName.matchesStored(child.name, requested: entry.name) else { throw UploadError.unresolved }
                }
            }
        }
        let listed = Set(settlement.listings.map(\.parent))
        for entry in move.entries where entry.item != move.item {
            guard let parent = results[entry.parent] else { throw UploadError.unresolved }
            if results[entry.item]!.observation != nil {
                guard parent.observation != nil else { throw UploadError.unresolved }
            } else if parent.observation != nil {
                guard listed.contains(entry.parent) else { throw UploadError.unresolved }
            }
        }
        return results
    }

    private func folderMoveRows(_ id: String) throws -> [CatalogRow] {
        try items("""
            WITH RECURSIVE tree(id) AS (
                SELECT id FROM items WHERE id = ? AND deleted = 0
                UNION SELECT child.id FROM items child JOIN tree ON child.parent_id = tree.id WHERE child.deleted = 0)
            SELECT \(CatalogRow.columns) FROM items WHERE id IN (SELECT id FROM tree) ORDER BY row
            """) { try $0.bind(1, id) }
    }

    private func folderMovePaths(_ move: CatalogFolderMove) throws -> [String: RelativePath] {
        guard move.item != Self.rootItemID, ReaderMessage.isItemID(move.item),
              ReaderMessage.isItemID(move.destinationParent), FileRenameRequest.supportsName(move.destinationName),
              !move.entries.isEmpty, Set(move.entries.map(\.item)).count == move.entries.count,
              !move.entries.contains(where: { $0.item == move.destinationParent }),
              let root = move.entries.first(where: { $0.item == move.item }), root.kind == .folder,
              let source = RelativePath(root.path), !source.isRoot,
              let parent = RelativePath(move.destinationParentPath),
              let target = parent.appending(move.destinationName),
              root.parent != move.destinationParent || !root.name.utf8.elementsEqual(move.destinationName.utf8) else {
            throw UploadError.unresolved
        }
        let entries = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        var result: [String: RelativePath] = [:]
        for entry in move.entries {
            guard ReaderMessage.isItemID(entry.item), entry.item != Self.rootItemID,
                  ReaderMessage.isItemID(entry.parent), entry.nativeID != 0, entry.size >= 0,
                  !entry.contentVersion.isEmpty, entry.contentVersion.utf8.count <= 128,
                  let path = RelativePath(entry.path),
                  path.components.last?.utf8.elementsEqual(entry.name.utf8) == true,
                  path.components.count >= source.components.count,
                  path.components.prefix(source.components.count).joined(separator: "/")
                    .utf8.elementsEqual(source.string.utf8),
                  let suffix = RelativePath(path.components.dropFirst(source.components.count).joined(separator: "/")),
                  let destination = target.appending(suffix), destination.components.count <= Self.maxDepth else {
                throw UploadError.unresolved
            }
            if entry.item != root.item {
                guard let ancestor = entries[entry.parent], ancestor.kind == .folder,
                      let ancestorPath = RelativePath(ancestor.path)?.appending(entry.name),
                      ancestorPath.string.utf8.elementsEqual(entry.path.utf8) else { throw UploadError.unresolved }
            }
            result[entry.item] = destination
        }
        return result
    }
}
