import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class FolderMoveTests: XCTestCase {
    private var directory: URL!
    private var catalog: Catalog!
    private var tree: CatalogRow!
    private var destination: CatalogRow!
    private var base: EditBaseReceipt!
    private var outbox: FileRenameOutbox!
    private var remote: FolderRemote!
    private let domain = UUID().uuidString

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        catalog = try Catalog.create(at: directory.appending(path: "catalog"), domainID: domain, rootName: "Location")
        try list(Catalog.rootItemID, [folder("Tree", 10), folder("Archive", 20)])
        tree = try child(Catalog.rootItemID, "Tree")
        destination = try child(Catalog.rootItemID, "Archive")
        try list(tree.id, [file("plain", 30), file("verified", 40), folder("Nested", 50), file("Café", 70)])
        let nested = try child(tree.id, "Nested")
        try list(nested.id, [file("deep", 60)])
        try list(destination.id, [])
        try catalog.setWriteAccess(creation: true, editing: true)
        let verified = try child(tree.id, "verified")
        base = try EditBaseReceipt(item: verified.id, version: version(40))
        try catalog.rememberEditBase(base, expectedVersion: verified.contentVersion)
        tree = try XCTUnwrap(catalog.item(id: tree.id))
        outbox = try FileRenameOutbox(directory: directory.appending(path: "Renames"))
        remote = FolderRemote()
        remote.parents = try parents()
        remote.roots[NameKey("Tree")] = FolderMoveEvidence(identity: try identity(10), name: "Tree")
        remote.settlement = { try self.settlements($0) }
    }

    override func tearDownWithError() throws {
        remote = nil
        catalog = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testSharedInventoryKeepsOldFileReadersClosedAndRejectsOldFolderDecode() throws {
        let record = try prepare()
        XCTAssertEqual(try outbox.intents(), [.folder(record)])
        XCTAssertEqual(try outbox.pendingIntentCount(domain: domain), 1)
        XCTAssertThrowsError(try outbox.records())
        XCTAssertThrowsError(try outbox.pendingCount(domain: domain))
        XCTAssertThrowsError(try outbox.replay(owner: domain, request: request()))
        XCTAssertThrowsError(try outbox.removeCompleted(owner: domain))
        XCTAssertThrowsError(try outbox.removeCompletedIntents(removedDomain: domain))
        let data = try Data(contentsOf: recordURL(record.id))
        XCTAssertThrowsError(try JSONDecoder().decode(PendingFileRename.self, from: data))
        XCTAssertEqual(try JSONDecoder().decode(PendingFolderMove.self, from: data), record)
        XCTAssertEqual(try outbox.replayFolder(owner: domain, request: request()), record)
        XCTAssertThrowsError(try outbox.replayFolder(owner: domain, request: request(name: "Other")))
    }

    func testAttemptCheckpointPrecedesDescendantReleaseAndRemoteMutation() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .attempting {
                XCTAssertEqual(try self.saved().state, .attempting)
                XCTAssertFalse(self.remote.events.contains("release descendants"))
                throw UploadError.unresolved
            }
        })
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.moves, 0)
        record = try saved()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
        let released = try XCTUnwrap(remote.events.firstIndex(of: "release descendants"))
        let moved = try XCTUnwrap(remote.events.firstIndex(of: "move"))
        XCTAssertLessThan(released, moved)
    }

    func testLostReplyReprovesRootAndSettlesWithoutRepeatingMove() throws {
        var record = try prepare()
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(try saved().state, .attempting)
        remote.disconnected = false
        remote.disconnectAfterMove = false
        record = try saved()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertNil(remote.roots[NameKey("Tree")])
    }

    func testRootSuccessIsDurableBeforeDescendantSettlement() throws {
        var record = try prepare()
        remote.settlement = { record in
            XCTAssertEqual(try self.saved().state, .moved)
            XCTAssertEqual(record.state, .moved)
            throw UploadError.unresolved
        }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .moved)
        XCTAssertEqual(try saved().state, .moved)
        XCTAssertEqual(remote.moves, 1)
        remote.settlement = { try self.settlements($0) }
        record = try saved()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
    }

    func testErrorReplyAfterRemoteSuccessCannotBecomeARefusal() throws {
        var record = try prepare()
        remote.replyErrorAfterMove = posixError("lost result", code: EACCES)
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertNil(record.refusal)
        XCTAssertEqual(remote.moves, 1)
    }

    func testDescendantReleaseFailureStopsBeforeRenameAndKeepsTheIntent() throws {
        var record = try prepare()
        remote.releaseFailure = posixError("in use", code: EBUSY)
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(try saved().state, .attempting)
        XCTAssertEqual(remote.moves, 0)
        remote.releaseFailure = nil
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
    }

    func testProvenMoveNeverRestartsEvenWhenOriginalReturnsToSource() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        remote.roots[NameKey(record.destination)] = nil
        remote.roots[NameKey(record.source)] = FolderMoveEvidence(identity: record.identity, name: record.oldName)
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .moved)
        XCTAssertEqual(remote.moves, 1)
    }

    func testChangedAndMissingChildrenSettleAfterRemoteSuccess() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        remote.settlement = { try self.settlements($0, changed: "verified", removed: "plain") }
        record = try saved()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let settled = try XCTUnwrap(record.settlements?.first?.settlement)
        XCTAssertEqual(try saved().settlements, record.settlements)
        try catalog.settleFolderMove(record.views[0].move, settlement: settled)
        let verified = try child(tree.id, "verified")
        XCTAssertNotEqual(verified.contentVersion, base.contentVersion)
        XCTAssertTrue(verified.contentVersion.hasPrefix("e1:"))
        let oldPlain = try XCTUnwrap(record.views[0].move.entries.first { $0.name == "plain" })
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: oldPlain.item)).deleted)
        let deep = try XCTUnwrap(record.views[0].move.entries.first { $0.name == "deep" })
        XCTAssertEqual(try catalog.item(id: deep.item)?.contentVersion, deep.contentVersion)
        XCTAssertEqual(try catalog.relativePath(of: deep.item)?.string, "Archive/Moved/Nested/deep")
        XCTAssertEqual(remote.moves, 1)
    }

    func testVerifiedRetryRequiresFreshFullEvidenceAndCompletedReplayIsLocal() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .verified { throw UploadError.unresolved }
        })
        let original = try saved()
        record = original
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.settlementVerifications, 1)
        XCTAssertEqual(record.settlements, original.settlements)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertEqual(record.state, .completed)
        let calls = remote.events
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.events, calls)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(try outbox.replayFolder(owner: domain, request: request()), record)
    }

    func testChangedAfterVerifiedEvidenceRetainsImmutableSettlementForFollowup() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let durable = try saved()
        remote.verifySettlement = { _ in throw SourceFailure.versionChanged }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record, durable)
        XCTAssertEqual(try saved(), durable)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertThrowsError(try outbox.removeCompletedIntents(removedDomain: domain))
    }

    func testRetryReloadsVerifiedIntentWhenPersistenceLeftCallerAtMoved() throws {
        var record = try prepare()
        var beforePersistence: PendingFolderMove?
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { beforePersistence = try self.saved() }
            if state == .verified { throw posixError("ambiguous persistence", code: EIO) }
        })
        let durable = try saved()
        record = try XCTUnwrap(beforePersistence)
        XCTAssertEqual(record.state, .moved)
        XCTAssertEqual(durable.state, .verified)
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record, durable)
        XCTAssertEqual(remote.settlementVerifications, 1)
        XCTAssertEqual(remote.events.filter { $0 == "settle" }.count, 1)
        XCTAssertEqual(remote.moves, 1)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        record = durable
        let calls = remote.events
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(remote.events, calls)
    }

    func testRenameSucceededButDirectorySyncMustSucceedBeforeRetryCanFinish() throws {
        var failDirectorySync = false
        var syncs = 0
        outbox = try FileRenameOutbox(directory: directory.appending(path: "Renames"), directorySync: { fd in
            syncs += 1
            if failDirectorySync { throw posixError("sync rename directory", code: EIO) }
            guard Darwin.fsync(fd) == 0 else { throw posixError("sync rename directory") }
        })
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { failDirectorySync = true }
        })
        XCTAssertEqual(record.state, .moved)
        let visible = try saved()
        XCTAssertEqual(visible.state, .verified)
        let before = syncs, remoteCalls = remote.events
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(syncs, before + 1)
        XCTAssertEqual(remote.events, remoteCalls)
        XCTAssertEqual(record.state, .moved)
        failDirectorySync = false
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(syncs, before + 2)
        XCTAssertEqual(record, visible)
        XCTAssertEqual(remote.events.filter { $0 == "settle" }.count, 1)
        XCTAssertEqual(remote.settlementVerifications, 1)
        XCTAssertEqual(remote.moves, 1)
    }

    func testInMemoryCompletionCannotBypassDurableIntent() throws {
        var record = try prepare()
        record.state = .completed
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
    }

    func testParentOrSourceReplacementNeverMovesTheNewObject() throws {
        var record = try prepare()
        let originalParents = remote.parents
        remote.parents[0] = FileRenameParent(path: "", name: "", identity: try identity(999))
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .prepared)
        remote.parents = originalParents
        remote.roots[NameKey("Tree")] = FolderMoveEvidence(identity: try identity(999), name: "Tree")
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .refused)
        XCTAssertEqual(record.refusal, .changed)
        XCTAssertEqual(remote.moves, 0)
    }

    func testUncertainRootMissingOrReplacedStaysPending() throws {
        var record = try prepare()
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        remote.disconnected = false
        remote.roots[NameKey(record.destination)] = FolderMoveEvidence(identity: try identity(999), name: record.name)
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        remote.roots[NameKey(record.destination)] = nil
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.moves, 1)
    }

    func testSourceProofFailureBeforeRequestIsRefusedWithoutReleasingChildren() throws {
        var record = try prepare()
        remote.verifySource = { _ in throw SourceFailure.versionChanged }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.refusal, .changed)
        XCTAssertFalse(remote.events.contains("release descendants"))
        XCTAssertEqual(remote.moves, 0)
    }

    func testCollisionAndCrossDeviceRefusalsKeepOriginalAtSource() throws {
        var record = try prepare()
        remote.roots[NameKey(record.destination)] = FolderMoveEvidence(identity: try identity(999), name: record.name)
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.refusal, .collision)
        XCTAssertEqual(remote.moves, 0)
        remote.roots[NameKey(record.destination)] = nil
        record = try prepare()
        remote.moveFailure = posixError("cross device", code: EXDEV)
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.refusal, .unsupported)
        XCTAssertNotNil(remote.roots[NameKey(record.source)])
        XCTAssertNil(remote.roots[NameKey(record.destination)])
    }

    func testCaseOnlyMoveRecoveryRequiresExactStoredName() throws {
        remote.parents = [remote.parents[0]]
        var record = try prepare(to: Catalog.rootItemID, name: "TREE")
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.moves, 1)
        remote.disconnected = false
        remote.disconnectAfterMove = false
        remote.roots[NameKey("Tree")] = FolderMoveEvidence(identity: record.identity, name: "tree")
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        remote.roots[NameKey("Tree")] = FolderMoveEvidence(identity: record.identity, name: "TREE")
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
    }

    func testCompletedFolderHistorySurvivesOwnerRemovalUntilAllViewsAreRemoved() throws {
        let other = UUID().uuidString
        let first = try view()
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertEqual(record.state, .verified)
        XCTAssertThrowsError(try outbox.removeCompletedIntents(removedDomain: domain))
        try FolderMoveTransaction.finishDomain(other, record: &record, outbox: outbox)
        XCTAssertEqual(record.state, .completed)
        try outbox.removeCompletedIntents(removedDomain: domain)
        XCTAssertEqual(try saved().removedDomains, [domain])
        XCTAssertThrowsError(try outbox.records())
        XCTAssertNil(try outbox.replayFolder(owner: domain, request: request()))
        try outbox.removeCompletedIntents(removedDomain: domain)
        XCTAssertEqual(try outbox.intents().count, 1)
        try outbox.removeCompletedIntents(removedDomain: other)
        XCTAssertTrue(try outbox.intents().isEmpty)
    }

    func testOwnerReplaySurvivesNonOwnerViewRemoval() throws {
        let other = UUID().uuidString, first = try view()
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        try FolderMoveTransaction.finishDomain(other, record: &record, outbox: outbox)
        try outbox.removeCompletedIntents(removedDomain: other)
        let replay = try XCTUnwrap(outbox.replayFolder(owner: domain, request: request()))
        XCTAssertEqual(replay.id, record.id)
        XCTAssertEqual(replay.removedDomains, [other])
        record = replay
        let calls = remote.events
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.events, calls)
        XCTAssertEqual(remote.moves, 1)
    }

    func testOverlappingSettlementsMustAgreeOnContentsRemovalAndNativeLookup() throws {
        let other = UUID().uuidString, first = try view()
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        let preserved = try settlements(record), changed = try settlements(record, changed: "verified")
        let removed = try settlements(record, removed: "plain")
        var proposed = record
        proposed.state = .verified
        proposed.settlements = [preserved[0], changed[1]]
        XCTAssertThrowsError(try outbox.save(proposed))
        proposed.settlements = [preserved[0], removed[1]]
        XCTAssertThrowsError(try outbox.save(proposed))
        let divergent = changed[1].settlement
        let alteredContents = try divergent.resolutions.map { resolution -> CatalogFolderMoveResolution in
            guard case .changed(let observation, let receipt) = resolution else { return resolution }
            let replacement = try EditBaseReceipt(item: receipt.item,
                version: version(receipt.version.identity.fileID, digest: "c", modified: 3, changed: 4))
            return .changed(observation, receipt: replacement)
        }
        proposed.settlements = [changed[0], FolderMoveSettlement(domain: other,
            settlement: CatalogFolderMoveSettlement(proofs: divergent.proofs,
                                                      resolutions: alteredContents, listings: divergent.listings))]
        XCTAssertThrowsError(try outbox.save(proposed))
        let alteredLookup = divergent.resolutions.map { resolution -> CatalogFolderMoveResolution in
            guard case .changed(let observation, let receipt) = resolution else { return resolution }
            return .changed(CatalogFolderMoveObservation(item: observation.item,
                path: RelativePath(observation.path)!, kind: observation.kind, nativeID: observation.nativeID + 1,
                fingerprint: ContentFingerprint(size: observation.size, mtimeNs: observation.mtimeNs,
                                                ctimeNs: observation.ctimeNs),
                preservesIdentity: true, preservesContents: false), receipt: receipt)
        }
        proposed.settlements = [changed[0], FolderMoveSettlement(domain: other,
            settlement: CatalogFolderMoveSettlement(proofs: divergent.proofs,
                                                      resolutions: alteredLookup, listings: divergent.listings))]
        XCTAssertThrowsError(try outbox.save(proposed))
        XCTAssertEqual(try saved().state, .moved)
        proposed.settlements = changed
        try outbox.save(proposed)
        XCTAssertEqual(try saved().settlements, changed)
    }

    func testCompleteListingCoversKnownChildrenFromEveryView() throws {
        let other = UUID().uuidString, first = try view()
        let missing = try XCTUnwrap(first.move.entries.first { $0.name == "plain" })
        let smaller = CatalogFolderMove(item: first.move.item, destinationParent: first.move.destinationParent,
            destinationName: first.move.destinationName,
            destinationParentPath: try XCTUnwrap(RelativePath(first.move.destinationParentPath)),
            entries: first.move.entries.filter { $0.item != missing.item })
        let second = FolderMoveView(domain: other, folder: .root, move: smaller,
                                     proofs: first.proofs.filter { $0.item != missing.item })
        var record = try prepare(views: [first, second])
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        let preserved = try settlements(record)
        let full = try rootListing(first)
        let omitted = CatalogFolderMoveListing(parent: full.parent, path: RelativePath(full.path)!,
            identity: full.identity, complete: true, children: full.children.filter { $0.name != missing.name })
        var proposed = record
        proposed.state = .verified
        proposed.settlements = [preserved[0], FolderMoveSettlement(domain: other,
            settlement: CatalogFolderMoveSettlement(proofs: preserved[1].settlement.proofs,
                resolutions: preserved[1].settlement.resolutions, listings: [omitted]))]
        XCTAssertThrowsError(try outbox.save(proposed))
        proposed.settlements = [preserved[0], FolderMoveSettlement(domain: other,
            settlement: CatalogFolderMoveSettlement(proofs: preserved[1].settlement.proofs,
                resolutions: preserved[1].settlement.resolutions, listings: [full]))]
        try outbox.save(proposed)
        XCTAssertEqual(try saved().state, .verified)
    }

    func testCompleteListingsMustAgreeOnReplacementAndUnknownChildIdentities() throws {
        let other = UUID().uuidString, first = try view()
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        let removed = try settlements(record, removed: "plain")
        func replaced(_ result: FolderMoveSettlement, identity: EditFileIdentity, name: String) -> FolderMoveSettlement {
            let listings = result.settlement.listings.map { listing in
                guard listing.parent == first.move.item else { return listing }
                return CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
                    identity: listing.identity, complete: true,
                    children: listing.children + [.init(name: name, identity: identity, kind: .file)])
            }
            return FolderMoveSettlement(domain: result.domain, settlement: CatalogFolderMoveSettlement(
                proofs: result.settlement.proofs, resolutions: result.settlement.resolutions, listings: listings))
        }
        var proposed = record
        proposed.state = .verified
        proposed.settlements = [replaced(removed[0], identity: try identity(900), name: "plain"),
                                 replaced(removed[1], identity: try identity(901), name: "plain")]
        XCTAssertThrowsError(try outbox.save(proposed))
        proposed.settlements = [replaced(removed[0], identity: try identity(900), name: "new-child"),
                                 replaced(removed[1], identity: try identity(901), name: "new-child")]
        XCTAssertThrowsError(try outbox.save(proposed))
        proposed.settlements = [replaced(removed[0], identity: try identity(900), name: "New-Café"),
                                 replaced(removed[1], identity: try identity(900), name: "New-Cafe\u{301}")]
        XCTAssertThrowsError(try outbox.save(proposed))
        proposed.settlements = [replaced(removed[0], identity: try identity(900), name: "plain"),
                                 replaced(removed[1], identity: try identity(900), name: "plain")]
        try outbox.save(proposed)
    }

    func testOverlappingDescendantCaseAndUnicodeAliasesCannotBypassProofComparison() throws {
        let first = try view(), other = UUID().uuidString
        for (name, alias) in [("plain", "PLAIN"), ("Café", "Cafe\u{301}"), ("Café", "CAFÉ")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first.move))
                as? [String: Any])
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            let index = try XCTUnwrap(entries.firstIndex { $0["name"] as? String == name })
            entries[index]["name"] = alias
            entries[index]["path"] = "Tree/" + alias
            object["entries"] = entries
            let move = try JSONDecoder().decode(CatalogFolderMove.self, from: JSONSerialization.data(withJSONObject: object))
            let second = FolderMoveView(domain: other, folder: .root, move: move, proofs: first.proofs)
            XCTAssertThrowsError(try prepare(views: [first, second]))
        }
        XCTAssertTrue(try outbox.intents().isEmpty)
    }

    func testImmutableAdmissionAndSettlementCannotBeReplacedOrRewound() throws {
        var record = try prepare()
        let source = try saved()
        let replaced = PendingFolderMove(kind: .folder, id: record.id, owner: domain,
                                         metadataVersion: record.metadataVersion, source: record.source,
                                         destination: record.destination, identity: record.identity,
                                         parents: [FileRenameParent(path: "", name: "", identity: try identity(999)),
                                                   record.parents[1]], views: record.views)
        try replaced.validate()
        XCTAssertThrowsError(try outbox.save(replaced))
        var mismatched = replaced
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&mismatched, outbox: outbox, remote: remote))
        XCTAssertTrue(remote.events.isEmpty)
        XCTAssertEqual(try saved(), source)
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let verified = record
        record.settlements = try settlements(record, changed: "verified")
        XCTAssertThrowsError(try outbox.save(record))
        XCTAssertThrowsError(try outbox.save(source))
        XCTAssertEqual(try saved(), verified)
    }

    func testIncompleteAdmissionAndSettlementCannotBecomeDurable() throws {
        let valid = try view()
        let incomplete = FolderMoveView(domain: domain, folder: .root, move: valid.move,
                                         proofs: Array(valid.proofs.dropLast()))
        XCTAssertThrowsError(try prepare(views: [incomplete]))
        XCTAssertTrue(try outbox.intents().isEmpty)
        var record = try prepare()
        remote.settlement = { record in
            let results = try self.settlements(record)
            let value = results[0].settlement
            return [FolderMoveSettlement(domain: self.domain, settlement: CatalogFolderMoveSettlement(
                proofs: value.proofs, resolutions: Array(value.resolutions.dropLast()), listings: []))]
        }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .moved)
        XCTAssertEqual(try saved().state, .moved)
        XCTAssertNil(try saved().settlements)
    }

    func testMissingChildNeedsCompleteParentListingAndRootCannotBeRemoved() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        let results = try settlements(record, removed: "plain")
        let value = results[0].settlement
        var invalid = record
        invalid.state = .verified
        invalid.settlements = [FolderMoveSettlement(domain: domain, settlement: CatalogFolderMoveSettlement(
            proofs: value.proofs, resolutions: value.resolutions, listings: []))]
        XCTAssertThrowsError(try outbox.save(invalid))
        invalid.settlements = [FolderMoveSettlement(domain: domain, settlement: CatalogFolderMoveSettlement(
            proofs: value.proofs, resolutions: value.resolutions.map {
                $0.item == tree.id ? .removed(item: tree.id) : $0
            }, listings: value.listings))]
        XCTAssertThrowsError(try outbox.save(invalid))
        XCTAssertEqual(try saved().state, .moved)
    }

    func testFolderIntentCannotOverwriteFileIntentWithSameUUIDOrViceVersa() throws {
        let candidate = try prepare()
        let fileRow = try child(tree.id, "verified")
        let fileView = try FileRenameView(domain: domain, folder: .root, row: fileRow,
                                          path: XCTUnwrap(RelativePath("Tree/verified")), nativeID: 40)
        let fileRecord = PendingFileRename(id: candidate.id, owner: domain, base: base,
                                           metadataVersion: fileRow.metadataVersion, source: "Tree/verified",
                                           destination: "Tree/renamed", views: [fileView])
        XCTAssertThrowsError(try outbox.save(fileRecord))
        XCTAssertEqual(try saved(), candidate)
        let separate = try FileRenameOutbox(directory: directory.appending(path: "OtherRenames"))
        try separate.save(fileRecord)
        XCTAssertThrowsError(try separate.save(candidate))
        XCTAssertEqual(try separate.records(), [fileRecord])
        XCTAssertEqual(try separate.intents(), [.file(fileRecord)])
        let encoded = try JSONEncoder().encode(fileRecord)
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])["kind"])
    }

    func testMalformedDiskRecordDoesNotDisappearFromInventory() throws {
        let record = try prepare()
        var malformed = try object(record)
        malformed["kind"] = "unknown"
        try JSONSerialization.data(withJSONObject: malformed).write(to: recordURL(record.id))
        XCTAssertThrowsError(try outbox.intents())
        XCTAssertThrowsError(try outbox.pendingIntentCount(domain: domain))
        XCTAssertThrowsError(try outbox.removeCompletedIntents(removedDomain: domain))
        malformed = try object(record)
        malformed["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: malformed).write(to: recordURL(record.id))
        XCTAssertThrowsError(try outbox.intents())
    }

    func testDuplicateProofsAndConflictingOverlappingViewsAreRejected() throws {
        let valid = try view()
        var proofs = valid.proofs
        proofs[proofs.count - 1] = proofs[0]
        let duplicate = FolderMoveView(domain: domain, folder: .root, move: valid.move, proofs: proofs)
        XCTAssertThrowsError(try prepare(views: [duplicate]))
        let wrongBase = try valid.proofs.map { proof -> CatalogFolderMoveProof in
            if case .file(let receipt) = proof, receipt.item == base.item {
                return .file(try EditBaseReceipt(item: receipt.item, version: receipt.version))
            }
            return proof
        }
        XCTAssertThrowsError(try prepare(views: [FolderMoveView(domain: domain, folder: .root,
                                                                move: valid.move, proofs: wrongBase)]))
        let other = UUID().uuidString
        let differing = try valid.proofs.map { proof -> CatalogFolderMoveProof in
            if case .file(let receipt) = proof, receipt.item != base.item {
                return .file(try EditBaseReceipt(item: receipt.item,
                    version: version(receipt.version.identity.fileID, digest: "b")))
            }
            return proof
        }
        let conflict = FolderMoveView(domain: other, folder: .root, move: valid.move, proofs: differing)
        XCTAssertThrowsError(try prepare(views: [valid, conflict]))
        XCTAssertTrue(try outbox.intents().isEmpty)
    }

    func testIncompleteAncestorsAndFalseUnchangedFieldsAreRefusedAtAdmission() throws {
        remote.parents = Array(remote.parents.prefix(1))
        XCTAssertThrowsError(try prepare())
        remote.parents = try parents()
        let view = try view()
        let request = try FileRenameRequest(item: tree.id, parent: destination.id, name: "Moved",
                                            contentVersion: tree.contentVersion, metadataVersion: tree.metadataVersion,
                                            changesName: false, changesParent: true)
        XCTAssertThrowsError(try outbox.prepareFolder(owner: domain, request: request,
            source: XCTUnwrap(RelativePath("Tree")), destination: XCTUnwrap(RelativePath("Archive/Moved")),
            identity: identity(10), parents: remote.parents, views: [view]))
        XCTAssertTrue(try outbox.intents().isEmpty)
    }

    private func prepare(to parent: String? = nil, name: String = "Moved",
                         views: [FolderMoveView]? = nil) throws -> PendingFolderMove {
        let views = try views ?? [view(to: parent, name: name)]
        let target = try XCTUnwrap(RelativePath(views[0].move.destinationParentPath)?.appending(name))
        return try outbox.prepareFolder(owner: domain, request: request(to: parent, name: name),
                                         source: XCTUnwrap(RelativePath("Tree")), destination: target,
                                         identity: identity(10), parents: remote.parents, views: views)
    }

    private func view(to parent: String? = nil, name: String = "Moved") throws -> FolderMoveView {
        let move = try catalog.prepareFolderMove(item: tree.id, destinationParent: parent ?? destination.id,
                                                 destinationName: name)
        let proofs = try move.entries.map { entry -> CatalogFolderMoveProof in
            if entry.kind == .folder { return .directory(item: entry.item, identity: try identity(entry.nativeID)) }
            if entry.item == base.item { return .file(base) }
            return .file(try EditBaseReceipt(item: entry.item, version: version(entry.nativeID)))
        }
        return FolderMoveView(domain: domain, folder: .root, move: move, proofs: proofs)
    }

    private func request(to parent: String? = nil, name: String = "Moved") throws -> FileRenameRequest {
        try FileRenameRequest(item: tree.id, parent: parent ?? destination.id, name: name,
                              contentVersion: tree.contentVersion, metadataVersion: tree.metadataVersion)
    }

    private func rootListing(_ view: FolderMoveView) throws -> CatalogFolderMoveListing {
        let root = try XCTUnwrap(view.move.entries.first { $0.item == view.move.item })
        let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
        let children = view.move.entries.filter { $0.parent == root.item }.map {
            CatalogFolderMoveListing.Child(name: $0.name, identity: proofs[$0.item]!.identity, kind: $0.kind)
        }
        return CatalogFolderMoveListing(parent: root.item, path: try XCTUnwrap(view.destinationPath(for: root)),
                                         identity: proofs[root.item]!.identity, complete: true, children: children)
    }

    private func settlements(_ record: PendingFolderMove, changed: String? = nil,
                             removed: String? = nil) throws -> [FolderMoveSettlement] {
        try record.views.map { view in
            let resolutions = try view.move.entries.map { entry -> CatalogFolderMoveResolution in
                if entry.name == removed { return .removed(item: entry.item) }
                let isChanged = entry.name == changed
                let fingerprint = ContentFingerprint(size: entry.size, mtimeNs: isChanged ? 3_000 : entry.mtimeNs,
                                                       ctimeNs: isChanged ? 4_000 : entry.ctimeNs)
                let after = CatalogFolderMoveObservation(item: entry.item,
                    path: try XCTUnwrap(view.destinationPath(for: entry)), kind: entry.kind,
                    nativeID: entry.nativeID + 1_000, fingerprint: fingerprint,
                    preservesIdentity: true, preservesContents: entry.kind == .file && !isChanged)
                if isChanged {
                    let receipt = try EditBaseReceipt(item: entry.item,
                        version: version(entry.nativeID, digest: "b", modified: 3, changed: 4))
                    return .changed(after, receipt: receipt)
                }
                return .preserved(after)
            }
            let proofs = Dictionary(uniqueKeysWithValues: view.proofs.map { ($0.item, $0) })
            var listings: [CatalogFolderMoveListing] = []
            if removed != nil {
                for parent in view.move.entries where parent.kind == .folder {
                    let children = view.move.entries.filter { $0.parent == parent.item && $0.name != removed }.map {
                        CatalogFolderMoveListing.Child(name: $0.name, identity: proofs[$0.item]!.identity, kind: $0.kind)
                    }
                    listings.append(CatalogFolderMoveListing(parent: parent.item,
                        path: try XCTUnwrap(view.destinationPath(for: parent)), identity: proofs[parent.item]!.identity,
                        complete: true, children: children))
                }
            }
            return FolderMoveSettlement(domain: view.domain, settlement: CatalogFolderMoveSettlement(
                proofs: view.proofs, resolutions: resolutions, listings: listings))
        }
    }

    private func identity(_ id: UInt64) throws -> EditFileIdentity {
        try EditFileIdentity(fileID: id, birthMicroseconds: 100)
    }

    private func version(_ id: UInt64, digest: Character = "a", modified: UInt64 = 1,
                         changed: UInt64 = 2) throws -> EditFileVersion {
        try EditFileVersion(identity: identity(id), size: 10, digest: String(repeating: String(digest), count: 64),
                            modifiedMicroseconds: modified, changedMicroseconds: changed, attributes: 32, security: Data([1]))
    }

    private func parents() throws -> [FileRenameParent] {
        [FileRenameParent(path: "", name: "", identity: try identity(1)),
         FileRenameParent(path: "Archive", name: "Archive", identity: try identity(20))]
    }

    private func saved() throws -> PendingFolderMove {
        guard case .folder(let record) = try XCTUnwrap(outbox.intents().first) else { throw UploadError.unresolved }
        return record
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appending(path: "Renames/" + id.uuidString + ".rename")
    }

    private func object(_ record: PendingFolderMove) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    private func child(_ parent: String, _ name: String) throws -> CatalogRow {
        try XCTUnwrap(catalog.liveChild(parent: parent, nameKey: NameKey(name)))
    }

    private func list(_ parent: String, _ children: [DirectoryListing.Parsed]) throws {
        _ = try catalog.reconcile(folder: parent, listing: DirectoryListing(children)) { _ in true }
    }

    private func folder(_ name: String, _ id: UInt64) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 1_000, ctimeNs: 2_000, fileID: id))
    }

    private func file(_ name: String, _ id: UInt64) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: id))
    }
}

private final class FolderRemote: FolderMoveRemote {
    var roots: [NameKey: FolderMoveEvidence] = [:]
    var parents: [FileRenameParent] = []
    var events: [String] = []
    var moves = 0
    var disconnectAfterMove = false
    var disconnected = false
    var moveFailure: Error?
    var replyErrorAfterMove: Error?
    var releaseFailure: Error?
    var settlement: ((PendingFolderMove) throws -> [FolderMoveSettlement])!
    var verifySource: (PendingFolderMove) throws -> Void = { _ in }
    var verifySettlement: (PendingFolderMove) throws -> Void = { _ in }
    var settlementVerifications = 0

    func protectFolderMoveParents(source: String, destination: String) throws -> [FileRenameParent] {
        events.append("parents")
        return parents
    }

    func inspectFolderMoveRoot(path: String) throws -> FolderMoveEvidence? {
        events.append("inspect")
        if disconnected { throw posixError("disconnected", code: EIO) }
        return roots[NameKey(path)]
    }

    func releaseFolderMoveRoot(path: String) throws { events.append("release root") }

    func verifyFolderMoveSource(_ record: PendingFolderMove) throws {
        events.append("verify source")
        try verifySource(record)
    }

    func releaseFolderMoveDescendants() throws {
        events.append("release descendants")
        if let releaseFailure { throw releaseFailure }
    }

    func moveFolder(source: String, destination: String) throws {
        events.append("move")
        if let moveFailure { throw moveFailure }
        let old = NameKey(source), new = NameKey(destination)
        guard let root = roots[old] else { throw posixError("move", code: ENOENT) }
        guard old == new || roots[new] == nil else { throw UploadError.collision }
        roots[old] = nil
        roots[new] = FolderMoveEvidence(identity: root.identity, name: RelativePath(destination)!.components.last!)
        moves += 1
        if disconnectAfterMove {
            disconnected = true
            throw posixError("lost reply", code: EIO)
        }
        if let replyErrorAfterMove { throw replyErrorAfterMove }
    }

    func settleFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveSettlement] {
        events.append("settle")
        return try settlement(record)
    }

    func verifyFolderMoveSettlement(_ record: PendingFolderMove) throws {
        events.append("verify settlement")
        settlementVerifications += 1
        try verifySettlement(record)
    }
}
