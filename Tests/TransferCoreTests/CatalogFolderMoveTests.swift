import Foundation
import XCTest
@testable import TransferCore

final class CatalogFolderMoveTests: XCTestCase {
    private typealias Parsed = DirectoryListing.Parsed
    private let root = Catalog.rootItemID
    private var directory: URL!
    private var catalog: Catalog!
    private var inbox: CatalogRow!
    private var archive: CatalogRow!
    private var kept: CatalogRow!
    private var tree: CatalogRow!
    private var nested: CatalogRow!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        catalog = try Catalog.create(at: directory.appending(path: "catalog.sqlite"), domainID: "domain-A",
                                     rootName: "Location")
        try list(root, [folder("Inbox", 1), folder("Archive", 2), folder("Kept", 3),
                        folder("Unlisted", 4), file("neighbor", 5)])
        inbox = try child(root, "Inbox")
        archive = try child(root, "Archive")
        kept = try child(root, "Kept")
        try list(inbox.id, [folder("Tree", 10), folder("ZOther", 11)])
        tree = try child(inbox.id, "Tree")
        try list(tree.id, [file("plain", 20), file("explicit", 21), folder("Nested", 22)])
        nested = try child(tree.id, "Nested")
        try list(nested.id, [file("deep", 30)])
        try list(archive.id, [])
        try list(kept.id, [])
    }

    override func tearDownWithError() throws {
        catalog = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testPopulatedMovePreservesIDsVersionsAndEnumerationKeys() throws {
        try catalog.setWriteAccess(creation: true, editing: true)
        let verified = try child(nested.id, "deep")
        let receipt = try EditBaseReceipt(item: verified.id, version: EditFileVersion(
            identity: EditFileIdentity(fileID: 30, birthMicroseconds: 100), size: verified.size,
            digest: String(repeating: "a", count: 64), modifiedMicroseconds: 1, changedMicroseconds: 2,
            attributes: 32, security: Data([1])))
        try catalog.rememberEditBase(receipt, expectedVersion: verified.contentVersion)
        let move = try prepare()
        let keys = try rows("SELECT id || '|' || enumeration_key FROM items ORDER BY row")
        let evidence = try observations(move)
        try catalog.commitFolderMove(move, observations: evidence)
        for before in move.entries {
            let after = try XCTUnwrap(catalog.item(id: before.item))
            XCTAssertEqual(after.contentVersion, before.contentVersion)
            XCTAssertEqual(after.keepRequested, before.keepRequested)
            XCTAssertEqual(after.parentID, before.item == tree.id ? archive.id : before.parent)
            XCTAssertEqual(try catalog.remoteIdentity(before.item), before.nativeID + 1_000)
            XCTAssertEqual(after.ctimeNs, before.ctimeNs + 100)
            if before.kind == .file { XCTAssertEqual(after.editVersion, before.contentVersion) }
        }
        XCTAssertEqual(try rows("SELECT id || '|' || enumeration_key FROM items ORDER BY row"), keys)
        XCTAssertEqual(try catalog.relativePath(of: verified.id)?.string, "Archive/Moved/Nested/deep")
        XCTAssertEqual(try catalog.item(id: verified.id)?.contentVersion, receipt.contentVersion)
        XCTAssertEqual(try catalog.item(id: tree.id)?.contentVersion, "d1")
        XCTAssertEqual(try catalog.counts().tombstones, 0)
    }

    func testEmptyRenameAndCaseOnlyRename() throws {
        let empty = try child(inbox.id, "ZOther")
        let move = try catalog.prepareFolderMove(item: empty.id, destinationParent: inbox.id, destinationName: "zother")
        XCTAssertEqual(move.entries.count, 1)
        let anchor = try catalog.currentAnchor()
        try catalog.commitFolderMove(move, observations: observations(move))
        XCTAssertEqual(try catalog.item(id: empty.id)?.name, "zother")
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 10, scope: .parent(inbox.id)).updated.map(\.id), [empty.id])
        XCTAssertTrue(try rows("SELECT item FROM departures").isEmpty)
        let moved = try catalog.prepareFolderMove(item: empty.id, destinationParent: archive.id, destinationName: "Empty")
        try catalog.commitFolderMove(moved, observations: observations(moved))
        XCTAssertEqual(try catalog.relativePath(of: empty.id)?.string, "Archive/Empty")
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 10, scope: .parent(inbox.id)).updated.map(\.id), [empty.id])
    }

    func testPopulatedRenameKeepsDescendantParents() throws {
        let move = try prepare(to: inbox.id, name: "Renamed")
        try catalog.commitFolderMove(move, observations: observations(move))
        for entry in move.entries {
            XCTAssertEqual(try catalog.item(id: entry.item)?.parentID, entry.parent)
            XCTAssertEqual(try catalog.item(id: entry.item)?.contentVersion, entry.contentVersion)
        }
        XCTAssertEqual(try catalog.relativePath(of: nested.id)?.string, "Inbox/Renamed/Nested")
        XCTAssertTrue(try rows("SELECT item FROM departures").isEmpty)
    }

    func testNestedExplicitKeepsAndDestinationInheritance() throws {
        let explicit = try child(tree.id, "explicit"), plain = try child(tree.id, "plain")
        let deep = try child(nested.id, "deep")
        try catalog.setKeep(ids: [explicit.id, nested.id, kept.id], value: true)
        let incoming = try prepare(to: kept.id)
        try catalog.commitFolderMove(incoming, observations: observations(incoming))
        for entry in incoming.entries { XCTAssertTrue(try XCTUnwrap(catalog.item(id: entry.item)).keep) }
        XCTAssertFalse(try XCTUnwrap(catalog.item(id: tree.id)).keepRequested)
        let outgoing = try prepare(to: archive.id, name: "Left")
        try catalog.commitFolderMove(outgoing, observations: observations(outgoing))
        for id in [tree.id, plain.id] { XCTAssertFalse(try XCTUnwrap(catalog.item(id: id)).keep) }
        for id in [explicit.id, nested.id, deep.id] { XCTAssertTrue(try XCTUnwrap(catalog.item(id: id)).keep) }
        XCTAssertEqual(Set(try catalog.keepRequests().map(\.id)), [explicit.id, nested.id, kept.id])
    }

    func testPathDerivedNativeIDsSurviveTheNextListing() throws {
        let move = try prepare(), evidence = try observations(move)
        try catalog.commitFolderMove(move, observations: evidence)
        let versions = Dictionary(uniqueKeysWithValues: move.entries.map { ($0.item, $0.contentVersion) })
        for parent in [archive.id, tree.id, nested.id] {
            let children = evidence.filter { observation in
                move.entries.first { $0.item == observation.item }!.parent == parent
                    || (parent == archive.id && observation.item == tree.id)
            }.map { observed -> Parsed in
                .entry(.init(name: RelativePath(observed.path)!.components.last!,
                             kind: observed.kind == .file ? .file : .folder, size: observed.size,
                             mtimeNs: observed.mtimeNs, ctimeNs: observed.ctimeNs, fileID: observed.nativeID))
            }
            let plan = try list(parent, children)
            XCTAssertEqual(plan.updated, 0)
            XCTAssertEqual(plan.inserted, 0)
            XCTAssertEqual(plan.tombstoned, 0)
        }
        for (id, version) in versions { XCTAssertEqual(try catalog.item(id: id)?.contentVersion, version) }
    }

    func testOfflineAvailabilityRequiresFreshMembershipAndTheNewChild() throws {
        try catalog.setKeep(ids: [tree.id], value: true)
        let move = try prepare(), evidence = try observations(move)
        var files = Dictionary(uniqueKeysWithValues: move.entries.filter { $0.kind == .file }
            .map { ($0.item, OfflineState.availableOffline) })
        let folders: Set<String> = [tree.id, nested.id]
        XCTAssertEqual(try catalog.keepSnapshot().states(files: files, folders: folders)[tree.id], .availableOffline)

        try catalog.commitFolderMove(move, observations: evidence)
        for id in folders { XCTAssertFalse(try XCTUnwrap(catalog.item(id: id)).listingComplete) }
        XCTAssertEqual(try catalog.keepSnapshot().states(files: files, folders: folders)[tree.id], .requested)
        let committed = try dump()
        try catalog.commitFolderMove(move, observations: evidence)
        XCTAssertEqual(try dump(), committed)

        for parent in [tree.id, nested.id] {
            var children = evidence.filter { observation in
                move.entries.first { $0.item == observation.item }!.parent == parent
            }.map { observed -> Parsed in
                .entry(.init(name: RelativePath(observed.path)!.components.last!,
                             kind: observed.kind == .file ? .file : .folder, size: observed.size,
                             mtimeNs: observed.mtimeNs, ctimeNs: observed.ctimeNs, fileID: observed.nativeID))
            }
            // This remote arrival was absent from the admission snapshot.
            if parent == nested.id { children.append(file("arrived", 5_000)) }
            try list(parent, children)
            XCTAssertEqual(try catalog.keepSnapshot().states(files: files, folders: folders)[tree.id], .requested)
        }
        for id in folders { XCTAssertTrue(try XCTUnwrap(catalog.item(id: id)).listingComplete) }
        let arrived = try child(nested.id, "arrived")
        XCTAssertTrue(arrived.keep)
        files[arrived.id] = .availableOffline
        XCTAssertEqual(try catalog.keepSnapshot().states(files: files, folders: folders)[tree.id], .availableOffline)
    }

    func testIncompleteDuplicateOrChangedEvidenceWritesNothing() throws {
        let move = try prepare(), evidence = try observations(move)
        try refuses(move, Array(evidence.dropLast()))
        try refuses(move, evidence + [evidence[0]])
        let data = try XCTUnwrap(evidence.first { $0.kind == .file })
        for changed in [
            observation(data, preservesContents: false), observation(data, size: data.size + 1),
            observation(data, preservesIdentity: false),
            observation(data, nativeID: 0), observation(data, kind: .folder),
            observation(data, path: "Archive/Moved/wrong")
        ] {
            try refuses(move, evidence.map { $0.item == data.item ? changed : $0 })
        }
        let directory = try XCTUnwrap(evidence.first { $0.item == nested.id })
        try refuses(move, evidence.map {
            $0.item == directory.item ? observation($0, preservesIdentity: false) : $0
        })
        let incomplete = CatalogFolderMove(item: move.item, destinationParent: move.destinationParent,
            destinationName: move.destinationName, destinationParentPath: RelativePath(move.destinationParentPath)!,
            entries: move.entries.filter { $0.item != data.item })
        try refuses(incomplete, evidence.filter { $0.item != data.item })
    }

    func testStaleDescendantAndNewChildRefuseTheWholeMove() throws {
        let move = try prepare(), evidence = try observations(move)
        let plain = try child(tree.id, "plain")
        try catalog.updateFingerprint(item: plain.id, fingerprint: .init(size: 10, mtimeNs: 9, ctimeNs: 2), fileID: 20)
        try refuses(move, evidence)
        let fresh = try prepare(), observed = try observations(fresh)
        try list(nested.id, [file("deep", 30), file("new", 31)])
        try refuses(fresh, observed)
        let beforeDeletion = try prepare(), beforeEvidence = try observations(beforeDeletion)
        try list(nested.id, [])
        try refuses(beforeDeletion, beforeEvidence)
    }

    func testPolicyChangesDoNotHideSameFingerprintNativeReplacement() throws {
        let move = try prepare(), evidence = try observations(move)
        try catalog.setKeep(ids: [nested.id], value: true)
        try catalog.setPaused(true)
        try list(nested.id, [file("deep", 300)])
        try refuses(move, evidence)
    }

    func testNamespaceAndListingChangesStillInvalidateAdmission() throws {
        let move = try prepare(), evidence = try observations(move)
        let plain = try child(tree.id, "plain")
        let rename = try CatalogFileMove(item: plain.id, sourceParent: tree.id, sourceName: plain.name,
            contentVersion: plain.contentVersion, sourceNativeID: 20,
            destinationParent: tree.id, destinationName: "renamed")
        try catalog.commitFileMove(rename,
            fingerprint: .init(size: plain.size, mtimeNs: plain.mtimeNs, ctimeNs: plain.ctimeNs), nativeID: 20)
        try refuses(move, evidence)
        let fresh = try prepare(), observed = try observations(fresh)
        try list(nested.id, [file("deep", 30)])
        try refuses(fresh, observed)
    }

    func testCurrentExplicitKeepsSurviveCommitAndReplay() throws {
        let explicit = try child(tree.id, "explicit"), plain = try child(tree.id, "plain")
        try catalog.setKeep(ids: [explicit.id, nested.id], value: true)
        let move = try prepare(), evidence = try observations(move)
        try catalog.setKeep(ids: [explicit.id, nested.id], value: false)
        try catalog.setKeep(ids: [plain.id], value: true)
        try catalog.commitFolderMove(move, observations: evidence)
        XCTAssertEqual(Set(try catalog.keepRequests().map(\.id)), [plain.id])
        XCTAssertEqual(Set(try catalog.keptItems().map(\.id)), [plain.id])

        try catalog.setKeep(ids: [tree.id], value: true)
        try catalog.setKeep(ids: [plain.id], value: false)
        let current = try dump()
        try catalog.commitFolderMove(move, observations: evidence)
        XCTAssertEqual(try dump(), current)
        XCTAssertEqual(Set(try catalog.keepRequests().map(\.id)), [tree.id])
        XCTAssertEqual(Set(try catalog.keptItems().map(\.id)), Set(move.entries.map(\.item)))
    }

    func testCurrentAncestorKeepsDetermineInheritanceAtCommitAndReplay() throws {
        let move = try prepare(), evidence = try observations(move)
        try catalog.setKeep(ids: [inbox.id], value: true)
        try catalog.commitFolderMove(move, observations: evidence)
        for entry in move.entries { XCTAssertFalse(try XCTUnwrap(catalog.item(id: entry.item)).keep) }

        let next = try prepare(to: kept.id), observed = try observations(next)
        try catalog.setKeep(ids: [kept.id], value: true)
        try catalog.commitFolderMove(next, observations: observed)
        for entry in next.entries {
            let row = try XCTUnwrap(catalog.item(id: entry.item))
            XCTAssertTrue(row.keep)
            XCTAssertFalse(row.keepRequested)
        }
        try catalog.setKeep(ids: [kept.id], value: false)
        let current = try dump()
        try catalog.commitFolderMove(next, observations: observed)
        XCTAssertEqual(try dump(), current)
        for entry in next.entries { XCTAssertFalse(try XCTUnwrap(catalog.item(id: entry.item)).keep) }
    }

    func testPauseChangesDoNotPreventCommitOrReplay() throws {
        try catalog.setKeep(ids: [tree.id], value: true)
        let move = try prepare(), evidence = try observations(move)
        try catalog.setPaused(true)
        try catalog.commitFolderMove(move, observations: evidence)
        for entry in move.entries {
            let row = try XCTUnwrap(catalog.item(id: entry.item))
            XCTAssertTrue(row.paused)
            XCTAssertEqual(row.contentVersion, entry.contentVersion)
        }
        try catalog.setPaused(false)
        let current = try dump()
        try catalog.commitFolderMove(move, observations: evidence)
        XCTAssertEqual(try dump(), current)
        for entry in move.entries { XCTAssertFalse(try XCTUnwrap(catalog.item(id: entry.item)).paused) }
    }

    func testDeparturesPaginationAndRepeatedMoves() throws {
        let anchor = try catalog.currentAnchor()
        let page = try catalog.folderPage(inbox.id, token: nil, size: 1)
        XCTAssertEqual(page.rows.map(\.id), [tree.id])
        let move = try prepare()
        try catalog.commitFolderMove(move, observations: observations(move))
        let first = try catalog.changes(after: anchor, limit: 1, scope: .parent(inbox.id))
        XCTAssertEqual(first.updated.map(\.id), [tree.id])
        XCTAssertTrue(first.deletedIDs.isEmpty)
        XCTAssertEqual(CatalogCursor.anchorSeq(first.anchor, epoch: catalog.epoch, lastSeq: .max),
                       try catalog.item(id: tree.id)?.changeSeq)
        XCTAssertEqual(try catalog.folderPage(inbox.id, token: XCTUnwrap(page.next), size: 10).rows.map(\.name), ["ZOther"])
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .parent(archive.id)).updated.map(\.id), [tree.id])
        XCTAssertEqual(Set(try rows("SELECT item FROM departures")), [tree.id])
        for parent in [kept.id, inbox.id, archive.id] {
            let next = try prepare(to: parent)
            try catalog.commitFolderMove(next, observations: observations(next))
        }
        for parent in [inbox.id, archive.id, kept.id] {
            let changes = try catalog.changes(after: anchor, limit: 100, scope: .parent(parent))
            XCTAssertEqual(changes.updated.map(\.id), [tree.id])
            XCTAssertTrue(changes.deletedIDs.isEmpty)
        }
        XCTAssertEqual(Set(try rows("SELECT parent FROM departures")), [inbox.id, kept.id])
    }

    func testExactRepeatIsIdempotentAndChangedRepeatIsRefused() throws {
        let move = try prepare(), evidence = try observations(move)
        let encoded = try JSONEncoder().encode(move)
        let restored = try JSONDecoder().decode(CatalogFolderMove.self, from: encoded)
        XCTAssertEqual(restored, move)
        let decodedEvidence = try JSONDecoder().decode([CatalogFolderMoveObservation].self,
                                                       from: JSONEncoder().encode(evidence))
        try catalog.commitFolderMove(restored, observations: decodedEvidence)
        let completed = try dump()
        try catalog.commitFolderMove(restored, observations: decodedEvidence)
        XCTAssertEqual(try dump(), completed)
        try refuses(move, evidence.map { observation($0, nativeID: $0.nativeID + 1) })
    }

    func testCyclesCollisionsAndInvalidDestinationsWriteNothing() throws {
        let move = try prepare(), evidence = try observations(move)
        let unlisted = try child(root, "Unlisted"), file = try child(root, "neighbor")
        for parent in [tree.id, nested.id, unlisted.id, file.id, UUID().uuidString] {
            let invalid = CatalogFolderMove(item: tree.id, destinationParent: parent, destinationName: "Moved",
                destinationParentPath: (try catalog.relativePath(of: parent)) ?? .root, entries: move.entries)
            try refuses(invalid, evidence)
        }
        try list(archive.id, [folder("mOvEd", 80)])
        try refuses(move, evidence, error: .collision)
        XCTAssertThrowsError(try catalog.prepareFolderMove(item: root, destinationParent: archive.id, destinationName: "Root"))
    }

    func testDeletedDestinationAndChangedDestinationPathAreRefused() throws {
        let move = try prepare(), evidence = try observations(move)
        let wrongPath = CatalogFolderMove(item: move.item, destinationParent: move.destinationParent,
            destinationName: move.destinationName, destinationParentPath: RelativePath("OldArchive")!,
            entries: move.entries)
        try refuses(wrongPath, evidence)
        try list(root, [folder("Inbox", 1), folder("Kept", 3), folder("Unlisted", 4), file("neighbor", 5)])
        try refuses(move, evidence)
    }

    func testDescendantPathLimitIsCheckedBeforeAnyMutation() throws {
        var parent = root
        for index in 0..<3 {
            let name = String(repeating: String(index), count: 230)
            let existing = try catalog.children(of: parent, limit: 100).map { row -> Parsed in
                .entry(.init(name: row.name, kind: row.kind == .file ? .file : .folder, size: row.size,
                             mtimeNs: row.mtimeNs, ctimeNs: row.ctimeNs, fileID: 1))
            }
            try list(parent, existing + [folder(name, UInt64(100 + index))])
            parent = try child(parent, name).id
        }
        try list(parent, [])
        let move = try catalog.prepareFolderMove(item: tree.id, destinationParent: parent,
                                                  destinationName: String(repeating: "x", count: 255))
        let ordinary = try observations(move)
        XCTAssertLessThan(ordinary.map { $0.path.utf8.count }.max()!, RelativePath.maxBytes)
        let deep = try child(nested.id, "deep")
        let longName = String(repeating: "d", count: 100)
        try list(nested.id, [file(longName, 30)])
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: deep.id)).deleted)
        XCTAssertThrowsError(try catalog.prepareFolderMove(item: tree.id, destinationParent: parent,
                                                           destinationName: String(repeating: "x", count: 255)))
        try refuses(move, ordinary)
    }

    func testSettlementChangesTimestampIdenticalFilesWithFreshVersions() throws {
        try catalog.setWriteAccess(creation: true, editing: true)
        let deep = try child(nested.id, "deep"), plain = try child(tree.id, "plain")
        let original = try receipt(item: deep.id, identity: EditFileIdentity(fileID: 10_030, birthMicroseconds: 100))
        try catalog.rememberEditBase(original, expectedVersion: deep.contentVersion)
        let move = try prepare(), proofs = try proofs(move, receipts: [deep.id: original])
        let changedPlain = try receipt(item: plain.id, identity: XCTUnwrap(proofs.first { $0.item == plain.id }).identity,
                                       digest: "b")
        let changedDeep = try receipt(item: deep.id, identity: original.version.identity, digest: "c")
        let settlement = try settlement(move, proofs: proofs, changed: [plain.id: changedPlain, deep.id: changedDeep])
        let restored = try JSONDecoder().decode(CatalogFolderMoveSettlement.self,
                                                 from: JSONEncoder().encode(settlement))
        try catalog.setKeep(ids: [plain.id], value: true)
        try catalog.setPaused(true)
        let key = try rows("SELECT id || '|' || enumeration_key FROM items ORDER BY row")
        try catalog.settleFolderMove(move, settlement: restored)
        for entry in move.entries {
            let row = try XCTUnwrap(catalog.item(id: entry.item))
            if let changed = [plain.id: changedPlain, deep.id: changedDeep][entry.item] {
                XCTAssertEqual(row.contentVersion, changed.contentVersion)
                XCTAssertNotEqual(row.contentVersion, entry.contentVersion)
                XCTAssertEqual(row.size, entry.size)
                XCTAssertEqual(row.mtimeNs, entry.mtimeNs)
                XCTAssertEqual(row.ctimeNs, entry.ctimeNs)
            } else {
                XCTAssertEqual(row.contentVersion, entry.contentVersion)
            }
            XCTAssertFalse(row.deleted)
        }
        XCTAssertEqual(try rows("SELECT id || '|' || enumeration_key FROM items ORDER BY row"), key)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.id)).keepRequested)
        XCTAssertTrue(try child(tree.id, "explicit").contentVersion.hasPrefix("f1:"))
        let committed = try dump()
        try catalog.settleFolderMove(move, settlement: restored)
        XCTAssertEqual(try dump(), committed)
        let plan = try list(nested.id, [.entry(.init(name: "deep", kind: .file, size: 10,
            mtimeNs: 1_000, ctimeNs: 2_000, fileID: 1_030))])
        XCTAssertEqual(plan.updated, 0)
        XCTAssertEqual(try catalog.item(id: deep.id)?.contentVersion, changedDeep.contentVersion)
    }

    func testSettlementRejectsUnprovedOrReusedChangedReceiptsAtomically() throws {
        let move = try prepare(), proofs = try proofs(move)
        let plain = try child(tree.id, "plain")
        guard case .file(let original) = try XCTUnwrap(proofs.first { $0.item == plain.id }) else {
            return XCTFail("Expected file proof")
        }
        for changed in [
            try receipt(item: plain.id, identity: original.version.identity),
            try receipt(item: plain.id, identity: original.version.identity, id: original.id, digest: "b"),
            try receipt(item: plain.id, identity: EditFileIdentity(fileID: 999, birthMicroseconds: 100), digest: "b"),
            try receipt(item: UUID().uuidString, identity: original.version.identity, digest: "b")
        ] {
            try refusesSettlement(move, settlement(move, proofs: proofs, changed: [plain.id: changed]))
        }
        let changed = try receipt(item: plain.id, identity: original.version.identity, digest: "b")
        let valid = try settlement(move, proofs: proofs, changed: [plain.id: changed])
        let invalid = valid.resolutions.map { resolution -> CatalogFolderMoveResolution in
            guard case .changed(let observed, let receipt) = resolution else { return resolution }
            return .changed(observation(observed, size: observed.size + 1), receipt: receipt)
        }
        try refusesSettlement(move, CatalogFolderMoveSettlement(proofs: proofs, resolutions: invalid, listings: []))
        try refusesSettlement(move, CatalogFolderMoveSettlement(proofs: Array(proofs.dropLast()),
                                                                 resolutions: valid.resolutions, listings: []))
        try refusesSettlement(move, CatalogFolderMoveSettlement(proofs: proofs,
            resolutions: valid.resolutions + [valid.resolutions[0]], listings: []))
    }

    func testSettlementRequiresTheAdmittedVerifiedReceipt() throws {
        try catalog.setWriteAccess(creation: true, editing: true)
        let plain = try child(tree.id, "plain")
        let original = try receipt(item: plain.id, identity: EditFileIdentity(fileID: 10_020, birthMicroseconds: 100))
        try catalog.rememberEditBase(original, expectedVersion: plain.contentVersion)
        let move = try prepare()
        try refusesSettlement(move, settlement(move))
        let valid = try settlement(move, proofs: proofs(move, receipts: [plain.id: original]))
        try catalog.settleFolderMove(move, settlement: valid)
        XCTAssertEqual(try catalog.item(id: plain.id)?.contentVersion, original.contentVersion)
    }

    func testSettlementOfMissingFileNeedsCompleteMatchingParentEvidence() throws {
        let move = try prepare(), proofs = try proofs(move), plain = try child(tree.id, "plain")
        let gone: Set<String> = [plain.id]
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, removed: gone)
        try refusesSettlement(move, settlement(move, proofs: proofs, removed: gone))
        let incomplete = CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
            identity: listing.identity, complete: false, children: listing.children)
        let wrongParent = CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
            identity: try EditFileIdentity(fileID: 999, birthMicroseconds: 100), complete: true, children: listing.children)
        let wrongPath = CatalogFolderMoveListing(parent: listing.parent, path: RelativePath("wrong")!,
            identity: listing.identity, complete: true, children: listing.children)
        let ambiguous = CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
            identity: listing.identity, complete: true, children: listing.children + [listing.children[0]])
        let stillPresent = try moveListing(move, parent: tree.id, proofs: proofs)
        for invalid in [incomplete, wrongParent, wrongPath, ambiguous, stillPresent] {
            try refusesSettlement(move, settlement(move, proofs: proofs, removed: gone, listings: [invalid]))
        }
        let accepted = try settlement(move, proofs: proofs, removed: gone, listings: [listing])
        let anchor = try catalog.currentAnchor()
        try catalog.settleFolderMove(move, settlement: accepted)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.id)).deleted)
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .parent(tree.id)).deletedIDs, [plain.id])
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .parent(inbox.id)).updated.map(\.id), [tree.id])
        let committed = try dump()
        try catalog.settleFolderMove(move, settlement: accepted)
        XCTAssertEqual(try dump(), committed)
    }

    func testReplacementWithIdenticalNativeDetailsGetsANewItemOnDiscovery() throws {
        let plain = try child(tree.id, "plain")
        try catalog.setKeep(ids: [plain.id], value: true)
        let move = try prepare(), proofs = try proofs(move)
        let replacement = CatalogFolderMoveListing.Child(name: plain.name,
            identity: try EditFileIdentity(fileID: 99_000, birthMicroseconds: 100), kind: .file)
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, replacements: [plain.id: replacement])
        let accepted = try settlement(move, proofs: proofs, removed: [plain.id], listings: [listing])
        try catalog.settleFolderMove(move, settlement: accepted)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.id)).deleted)
        XCTAssertNil(try catalog.liveChild(parent: tree.id, nameKey: NameKey(plain.name)))
        let evidence = try observations(move)
        let children = evidence.filter { entry in move.entries.first { $0.item == entry.item }!.parent == tree.id }
            .map { observed -> Parsed in
                .entry(.init(name: RelativePath(observed.path)!.components.last!,
                             kind: observed.kind == .file ? .file : .folder,
                             size: observed.size, mtimeNs: observed.mtimeNs, ctimeNs: observed.ctimeNs,
                             fileID: observed.nativeID))
            }
        try list(tree.id, children)
        let discovered = try child(tree.id, plain.name)
        XCTAssertNotEqual(discovered.id, plain.id)
        XCTAssertEqual(try catalog.remoteIdentity(discovered.id), 1_020)
        XCTAssertFalse(discovered.keepRequested)
        XCTAssertNil(discovered.editVersion)
        try refusesSettlement(move, accepted)
    }

    func testReplacedDirectoryRetiresItsKnownSubtreeWithoutInferringChildren() throws {
        let move = try prepare(), proofs = try proofs(move), deep = try child(nested.id, "deep")
        let replacement = CatalogFolderMoveListing.Child(name: nested.name,
            identity: try EditFileIdentity(fileID: 99_000, birthMicroseconds: 100), kind: .folder)
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, replacements: [nested.id: replacement])
        try refusesSettlement(move, settlement(move, proofs: proofs, removed: [nested.id], listings: [listing]))
        let accepted = try settlement(move, proofs: proofs, removed: [nested.id, deep.id], listings: [listing])
        let anchor = try catalog.currentAnchor()
        try catalog.settleFolderMove(move, settlement: accepted)
        for id in [nested.id, deep.id] { XCTAssertTrue(try XCTUnwrap(catalog.item(id: id)).deleted) }
        XCTAssertEqual(Set(try catalog.changes(after: anchor, limit: 100).deletedIDs), [nested.id, deep.id])
        let committed = try dump()
        try catalog.settleFolderMove(move, settlement: accepted)
        XCTAssertEqual(try dump(), committed)
        XCTAssertFalse(try XCTUnwrap(catalog.item(id: tree.id)).listingComplete)
    }

    func testSettlementChangePagesDeliverEveryTombstoneAndTheRootDeparture() throws {
        let move = try prepare(), proofs = try proofs(move)
        let gone: Set<String> = [try child(tree.id, "plain").id, try child(tree.id, "explicit").id]
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, removed: gone)
        let anchor = try catalog.currentAnchor()
        try catalog.settleFolderMove(move,
            settlement: settlement(move, proofs: proofs, removed: gone, listings: [listing]))
        var token = anchor, deleted: [String] = [], updated: [String] = []
        while true {
            let batch = try catalog.changes(after: token, limit: 1, scope: .parent(tree.id))
            deleted += batch.deletedIDs
            updated += batch.updated.map(\.id)
            token = batch.anchor
            if !batch.moreComing { break }
        }
        XCTAssertEqual(Set(deleted), gone)
        XCTAssertEqual(deleted.count, gone.count)
        XCTAssertEqual(updated, [nested.id])
        let departed = try catalog.changes(after: anchor, limit: 100, scope: .parent(inbox.id))
        XCTAssertEqual(departed.updated.map(\.id), [tree.id])
        XCTAssertTrue(departed.deletedIDs.isEmpty)
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .parent(archive.id)).updated.map(\.id), [tree.id])
    }

    func testListingElsewhereDoesNotInferIdentityAtAnOldName() throws {
        let move = try prepare(), proofs = try proofs(move), plain = try child(tree.id, "plain")
        let absent = try moveListing(move, parent: tree.id, proofs: proofs, removed: [plain.id])
        let otherName = CatalogFolderMoveListing.Child(name: "external-rename",
            identity: try XCTUnwrap(proofs.first { $0.item == plain.id }).identity, kind: .file)
        let listing = CatalogFolderMoveListing(parent: absent.parent, path: RelativePath(absent.path)!,
            identity: absent.identity, complete: true, children: absent.children + [otherName])
        try catalog.settleFolderMove(move,
            settlement: settlement(move, proofs: proofs, removed: [plain.id], listings: [listing]))
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.id)).deleted)
        XCTAssertNil(try catalog.liveChild(parent: tree.id, nameKey: NameKey("external-rename")))
    }

    func testSettlementRefusesRootRemovalAndContradictoryRetainedChild() throws {
        let move = try prepare(), proofs = try proofs(move), plain = try child(tree.id, "plain")
        try refusesSettlement(move, settlement(move, proofs: proofs, removed: [tree.id]))
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, removed: [plain.id])
        try refusesSettlement(move, settlement(move, proofs: proofs, listings: [listing]))
        let accepted = try settlement(move, proofs: proofs, removed: [plain.id], listings: [listing])
        try list(nested.id, [file("deep", 30), file("new", 31)])
        try refusesSettlement(move, accepted)
    }

    func testRemovalEvidenceDoesNotHideUnsupportedOccupantsOrCaseAliases() throws {
        let move = try prepare(), proofs = try proofs(move), plain = try child(tree.id, "plain")
        let identity = try XCTUnwrap(proofs.first { $0.item == plain.id }).identity
        let alias = CatalogFolderMoveListing.Child(name: "PLAIN", identity: identity, kind: .file)
        let listing = try moveListing(move, parent: tree.id, proofs: proofs, replacements: [plain.id: alias])
        try refusesSettlement(move, settlement(move, proofs: proofs, removed: [plain.id], listings: [listing]))
        let unsupported = CatalogFolderMoveListing.Child(name: plain.name,
            identity: try EditFileIdentity(fileID: 99_000, birthMicroseconds: 100), kind: nil)
        let complete = try moveListing(move, parent: tree.id, proofs: proofs, replacements: [plain.id: unsupported])
        try catalog.settleFolderMove(move,
            settlement: settlement(move, proofs: proofs, removed: [plain.id], listings: [complete]))
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.id)).deleted)
        XCTAssertFalse(try XCTUnwrap(catalog.item(id: tree.id)).listingComplete)
    }

    private func receipt(item: String, identity: EditFileIdentity, id: UUID = UUID(),
                         digest: String = "a") throws -> EditBaseReceipt {
        try EditBaseReceipt(id: id, item: item, version: EditFileVersion(identity: identity, size: 10,
            digest: String(repeating: digest, count: 64), modifiedMicroseconds: 1, changedMicroseconds: 2,
            attributes: 32, security: Data([1])))
    }

    private func proofs(_ move: CatalogFolderMove,
                        receipts: [String: EditBaseReceipt] = [:]) throws -> [CatalogFolderMoveProof] {
        try move.entries.map { entry in
            let identity = try EditFileIdentity(fileID: entry.nativeID + 10_000, birthMicroseconds: 100)
            if entry.kind == .folder { return .directory(item: entry.item, identity: identity) }
            return .file(try receipts[entry.item] ?? receipt(item: entry.item, identity: identity))
        }
    }

    private func settlement(_ move: CatalogFolderMove, proofs supplied: [CatalogFolderMoveProof]? = nil,
                            removed: Set<String> = [], changed: [String: EditBaseReceipt] = [:],
                            listings: [CatalogFolderMoveListing] = []) throws -> CatalogFolderMoveSettlement {
        let resolutions = try observations(move).map { observed -> CatalogFolderMoveResolution in
            if removed.contains(observed.item) { return .removed(item: observed.item) }
            if let receipt = changed[observed.item] {
                let after = CatalogFolderMoveObservation(item: observed.item, path: RelativePath(observed.path)!,
                    kind: observed.kind, nativeID: observed.nativeID,
                    fingerprint: .init(size: receipt.version.size,
                                       mtimeNs: Int64(receipt.version.modifiedMicroseconds) * 1_000,
                                       ctimeNs: Int64(receipt.version.changedMicroseconds) * 1_000),
                    preservesIdentity: true, preservesContents: false)
                return .changed(after, receipt: receipt)
            }
            return .preserved(observed)
        }
        return try CatalogFolderMoveSettlement(proofs: supplied ?? proofs(move),
                                                resolutions: resolutions, listings: listings)
    }

    private func moveListing(_ move: CatalogFolderMove, parent: String, proofs: [CatalogFolderMoveProof],
                             removed: Set<String> = [], replacements: [String: CatalogFolderMoveListing.Child] = [:])
        throws -> CatalogFolderMoveListing {
        let proof = try XCTUnwrap(proofs.first { $0.item == parent })
        let path = try XCTUnwrap(observations(move).first { $0.item == parent }).path
        let children = try move.entries.filter { $0.parent == parent }.compactMap { entry -> CatalogFolderMoveListing.Child? in
            if let replacement = replacements[entry.item] { return replacement }
            if removed.contains(entry.item) { return nil }
            return CatalogFolderMoveListing.Child(name: entry.name,
                identity: try XCTUnwrap(proofs.first { $0.item == entry.item }).identity, kind: entry.kind)
        }
        return CatalogFolderMoveListing(parent: parent, path: RelativePath(path)!, identity: proof.identity,
                                         complete: true, children: children)
    }

    private func refusesSettlement(_ move: CatalogFolderMove, _ settlement: CatalogFolderMoveSettlement,
                                   line: UInt = #line) throws {
        let before = try dump()
        XCTAssertThrowsError(try catalog.settleFolderMove(move, settlement: settlement), line: line) {
            XCTAssertEqual($0 as? UploadError, .unresolved, line: line)
        }
        XCTAssertEqual(try dump(), before, line: line)
    }

    private func prepare(to parent: String? = nil, name: String = "Moved") throws -> CatalogFolderMove {
        try catalog.prepareFolderMove(item: tree.id, destinationParent: parent ?? archive.id, destinationName: name)
    }

    private func observations(_ move: CatalogFolderMove) throws -> [CatalogFolderMoveObservation] {
        let source = try XCTUnwrap(move.entries.first { $0.item == move.item }).path
        let target = try XCTUnwrap(RelativePath(move.destinationParentPath)?.appending(move.destinationName))
        return try move.entries.map { entry in
            let suffix = try XCTUnwrap(RelativePath(entry.path == source ? "" : String(entry.path.dropFirst(source.count + 1))))
            return CatalogFolderMoveObservation(item: entry.item, path: try XCTUnwrap(target.appending(suffix)),
                kind: entry.kind, nativeID: entry.nativeID + 1_000,
                fingerprint: .init(size: entry.size, mtimeNs: entry.mtimeNs, ctimeNs: entry.ctimeNs + 100),
                preservesIdentity: true, preservesContents: entry.kind == .file)
        }
    }

    private func observation(_ original: CatalogFolderMoveObservation, size: Int64? = nil,
                             nativeID: UInt64? = nil, kind: CatalogRow.Kind? = nil, path: String? = nil,
                             preservesIdentity: Bool? = nil, preservesContents: Bool? = nil) -> CatalogFolderMoveObservation {
        CatalogFolderMoveObservation(item: original.item, path: RelativePath(path ?? original.path)!,
            kind: kind ?? original.kind, nativeID: nativeID ?? original.nativeID,
            fingerprint: .init(size: size ?? original.size, mtimeNs: original.mtimeNs, ctimeNs: original.ctimeNs),
            preservesIdentity: preservesIdentity ?? original.preservesIdentity,
            preservesContents: preservesContents ?? original.preservesContents)
    }

    private func refuses(_ move: CatalogFolderMove, _ evidence: [CatalogFolderMoveObservation],
                         error: UploadError = .unresolved, line: UInt = #line) throws {
        let before = try dump()
        XCTAssertThrowsError(try catalog.commitFolderMove(move, observations: evidence), line: line) {
            XCTAssertEqual($0 as? UploadError, error, line: line)
        }
        XCTAssertEqual(try dump(), before, line: line)
    }

    private func child(_ parent: String, _ name: String) throws -> CatalogRow {
        try XCTUnwrap(catalog.liveChild(parent: parent, nameKey: NameKey(name)))
    }

    private func folder(_ name: String, _ id: UInt64) -> Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 1_000, ctimeNs: 2_000, fileID: id))
    }

    private func file(_ name: String, _ id: UInt64) -> Parsed {
        .entry(.init(name: name, kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: id))
    }

    @discardableResult
    private func list(_ parent: String, _ entries: [Parsed]) throws -> ReconcilePlan {
        try XCTUnwrap(catalog.reconcile(folder: parent, listing: DirectoryListing(entries)) { _ in true })
    }

    private func rows(_ sql: String) throws -> [String] {
        try catalog.database.prepare(sql) {
            var values: [String] = []
            while try $0.step() { values.append($0.text(0)) }
            return values
        }
    }

    private func dump() throws -> [String] {
        let fields = ["row", "id", "quote(parent_id)", "hex(name)", "hex(name_key)", "kind", "size", "mtime_ns",
                      "ctime_ns", "quote(file_id)", "keep", "keep_request", "deleted", "change_seq",
                      "hex(enumeration_key)", "quote(edit_version)", "listing_complete", "quote(list_gen)"]
        return try rows("SELECT \(fields.joined(separator: " || '|' || ")) FROM items ORDER BY row")
            + rows("SELECT item || '|' || parent || '|' || seq FROM departures ORDER BY item, parent")
            + rows("SELECT last_seq || '|' || listing_gen FROM meta")
    }
}
