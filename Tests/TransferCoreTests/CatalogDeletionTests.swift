import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class CatalogDeletionTests: XCTestCase {
    private typealias Parsed = DirectoryListing.Parsed
    private let root = Catalog.rootItemID
    private var fixture: DeletionFixture!
    private var owner: Catalog!
    private var neighbor: Catalog!
    private var ids: [String: String] = [:]
    private var shared: [String: String] = [:]
    private var server: DeletionServer { fixture.server }
    private var reads: [String] = []

    override func setUpWithError() throws {
        fixture = try DeletionFixture()
        owner = try Catalog.create(at: fixture.directory.appending(path: "owner.sqlite"), domainID: fixture.owner,
                                   rootName: "Docs")
        neighbor = try Catalog.create(at: fixture.directory.appending(path: "neighbor.sqlite"),
                                      domainID: fixture.neighbor, rootName: "share")
        var pending = [(root, "Docs")]
        while let next = pending.popLast() {
            try list(owner, next.0, next.1)
            for row in try owner.children(of: next.0, limit: 100) where row.kind == .folder {
                pending.append((row.id, next.1 + "/" + row.name))
            }
        }
        try list(neighbor, root, "")
        try list(neighbor, XCTUnwrap(neighbor.liveChild(parent: root, nameKey: NameKey("Docs"))).id, "Docs")
        ids = try paths(owner)
        shared = try paths(neighbor)
        reads = []
    }

    override func tearDown() {
        owner = nil
        neighbor = nil
        fixture.remove()
        fixture = nil
    }

    func testSettledRefusalPreservesSelectedMetadataAndKeepsOldEventReplay() throws {
        let tree = try XCTUnwrap(ids["Tree"]), before = try XCTUnwrap(owner.item(id: tree))
        var record = try prepare()
        server.markFailures["Docs/Tree/a"] = ItemDeletionError.sharingViolation
        try fixture.run(&record)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        let first = try settle(record)
        let final = try complete(record, first)
        XCTAssertTrue(final.isSettled)
        let after = try XCTUnwrap(owner.item(id: tree))
        XCTAssertEqual(after.metadataVersion, record.plan.request.metadataVersion)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.contentVersion, before.contentVersion)
        XCTAssertEqual(after.keep, before.keep)
        XCTAssertTrue(final.refresh.contains(root))
        XCTAssertTrue(try settle(record, previous: final).isSettled)
        XCTAssertEqual(try owner.item(id: tree)?.metadataVersion, after.metadataVersion)
        let replay = try XCTUnwrap(fixture.outbox.replay(endpoint: fixture.endpoint,
            owner: fixture.owner, request: record.plan.request))
        XCTAssertEqual(replay.selectedOutcome, .directoryNotEmpty)
        XCTAssertNil(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: DeletionRequest(item: tree, contentVersion: after.contentVersion,
                                     metadataVersion: after.metadataVersion, eventVersion: Data([2]))))
    }

    func testUnconfirmedSurvivorSignalsAfterFreshListingAndKeepsOldEventReplay() throws {
        let tree = try XCTUnwrap(ids["Tree"])
        try owner.setKeep(ids: [tree], value: true)
        let before = try XCTUnwrap(owner.item(id: tree))
        let neighborBefore = try owner.item(id: XCTUnwrap(ids["neighbor"]))
        var record = try prepare()
        server.markFailures["Docs/Tree"] = SourceFailure.serverUnreachable
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        XCTAssertEqual(record.selectedOutcome, .unconfirmed)
        XCTAssertNotNil(server.objects["Docs/Tree"])
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(try owner.item(id: tree)?.metadataVersion, before.metadataVersion)
        let anchor = try owner.currentAnchor()
        let final = try complete(record, first)
        let after = try XCTUnwrap(owner.item(id: tree))
        XCTAssertGreaterThan(after.changeSeq, before.changeSeq)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.contentVersion, before.contentVersion)
        XCTAssertEqual(after.keep, before.keep)
        XCTAssertEqual(after.keepRequested, before.keepRequested)
        XCTAssertFalse(after.deleted)
        XCTAssertTrue(final.refresh.contains(root))
        XCTAssertEqual(try owner.changes(after: anchor, limit: 100).updated.map(\.id), [tree])
        XCTAssertTrue(try settle(record, previous: final).isSettled)
        XCTAssertEqual(try owner.item(id: tree)?.metadataVersion, after.metadataVersion)
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["neighbor"])), neighborBefore)
        let shared = try settle(record, catalog: neighbor)
        XCTAssertTrue(try complete(record, shared, catalog: neighbor).isSettled)
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        fixture.outbox = try fixture.makeOutbox()
        let replay = try XCTUnwrap(fixture.outbox.replay(endpoint: fixture.endpoint,
            owner: fixture.owner, request: record.plan.request))
        XCTAssertThrowsError(try replay.requireConfirmedDeletion()) {
            XCTAssertEqual($0 as? ItemDeletionError, .unresolved)
        }
        XCTAssertEqual(replay, record)
        let refreshed = DeletionRequest(item: tree, contentVersion: after.contentVersion,
            metadataVersion: after.metadataVersion, eventVersion: record.plan.request.eventVersion)
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint,
            owner: fixture.owner, request: refreshed), record)
        let completed = try settle(record)
        XCTAssertTrue(try complete(record, completed).isSettled)
        XCTAssertEqual(try owner.item(id: tree)?.metadataVersion, after.metadataVersion)
        XCTAssertNil(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: DeletionRequest(item: tree, contentVersion: after.contentVersion,
                                     metadataVersion: after.metadataVersion, eventVersion: Data([2]))))
    }

    func testConfirmedDeletionTombstonesEachAdmittedRowOnceInEachView() throws {
        var record = try prepare()
        try fixture.run(&record)
        let anchor = try owner.currentAnchor()
        let settlement = try settle(record)
        let admitted = try rows("Tree/Empty", "Tree/Sub/c", "Tree/Sub/d", "Tree/Sub", "Tree/a", "Tree/b", "Tree")
        XCTAssertTrue(settlement.isSettled)
        XCTAssertEqual(settlement.tombstoned, admitted)
        XCTAssertEqual(settlement.listings, [])
        XCTAssertEqual(settlement.refresh, [root])
        let changes = try owner.changes(after: anchor, limit: 100)
        XCTAssertEqual(changes.deletedIDs, admitted)
        XCTAssertEqual(changes.updated, [])
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["neighbor"]))?.deleted, false)

        let committed = try dump(owner)
        XCTAssertTrue(try settle(record, previous: settlement).isSettled)
        let replay = try settle(record)
        XCTAssertFalse(replay.isSettled)
        XCTAssertEqual(replay.tombstoned, [])
        XCTAssertEqual(try dump(owner), committed)
        XCTAssertTrue(try complete(record, replay).isSettled)
        let view = try settle(record, catalog: neighbor)
        XCTAssertTrue(view.isSettled)
        XCTAssertEqual(view.tombstoned, [try XCTUnwrap(shared["Docs/Tree"])])
        XCTAssertEqual(view.refresh, [try XCTUnwrap(shared["Docs"])])
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        XCTAssertTrue(record.isComplete)
    }

    func testFirstSettlementPreservesReconciledReplacementDirectoryWithSameIDAndVersion() throws {
        try replacementBeforeSettlement("Tree/Empty", replacement: .directory(DeletionFixture.identity(81)))
    }

    func testAdmittedKindMismatchReconcilesInsteadOfBlockingCompletion() throws {
        server.objects["Docs/Tree/Empty"] = .file(try DeletionFixture.version(81))
        var record = try prepare()
        try fixture.run(&record)
        let empty = try XCTUnwrap(ids["Tree/Empty"])
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertFalse(first.tombstoned.contains(empty))
        XCTAssertTrue(try complete(record, first).isSettled)
        XCTAssertEqual(try owner.item(id: empty)?.deleted, true)
    }

    func testMissingFolderStillPresentInParentStopsReconciliation() throws {
        var record = try prepare()
        try fixture.run(&record)
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(80))
        try list(owner, root, "Docs")
        let first = try settle(record)
        let next = try advance(record, first)
        XCTAssertEqual(next.listings, try rows("Tree"))
        XCTAssertThrowsError(try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
            locationRoot: XCTUnwrap(RelativePath("Docs")), previous: next,
            listing: { path in
                if path.string == "Tree" { throw posixError("unreadable test folder", code: ENOENT) }
                return try self.serverListing("Docs")
            }, confirmMissing: { _, _ in }, accept: { _ in true })) {
                XCTAssertEqual($0 as? ItemDeletionError, .unresolved)
            }
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree"]))?.deleted, false)
    }

    func testFirstSettlementPreservesReconciledReplacementFileWithIdenticalFingerprint() throws {
        try replacementBeforeSettlement("Tree/a", replacement: .file(DeletionFixture.version(82)))
    }

    func testUnchangedNativeIDAndFingerprintStillRequireFreshReconciliationAfterAListing() throws {
        var objects = server.objects
        var record = try prepare()
        let sequence = try owner.counts().lastSeq, generation = try owner.counts().listingGen
        try fixture.run(&record)
        objects["Docs/Tree/a"] = .file(try DeletionFixture.version(15, digest: "b"))
        server.objects = objects
        try list(owner, XCTUnwrap(ids["Tree"]), "Docs/Tree")
        XCTAssertEqual(try owner.counts().lastSeq, sequence)
        XCTAssertGreaterThan(try owner.counts().listingGen, generation)
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.tombstoned, [])
        XCTAssertTrue(try complete(record, first).isSettled)
        for id in ids.values { XCTAssertEqual(try owner.item(id: id)?.deleted, false) }
    }

    private func replacementBeforeSettlement(_ path: String, replacement: ItemDeletionEvidence) throws {
        let id = try XCTUnwrap(ids[path]), before = try XCTUnwrap(owner.item(id: id))
        var record = try prepare()
        try fixture.run(&record)
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(10))
        server.objects["Docs/" + path] = replacement
        try list(owner, XCTUnwrap(ids["Tree"]), "Docs/Tree")
        let replaced = try XCTUnwrap(owner.item(id: id))
        XCTAssertEqual(replaced.id, before.id)
        XCTAssertEqual(replaced.contentVersion, before.contentVersion)
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertFalse(first.tombstoned.contains(id))
        XCTAssertEqual(try owner.item(id: id), replaced)
        let final = try complete(record, first)
        XCTAssertTrue(final.isSettled)
        XCTAssertEqual(try owner.item(id: id)?.deleted, false)
        let committed = try dump(owner)
        let replay = try settle(record)
        XCTAssertFalse(replay.isSettled)
        XCTAssertEqual(replay.tombstoned, [])
        XCTAssertEqual(try dump(owner), committed)
        XCTAssertTrue(try complete(record, replay).isSettled)
        XCTAssertEqual(try owner.item(id: id)?.deleted, false)
    }

    func testReplayAfterPreservingReplacementWithoutPreviousNeverTombstonesIt() throws {
        var record = try prepare()
        try fixture.run(&record)
        let tree = try XCTUnwrap(ids["Tree"]), a = try XCTUnwrap(ids["Tree/a"])
        try owner.updateFingerprint(item: a, fingerprint: ContentFingerprint(size: 99, mtimeNs: 1, ctimeNs: 2), fileID: 15)
        let first = try settle(record)
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(10))
        server.objects["Docs/Tree/a"] = .file(try DeletionFixture.version(15, digest: "b"))
        let finished = try complete(record, first)
        XCTAssertTrue(finished.isSettled)
        XCTAssertEqual(try owner.item(id: a)?.contentVersion,
                       record.plan.views[0].items.first { $0.item == a }?.contentVersion)
        XCTAssertEqual(try owner.item(id: tree)?.contentVersion, "d1")
        fixture.outbox = try fixture.makeOutbox()
        let restarted = try XCTUnwrap(fixture.outbox.records().first)
        let before = try dump(owner)
        let replay = try settle(restarted)
        XCTAssertFalse(replay.isSettled)
        XCTAssertEqual(replay.tombstoned, [])
        XCTAssertEqual(try dump(owner), before)
        XCTAssertTrue(try complete(restarted, replay).isSettled)
        for id in [a, tree] { XCTAssertEqual(try owner.item(id: id)?.deleted, false) }
    }

    func testEarlierListingResolutionsSurviveMultipleSettlementSteps() throws {
        var record = try prepare()
        try fixture.run(&record)
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(10))
        server.objects["Docs/Tree/Sub"] = .directory(try DeletionFixture.identity(12))
        server.objects["Docs/Tree/Sub/c"] = .file(try DeletionFixture.version(13, digest: "b"))
        try list(owner, root, "Docs")
        var settlement = try settle(record)
        XCTAssertFalse(settlement.isSettled)
        settlement = try advance(record, settlement)
        XCTAssertEqual(reads, ["Docs", "Docs"])
        XCTAssertEqual(settlement.listings, try rows("Tree"))
        settlement = try advance(record, settlement)
        XCTAssertEqual(settlement.listings, try rows("Tree/Sub"))
        settlement = try advance(record, settlement)
        XCTAssertTrue(settlement.isSettled)
        XCTAssertEqual(reads, ["Docs", "Docs", "Docs/Tree", "Docs/Tree/Sub"])
        for path in ["Tree", "Tree/Sub", "Tree/Sub/c"] {
            XCTAssertEqual(try owner.item(id: XCTUnwrap(ids[path]))?.deleted, false)
        }
        XCTAssertTrue(try settle(record, previous: settlement).isSettled)
    }

    func testUnconfirmedChildHoldsItsDeletedFolderUntilAReachableAncestorIsListed() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/b"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.run(&record)
        XCTAssertEqual(fixture.outcome("Docs/Tree/b", record), .unconfirmed)
        XCTAssertEqual(record.selectedOutcome, .deleted)
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.blocked, try rows("Tree/b", "Tree"))
        XCTAssertEqual(first.listings, [root])
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree/b"]))?.deleted, false)
        let second = try advance(record, first)
        XCTAssertTrue(second.isSettled)
        XCTAssertEqual(fixture.outcome("Docs/Tree/b", record), .unconfirmed)
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree/b"]))?.deleted, true)
    }

    func testStoppedOperationWithUnconfirmedNodeCannotFinishItsDomainEarly() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.blocked, try rows("Tree/Sub/c"))
        XCTAssertEqual(first.listings, try rows("Tree/Sub"))
        XCTAssertTrue(record.blocksWrites)
        let repeated = try settle(record, previous: first)
        XCTAssertFalse(repeated.isSettled)
        let final = try advance(record, repeated)
        XCTAssertTrue(final.isSettled)
        XCTAssertEqual(fixture.outcome("Docs/Tree/Sub/c", record), .unconfirmed)
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        let sharedResult = try settle(record, catalog: neighbor)
        XCTAssertFalse(sharedResult.isSettled)
        XCTAssertEqual(sharedResult.blocked, [])
        XCTAssertTrue(try complete(record, sharedResult, catalog: neighbor).isSettled)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        XCTAssertFalse(record.blocksWrites)
        XCTAssertTrue(record.hasUnconfirmed && record.isPending)
    }

    func testMissingFolderRelistsReachableAncestorInsteadOfInventingEmptyContents() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        for path in Array(server.objects.keys) where path.hasPrefix("Docs/Tree") { server.objects[path] = nil }
        let first = try settle(record)
        let final = try advance(record, first)
        XCTAssertTrue(final.isSettled)
        XCTAssertEqual(reads, ["Docs/Tree/Sub", "Docs/Tree", "Docs"])
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree"]))?.deleted, true)
        XCTAssertEqual(fixture.outcome("Docs/Tree/Sub/c", record), .unconfirmed)
    }

    func testMissingLocationRootFailsWithoutChangingTheCatalog() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        server.objects = ["": .directory(try DeletionFixture.identity(1))]
        let first = try settle(record), before = try dump(owner)
        XCTAssertThrowsError(try advance(record, first)) {
            XCTAssertEqual(($0 as NSError).code, Int(ENOENT))
        }
        XCTAssertEqual(try dump(owner), before)
        XCTAssertFalse(try settle(record, previous: first).isSettled)
    }

    func testExternalUnreadableListingAdvancesGenerationButCannotSettleAnObligation() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        let first = try settle(record), sub = try XCTUnwrap(ids["Tree/Sub"])
        let generation = try owner.counts().listingGen
        try reconcile(owner, sub, [.unreadable(.init(name: "c", error: EACCES)), entry("d", .file, 14)])
        XCTAssertGreaterThan(try owner.counts().listingGen, generation)
        XCTAssertEqual(try owner.item(id: sub)?.listingComplete, false)
        let waiting = try settle(record, previous: first)
        XCTAssertFalse(waiting.isSettled)
        XCTAssertEqual(waiting.blocked, try rows("Tree/Empty", "Tree/Sub/c"))
        XCTAssertTrue(try complete(record, waiting).isSettled)
    }

    func testAnExistingTombstoneFromAnIncompleteListingStillNeedsFreshEvidence() throws {
        var record = try prepare()
        try fixture.run(&record)
        try reconcile(owner, root, [.unreadable(.init(name: "neighbor", error: EACCES))])
        XCTAssertEqual(try owner.item(id: root)?.listingComplete, false)
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree"]))?.deleted, true)
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.tombstoned, [])
        XCTAssertEqual(first.listings, [root])
        XCTAssertTrue(try advance(record, first).isSettled)
    }

    func testUnreadableSkippedAndInterruptedListingsNeverResolveOrMutateTheCatalog() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        let first = try settle(record), before = try dump(owner)
        let invalid: [[Parsed]] = [[.unreadable(.init(name: "c", error: EACCES))], [.otherKind], [.invalidName],
                                  [entry("c", .file, 13), entry("C", .file, 14)]]
        for entries in invalid {
            XCTAssertThrowsError(try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
                locationRoot: XCTUnwrap(RelativePath("Docs")), previous: first,
                listing: { _ in DirectoryListing(entries) }, confirmMissing: { _, _ in XCTFail("Incomplete listing") },
                accept: { _ in XCTFail("Incomplete listing"); return true })) {
                XCTAssertEqual($0 as? SourceFailure, .listingIncomplete)
            }
            XCTAssertEqual(try dump(owner), before)
        }
        XCTAssertThrowsError(try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
            locationRoot: XCTUnwrap(RelativePath("Docs")), previous: first,
            listing: { _ in throw SourceFailure.listingIncomplete }, confirmMissing: { _, _ in }, accept: { _ in true }))
        XCTAssertEqual(try dump(owner), before)
        XCTAssertFalse(try settle(record, previous: first).isSettled)
    }

    func testListingCommittedAfterBarrierDoesNotProveItStartedAfterBarrier() throws {
        let stale = try serverListing("Docs")
        var record = try prepare()
        try fixture.run(&record)
        try owner.setKeep(ids: rows("Tree"), value: true)
        let first = try settle(record)
        XCTAssertNotNil(try owner.reconcile(folder: root, listing: stale) { _ in true })
        let waiting = try settle(record, previous: first)
        XCTAssertFalse(waiting.isSettled)
        XCTAssertEqual(waiting.tombstoned, [])
        XCTAssertTrue(try advance(record, waiting).isSettled)
    }

    func testCatalogChangeDuringFreshReadRefusesTheObservation() throws {
        var record = try prepare()
        try fixture.run(&record)
        try owner.setKeep(ids: rows("Tree"), value: true)
        let first = try settle(record)
        XCTAssertThrowsError(try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
            locationRoot: XCTUnwrap(RelativePath("Docs")), previous: first, listing: { _ in
                try self.owner.setKeep(ids: self.rows("Tree"), value: false)
                return DirectoryListing([])
            }, confirmMissing: { _, _ in }, accept: { _ in true })) {
                XCTAssertEqual($0 as? ItemDeletionError, .unresolved)
            }
        XCTAssertFalse(try settle(record, previous: first).isSettled)
        XCTAssertEqual(try owner.item(id: XCTUnwrap(ids["Tree"]))?.deleted, false)
    }

    func testConfirmationRefusalAndMissingNameFailureKeepTheObligation() throws {
        var record = try prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.outbox.stop(&record)
        let first = try settle(record), before = try dump(owner)
        let refused = try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
            locationRoot: XCTUnwrap(RelativePath("Docs")), previous: first,
            listing: { _ in try self.serverListing("Docs/Tree/Sub") }, confirmMissing: { _, _ in }, accept: { _ in false })
        XCTAssertFalse(refused.isSettled)
        XCTAssertEqual(try dump(owner), before)
        XCTAssertThrowsError(try owner.reconcileDeletion(record, endpoint: fixture.endpoint,
            locationRoot: XCTUnwrap(RelativePath("Docs")), previous: refused,
            listing: { _ in try self.serverListing("Docs/Tree/Sub") },
            confirmMissing: { _, _ in throw SourceFailure.listingIncomplete }, accept: { _ in true }))
        XCTAssertEqual(try dump(owner), before)
    }

    func testLegacyViewWithoutAdmissionEvidenceRequiresFreshListings() throws {
        let owned = try view(owner, location: "Docs"), shared = try view(neighbor, location: "")
        let views = try [owned, shared].map {
            try DeletionView(domain: $0.domain, folder: XCTUnwrap(RelativePath($0.folder)), items: $0.items)
        }
        var record = try prepare(views: views)
        try fixture.run(&record)
        let before = try dump(owner), first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.tombstoned, [])
        XCTAssertEqual(try dump(owner), before)
        XCTAssertTrue(try complete(record, first).isSettled)
    }

    func testAdmissionIsPersistedAndCannotBeChangedByReplay() throws {
        let record = try prepare(), stored = try XCTUnwrap(fixture.outbox.records().first)
        XCTAssertEqual(stored, record)
        let admission = try XCTUnwrap(stored.plan.views[0].catalogAdmission)
        XCTAssertEqual(admission.epoch, owner.epoch)
        XCTAssertEqual(admission.sequence, try owner.counts().lastSeq)
        XCTAssertEqual(admission.listingGeneration, try owner.counts().listingGen)
        try owner.setKeep(ids: rows("Tree"), value: true)
        let changed = try [view(owner, location: "Docs"), view(neighbor, location: "")]
        XCTAssertNotEqual(changed, record.plan.views)
        let replay = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: record.plan.request, traversal: fixture.traversal(), views: changed,
            protectedRoots: [], recursive: true)
        XCTAssertEqual(replay.plan.views, record.plan.views)
        XCTAssertEqual(try prepare(), record)
        let next = DeletionRequest(item: record.plan.request.item,
            contentVersion: record.plan.request.contentVersion,
            metadataVersion: record.plan.request.metadataVersion, eventVersion: Data([2]))
        XCTAssertThrowsError(try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: next, traversal: fixture.traversal(), views: changed, protectedRoots: [], recursive: true)) {
            XCTAssertEqual($0 as? ItemDeletionError, .busy)
        }
    }

    func testSurvivorsKeepRowsAndFlagsWhileConfirmedSiblingsAreTombstoned() throws {
        try owner.setKeep(ids: rows("Tree/b", "Tree/Sub"), value: true)
        var record = try prepare()
        server.objects["Docs/Tree/a"] = .file(try DeletionFixture.version(50))
        server.objects["Docs/Tree/b"] = .file(try DeletionFixture.version(16, digest: "c"))
        try fixture.run(&record)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        let survivors = try rows("Tree/a", "Tree/b", "Tree").map { try XCTUnwrap(owner.item(id: $0)) }
        let first = try settle(record)
        XCTAssertFalse(first.isSettled)
        XCTAssertEqual(first.tombstoned, try rows("Tree/Empty", "Tree/Sub/c", "Tree/Sub/d", "Tree/Sub"))
        for row in survivors { XCTAssertEqual(try owner.item(id: row.id), row) }
        XCTAssertTrue(try complete(record, first).isSettled)
        let kept = try XCTUnwrap(owner.item(id: XCTUnwrap(ids["Tree/b"])))
        XCTAssertTrue(kept.keep && kept.keepRequested && !kept.deleted)
        let removed = try XCTUnwrap(owner.item(id: XCTUnwrap(ids["Tree/Sub/c"])))
        XCTAssertTrue(removed.deleted && removed.keep)
    }

    func testMovedRowReconcilesItsCurrentParentAndPreservesNewOccupantsAtTheOldPath() throws {
        var record = try prepare()
        try fixture.run(&record)
        let b = try XCTUnwrap(ids["Tree/b"]), tree = try XCTUnwrap(ids["Tree"])
        let row = try XCTUnwrap(owner.item(id: b))
        try owner.commitFileMove(CatalogFileMove(item: b, sourceParent: tree, sourceName: "b",
            contentVersion: row.contentVersion, sourceNativeID: 16, destinationParent: root, destinationName: "b"),
            fingerprint: ContentFingerprint(size: 12, mtimeNs: 1_000, ctimeNs: 2_000), nativeID: 16)
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(80))
        server.objects["Docs/Tree/b"] = .file(try DeletionFixture.version(81))
        let first = try settle(record)
        XCTAssertEqual(first.tombstoned, [])
        XCTAssertTrue(try complete(record, first).isSettled)
        XCTAssertEqual(try owner.item(id: b)?.deleted, true)
        let replacement = try XCTUnwrap(owner.liveChild(parent: tree, nameKey: NameKey("b")))
        XCTAssertNotEqual(replacement.id, b)
        XCTAssertFalse(replacement.deleted)
    }

    func testMissingRowRollsBackTheWholeSettlement() throws {
        let owned = try view(owner, location: "Docs")
        let views = try [
            DeletionView(domain: fixture.owner, folder: XCTUnwrap(RelativePath("Docs")), items: owned.items.map {
                $0.path == "Tree" ? DeletionViewItem(item: UUID().uuidString, path: RelativePath("Tree")!,
                                                     contentVersion: $0.contentVersion) : $0
            }, catalogAdmission: owned.catalogAdmission),
            DeletionView(domain: fixture.neighbor, folder: .root, items: [DeletionViewItem(
                item: UUID().uuidString, path: XCTUnwrap(RelativePath("Docs/Tree")), contentVersion: "d1")])
        ]
        var record = try prepare(views: views)
        try fixture.run(&record)
        let owners = try dump(owner), neighbors = try dump(neighbor)
        XCTAssertThrowsError(try settle(record))
        XCTAssertThrowsError(try settle(record, catalog: neighbor))
        XCTAssertEqual(try dump(owner), owners)
        XCTAssertEqual(try dump(neighbor), neighbors)
    }

    func testAdmissionRefusesMissingStaleAndIncorrectlyMappedRows() throws {
        let selected = try XCTUnwrap(ids["Tree"]), folder = try XCTUnwrap(RelativePath("Docs"))
        let entries = try [DeletionViewItem(item: UUID().uuidString, path: .root, contentVersion: "d1"),
                           DeletionViewItem(item: selected, path: XCTUnwrap(RelativePath("wrong")), contentVersion: "d1"),
                           DeletionViewItem(item: selected, path: XCTUnwrap(RelativePath("Tree")), contentVersion: "wrong")]
        for entry in entries {
            XCTAssertThrowsError(try owner.deletionView(locationRoot: folder, items: [entry]))
        }
    }

    func testUnsettledForeignRootEndpointAndCatalogIncarnationAreRefused() throws {
        var record = try prepare()
        XCTAssertThrowsError(try settle(record))
        try fixture.run(&record)
        let before = try dump(owner)
        XCTAssertThrowsError(try owner.settleDeletion(record, endpoint: fixture.endpoint, locationRoot: .root))
        XCTAssertThrowsError(try owner.settleDeletion(record, endpoint: XCTUnwrap(ShareAddress("//other@fixture/share")),
                                                     locationRoot: XCTUnwrap(RelativePath("Docs"))))
        let replacement = try Catalog.create(at: fixture.directory.appending(path: "replacement.sqlite"),
                                             domainID: fixture.owner, rootName: "Docs")
        XCTAssertThrowsError(try settle(record, catalog: replacement))
        let other = try settle(record, catalog: neighbor)
        XCTAssertThrowsError(try settle(record, previous: other))
        XCTAssertEqual(try dump(owner), before)
    }

    private func prepare(views: [DeletionView]? = nil) throws -> PendingDeletion {
        let views = try views ?? [view(owner, location: "Docs"), view(neighbor, location: "")]
        let selected = try XCTUnwrap(views[0].items.first { $0.path == "Tree" })
        let request = DeletionRequest(item: selected.item, contentVersion: selected.contentVersion,
                                      metadataVersion: try owner.item(id: selected.item)?.metadataVersion ?? "0",
                                      eventVersion: Data([1]))
        return try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner, request: request,
                                          traversal: fixture.traversal(), views: views, protectedRoots: [], recursive: true)
    }

    private func view(_ catalog: Catalog, location: String) throws -> DeletionView {
        let folder = try XCTUnwrap(RelativePath(location))
        let items = try paths(catalog).sorted { $0.key < $1.key }.compactMap { path, id -> DeletionViewItem? in
            let relative = try XCTUnwrap(RelativePath(path)), share = try XCTUnwrap(folder.appending(relative)).string
            guard share == "Docs/Tree" || share.hasPrefix("Docs/Tree/") else { return nil }
            return DeletionViewItem(item: id, path: relative, contentVersion: try XCTUnwrap(catalog.item(id: id)).contentVersion)
        }
        return try catalog.deletionView(locationRoot: folder, items: items)
    }

    private func location(_ catalog: Catalog) -> RelativePath {
        catalog.domainID == fixture.owner ? RelativePath("Docs")! : .root
    }

    private func settle(_ record: PendingDeletion, catalog: Catalog? = nil,
                        previous: CatalogDeletionSettlement? = nil) throws -> CatalogDeletionSettlement {
        let catalog = catalog ?? owner!
        return try catalog.settleDeletion(record, endpoint: fixture.endpoint, locationRoot: location(catalog), previous: previous)
    }

    private func advance(_ record: PendingDeletion, _ previous: CatalogDeletionSettlement,
                         catalog: Catalog? = nil) throws -> CatalogDeletionSettlement {
        let catalog = catalog ?? owner!, folder = location(catalog)
        return try catalog.reconcileDeletion(record, endpoint: fixture.endpoint, locationRoot: folder, previous: previous,
            listing: { path in try self.serverListing(XCTUnwrap(folder.appending(path)).string) },
            confirmMissing: { path, children in
                let parent = try XCTUnwrap(folder.appending(path)).string
                for child in children {
                    let path = parent.isEmpty ? child.name : parent + "/" + child.name
                    if self.server.objects[path] != nil { throw SourceFailure.listingIncomplete }
                }
            }, accept: { _ in true })
    }

    private func complete(_ record: PendingDeletion, _ previous: CatalogDeletionSettlement,
                          catalog: Catalog? = nil) throws -> CatalogDeletionSettlement {
        var result = previous
        for _ in 0..<20 where !result.isSettled { result = try advance(record, result, catalog: catalog) }
        XCTAssertTrue(result.isSettled)
        return result
    }

    private func paths(_ catalog: Catalog) throws -> [String: String] {
        var result: [String: String] = [:], pending = [root]
        while let id = pending.popLast() {
            for row in try catalog.children(of: id, limit: 100) {
                pending.append(row.id)
                result[try XCTUnwrap(catalog.relativePath(of: row.id)).string] = row.id
            }
        }
        return result
    }

    private func rows(_ paths: String...) throws -> [String] { try paths.map { try XCTUnwrap(ids[$0]) } }

    private func serverListing(_ path: String) throws -> DirectoryListing {
        reads.append(path)
        guard let object = server.objects[path] else { throw posixError("list test folder", code: ENOENT) }
        guard object.kind == .folder else { throw posixError("list test folder", code: ENOTDIR) }
        guard !server.incomplete.contains(path) else { throw SourceFailure.listingIncomplete }
        let entries = server.objects.keys.filter { !$0.isEmpty && $0 != path && DeletionServer.parent($0) == path }
            .sorted().map { key in
                let object = server.objects[key]!
                return entry(String(key.split(separator: "/").last!), object.kind, object.identity.fileID)
            }
        return DirectoryListing(entries)
    }

    private func list(_ catalog: Catalog, _ folder: String, _ path: String) throws {
        XCTAssertNotNil(try catalog.reconcile(folder: folder, listing: serverListing(path)) { _ in true })
    }

    private func reconcile(_ catalog: Catalog, _ folder: String, _ entries: [Parsed]) throws {
        XCTAssertNotNil(try catalog.reconcile(folder: folder, listing: DirectoryListing(entries)) { _ in true })
    }

    private func entry(_ name: String, _ kind: CatalogRow.Kind, _ fileID: UInt64) -> Parsed {
        .entry(.init(name: name, kind: kind == .folder ? .folder : .file, size: kind == .folder ? 0 : 12,
                     mtimeNs: 1_000, ctimeNs: 2_000, fileID: fileID))
    }

    private func dump(_ catalog: Catalog) throws -> [String] {
        try catalog.database.prepare("""
            SELECT row || '|' || id || '|' || quote(parent_id) || '|' || hex(name) || '|' || size || '|' || mtime_ns
              || '|' || quote(file_id) || '|' || keep || '|' || keep_request || '|' || deleted || '|' || change_seq
              || '|' || quote(edit_version) || '|' || quote(list_gen) || '|' || listing_complete FROM items
            UNION ALL SELECT 'meta|' || last_seq || '|' || listing_gen FROM meta
            UNION ALL SELECT 'departure|' || item || '|' || parent || '|' || seq FROM departures
            ORDER BY 1
            """) {
            var values: [String] = []
            while try $0.step() { values.append($0.text(0)) }
            return values
        }
    }
}
