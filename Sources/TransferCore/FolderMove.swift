import Darwin
import Foundation

public struct FolderMoveView: Codable, Equatable, Sendable {
    public let domain: String
    public let folder: String
    public let move: CatalogFolderMove
    public let proofs: [CatalogFolderMoveProof]

    public init(domain: String, folder: RelativePath, move: CatalogFolderMove,
                proofs: [CatalogFolderMoveProof]) {
        self.domain = domain
        self.folder = folder.string
        self.move = move
        self.proofs = proofs
    }

    public func destinationPath(for entry: CatalogFolderMoveEntry) -> RelativePath? {
        move.destinationPath(for: entry)
    }

    func validate(source: RelativePath, destination: RelativePath, identity: EditFileIdentity) throws {
        guard UUID(uuidString: domain)?.uuidString == domain, let folder = RelativePath(folder),
              !move.entries.isEmpty, move.entries.count <= DirectoryListing.defaultLimit,
              Set(move.entries.map(\.item)).count == move.entries.count,
              proofs.count == move.entries.count, Set(proofs.map(\.item)) == Set(move.entries.map(\.item)),
              let root = move.entries.first(where: { $0.item == move.item }), root.kind == .folder,
              let rootPath = RelativePath(root.path), !rootPath.isRoot,
              folder.appending(rootPath)?.string.utf8.elementsEqual(source.string.utf8) == true,
              ReaderMessage.isItemID(move.destinationParent),
              !move.entries.contains(where: { $0.item == move.destinationParent }),
              !move.entries.contains(where: { $0.item == root.parent }),
              let target = RelativePath(move.destinationParentPath)?.appending(move.destinationName),
              folder.appending(target)?.string.utf8.elementsEqual(destination.string.utf8) == true,
              proofs.first(where: { $0.item == root.item })?.identity == identity else {
            throw UploadError.invalidRequest
        }
        let entries = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
        let admitted = Dictionary(uniqueKeysWithValues: proofs.map { ($0.item, $0) })
        for entry in move.entries {
            guard ReaderMessage.isItemID(entry.item), entry.item != Catalog.rootItemID,
                  ReaderMessage.isItemID(entry.parent), entry.nativeID != 0, entry.size >= 0,
                  !entry.contentVersion.isEmpty, entry.contentVersion.utf8.count <= 128,
                  let path = RelativePath(entry.path),
                  folder.appending(path) != nil,
                  path.components.last?.utf8.elementsEqual(entry.name.utf8) == true,
                  let after = destinationPath(for: entry), after.components.count <= Catalog.maxDepth,
                  folder.appending(after) != nil else { throw UploadError.invalidRequest }
            if entry.item != root.item {
                guard let parent = entries[entry.parent], parent.kind == .folder,
                      RelativePath(parent.path)?.appending(entry.name)?.string.utf8
                        .elementsEqual(entry.path.utf8) == true else { throw UploadError.invalidRequest }
            }
            switch admitted[entry.item]! {
            case .directory:
                guard entry.kind == .folder else { throw UploadError.invalidRequest }
            case .file(let receipt):
                guard entry.kind == .file, receipt.version.size == entry.size,
                      !entry.contentVersion.hasPrefix("e1:") || receipt.contentVersion == entry.contentVersion else {
                    throw UploadError.invalidRequest
                }
            }
        }
        for children in Dictionary(grouping: move.entries, by: \.parent).values {
            guard Set(children.map { NameKey($0.name) }).count == children.count else {
                throw UploadError.invalidRequest
            }
        }
    }
}

public struct FolderMoveSettlement: Codable, Equatable, Sendable {
    public let domain: String
    public let settlement: CatalogFolderMoveSettlement

    public init(domain: String, settlement: CatalogFolderMoveSettlement) {
        self.domain = domain
        self.settlement = settlement
    }
}

public enum FolderMoveObservation: Sendable {
    case directory(CatalogFolderMoveObservation, identity: EditFileIdentity)
    case file(CatalogFolderMoveObservation, version: EditFileVersion)
    case removed(item: String)

    public var item: String {
        switch self {
        case .directory(let observation, _), .file(let observation, _): observation.item
        case .removed(let item): item
        }
    }
}

public struct FolderMoveRefresh: Sendable {
    public let domain: String
    public let observations: [FolderMoveObservation]
    public let listings: [CatalogFolderMoveListing]

    public init(domain: String, observations: [FolderMoveObservation], listings: [CatalogFolderMoveListing]) {
        self.domain = domain
        self.observations = observations
        self.listings = listings
    }
}

public struct FolderMoveRecoveryView: Codable, Equatable, Sendable {
    public let domain: String
    public let expected: CatalogFolderMoveState
    public let target: CatalogFolderMoveState
    public let listings: [CatalogFolderMoveListing]

    public init(domain: String, expected: CatalogFolderMoveState, target: CatalogFolderMoveState,
                listings: [CatalogFolderMoveListing]) {
        self.domain = domain
        self.expected = expected
        self.target = target
        self.listings = listings
    }
}

public struct PendingFolderMove: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder }
    public enum State: String, Codable, Sendable { case prepared, attempting, moved, verified, recovering, completed, refused }

    public let kind: Kind
    public let id: UUID
    public let owner: String
    public let metadataVersion: String
    public let source: String
    public let destination: String
    public let identity: EditFileIdentity
    public let parents: [FileRenameParent]
    public let views: [FolderMoveView]
    public var state: State = .prepared
    public var refusal: PendingFileRename.Refusal?
    public var settlements: [FolderMoveSettlement]?
    public var recovery: [FolderMoveRecoveryView]?
    public var finishedDomains: [String] = []
    public var removedDomains: [String] = []

    public var isPending: Bool { state != .completed && state != .refused }
    public var name: String { RelativePath(destination)?.components.last ?? "" }
    public var oldName: String { RelativePath(source)?.components.last ?? "" }

    public var rootRetired: Bool {
        if let recovery {
            return recovery.contains { current in
                guard let view = views.first(where: { $0.domain == current.domain }) else { return false }
                return current.target.entries.contains { $0.item == view.move.item && $0.retired }
            }
        }
        return settlements?.contains { current in
            guard let view = views.first(where: { $0.domain == current.domain }) else { return false }
            return current.settlement.resolutions.contains(.removed(item: view.move.item))
        } == true
    }

    public func requireMoved() throws {
        guard state == .completed else { throw UploadError.pendingWrites }
        guard !rootRetired else { throw SourceFailure.versionChanged }
    }

    public var destinationParents: [FileRenameParent] {
        guard let path = RelativePath(destination) else { return [] }
        let required = Set((0..<path.components.count).map {
            Data(path.components.prefix($0).joined(separator: "/").utf8)
        })
        return parents.filter { required.contains(Data($0.path.utf8)) }
    }

    func validate() throws {
        guard kind == .folder, UUID(uuidString: owner)?.uuidString == owner,
              metadataVersion.utf8.count <= 20, Int64(metadataVersion).map({ $0 >= 0 }) == true,
              let source = RelativePath(source), let destination = RelativePath(destination),
              !source.isRoot, !destination.isRoot, !source.string.utf8.elementsEqual(destination.string.utf8),
              FileRenameRequest.supportsName(oldName), FileRenameRequest.supportsName(name),
              destination.components.count <= source.components.count
                || destination.components.prefix(source.components.count).map(NameKey.init)
                    != source.components.map(NameKey.init),
              !views.isEmpty, Set(views.map(\.domain)).count == views.count,
              let ownerView = views.first(where: { $0.domain == owner }),
              ownerView.move.entries.first(where: { $0.item == ownerView.move.item })
                .map({ String($0.changeSeq) == metadataVersion }) == true,
              (state == .refused) == (refusal != nil),
              [.verified, .recovering, .completed].contains(state) == (settlements != nil),
              recovery == nil || state == .recovering || state == .completed,
              state != .recovering || recovery != nil,
              Set(finishedDomains).count == finishedDomains.count,
              Set(finishedDomains).isSubset(of: Set(views.map(\.domain))),
              finishedDomains.isEmpty || [.verified, .recovering, .completed].contains(state),
              state != .completed || Set(finishedDomains) == Set(views.map(\.domain)),
              Set(removedDomains).count == removedDomains.count,
              Set(removedDomains).isSubset(of: Set(views.map(\.domain))),
              removedDomains.isEmpty || !isPending else { throw UploadError.invalidRequest }
        let required = Set([source, destination].flatMap { path in
            (0..<path.components.count).map { Data(path.components.prefix($0).joined(separator: "/").utf8) }
        })
        guard parents.count == required.count, Set(parents.map { Data($0.path.utf8) }) == required else {
            throw UploadError.invalidRequest
        }
        for parent in parents {
            guard let path = RelativePath(parent.path),
                  parent.name.utf8.elementsEqual((path.components.last ?? "").utf8),
                  parent.identity != identity else { throw UploadError.invalidRequest }
        }
        var remaining = DirectoryListing.defaultLimit
        var physicalProofs: [[NameKey]: (path: Data, proof: CatalogFolderMoveProof)] = [:]
        for view in views {
            guard view.move.entries.count <= remaining else { throw UploadError.invalidRequest }
            remaining -= view.move.entries.count
            try view.validate(source: source, destination: destination, identity: identity)
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            for entry in view.move.entries {
                let path = RelativePath(view.folder)!.appending(RelativePath(entry.path)!)!
                let key = path.components.map(NameKey.init), exact = Data(path.string.utf8)
                let proof = proofs[entry.item]!
                if let previous = physicalProofs[key] {
                    guard previous.path == exact, previous.proof.identity == proof.identity else {
                        throw UploadError.invalidRequest
                    }
                    switch (previous.proof, proof) {
                    case (.directory, .directory): break
                    case (.file(let lhs), .file(let rhs)):
                        guard lhs.version == rhs.version else { throw UploadError.invalidRequest }
                    default: throw UploadError.invalidRequest
                    }
                }
                physicalProofs[key] = (exact, proof)
            }
        }
        if let settlements { try validateSettlements(settlements) }
        if let recovery { try validateRecovery(recovery) }
    }

    func validateUpdate(from previous: Self) throws {
        try validateAdmissionMatches(previous)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settlementUnchanged = try previous.settlements == nil
            || encoder.encode(previous.settlements) == encoder.encode(settlements)
        let replanned = try encoder.encode(previous.recovery) != encoder.encode(recovery)
        guard settlementUnchanged,
              replanned ? finishedDomains.isEmpty : Set(previous.finishedDomains).isSubset(of: Set(finishedDomains)),
              Set(previous.removedDomains).isSubset(of: Set(removedDomains)) else { throw UploadError.invalidRequest }
        let allowed: [State: Set<State>] = [
            .prepared: [.prepared, .attempting, .moved, .refused],
            .attempting: [.attempting, .moved, .refused], .moved: [.moved, .verified],
            .verified: [.verified, .recovering, .completed], .recovering: [.recovering, .completed],
            .completed: [.completed], .refused: [.refused]
        ]
        guard allowed[previous.state]?.contains(state) == true,
              previous.refusal == nil || previous.refusal == refusal else { throw UploadError.invalidRequest }
        if replanned {
            guard state == .recovering, let recovery else { throw UploadError.invalidRequest }
            try validateRecoveryTransition(recovery, from: previous)
        }
    }

    func validateAdmissionMatches(_ previous: Self) throws {
        var immutable = previous
        immutable.state = state
        immutable.refusal = refusal
        immutable.settlements = settlements
        immutable.recovery = recovery
        immutable.finishedDomains = finishedDomains
        immutable.removedDomains = removedDomains
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard try encoder.encode(immutable) == encoder.encode(self) else { throw UploadError.invalidRequest }
    }

    private func validateSettlements(_ settlements: [FolderMoveSettlement]) throws {
        enum PhysicalResolution: Equatable {
            case removed
            case preserved(EditFileIdentity, CatalogRow.Kind, UInt64, ContentFingerprint, EditFileVersion?)
            case changed(EditFileVersion, UInt64, ContentFingerprint)
        }
        guard settlements.count == views.count, Set(settlements.map(\.domain)) == Set(views.map(\.domain)) else {
            throw UploadError.invalidRequest
        }
        if settlements.contains(where: { result in
            result.settlement.resolutions.contains(.removed(item: views.first { $0.domain == result.domain }!.move.item))
        }) {
            try validateRetiredRoots(settlements.map { result in
                let view = views.first { $0.domain == result.domain }!
                guard result.settlement.proofs == view.proofs else { throw UploadError.invalidRequest }
                return (view, try CatalogFolderMoveState.settled(view.move, settlement: result.settlement),
                        result.settlement.listings)
            })
            return
        }
        var physical: [[NameKey]: PhysicalResolution] = [:]
        var knownChildren: [[NameKey]: [NameKey: CatalogFolderMoveListing.Child]] = [:]
        var completeListings: [[NameKey]: [NameKey: CatalogFolderMoveListing.Child]] = [:]
        var remaining = DirectoryListing.defaultLimit
        for result in settlements {
            let view = views.first { $0.domain == result.domain }!, move = view.move
            let settled = result.settlement
            guard settled.proofs == view.proofs, settled.resolutions.count == move.entries.count,
                  Set(settled.resolutions.map(\.item)) == Set(move.entries.map(\.item)),
                  Set(settled.listings.map(\.parent)).count == settled.listings.count else {
                throw UploadError.invalidRequest
            }
            let entries = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0) })
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            let resolutions = Dictionary(uniqueKeysWithValues: settled.resolutions.map { ($0.item, $0) })
            var versions = Set(move.entries.map(\.contentVersion))
            for proof in view.proofs {
                if case .file(let receipt) = proof { versions.insert(receipt.contentVersion) }
            }
            for resolution in settled.resolutions {
                let entry = entries[resolution.item]!
                let physicalPath = RelativePath(view.folder)!.appending(RelativePath(entry.path)!)!
                let key = physicalPath.components.map(NameKey.init)
                let parentKey = Array(key.dropLast())
                knownChildren[parentKey, default: [:]][NameKey(entry.name)] = CatalogFolderMoveListing.Child(
                    name: entry.name, identity: proofs[entry.item]!.identity, kind: entry.kind)
                let evidence: PhysicalResolution
                switch resolution {
                case .removed: evidence = .removed
                case .preserved(let after):
                    let version: EditFileVersion?
                    if case .file(let receipt) = proofs[entry.item]! { version = receipt.version }
                    else { version = nil }
                    evidence = .preserved(proofs[entry.item]!.identity, after.kind, after.nativeID,
                        ContentFingerprint(size: after.size, mtimeNs: after.mtimeNs, ctimeNs: after.ctimeNs), version)
                case .changed(let after, let receipt):
                    evidence = .changed(receipt.version, after.nativeID,
                        ContentFingerprint(size: after.size, mtimeNs: after.mtimeNs, ctimeNs: after.ctimeNs))
                }
                guard physical[key] == nil || physical[key] == evidence else { throw UploadError.invalidRequest }
                physical[key] = evidence
                let observation: CatalogFolderMoveObservation
                switch resolution {
                case .removed:
                    guard entry.item != move.item else { throw UploadError.invalidRequest }
                    continue
                case .preserved(let after):
                    guard entry.kind != .file || (after.preservesContents && after.size == entry.size) else {
                        throw UploadError.invalidRequest
                    }
                    if case .file(let receipt) = proofs[entry.item]! {
                        guard after.mtimeNs >= 0,
                              UInt64(after.mtimeNs / 1_000) == receipt.version.modifiedMicroseconds else {
                            throw UploadError.invalidRequest
                        }
                    }
                    observation = after
                case .changed(let after, let receipt):
                    guard case .file(let original) = proofs[entry.item]!, entry.kind == .file,
                          receipt.item == entry.item, receipt.version.identity == original.version.identity,
                          !receipt.version.hasSameContents(as: original.version)
                            || receipt.version.modifiedMicroseconds != original.version.modifiedMicroseconds,
                          versions.insert(receipt.contentVersion).inserted,
                          after.preservesContents == receipt.version.hasSameContents(as: original.version),
                          after.size == receipt.version.size, after.mtimeNs >= 0, after.ctimeNs >= 0,
                          UInt64(after.mtimeNs / 1_000) == receipt.version.modifiedMicroseconds,
                          UInt64(after.ctimeNs / 1_000) == receipt.version.changedMicroseconds else {
                        throw UploadError.invalidRequest
                    }
                    observation = after
                }
                guard observation.kind == entry.kind, observation.nativeID != 0, observation.size >= 0,
                      observation.preservesIdentity,
                      view.destinationPath(for: entry)?.string.utf8.elementsEqual(observation.path.utf8) == true else {
                    throw UploadError.invalidRequest
                }
                if entry.item != move.item, case .removed = resolutions[entry.parent]! {
                    throw UploadError.invalidRequest
                }
            }
            let children = Dictionary(grouping: move.entries, by: \.parent)
            for listing in settled.listings {
                guard let entry = entries[listing.parent], entry.kind == .folder, listing.complete,
                      listing.identity == proofs[entry.item]?.identity,
                      view.destinationPath(for: entry)?.string.utf8.elementsEqual(listing.path.utf8) == true,
                      listing.children.count <= remaining,
                      listing.children.allSatisfy({ RelativePath.isValidComponent($0.name) }),
                      Set(listing.children.map { NameKey($0.name) }).count == listing.children.count else {
                    throw UploadError.invalidRequest
                }
                if case .removed = resolutions[entry.item]! { throw UploadError.invalidRequest }
                remaining -= listing.children.count
                let listed = Dictionary(uniqueKeysWithValues: listing.children.map { (NameKey($0.name), $0) })
                let parentPath = RelativePath(view.folder)!.appending(RelativePath(entry.path)!)!
                let parentKey = parentPath.components.map(NameKey.init)
                if let previous = completeListings[parentKey] {
                    guard previous.count == listed.count, listed.allSatisfy({ key, child in
                        guard let old = previous[key] else { return false }
                        return old.identity == child.identity && old.kind == child.kind
                            && old.name.utf8.elementsEqual(child.name.utf8)
                    }) else { throw UploadError.invalidRequest }
                }
                completeListings[parentKey] = listed
                for child in children[entry.item] ?? [] {
                    let found = listed[NameKey(child.name)]
                    if case .removed = resolutions[child.item]! {
                        guard found?.matches(identity: proofs[child.item]!.identity, exactName: child.name) != true else {
                            throw UploadError.invalidRequest
                        }
                    } else {
                        guard let found, found.identity == proofs[child.item]!.identity, found.kind == child.kind,
                              found.name.utf8.elementsEqual(child.name.utf8) else { throw UploadError.invalidRequest }
                    }
                }
            }
            let listed = Set(settled.listings.map(\.parent))
            for entry in move.entries where entry.item != move.item {
                if case .removed = resolutions[entry.item]!,
                   case .removed = resolutions[entry.parent]! { continue }
                if case .removed = resolutions[entry.item]!, !listed.contains(entry.parent) {
                    throw UploadError.invalidRequest
                }
            }
        }
        for (parent, listed) in completeListings {
            for (key, known) in knownChildren[parent] ?? [:] {
                guard let resolution = physical[parent + [key]] else { throw UploadError.invalidRequest }
                let found = listed[key]
                if case .removed = resolution {
                    guard found?.matches(identity: known.identity, exactName: known.name) != true else {
                        throw UploadError.invalidRequest
                    }
                } else {
                    guard let found, found.identity == known.identity, found.kind == known.kind,
                          found.name.utf8.elementsEqual(known.name.utf8) else { throw UploadError.invalidRequest }
                }
            }
        }
    }
}

extension PendingFolderMove {
    private func rootRetirement(_ view: FolderMoveView, listing: CatalogFolderMoveListing) throws
        -> CatalogFolderMoveRetirement {
        guard let relative = RelativePath(view.move.destinationParentPath),
              let path = RelativePath(view.folder)?.appending(relative),
              let parent = destinationParents.first(where: { $0.path.utf8.elementsEqual(path.string.utf8) }) else {
            throw UploadError.unresolved
        }
        return try .proved(parent: view.move.destinationParent, name: view.move.destinationName,
                           identity: identity, parentIdentity: parent.identity, parentPath: relative, listing: listing)
    }

    private func validateRetiredRoots(_ targets: [(FolderMoveView, CatalogFolderMoveState, [CatalogFolderMoveListing])]) throws {
        var previous: [NameKey: CatalogFolderMoveListing.Child]?
        var remaining = DirectoryListing.defaultLimit
        for (view, target, listings) in targets {
            guard target.entries.allSatisfy(\.retired), listings.count == 1,
                  let root = target.entries.first(where: { $0.item == view.move.item }),
                  root.retirement == (try rootRetirement(view, listing: listings[0])),
                  listings[0].children.count <= remaining else { throw UploadError.unresolved }
            remaining -= listings[0].children.count
            let children = Dictionary(uniqueKeysWithValues: listings[0].children.map { (NameKey($0.name), $0) })
            if let previous {
                guard previous.count == children.count, children.allSatisfy({ key, child in
                    guard let old = previous[key] else { return false }
                    return old.identity == child.identity && old.kind == child.kind
                        && old.name.utf8.elementsEqual(child.name.utf8)
                }) else { throw UploadError.unresolved }
            }
            previous = children
        }
    }

    public func allowedCatalogStates(domain: String) throws -> [CatalogFolderMoveState] {
        guard let view = views.first(where: { $0.domain == domain }) else { throw UploadError.invalidRequest }
        var states = [try CatalogFolderMoveState.admission(view.move, proofs: view.proofs)]
        if let current = recovery?.first(where: { $0.domain == domain }) {
            for state in [current.expected, current.target] where !states.contains(state) { states.append(state) }
        } else {
            states.append(try latestTarget(domain: domain))
        }
        return states
    }

    public func latestTarget(domain: String) throws -> CatalogFolderMoveState {
        if let current = recovery?.first(where: { $0.domain == domain }) { return current.target }
        guard let view = views.first(where: { $0.domain == domain }),
              let settlement = settlements?.first(where: { $0.domain == domain }) else { throw UploadError.unresolved }
        return try CatalogFolderMoveState.settled(view.move, settlement: settlement.settlement)
    }

    private func validateRecovery(_ recovery: [FolderMoveRecoveryView]) throws {
        guard recovery.count == views.count, Set(recovery.map(\.domain)) == Set(views.map(\.domain)) else {
            throw UploadError.invalidRequest
        }
        for current in recovery {
            let view = views.first { $0.domain == current.domain }!
            let admission = try CatalogFolderMoveState.admission(view.move, proofs: view.proofs)
            try current.expected.validate(view.move, admission: admission)
            try current.target.validate(view.move, admission: admission)
            guard current.target.moved else { throw UploadError.invalidRequest }
        }
        try validateRecoveryEvidence(recovery, previousTargets: nil)
    }

    private func validateRecoveryTransition(_ recovery: [FolderMoveRecoveryView], from previous: Self) throws {
        var usedVersions = Set(views.flatMap { $0.move.entries.map(\.contentVersion) })
        var previousTargets: [String: CatalogFolderMoveState] = [:]
        for view in views {
            previousTargets[view.domain] = try previous.latestTarget(domain: view.domain)
            for state in try previous.allowedCatalogStates(domain: view.domain) {
                for entry in state.entries {
                    usedVersions.insert(entry.contentVersion)
                    if case .file(let receipt) = entry.proof { usedVersions.insert(receipt.contentVersion) }
                }
            }
        }
        for current in recovery {
            guard try previous.allowedCatalogStates(domain: current.domain).contains(current.expected),
                  let prior = previousTargets[current.domain] else { throw UploadError.unresolved }
            let before = Dictionary(uniqueKeysWithValues: prior.entries.map { ($0.item, $0) })
            for after in current.target.entries {
                let old = before[after.item]!
                if old.retired {
                    guard after == old else { throw UploadError.unresolved }
                } else if after.retired {
                    guard let witness = after.retirement, after == old.retiring(witness) else { throw UploadError.unresolved }
                } else {
                    switch (old.proof, after.proof) {
                    case (.directory, .directory):
                        guard old.proof == after.proof, old.contentVersion == after.contentVersion else {
                            throw UploadError.unresolved
                        }
                    case (.file(let original), .file(let receipt)):
                        let unchanged = receipt.version.hasSameContents(as: original.version)
                            && receipt.version.modifiedMicroseconds == original.version.modifiedMicroseconds
                        if unchanged {
                            guard receipt == original, after.contentVersion == old.contentVersion else {
                                throw UploadError.unresolved
                            }
                        } else {
                            guard receipt.version.identity == original.version.identity,
                                  after.contentVersion == receipt.contentVersion,
                                  usedVersions.insert(receipt.contentVersion).inserted else { throw UploadError.unresolved }
                        }
                    default: throw UploadError.unresolved
                    }
                }
            }
        }
        try validateRecoveryEvidence(recovery, previousTargets: previousTargets)
    }

    private func validateRecoveryEvidence(_ recovery: [FolderMoveRecoveryView],
                                          previousTargets: [String: CatalogFolderMoveState]?) throws {
        if recovery.contains(where: { current in
            let view = views.first { $0.domain == current.domain }!
            return current.target.entries.contains { $0.item == view.move.item && $0.retired }
        }) {
            try validateRetiredRoots(recovery.map { current in
                (views.first { $0.domain == current.domain }!, current.target, current.listings)
            })
            return
        }
        struct Known {
            let name: String
            let kind: CatalogRow.Kind
            let entry: CatalogFolderMoveState.Entry
            let newlyRetired: Bool
        }
        var known: [[NameKey]: Known] = [:]
        var listed: [[NameKey]: [NameKey: CatalogFolderMoveListing.Child]] = [:]
        var remaining = DirectoryListing.defaultLimit
        for current in recovery {
            let view = views.first { $0.domain == current.domain }!
            let original = Dictionary(uniqueKeysWithValues: view.move.entries.map { ($0.item, $0) })
            let target = Dictionary(uniqueKeysWithValues: current.target.entries.map { ($0.item, $0) })
            let previous = Dictionary(uniqueKeysWithValues: (previousTargets?[current.domain]?.entries ?? [])
                .map { ($0.item, $0) })
            for entry in current.target.entries where entry.retired && previous[entry.item]?.retired == false {
                let snapshot = original[entry.item]!, parent = target[snapshot.parent]!
                let witness: CatalogFolderMoveRetirement
                if parent.retired { witness = .parent(item: parent.item) }
                else {
                    guard let listing = current.listings.first(where: { $0.parent == parent.item }),
                          let path = view.destinationPath(for: original[parent.item]!) else { throw UploadError.unresolved }
                    witness = try .proved(snapshot, identity: entry.proof.identity,
                                          parentIdentity: parent.proof.identity, parentPath: path, listing: listing)
                }
                guard entry.retirement == witness else { throw UploadError.unresolved }
            }
            for entry in current.target.entries {
                let snapshot = original[entry.item]!
                let path = RelativePath(view.folder)!.appending(RelativePath(snapshot.path)!)!
                let key = path.components.map(NameKey.init)
                let value = Known(name: snapshot.name, kind: snapshot.kind, entry: entry,
                                  newlyRetired: entry.retired && previous[entry.item]?.retired == false)
                if let other = known[key] {
                    guard other.entry.retired == entry.retired, other.entry.proof.identity == entry.proof.identity,
                          other.newlyRetired == value.newlyRetired, other.kind == snapshot.kind,
                          other.name.utf8.elementsEqual(snapshot.name.utf8) else { throw UploadError.unresolved }
                    if !entry.retired {
                        guard other.entry.nativeID == entry.nativeID, other.entry.fingerprint == entry.fingerprint else {
                            throw UploadError.unresolved
                        }
                        if case .file(let lhs) = other.entry.proof, case .file(let rhs) = entry.proof {
                            guard lhs.version.hasSameContents(as: rhs.version),
                                  lhs.version.modifiedMicroseconds == rhs.version.modifiedMicroseconds else {
                                throw UploadError.unresolved
                            }
                        }
                    }
                }
                known[key] = value
            }
            guard Set(current.listings.map(\.parent)).count == current.listings.count else { throw UploadError.unresolved }
            for listing in current.listings {
                guard let before = original[listing.parent], before.kind == .folder,
                      let parent = target[listing.parent], !parent.retired, listing.complete,
                      listing.identity == parent.proof.identity,
                      view.destinationPath(for: before)?.string.utf8.elementsEqual(listing.path.utf8) == true,
                      listing.children.count <= remaining,
                      listing.children.allSatisfy({ RelativePath.isValidComponent($0.name) }),
                      Set(listing.children.map { NameKey($0.name) }).count == listing.children.count else {
                    throw UploadError.unresolved
                }
                remaining -= listing.children.count
                let path = RelativePath(view.folder)!.appending(RelativePath(before.path)!)!
                let key = path.components.map(NameKey.init)
                let children = Dictionary(uniqueKeysWithValues: listing.children.map { (NameKey($0.name), $0) })
                if let earlier = listed[key] {
                    guard earlier.count == children.count, children.allSatisfy({ name, child in
                        guard let old = earlier[name] else { return false }
                        return old.identity == child.identity && old.kind == child.kind
                            && old.name.utf8.elementsEqual(child.name.utf8)
                    }) else { throw UploadError.unresolved }
                }
                listed[key] = children
            }
        }
        for (path, child) in known {
            let parentPath = Array(path.dropLast()), key = path.last!
            if child.newlyRetired, known[parentPath]?.entry.retired == false {
                guard listed[parentPath] != nil else { throw UploadError.unresolved }
            }
            guard let listing = listed[parentPath] else { continue }
            let found = listing[key]
            if child.newlyRetired {
                guard found?.matches(identity: child.entry.proof.identity, exactName: child.name) != true else {
                    throw UploadError.unresolved
                }
            } else if !child.entry.retired {
                guard let found, found.identity == child.entry.proof.identity, found.kind == child.kind,
                      found.name.utf8.elementsEqual(child.name.utf8) else { throw UploadError.unresolved }
            }
        }
    }

    func makeRecovery(expected: [String: CatalogFolderMoveState], refreshes: [FolderMoveRefresh]) throws
        -> [FolderMoveRecoveryView] {
        guard Set(expected.keys) == Set(views.map(\.domain)), refreshes.count == views.count,
              Set(refreshes.map(\.domain)) == Set(views.map(\.domain)) else { throw UploadError.unresolved }
        return try views.map { view in
            let prior = try latestTarget(domain: view.domain), refresh = refreshes.first { $0.domain == view.domain }!
            guard try allowedCatalogStates(domain: view.domain).contains(expected[view.domain]!),
                  refresh.observations.count == view.move.entries.count,
                  Set(refresh.observations.map(\.item)) == Set(view.move.entries.map(\.item)) else {
                throw UploadError.unresolved
            }
            let observations = Dictionary(uniqueKeysWithValues: refresh.observations.map { ($0.item, $0) })
            let original = Dictionary(uniqueKeysWithValues: view.move.entries.map { ($0.item, $0) })
            let priorEntries = Dictionary(uniqueKeysWithValues: prior.entries.map { ($0.item, $0) })
            if priorEntries[view.move.item]?.retired == true {
                guard refresh.observations.allSatisfy({ if case .removed = $0 { true } else { false } }),
                      let listings = recovery?.first(where: { $0.domain == view.domain })?.listings
                        ?? settlements?.first(where: { $0.domain == view.domain })?.settlement.listings else {
                    throw UploadError.unresolved
                }
                return FolderMoveRecoveryView(domain: view.domain, expected: expected[view.domain]!,
                                              target: prior, listings: listings)
            }
            let entries = try prior.entries.map { before -> CatalogFolderMoveState.Entry in
                let observed = observations[before.item]!
                if before.retired {
                    guard case .removed = observed else { throw UploadError.unresolved }
                    return before
                }
                let after: CatalogFolderMoveObservation, proof: CatalogFolderMoveProof, version: String
                switch observed {
                case .removed:
                    let entry = original[before.item]!
                    if entry.item == view.move.item {
                        guard let listing = refresh.listings.first(where: { $0.parent == view.move.destinationParent }) else {
                            throw UploadError.unresolved
                        }
                        return before.retiring(try rootRetirement(view, listing: listing))
                    }
                    guard let parent = priorEntries[entry.parent] else { throw UploadError.unresolved }
                    if case .removed = observations[parent.item]! {
                        return before.retiring(.parent(item: parent.item))
                    }
                    guard let listing = refresh.listings.first(where: { $0.parent == parent.item }),
                          let path = view.destinationPath(for: original[parent.item]!) else { throw UploadError.unresolved }
                    return before.retiring(try .proved(entry, identity: before.proof.identity,
                        parentIdentity: parent.proof.identity, parentPath: path, listing: listing))
                case .directory(let value, let identity):
                    guard original[before.item]!.kind == .folder, identity == before.proof.identity else {
                        throw UploadError.unresolved
                    }
                    after = value
                    proof = before.proof
                    version = before.contentVersion
                case .file(let value, let fresh):
                    guard case .file(let base) = before.proof, original[before.item]!.kind == .file,
                          fresh.identity == base.version.identity, value.size == fresh.size,
                          value.mtimeNs >= 0, value.ctimeNs >= 0,
                          UInt64(value.mtimeNs / 1_000) == fresh.modifiedMicroseconds,
                          UInt64(value.ctimeNs / 1_000) == fresh.changedMicroseconds,
                          value.preservesContents == fresh.hasSameContents(as: base.version) else {
                        throw UploadError.unresolved
                    }
                    after = value
                    if fresh.hasSameContents(as: base.version)
                        && fresh.modifiedMicroseconds == base.version.modifiedMicroseconds {
                        proof = before.proof
                        version = before.contentVersion
                    } else {
                        let receipt = try EditBaseReceipt(item: before.item, version: fresh)
                        proof = .file(receipt)
                        version = receipt.contentVersion
                    }
                }
                guard after.kind == original[before.item]!.kind, after.nativeID != 0, after.size >= 0,
                      after.preservesIdentity,
                      view.destinationPath(for: original[before.item]!)?.string.utf8.elementsEqual(after.path.utf8) == true else {
                    throw UploadError.unresolved
                }
                return CatalogFolderMoveState.Entry(item: before.item, nativeID: after.nativeID,
                    fingerprint: ContentFingerprint(size: after.size, mtimeNs: after.mtimeNs, ctimeNs: after.ctimeNs),
                    contentVersion: version, proof: proof)
            }
            return FolderMoveRecoveryView(domain: view.domain, expected: expected[view.domain]!,
                target: CatalogFolderMoveState(moved: true, entries: entries), listings: refresh.listings)
        }
    }
}

extension FileRenameOutbox {
    func reloadFolder(_ record: PendingFolderMove) throws -> PendingFolderMove {
        guard let intent = try intents().first(where: { $0.id == record.id }),
              case .folder(let durable) = intent else { throw UploadError.unresolved }
        try record.validateAdmissionMatches(durable)
        // A previous rename may be visible even though syncing its directory failed.
        try syncDirectory()
        return durable
    }

    public func replayFolder(owner: String, request: FileRenameRequest) throws -> PendingFolderMove? {
        let inventory = try intents()
        for intent in inventory {
            if case .folder(let record) = intent, record.owner == owner, record.state != .refused,
               !record.removedDomains.contains(owner), record.metadataVersion == request.metadataVersion,
               record.name.utf8.elementsEqual(request.name.utf8),
               let view = record.views.first(where: { $0.domain == owner }),
               view.move.item == request.item, view.move.destinationParent == request.parent,
               view.move.entries.first(where: { $0.item == request.item })?.contentVersion == request.contentVersion {
                return record
            }
        }
        guard !inventory.contains(where: { $0.isPending && $0.domains.contains(owner) }) else {
            throw UploadError.pendingWrites
        }
        return nil
    }

    public func prepareFolder(owner: String, request: FileRenameRequest, source: RelativePath,
                              destination: RelativePath, identity: EditFileIdentity,
                              parents: [FileRenameParent], views: [FolderMoveView]) throws -> PendingFolderMove {
        if let existing = try replayFolder(owner: owner, request: request) { return existing }
        guard let view = views.first(where: { $0.domain == owner }), view.move.item == request.item,
              view.move.destinationParent == request.parent,
              let root = view.move.entries.first(where: { $0.item == request.item }),
              root.contentVersion == request.contentVersion, String(root.changeSeq) == request.metadataVersion,
              request.changesName || root.name.utf8.elementsEqual(request.name.utf8),
              request.changesParent || root.parent == request.parent,
              destination.components.last?.utf8.elementsEqual(request.name.utf8) == true else {
            throw UploadError.invalidRequest
        }
        guard !((try intents()).contains { intent in
            intent.isPending && !Set(intent.domains).isDisjoint(with: Set(views.map(\.domain)))
        }) else { throw UploadError.pendingWrites }
        let record = PendingFolderMove(kind: .folder, id: UUID(), owner: owner,
                                       metadataVersion: request.metadataVersion, source: source.string,
                                       destination: destination.string, identity: identity, parents: parents, views: views)
        try save(record)
        return record
    }
}

public struct FolderMoveEvidence: Sendable {
    public let identity: EditFileIdentity
    public let name: String

    public init(identity: EditFileIdentity, name: String) {
        self.identity = identity
        self.name = name
    }
}

public protocol FolderMoveRemote {
    func protectFolderMoveParents(source: String, destination: String) throws -> [FileRenameParent]
    // Nil requires definitive absence; a non-directory destination throws collision.
    func inspectFolderMoveRoot(path: String) throws -> FolderMoveEvidence?
    func releaseFolderMoveRoot(path: String) throws
    // Recheck every admission proof under protection, including complete file contents.
    func verifyFolderMoveSource(_ record: PendingFolderMove) throws
    // Close descendants before rename; retain the root and both external ancestor chains.
    func releaseFolderMoveDescendants() throws
    // Rename the guarded root handle without replacing a destination or copying any contents.
    func moveFolder(source: String, destination: String) throws
    func settleFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveSettlement]
    // Lost protection requires fresh full proof of the immutable settlement before local replay.
    func verifyFolderMoveSettlement(_ record: PendingFolderMove) throws
    func refreshFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveRefresh]
    func verifyFolderMoveRecovery(_ record: PendingFolderMove) throws
}

public enum FolderMoveTransaction {
    // Completed replay is a no-op; callers must never reapply its original settlement.
    public static func publish(_ record: inout PendingFolderMove, outbox: FileRenameOutbox,
                               remote: FolderMoveRemote,
                               checkpoint: (PendingFolderMove.State) throws -> Void = { _ in }) throws {
        record = try outbox.reloadFolder(record)
        try record.validate()
        if record.state == .completed { return }
        if record.state == .refused { throw refusalError(record.refusal) }
        let awaitingMove = record.state == .prepared || record.state == .attempting
        guard try remote.protectFolderMoveParents(source: awaitingMove ? record.source : record.destination,
                                                  destination: record.destination)
            == (awaitingMove ? record.parents : record.destinationParents) else { throw UploadError.unresolved }
        if !awaitingMove {
            try settle(&record, outbox: outbox, remote: remote, checkpoint: checkpoint)
            return
        }
        let destination = try inspectDestination(record.destination, remote: remote)
        let target = destination.evidence
        if let target, target.identity == record.identity, target.name.utf8.elementsEqual(record.name.utf8) {
            try settle(&record, outbox: outbox, remote: remote, checkpoint: checkpoint)
            return
        }
        guard record.state == .prepared || record.state == .attempting else { throw UploadError.unresolved }
        try remote.releaseFolderMoveRoot(path: record.destination)
        guard let source = try remote.inspectFolderMoveRoot(path: record.source),
              source.identity == record.identity, source.name.utf8.elementsEqual(record.oldName.utf8) else {
            if record.state == .prepared { try refuse(&record, .changed, outbox: outbox) }
            throw UploadError.unresolved
        }
        if destination.collision || target.map({ $0.identity != record.identity }) == true {
            try refuse(&record, .collision, outbox: outbox)
        }
        do { try remote.verifyFolderMoveSource(record) }
        catch SourceFailure.versionChanged {
            if record.state == .prepared { try refuse(&record, .changed, outbox: outbox) }
            throw SourceFailure.versionChanged
        }
        record.state = .attempting
        try outbox.save(record)
        try checkpoint(.attempting)
        try remote.releaseFolderMoveDescendants()
        do { try remote.moveFolder(source: record.source, destination: record.destination) }
        catch {
            // Even an error reply is not a refusal until fresh evidence excludes remote success.
            let destination = try inspectDestination(record.destination, remote: remote)
            if let after = destination.evidence,
               after.identity == record.identity, after.name.utf8.elementsEqual(record.name.utf8) {
                try settle(&record, outbox: outbox, remote: remote, checkpoint: checkpoint)
                return
            }
            let reason: PendingFileRename.Refusal?
            let failure = error as NSError
            if destination.collision || error as? UploadError == .collision
                || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST)) { reason = .collision }
            else if failure.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM), Int(ENOTSUP), Int(EINVAL), Int(EXDEV)].contains(failure.code) {
                reason = .unsupported
            } else { reason = nil }
            try remote.releaseFolderMoveRoot(path: record.destination)
            if let reason, let intact = try remote.inspectFolderMoveRoot(path: record.source),
               intact.identity == record.identity, intact.name.utf8.elementsEqual(record.oldName.utf8) {
                try refuse(&record, reason, outbox: outbox)
            }
            throw error
        }
        guard let after = try remote.inspectFolderMoveRoot(path: record.destination),
              after.identity == record.identity, after.name.utf8.elementsEqual(record.name.utf8) else {
            throw UploadError.unresolved
        }
        try settle(&record, outbox: outbox, remote: remote, checkpoint: checkpoint)
    }

    private static func settle(_ record: inout PendingFolderMove, outbox: FileRenameOutbox,
                               remote: FolderMoveRemote,
                               checkpoint: (PendingFolderMove.State) throws -> Void) throws {
        if record.state == .verified {
            try remote.verifyFolderMoveSettlement(record)
            return
        }
        if record.state == .recovering {
            try remote.verifyFolderMoveRecovery(record)
            return
        }
        record.state = .moved
        try outbox.save(record)
        try checkpoint(.moved)
        var settled = record
        settled.settlements = try remote.settleFolderMove(record)
        settled.state = .verified
        try outbox.save(settled)
        record = settled
        try checkpoint(.verified)
    }

    private static func inspectDestination(_ path: String, remote: FolderMoveRemote) throws
        -> (evidence: FolderMoveEvidence?, collision: Bool) {
        do { return (try remote.inspectFolderMoveRoot(path: path), false) }
        catch UploadError.collision { return (nil, true) }
    }

    public static func replan(_ record: inout PendingFolderMove, outbox: FileRenameOutbox,
                              expected: [String: CatalogFolderMoveState], remote: FolderMoveRemote,
                              checkpoint: (PendingFolderMove.State) throws -> Void = { _ in }) throws {
        record = try outbox.reloadFolder(record)
        guard record.state == .verified || record.state == .recovering,
              try remote.protectFolderMoveParents(source: record.destination, destination: record.destination)
                == record.destinationParents else { throw UploadError.unresolved }
        var planned = record
        planned.recovery = try record.makeRecovery(expected: expected, refreshes: remote.refreshFolderMove(record))
        planned.state = .recovering
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if try encoder.encode(planned.recovery) != encoder.encode(record.recovery) { planned.finishedDomains = [] }
        try outbox.save(planned)
        record = planned
        try checkpoint(.recovering)
    }

    // Catalog, keeps and replay bookkeeping for this domain must all be durable first.
    public static func finishDomain(_ domain: String, record: inout PendingFolderMove,
                                    outbox: FileRenameOutbox) throws {
        record = try outbox.reloadFolder(record)
        guard [.verified, .recovering, .completed].contains(record.state),
              record.views.contains(where: { $0.domain == domain }) else { throw UploadError.invalidRequest }
        var updated = record
        if !updated.finishedDomains.contains(domain) { updated.finishedDomains.append(domain) }
        if Set(updated.finishedDomains) == Set(updated.views.map(\.domain)) { updated.state = .completed }
        try outbox.save(updated)
        record = updated
    }

    private static func refuse(_ record: inout PendingFolderMove, _ reason: PendingFileRename.Refusal,
                               outbox: FileRenameOutbox) throws -> Never {
        record.state = .refused
        record.refusal = reason
        try outbox.save(record)
        throw refusalError(reason)
    }

    private static func refusalError(_ reason: PendingFileRename.Refusal?) -> Error {
        switch reason {
        case .collision: return UploadError.collision
        case .changed: return SourceFailure.versionChanged
        case .unsupported: return CocoaError(.featureUnsupported)
        case nil: return UploadError.unresolved
        }
    }
}
