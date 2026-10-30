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
        guard let root = move.entries.first(where: { $0.item == move.item }),
              let source = RelativePath(root.path), let path = RelativePath(entry.path),
              let target = RelativePath(move.destinationParentPath)?.appending(move.destinationName),
              path.components.count >= source.components.count,
              path.components.prefix(source.components.count).joined(separator: "/")
                .utf8.elementsEqual(source.string.utf8),
              let suffix = RelativePath(path.components.dropFirst(source.components.count).joined(separator: "/")) else {
            return nil
        }
        return target.appending(suffix)
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

public struct PendingFolderMove: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder }
    public enum State: String, Codable, Sendable { case prepared, attempting, moved, verified, completed, refused }

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
    public var finishedDomains: [String] = []
    public var removedDomains: [String] = []

    public var isPending: Bool { state != .completed && state != .refused }
    public var name: String { RelativePath(destination)?.components.last ?? "" }
    public var oldName: String { RelativePath(source)?.components.last ?? "" }

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
              (state == .verified || state == .completed) == (settlements != nil),
              Set(finishedDomains).count == finishedDomains.count,
              Set(finishedDomains).isSubset(of: Set(views.map(\.domain))),
              finishedDomains.isEmpty || state == .verified || state == .completed,
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
    }

    func validateUpdate(from previous: Self) throws {
        try validateAdmissionMatches(previous)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settlementUnchanged = try previous.settlements == nil
            || encoder.encode(previous.settlements) == encoder.encode(settlements)
        guard settlementUnchanged,
              Set(previous.finishedDomains).isSubset(of: Set(finishedDomains)),
              Set(previous.removedDomains).isSubset(of: Set(removedDomains)) else { throw UploadError.invalidRequest }
        let allowed: [State: Set<State>] = [
            .prepared: [.prepared, .attempting, .moved, .refused],
            .attempting: [.attempting, .moved, .refused], .moved: [.moved, .verified],
            .verified: [.verified, .completed], .completed: [.completed], .refused: [.refused]
        ]
        guard allowed[previous.state]?.contains(state) == true,
              previous.refusal == nil || previous.refusal == refusal else { throw UploadError.invalidRequest }
    }

    func validateAdmissionMatches(_ previous: Self) throws {
        var immutable = previous
        immutable.state = state
        immutable.refusal = refusal
        immutable.settlements = settlements
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
        var physical: [[NameKey]: PhysicalResolution] = [:]
        var knownChildren: [[NameKey]: [NameKey: CatalogFolderMoveListing.Child]] = [:]
        var completeListings: [[NameKey]: [NameKey: CatalogFolderMoveListing.Child]] = [:]
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
                    observation = after
                case .changed(let after, let receipt):
                    guard case .file(let original) = proofs[entry.item]!, entry.kind == .file,
                          receipt.item == entry.item, receipt.version.identity == original.version.identity,
                          !receipt.version.hasSameContents(as: original.version),
                          versions.insert(receipt.contentVersion).inserted, !after.preservesContents,
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
            var remaining = DirectoryListing.defaultLimit
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
                        guard found?.identity != proofs[child.item]!.identity else { throw UploadError.invalidRequest }
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
                    guard found?.identity != known.identity else { throw UploadError.invalidRequest }
                } else {
                    guard let found, found.identity == known.identity, found.kind == known.kind,
                          found.name.utf8.elementsEqual(known.name.utf8) else { throw UploadError.invalidRequest }
                }
            }
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
    // Fresh exact spelling and directory identity; nil requires definitive name absence.
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
}

public enum FolderMoveTransaction {
    public static func publish(_ record: inout PendingFolderMove, outbox: FileRenameOutbox,
                               remote: FolderMoveRemote,
                               checkpoint: (PendingFolderMove.State) throws -> Void = { _ in }) throws {
        record = try outbox.reloadFolder(record)
        try record.validate()
        if record.state == .completed { return }
        if record.state == .refused { throw refusalError(record.refusal) }
        guard try remote.protectFolderMoveParents(source: record.source, destination: record.destination)
            == record.parents else { throw UploadError.unresolved }
        let target = try remote.inspectFolderMoveRoot(path: record.destination)
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
        if let target, target.identity != record.identity { try refuse(&record, .collision, outbox: outbox) }
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
            if let after = try remote.inspectFolderMoveRoot(path: record.destination),
               after.identity == record.identity, after.name.utf8.elementsEqual(record.name.utf8) {
                try settle(&record, outbox: outbox, remote: remote, checkpoint: checkpoint)
                return
            }
            let reason: PendingFileRename.Refusal?
            let failure = error as NSError
            if error as? UploadError == .collision
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

    // Catalog, keeps and replay bookkeeping for this domain must all be durable first.
    public static func finishDomain(_ domain: String, record: inout PendingFolderMove,
                                    outbox: FileRenameOutbox) throws {
        record = try outbox.reloadFolder(record)
        guard record.state == .verified || record.state == .completed,
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
