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
        try catalog.setAllowsWriting(true)
        let verified = try child(tree.id, "verified")
        base = try EditBaseReceipt(item: verified.id, version: version(40))
        try catalog.rememberEditBase(base, expectedVersion: verified.contentVersion)
        tree = try XCTUnwrap(catalog.item(id: tree.id))
        outbox = try FileRenameOutbox(directory: directory.appending(path: "Renames"))
        remote = FolderRemote()
        remote.parents = try parents()
        remote.roots[NameKey("Tree")] = FolderMoveEvidence(identity: try identity(10), name: "Tree")
        remote.settlement = { try self.settlements($0) }
        remote.refresh = { try self.refreshes($0) }
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

    func testFileAdmissionWaitsForFolderIntentButAcceptsCompletedHistory() throws {
        var folder = try prepare()
        let row = try XCTUnwrap(catalog.item(id: base.item))
        let path = try XCTUnwrap(catalog.relativePath(of: row.id))
        let request = try FileRenameRequest(item: row.id, parent: XCTUnwrap(row.parentID), name: "renamed",
            contentVersion: row.contentVersion, metadataVersion: row.metadataVersion)
        let view = try FileRenameView(domain: domain, folder: .root, row: row, path: path, nativeID: 40)
        XCTAssertThrowsError(try outbox.replayFile(owner: domain, request: request))
        XCTAssertThrowsError(try outbox.prepareFile(owner: domain, request: request, base: base,
                                                   source: path, views: [view]))
        XCTAssertEqual(try outbox.intents().count, 1)
        try FolderMoveTransaction.publish(&folder, outbox: outbox, remote: remote)
        try FolderMoveTransaction.finishDomain(domain, record: &folder, outbox: outbox)
        XCTAssertNil(try outbox.replayFile(owner: domain, request: request))
        let file = try outbox.prepareFile(owner: domain, request: request, base: base, source: path, views: [view])
        XCTAssertEqual(try outbox.replayFile(owner: domain, request: request), file)
        XCTAssertEqual(try outbox.prepareFile(owner: domain, request: request, base: base,
                                             source: path, views: [view]), file)
        XCTAssertEqual(try outbox.intents().count, 2)
        XCTAssertEqual(try outbox.pendingIntentCount(domain: domain), 1)
        XCTAssertThrowsError(try outbox.records())
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

    func testParentCreationTimesCheckpointBeforeReleasingMoveProtection() throws {
        var record = try prepare()
        let admitted = record.parents
        remote.changedParentBirthAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        XCTAssertEqual(record.state, .moved)
        XCTAssertNotEqual(record.parents, admitted)
        XCTAssertEqual(try saved().parents, remote.parents)
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertEqual(record.state, .completed)
    }

    func testLostProtectionCannotRebindChangedParentCreationTimes() throws {
        var record = try prepare()
        let admitted = record.parents
        remote.changedParentBirthAfterMove = true
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(try saved().parents, admitted)
        remote.disconnected = false
        remote.disconnectAfterMove = false
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(try saved().parents, admitted)
    }

    func testParentCheckpointNeverAcceptsAnotherDirectoryOrChangesAfterSettlement() throws {
        var record = try prepare()
        remote.verifySource = { _ in
            let old = self.remote.parents[0]
            self.remote.parents[0] = FileRenameParent(path: old.path, name: old.name,
                identity: try self.identity(old.identity.fileID + 100))
        }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(try saved().state, .attempting)
        remote.parents = record.parents
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        let old = record.parents[0]
        record.parents[0] = FileRenameParent(path: old.path, name: old.name,
            identity: try EditFileIdentity(fileID: old.identity.fileID,
                                           birthMicroseconds: old.identity.birthMicroseconds + 1))
        XCTAssertThrowsError(try outbox.save(record))
        XCTAssertEqual(try saved().parents, remote.parents)
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
        remote.settlement = { record in
            try self.departedRoot(record).map { refresh in
                let view = record.views.first { $0.domain == refresh.domain }!
                return FolderMoveSettlement(domain: view.domain, settlement: CatalogFolderMoveSettlement(
                    proofs: view.proofs, resolutions: view.move.entries.map { .removed(item: $0.item) },
                    listings: refresh.listings))
            }
        }
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertTrue(record.rootRetired)
        let view = record.views[0]
        try catalog.settleFolderMove(view.move, settlement: XCTUnwrap(record.settlements?.first).settlement)
        XCTAssertTrue(try record.latestTarget(domain: domain).entries.allSatisfy(\.retired))
        for entry in view.move.entries { XCTAssertEqual(try catalog.item(id: entry.item)?.deleted, true) }
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertThrowsError(try record.requireMoved()) { XCTAssertEqual($0 as? SourceFailure, .versionChanged) }
        let completed = record, events = remote.events
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record, completed)
        XCTAssertEqual(remote.events, events)
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

    func testSourceOnlyAncestorChangesRequireDurablyMovedState() throws {
        var record = try prepareNestedMove()
        let originalParents = remote.parents
        remote.parents[2] = FileRenameParent(path: "Tree", name: "Tree", identity: try identity(999))
        record.state = .moved
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .prepared)
        XCTAssertEqual(remote.protectedSources.last, record.source)
        XCTAssertEqual(remote.moves, 0)
        remote.parents = originalParents
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.moves, 1)
        remote.disconnected = false
        remote.parents.removeLast()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.protectedSources.last, record.source)
        remote.parents = originalParents
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        XCTAssertEqual(try saved().state, .moved)
        remote.parents.removeLast()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.protectedSources.last, record.destination)
        XCTAssertEqual(record.parents, originalParents)
        remote.parents = originalParents
        remote.parents[2] = FileRenameParent(path: "Tree", name: "TREE", identity: try identity(999))
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.settlementVerifications, 1)
        let expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertEqual(record.state, .recovering)
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertTrue(remote.events.contains("verify recovery"))
        XCTAssertEqual(remote.protectedSources.last, record.destination)
        XCTAssertEqual(remote.moves, 1)
    }

    func testDestinationAncestorsRemainStrictAfterMoveAndDuringRecovery() throws {
        var record = try prepareNestedMove()
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .moved { throw UploadError.unresolved }
        })
        let parents = record.destinationParents
        for state in [PendingFolderMove.State.moved, .verified, .recovering] {
            let durable = try saved()
            XCTAssertEqual(durable.state, state)
            for index in parents.indices {
                remote.parents = parents
                let parent = parents[index]
                remote.parents[index] = FileRenameParent(path: parent.path, name: parent.name, identity: try identity(999))
                XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
                if state != .moved {
                    let expected = try classified(record)
                    XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox,
                                                                          expected: expected, remote: remote))
                }
                XCTAssertEqual(try saved(), durable)
            }
            remote.parents = [parents[0], FileRenameParent(path: "Archive", name: "ARCHIVE", identity: parents[1].identity)]
            XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
            XCTAssertEqual(try saved(), durable)
            remote.parents = parents
            if state == .verified {
                let expected = try classified(record)
                try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
            } else {
                try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
            }
        }
        XCTAssertEqual(remote.moves, 1)
    }

    func testDestinationParentSubsetUsesExactComponentPrefixes() throws {
        let original = try prepare()
        let paths = ["", "Archive", "Archive/Café", "Archive/Cafe\u{301}", "Archive/CaféExtra", "archive"]
        let parents = try paths.enumerated().map { index, path in
            FileRenameParent(path: path, name: RelativePath(path)!.components.last ?? "", identity: try identity(UInt64(index + 1)))
        }
        let record = PendingFolderMove(kind: .folder, id: original.id, owner: original.owner,
            metadataVersion: original.metadataVersion, source: original.source, destination: "Archive/Café/Moved",
            identity: original.identity, parents: parents, views: original.views)
        XCTAssertEqual(record.destinationParents, Array(parents.prefix(3)))
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

    func testNonDirectoryDestinationRefusesOnlyWhileOriginalSourceIsProved() throws {
        var record = try prepare()
        remote.nonDirectories.insert(NameKey(record.destination))
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.refusal, .collision)
        XCTAssertEqual(remote.moves, 0)
        remote.nonDirectories.removeAll()
        record = try prepare()
        remote.disconnectAfterMove = true
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        remote.disconnected = false
        remote.nonDirectories.insert(NameKey(record.destination))
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertNil(record.refusal)
        XCTAssertEqual(remote.moves, 1)
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

    func testSettlementListingBudgetIsSharedAcrossViews() throws {
        let first = try view()
        let second = FolderMoveView(domain: UUID().uuidString, folder: .root,
                                    move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        let preserved = try settlements(record), root = try rootListing(first)
        let unknown = try identity(9_000)
        let children = root.children + (root.children.count..<DirectoryListing.defaultLimit / 2).map {
            CatalogFolderMoveListing.Child(name: "unknown-\($0)", identity: unknown, kind: .file)
        }
        func withChildren(_ children: [CatalogFolderMoveListing.Child]) -> [FolderMoveSettlement] {
            preserved.map {
                FolderMoveSettlement(domain: $0.domain, settlement: CatalogFolderMoveSettlement(
                    proofs: $0.settlement.proofs, resolutions: $0.settlement.resolutions,
                    listings: [CatalogFolderMoveListing(parent: root.parent, path: RelativePath(root.path)!,
                        identity: root.identity, complete: true, children: children)]))
            }
        }
        record.state = .verified
        record.settlements = withChildren(children)
        XCTAssertNoThrow(try record.validate())
        record.settlements = withChildren(children + [
            CatalogFolderMoveListing.Child(name: "one-too-many", identity: unknown, kind: .file)
        ])
        XCTAssertThrowsError(try record.validate())
        XCTAssertEqual(try saved().state, .prepared)
        XCTAssertEqual(remote.moves, 0)
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

    func testInitialSettlementRequiresNewReceiptForMtimeOnlyChange() throws {
        var record = try prepare()
        let refreshed = try EditBaseReceipt(item: base.item, version: version(40, modified: 2, changed: 3))
        func result(_ record: PendingFolderMove, changed: Bool) throws -> [FolderMoveSettlement] {
            try settlements(record).map { result in
                let resolutions = result.settlement.resolutions.map { resolution -> CatalogFolderMoveResolution in
                    guard case .preserved(let observed) = resolution, observed.item == base.item else { return resolution }
                    let after = CatalogFolderMoveObservation(item: observed.item, path: RelativePath(observed.path)!,
                        kind: .file, nativeID: observed.nativeID,
                        fingerprint: ContentFingerprint(size: observed.size, mtimeNs: 2_000, ctimeNs: 3_000),
                        preservesIdentity: true, preservesContents: true)
                    return changed ? .changed(after, receipt: refreshed) : .preserved(after)
                }
                return FolderMoveSettlement(domain: result.domain, settlement: CatalogFolderMoveSettlement(
                    proofs: result.settlement.proofs, resolutions: resolutions, listings: result.settlement.listings))
            }
        }
        remote.settlement = { try result($0, changed: false) }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .moved)
        remote.settlement = { try result($0, changed: true) }
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let settlement = try XCTUnwrap(record.settlements?.first?.settlement)
        try catalog.settleFolderMove(record.views[0].move, settlement: settlement)
        XCTAssertEqual(try catalog.item(id: base.item)?.contentVersion, refreshed.contentVersion)
        XCTAssertNotEqual(refreshed.contentVersion, base.contentVersion)
        XCTAssertEqual(remote.moves, 1)
    }

    func testActiveRecoveryRejectsOlderStateDecoderAndCompletedReplayDoesNothing() throws {
        struct EarlierFolderRecord: Decodable {
            enum State: String, Decodable { case prepared, attempting, moved, verified, completed, refused }
            let state: State
            let settlements: [FolderMoveSettlement]?
        }
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let original = record.settlements
        remote.refresh = { try self.refreshes($0, contents: ["verified": "b"]) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: classified(record), remote: remote)
        XCTAssertThrowsError(try JSONDecoder().decode(EarlierFolderRecord.self,
            from: Data(contentsOf: recordURL(record.id))))
        let current = try XCTUnwrap(record.recovery?.first)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        let earlier = try JSONDecoder().decode(EarlierFolderRecord.self, from: Data(contentsOf: recordURL(record.id)))
        XCTAssertEqual(earlier.state, .completed)
        XCTAssertEqual(earlier.settlements, original)
        let anchor = try catalog.currentAnchor(), calls = remote.events
        remote.disconnected = true
        record = try XCTUnwrap(outbox.replayFolder(owner: domain, request: request()))
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(remote.events, calls)
        XCTAssertEqual(try catalog.currentAnchor(), anchor)
        XCTAssertEqual(try catalog.item(id: base.item)?.contentVersion,
                       current.target.entries.first { $0.item == base.item }?.contentVersion)
    }

    func testRecoveryCatchesUpOverlappingCatalogsAfterCommitBeforeMarker() throws {
        let otherDomain = UUID().uuidString
        let other = try Catalog.create(at: directory.appending(path: "other-catalog"), domainID: otherDomain,
                                        rootName: "Other")
        try other.reconcile(folder: Catalog.rootItemID,
            listing: DirectoryListing([folder("Tree", 10), folder("Archive", 20)])) { _ in true }
        let otherTree = try XCTUnwrap(other.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Tree")))
        let archive = try XCTUnwrap(other.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Archive")))
        try other.reconcile(folder: otherTree.id, listing: DirectoryListing([
            file("plain", 30), file("verified", 40), folder("Nested", 50), file("Café", 70)])) { _ in true }
        let nested = try XCTUnwrap(other.liveChild(parent: otherTree.id, nameKey: NameKey("Nested")))
        try other.reconcile(folder: nested.id, listing: DirectoryListing([file("deep", 60)])) { _ in true }
        try other.reconcile(folder: archive.id, listing: DirectoryListing([])) { _ in true }
        let first = try view(), move = try other.prepareFolderMove(item: otherTree.id,
            destinationParent: archive.id, destinationName: "Moved")
        let proofs = try move.entries.map { entry -> CatalogFolderMoveProof in
            if entry.kind == .folder { return .directory(item: entry.item, identity: try identity(entry.nativeID)) }
            return .file(try EditBaseReceipt(item: entry.item, version: version(entry.nativeID)))
        }
        let second = FolderMoveView(domain: otherDomain, folder: .root, move: move, proofs: proofs)
        var record = try prepare(views: [first, second])
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let originalSettlements = record.settlements
        try catalog.settleFolderMove(first.move, settlement: XCTUnwrap(record.settlements?.first?.settlement))
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        remote.refresh = { try self.refreshes($0, contents: ["verified": "b"], removed: ["plain"]) }
        var expected = try classified(record)
        expected[otherDomain] = try other.classifyFolderMove(move, proofs: proofs,
            allowed: record.allowedCatalogStates(domain: otherDomain))
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertEqual(record.state, .recovering)
        XCTAssertTrue(record.finishedDomains.isEmpty)
        let firstRound = try XCTUnwrap(record.recovery)
        let ownerTarget = try XCTUnwrap(firstRound.first { $0.domain == domain })
        try catalog.applyFolderMoveRecovery(first.move, proofs: first.proofs,
                                             expected: ownerTarget.expected, target: ownerTarget.target)
        record = try saved()
        expected = try classified(record)
        expected[otherDomain] = try other.classifyFolderMove(move, proofs: proofs,
            allowed: record.allowedCatalogStates(domain: otherDomain))
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        for current in try XCTUnwrap(record.recovery) {
            XCTAssertEqual(current.target, firstRound.first { $0.domain == current.domain }?.target)
            XCTAssertLessThanOrEqual(try record.allowedCatalogStates(domain: current.domain).count, 3)
            let catalog = current.domain == domain ? self.catalog! : other
            let view = current.domain == domain ? first : second
            try catalog.applyFolderMoveRecovery(view.move, proofs: view.proofs,
                                                 expected: current.expected, target: current.target)
            XCTAssertEqual(try catalog.classifyFolderMove(view.move, proofs: view.proofs,
                allowed: record.allowedCatalogStates(domain: current.domain)), current.target)
            try FolderMoveTransaction.finishDomain(current.domain, record: &record, outbox: outbox)
        }
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.settlements, originalSettlements)
        XCTAssertEqual(record.recovery?.count, 2)
        XCTAssertEqual(remote.moves, 1)
        for (view, catalog) in [(first, catalog!), (second, other)] {
            let plain = try XCTUnwrap(view.move.entries.first { $0.name == "plain" })
            XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.item)).deleted)
            XCTAssertNil(try catalog.liveChild(parent: view.move.item, nameKey: NameKey("plain")))
            XCTAssertEqual(try catalog.item(id: view.move.item)?.name, "Moved")
        }
    }

    func testRecoveryReusesReceiptsForCtimeAndMintsForMtimeOrRevertedContents() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let original = record
        remote.refresh = { try self.refreshes($0, changedTime: 9) }
        var expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        var current = try XCTUnwrap(record.recovery?.first)
        let item = base.item
        XCTAssertEqual(current.target.entries.first { $0.item == item }?.proof, .file(base))
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        remote.refresh = { try self.refreshes($0, modified: ["verified": 2], changedTime: 9) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        current = try XCTUnwrap(record.recovery?.first)
        let retimed = try XCTUnwrap(current.target.entries.first { $0.item == item })
        XCTAssertNotEqual(retimed.contentVersion, base.contentVersion)
        guard case .file(let retimedReceipt) = retimed.proof else { return XCTFail("Expected receipt") }
        XCTAssertTrue(retimedReceipt.version.hasSameContents(as: base.version))
        XCTAssertEqual(retimedReceipt.version.modifiedMicroseconds, 2)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        remote.refresh = { try self.refreshes($0, contents: ["verified": "b"], changedTime: 10) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        let changed = try XCTUnwrap(record.recovery?.first?.target.entries.first { $0.item == item })
        remote.refresh = { try self.refreshes($0, contents: ["verified": "a"], modified: ["verified": 1], changedTime: 11) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        current = try XCTUnwrap(record.recovery?.first)
        let reverted = try XCTUnwrap(current.target.entries.first { $0.item == item })
        XCTAssertNotEqual(reverted.contentVersion, changed.contentVersion)
        XCTAssertNotEqual(reverted.contentVersion, retimed.contentVersion)
        XCTAssertNotEqual(reverted.contentVersion, base.contentVersion)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        remote.refresh = { try self.refreshes($0, changedTime: 12) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertEqual(record.recovery?.first?.target.entries.first { $0.item == item }?.proof, reverted.proof)
        XCTAssertEqual(record.settlements, original.settlements)
        XCTAssertEqual(record.views, original.views)
    }

    func testRetirementWitnessSurvivesReappearanceAndFurtherReplans() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        remote.refresh = { try self.refreshes($0, removed: ["plain"]) }
        var expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        var current = try XCTUnwrap(record.recovery?.first)
        let plain = try XCTUnwrap(record.views[0].move.entries.first { $0.name == "plain" })
        let retired = try XCTUnwrap(current.target.entries.first { $0.item == plain.item })
        XCTAssertNotNil(retired.retirement)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        remote.refresh = { try self.refreshes($0, reappeared: ["plain"]) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertEqual(record.recovery?.first?.target.entries.first { $0.item == plain.item }, retired)
        remote.refresh = { try self.refreshes($0) }
        expected = try classified(record)
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        current = try XCTUnwrap(record.recovery?.first)
        XCTAssertTrue(current.listings.isEmpty)
        XCTAssertEqual(current.target.entries.first { $0.item == plain.item }, retired)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: plain.item)).deleted)
        XCTAssertNil(try catalog.liveChild(parent: tree.id, nameKey: NameKey(plain.name)))
    }

    func testSettlementRetiresRenamedBindingsAcrossOverlappingViews() throws {
        let first = try view(), other = UUID().uuidString
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        remote.settlement = { try self.settlements($0, renamed: ["plain": "PLAIN", "Café": "CAF\u{c9}"]) }
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(try saved(), record)
        for view in record.views {
            let target = try record.latestTarget(domain: view.domain)
            let retired = Set(target.entries.filter(\.retired).map(\.item))
            XCTAssertEqual(retired, Set(view.move.entries.filter { ["plain", "Café"].contains($0.name) }.map(\.item)))
        }
        try catalog.settleFolderMove(first.move, settlement: XCTUnwrap(record.settlements?.first).settlement)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: childID("plain", in: first))).deleted)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: childID("Café", in: first))).deleted)
    }

    func testSettlementCannotRetireAnotherNormalizationOfTheSameName() throws {
        var record = try prepare()
        remote.settlement = { try self.settlements($0, renamed: ["Café": "Cafe\u{301}"]) }
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .invalidRequest)
        }
        XCTAssertNil(try saved().settlements)
    }

    func testRecoveryRetiresRenamedFilesAndDirectoryDescendantsAcrossViews() throws {
        let first = try view(), other = UUID().uuidString
        let second = FolderMoveView(domain: other, folder: .root, move: first.move, proofs: first.proofs)
        var record = try prepare(views: [first, second])
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        try catalog.settleFolderMove(first.move, settlement: XCTUnwrap(record.settlements?.first).settlement)
        let original = record
        let expected = try Dictionary(uniqueKeysWithValues: record.views.map {
            ($0.domain, try record.latestTarget(domain: $0.domain))
        })
        remote.refresh = { try self.refreshes($0, renamed: ["plain": "plain"]) }
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
        XCTAssertEqual(try saved(), original)
        remote.refresh = { try self.refreshes($0, removed: ["deep"],
            renamed: ["plain": "PLAIN", "Café": "CAF\u{c9}", "Nested": "NESTED"]) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertEqual(record.state, .recovering)
        XCTAssertEqual(try saved(), record)
        let current = try XCTUnwrap(record.recovery?.first)
        let nested = try childID("Nested", in: first), deep = try childID("deep", in: first)
        XCTAssertEqual(current.target.entries.first { $0.item == deep }?.retirement, .parent(item: nested))
        try catalog.applyFolderMoveRecovery(first.move, proofs: first.proofs, expected: current.expected, target: current.target)
        for entry in first.move.entries {
            let retired = ["plain", "Café", "Nested", "deep"].contains(entry.name)
            XCTAssertEqual(try catalog.item(id: entry.item)?.deleted, retired)
        }
    }

    func testRecoveryKeepsAChildListedInAnotherNormalization() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let expected = try Dictionary(uniqueKeysWithValues: record.views.map {
            ($0.domain, try record.latestTarget(domain: $0.domain))
        })
        remote.refresh = { try self.refreshes($0, removed: ["deep"], spelled: ["Café": "Cafe\u{301}"]) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        let current = try XCTUnwrap(record.recovery?.first)
        let cafe = try childID("Café", in: XCTUnwrap(record.views.first))
        XCTAssertEqual(current.target.entries.first { $0.item == cafe }?.retired, false)
    }

    func testNewRetirementNeedsCompleteProofAndParentWitnessCannotCycle() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let original = record
        remote.refresh = { record in
            try self.refreshes(record, removed: ["plain"]).map {
                FolderMoveRefresh(domain: $0.domain, observations: $0.observations, listings: [])
            }
        }
        let expected = try classified(record)
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
        XCTAssertEqual(try saved(), original)
        remote.refresh = { try self.refreshes($0, removed: ["Nested", "deep"]) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        let current = try XCTUnwrap(record.recovery?.first)
        let nested = try XCTUnwrap(record.views[0].move.entries.first { $0.name == "Nested" })
        let deep = try XCTUnwrap(record.views[0].move.entries.first { $0.name == "deep" })
        XCTAssertEqual(current.target.entries.first { $0.item == deep.item }?.retirement, .parent(item: nested.item))
        let invalid = CatalogFolderMoveState(moved: true, entries: current.target.entries.map { entry in
            entry.item == nested.item ? entry.retiring(.parent(item: deep.item)) : entry
        })
        let before = try catalog.currentAnchor()
        XCTAssertThrowsError(try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                                                  expected: current.expected, target: invalid))
        XCTAssertEqual(try catalog.currentAnchor(), before)
    }

    func testRootRetirementRequiresListingAndClassifiedLocalState() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let original = record, expected = try classified(record)
        remote.roots[NameKey(record.destination)] = FolderMoveEvidence(identity: try identity(999), name: record.name)
        remote.refresh = { record in
            try self.departedRoot(record).map {
                FolderMoveRefresh(domain: $0.domain, observations: $0.observations, listings: [])
            }
        }
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
        XCTAssertEqual(try saved(), original)
        remote.roots[NameKey(record.destination)] = FolderMoveEvidence(identity: record.identity, name: record.name)
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: [:], remote: remote))
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(remote.moves, 1)
    }

    func testRootDepartureProofRejectsIncompleteChangedParentAndSurvivingBinding() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let original = record, expected = try classified(record)
        let good = try departedRoot(record)[0], listing = good.listings[0]
        let bad = [
            CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
                identity: listing.identity, complete: false, children: []),
            CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
                identity: try identity(999), complete: true, children: []),
            CatalogFolderMoveListing(parent: listing.parent, path: .root,
                identity: listing.identity, complete: true, children: []),
            CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
                identity: listing.identity, complete: true,
                children: [.init(name: record.name, identity: record.identity, kind: nil)]),
            CatalogFolderMoveListing(parent: listing.parent, path: RelativePath(listing.path)!,
                identity: listing.identity, complete: true, children: [
                    .init(name: "other", identity: try identity(90), kind: .folder),
                    .init(name: "OTHER", identity: try identity(91), kind: .folder)])]
        for listing in bad {
            remote.refresh = { _ in [FolderMoveRefresh(domain: self.domain, observations: good.observations,
                                                       listings: [listing])] }
            XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
            XCTAssertEqual(try saved(), original)
        }
        let survivors = try refreshes(record)[0].observations
        remote.refresh = { _ in [FolderMoveRefresh(domain: self.domain,
            observations: survivors.map { $0.item == original.views[0].move.item ? .removed(item: $0.item) : $0 },
            listings: good.listings)] }
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
        XCTAssertEqual(try saved(), original)
    }

    func testRootRetirementSurvivesReappearanceAndDiscoveryUsesNewIDs() throws {
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        let view = record.views[0]
        try catalog.settleFolderMove(view.move, settlement: XCTUnwrap(record.settlements?.first).settlement)
        let renamed = CatalogFolderMoveListing.Child(name: "MOVED", identity: record.identity, kind: .folder)
        remote.refresh = { try self.departedRoot($0, children: [renamed]) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: classified(record), remote: remote)
        let target = try record.latestTarget(domain: domain)
        let recovery = try XCTUnwrap(record.recovery?.first)
        try catalog.applyFolderMoveRecovery(view.move, proofs: view.proofs, expected: recovery.expected, target: target)
        record = try saved()
        remote.roots[NameKey(record.destination)] = FolderMoveEvidence(identity: record.identity, name: record.name)
        remote.refresh = { try self.refreshes($0) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: classified(record), remote: remote)
        XCTAssertEqual(try record.latestTarget(domain: domain), target)
        XCTAssertFalse(try XCTUnwrap(record.recovery?.first).listings.isEmpty)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertEqual(try outbox.pendingIntentCount(domain: domain), 0)
        XCTAssertThrowsError(try record.requireMoved()) { XCTAssertEqual($0 as? SourceFailure, .versionChanged) }
        try list(destination.id, [folder("Moved", 10)])
        let discovered = try child(destination.id, "Moved")
        XCTAssertNotEqual(discovered.id, view.move.item)
        XCTAssertFalse(discovered.keepRequested)
        try list(discovered.id, [file("verified", 40)])
        let fresh = try child(discovered.id, "verified")
        XCTAssertNotEqual(fresh.id, base.item)
        XCTAssertFalse(fresh.contentVersion.hasPrefix("e1:"))
        XCTAssertFalse(fresh.keepRequested)
        let anchor = try catalog.currentAnchor()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(try catalog.currentAnchor(), anchor)
        XCTAssertThrowsError(try saved().requireMoved()) { XCTAssertEqual($0 as? SourceFailure, .versionChanged) }
    }

    func testReplacementRootRetiresOverlappingViewsAfterPartialCompletionAndRestart() throws {
        let otherDomain = UUID().uuidString
        let other = try Catalog.create(at: directory.appending(path: "root-overlap"), domainID: otherDomain,
                                       rootName: "Other")
        try other.reconcile(folder: Catalog.rootItemID,
            listing: DirectoryListing([folder("Tree", 10), folder("Archive", 20)])) { _ in true }
        let otherTree = try XCTUnwrap(other.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Tree")))
        let archive = try XCTUnwrap(other.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Archive")))
        try other.reconcile(folder: otherTree.id,
            listing: DirectoryListing([file("plain", 30), file("verified", 40)])) { _ in true }
        try other.reconcile(folder: archive.id, listing: DirectoryListing([])) { _ in true }
        let first = try view(), move = try other.prepareFolderMove(item: otherTree.id,
            destinationParent: archive.id, destinationName: "Moved")
        let proofs = try move.entries.map { entry -> CatalogFolderMoveProof in
            if entry.kind == .folder { return .directory(item: entry.item, identity: try identity(entry.nativeID)) }
            return .file(try EditBaseReceipt(item: entry.item, version: version(entry.nativeID)))
        }
        let second = FolderMoveView(domain: otherDomain, folder: .root, move: move, proofs: proofs)
        var record = try prepare(views: [first, second])
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        try catalog.settleFolderMove(first.move, settlement: XCTUnwrap(record.settlements?.first).settlement)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        let replacement = CatalogFolderMoveListing.Child(name: record.name, identity: try identity(999), kind: .folder)
        remote.refresh = { try self.departedRoot($0, children: [replacement]) }
        var expected = try classified(record)
        expected[otherDomain] = try other.classifyFolderMove(move, proofs: proofs,
            allowed: record.allowedCatalogStates(domain: otherDomain))
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        XCTAssertTrue(record.finishedDomains.isEmpty)
        let initial = try XCTUnwrap(record.recovery)
        let owner = try XCTUnwrap(initial.first { $0.domain == domain })
        try catalog.applyFolderMoveRecovery(first.move, proofs: first.proofs, expected: owner.expected, target: owner.target)
        record = try FileRenameOutbox(directory: directory.appending(path: "Renames")).reloadFolder(record)
        expected = try classified(record)
        expected[otherDomain] = try other.classifyFolderMove(move, proofs: proofs,
            allowed: record.allowedCatalogStates(domain: otherDomain))
        remote.refresh = { try self.refreshes($0) }
        try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote)
        for current in try XCTUnwrap(record.recovery) {
            let view = current.domain == domain ? first : second
            let catalog = current.domain == domain ? self.catalog! : other
            XCTAssertEqual(current.target, initial.first { $0.domain == current.domain }?.target)
            try catalog.applyFolderMoveRecovery(view.move, proofs: view.proofs,
                expected: current.expected, target: current.target)
            for entry in view.move.entries { XCTAssertEqual(try catalog.item(id: entry.item)?.deleted, true) }
            try FolderMoveTransaction.finishDomain(current.domain, record: &record, outbox: outbox)
        }
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(try outbox.pendingIntentCount(domain: otherDomain), 0)
        XCTAssertThrowsError(try record.requireMoved()) { XCTAssertEqual($0 as? SourceFailure, .versionChanged) }
        try list(destination.id, [folder("Moved", 999)])
        XCTAssertNotEqual(try child(destination.id, "Moved").id, first.move.item)
        XCTAssertEqual(remote.moves, 1)
    }

    private func departedRoot(_ record: PendingFolderMove,
                              children: [CatalogFolderMoveListing.Child] = []) throws -> [FolderMoveRefresh] {
        try record.views.map { view in
            let relative = RelativePath(view.move.destinationParentPath)!
            let path = RelativePath(view.folder)!.appending(relative)!
            let parent = try XCTUnwrap(record.destinationParents.first { $0.path == path.string })
            return FolderMoveRefresh(domain: view.domain,
                observations: view.move.entries.map { .removed(item: $0.item) }, listings: [
                    CatalogFolderMoveListing(parent: view.move.destinationParent, path: relative,
                        identity: parent.identity, complete: true, children: children)])
        }
    }

    func testRecoveryCheckpointAndAmbiguousPersistenceKeepTheMintedTarget() throws {
        var failSync = false
        outbox = try FileRenameOutbox(directory: directory.appending(path: "Renames"), directorySync: { fd in
            if failSync { throw posixError("sync rename directory", code: EIO) }
            guard Darwin.fsync(fd) == 0 else { throw posixError("sync rename directory") }
        })
        var record = try prepare()
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        remote.refresh = { record in
            let result = try self.refreshes(record, contents: ["verified": "b"])
            failSync = true
            return result
        }
        let expected = try classified(record)
        XCTAssertThrowsError(try FolderMoveTransaction.replan(&record, outbox: outbox, expected: expected, remote: remote))
        XCTAssertEqual(record.state, .verified)
        let visible = try saved()
        XCTAssertEqual(visible.state, .recovering)
        let calls = remote.events
        XCTAssertThrowsError(try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.events, calls)
        failSync = false
        try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.recovery, visible.recovery)
        XCTAssertEqual(record.state, .recovering)
        XCTAssertTrue(remote.events.contains("verify recovery"))
        let current = try XCTUnwrap(record.recovery?.first)
        try catalog.applyFolderMoveRecovery(record.views[0].move, proofs: record.views[0].proofs,
                                             expected: current.expected, target: current.target)
        try FolderMoveTransaction.finishDomain(domain, record: &record, outbox: outbox)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(remote.moves, 1)
    }

    private func prepare(to parent: String? = nil, name: String = "Moved",
                         views: [FolderMoveView]? = nil) throws -> PendingFolderMove {
        let views = try views ?? [view(to: parent, name: name)]
        let target = try XCTUnwrap(RelativePath(views[0].move.destinationParentPath)?.appending(name))
        return try outbox.prepareFolder(owner: domain, request: request(to: parent, name: name),
                                         source: XCTUnwrap(RelativePath("Tree")), destination: target,
                                         identity: identity(10), parents: remote.parents, views: views)
    }

    private func prepareNestedMove() throws -> PendingFolderMove {
        tree = try child(tree.id, "Nested")
        remote.parents.append(FileRenameParent(path: "Tree", name: "Tree", identity: try identity(10)))
        remote.roots[NameKey("Tree/Nested")] = FolderMoveEvidence(identity: try identity(50), name: "Nested")
        return try outbox.prepareFolder(owner: domain, request: request(),
            source: XCTUnwrap(RelativePath("Tree/Nested")), destination: XCTUnwrap(RelativePath("Archive/Moved")),
            identity: identity(50), parents: remote.parents, views: [view()])
    }

    private func childID(_ name: String, in view: FolderMoveView) throws -> String {
        try XCTUnwrap(view.move.entries.first { $0.name == name }).item
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
                             removed: String? = nil, renamed: [String: String] = [:]) throws -> [FolderMoveSettlement] {
        try record.views.map { view in
            let resolutions = try view.move.entries.map { entry -> CatalogFolderMoveResolution in
                if entry.name == removed || renamed[entry.name] != nil { return .removed(item: entry.item) }
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
            if removed != nil || !renamed.isEmpty {
                for parent in view.move.entries where parent.kind == .folder {
                    let children = view.move.entries.filter { $0.parent == parent.item && $0.name != removed }.map {
                        CatalogFolderMoveListing.Child(name: renamed[$0.name] ?? $0.name,
                            identity: proofs[$0.item]!.identity, kind: $0.kind)
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

    private func refreshes(_ record: PendingFolderMove, contents: [String: Character] = [:],
                           modified: [String: UInt64] = [:], changedTime: UInt64? = nil,
                           removed: Set<String> = [], reappeared: Set<String> = [],
                           renamed: [String: String] = [:], spelled: [String: String] = [:]) throws -> [FolderMoveRefresh] {
        try record.views.map { view in
            let previous = try record.latestTarget(domain: view.domain)
            let prior = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.item, $0) })
            let observations = try view.move.entries.map { entry -> FolderMoveObservation in
                let before = prior[entry.item]!
                if before.retired || removed.contains(entry.name) || renamed[entry.name] != nil {
                    return .removed(item: entry.item)
                }
                let path = try XCTUnwrap(view.destinationPath(for: entry))
                switch before.proof {
                case .directory(_, let identity):
                    return .directory(CatalogFolderMoveObservation(item: entry.item, path: path, kind: .folder,
                        nativeID: before.nativeID, fingerprint: ContentFingerprint(size: before.size,
                            mtimeNs: before.mtimeNs, ctimeNs: changedTime.map { Int64($0) * 1_000 } ?? before.ctimeNs),
                        preservesIdentity: true, preservesContents: false), identity: identity)
                case .file(let receipt):
                    let digest = contents[entry.name].map { String(repeating: String($0), count: 64) }
                        ?? receipt.version.digest
                    let version = try EditFileVersion(identity: receipt.version.identity, size: receipt.version.size,
                        digest: digest, modifiedMicroseconds: modified[entry.name] ?? receipt.version.modifiedMicroseconds,
                        changedMicroseconds: changedTime ?? receipt.version.changedMicroseconds,
                        attributes: receipt.version.attributes, security: receipt.version.security)
                    return .file(CatalogFolderMoveObservation(item: entry.item, path: path, kind: .file,
                        nativeID: before.nativeID, fingerprint: ContentFingerprint(size: version.size,
                            mtimeNs: Int64(version.modifiedMicroseconds) * 1_000,
                            ctimeNs: Int64(version.changedMicroseconds) * 1_000),
                        preservesIdentity: true, preservesContents: version.hasSameContents(as: receipt.version)),
                        version: version)
                }
            }
            var listings: [CatalogFolderMoveListing] = []
            if !removed.isEmpty || !reappeared.isEmpty || !renamed.isEmpty {
                for parent in view.move.entries where parent.kind == .folder
                    && !prior[parent.item]!.retired && !removed.contains(parent.name) && renamed[parent.name] == nil {
                    let children = view.move.entries.filter { entry in
                        entry.parent == parent.item && (!prior[entry.item]!.retired || reappeared.contains(entry.name))
                            && !removed.contains(entry.name)
                    }.map {
                        CatalogFolderMoveListing.Child(name: renamed[$0.name] ?? spelled[$0.name] ?? $0.name,
                            identity: prior[$0.item]!.proof.identity, kind: $0.kind)
                    }
                    listings.append(CatalogFolderMoveListing(parent: parent.item,
                        path: try XCTUnwrap(view.destinationPath(for: parent)), identity: prior[parent.item]!.proof.identity,
                        complete: true, children: children))
                }
            }
            return FolderMoveRefresh(domain: view.domain, observations: observations, listings: listings)
        }
    }

    private func classified(_ record: PendingFolderMove) throws -> [String: CatalogFolderMoveState] {
        let view = try XCTUnwrap(record.views.first { $0.domain == domain })
        return [domain: try catalog.classifyFolderMove(view.move, proofs: view.proofs,
                                                       allowed: record.allowedCatalogStates(domain: domain))]
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
    var nonDirectories: Set<NameKey> = []
    var parents: [FileRenameParent] = []
    var events: [String] = []
    var protectedSources: [String] = []
    var moves = 0
    var disconnectAfterMove = false
    var disconnected = false
    var moveFailure: Error?
    var replyErrorAfterMove: Error?
    var releaseFailure: Error?
    var changedParentBirthAfterMove = false
    var settlement: ((PendingFolderMove) throws -> [FolderMoveSettlement])!
    var refresh: ((PendingFolderMove) throws -> [FolderMoveRefresh])!
    var verifySource: (PendingFolderMove) throws -> Void = { _ in }
    var verifySettlement: (PendingFolderMove) throws -> Void = { _ in }
    var verifyRecovery: (PendingFolderMove) throws -> Void = { _ in }
    var settlementVerifications = 0

    func protectFolderMoveParents(source: String, destination: String) throws -> [FileRenameParent] {
        events.append("parents")
        protectedSources.append(source)
        let required = Set(try [source, destination].flatMap { path in
            let components = try XCTUnwrap(RelativePath(path)).components
            return (0..<components.count).map { Data(components.prefix($0).joined(separator: "/").utf8) }
        })
        return parents.filter { required.contains(Data($0.path.utf8)) }
    }

    func inspectFolderMoveRoot(path: String) throws -> FolderMoveEvidence? {
        events.append("inspect")
        if disconnected { throw posixError("disconnected", code: EIO) }
        if nonDirectories.contains(NameKey(path)) { throw UploadError.collision }
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
        if changedParentBirthAfterMove {
            parents = try parents.map {
                FileRenameParent(path: $0.path, name: $0.name,
                    identity: try EditFileIdentity(fileID: $0.identity.fileID,
                                               birthMicroseconds: $0.identity.birthMicroseconds + 1))
            }
        }
        if disconnectAfterMove {
            disconnected = true
            throw posixError("lost reply", code: EIO)
        }
        if let replyErrorAfterMove { throw replyErrorAfterMove }
    }

    func folderMoveParentsAfterRename(_ parents: [FileRenameParent]) throws -> [FileRenameParent] {
        if disconnected { throw posixError("disconnected", code: EIO) }
        events.append("checkpoint parents")
        return self.parents
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

    func refreshFolderMove(_ record: PendingFolderMove) throws -> [FolderMoveRefresh] {
        events.append("refresh")
        return try refresh(record)
    }

    func verifyFolderMoveRecovery(_ record: PendingFolderMove) throws {
        events.append("verify recovery")
        try verifyRecovery(record)
    }
}
