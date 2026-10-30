import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class FileRenameTests: XCTestCase {
    private var directory: URL!
    private var catalog: Catalog!
    private var row: CatalogRow!
    private var base: EditBaseReceipt!
    private var outbox: FileRenameOutbox!
    private var remote: RenameRemote!
    private let domain = UUID().uuidString

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalog = try Catalog.create(at: directory.appending(path: "catalog"), domainID: domain, rootName: "Location")
        try catalog.reconcile(folder: Catalog.rootItemID, listing: DirectoryListing([
            .entry(.init(name: "original.txt", kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: 7)),
            .entry(.init(name: "z.txt", kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: 8))
        ])) { _ in true }
        row = try XCTUnwrap(catalog.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("original.txt")))
        base = try EditBaseReceipt(item: row.id, version: version())
        try catalog.setWriteAccess(creation: true, editing: true)
        try catalog.rememberEditBase(base, expectedVersion: row.contentVersion)
        row = try XCTUnwrap(catalog.item(id: row.id))
        outbox = try FileRenameOutbox(directory: directory.appending(path: "Renames"))
        remote = RenameRemote()
        remote.files[NameKey(row.name)] = FileRenameEvidence(version: base.version, name: row.name)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func version(identity: UInt64 = 12, digest: Character = "a") throws -> EditFileVersion {
        try EditFileVersion(identity: EditFileIdentity(fileID: identity, birthMicroseconds: 34), size: 10,
                            digest: String(repeating: String(digest), count: 64), modifiedMicroseconds: 1,
                            changedMicroseconds: 2, attributes: 32, security: Data([1]))
    }

    private func request(name: String = "renamed.txt", metadata: String? = nil) throws -> FileRenameRequest {
        try FileRenameRequest(item: row.id, parent: Catalog.rootItemID, name: name,
                              contentVersion: base.contentVersion, metadataVersion: metadata ?? row.metadataVersion)
    }

    private func prepare(name: String = "renamed.txt") throws -> PendingFileRename {
        let view = try FileRenameView(domain: domain, folder: .root, row: row,
                                      path: XCTUnwrap(RelativePath(row.name)), nativeID: 7)
        return try outbox.prepare(owner: domain, request: request(name: name), base: base,
                                  source: XCTUnwrap(RelativePath(row.name)), views: [view])
    }

    func testLostReplyUsesFreshEvidenceWithoutAnotherRename() throws {
        var record = try prepare()
        remote.failAfterMove = true
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(try outbox.pendingCount(domain: domain), 1)
        remote.failAfterMove = false
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertNil(remote.files[NameKey("original.txt")])
        XCTAssertEqual(remote.files[NameKey("renamed.txt")]?.version, base.version)
    }

    func testBeforeRequestCrashRetriesOnlyTheVerifiedOriginal() throws {
        var record = try prepare()
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        XCTAssertEqual(remote.moves, 0)
        record = try XCTUnwrap(outbox.records().first)
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
    }

    func testChangedOrReplacedSourceIsRefusedWithoutMutation() throws {
        for changed in [try version(digest: "b"), try version(identity: 13)] {
            var record = try prepare()
            remote.files[NameKey(row.name)] = FileRenameEvidence(version: changed, name: row.name)
            XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)) {
                XCTAssertEqual($0 as? SourceFailure, .versionChanged)
            }
            XCTAssertEqual(record.state, .refused)
            XCTAssertEqual(remote.moves, 0)
            XCTAssertEqual(try outbox.pendingCount(domain: domain), 0)
            XCTAssertEqual(remote.files[NameKey(row.name)]?.version, changed)
        }
    }

    func testUncertainChangedDestinationStaysPendingAndNeverMovesACompetitor() throws {
        var record = try prepare()
        remote.failAfterMove = true
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        remote.failAfterMove = false
        let competitor = try version(identity: 99, digest: "b")
        remote.files[NameKey(record.name)] = FileRenameEvidence(version: competitor, name: record.name)
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(try outbox.pendingCount(domain: domain), 1)
        XCTAssertThrowsError(try outbox.removeCompleted(owner: domain))
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(remote.files[NameKey(record.name)]?.version, competitor)
    }

    func testCollisionBeforeAndDuringRequestPreservesBothVersions() throws {
        for duringRequest in [false, true] {
            var record = try prepare()
            let competitor = FileRenameEvidence(version: try version(identity: 99, digest: "b"), name: record.name)
            let name = record.name
            if duringRequest {
                remote.beforeMove = { self.remote.files[NameKey(name)] = competitor }
            } else {
                remote.files[NameKey(record.name)] = competitor
            }
            XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)) {
                XCTAssertEqual($0 as? UploadError, .collision)
            }
            XCTAssertEqual(record.state, .refused)
            XCTAssertEqual(remote.files[NameKey(row.name)]?.version, base.version)
            XCTAssertEqual(remote.files[NameKey(record.name)]?.version, competitor.version)
            remote.files[NameKey(record.name)] = nil
        }
    }

    func testCaseOnlyRecoveryRequiresExactStoredSpelling() throws {
        var record = try prepare(name: "ORIGINAL.txt")
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        XCTAssertEqual(remote.moves, 0)
        remote.failAfterMove = true
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.moves, 1)
        remote.failAfterMove = false
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(remote.files[NameKey(row.name)]?.name, "ORIGINAL.txt")
    }

    func testPendingRequestsCannotReplaceIntentAndReplayUsesBothVersions() throws {
        let first = try prepare()
        XCTAssertEqual(try prepare().id, first.id)
        XCTAssertThrowsError(try prepare(name: "other.txt"))
        XCTAssertThrowsError(try outbox.replay(owner: domain, request: request(metadata: "999")))
        XCTAssertEqual(try outbox.records(), [first])
        var completed = first
        try FileRenameTransaction.publish(&completed, outbox: outbox, remote: remote)
        completed.state = .completed
        try outbox.save(completed)
        XCTAssertEqual(try outbox.replay(owner: domain, request: request())?.id, first.id)
        XCTAssertNil(try outbox.replay(owner: domain, request: request(metadata: "999")))
    }

    func testCatalogCommitPreservesContentsKeepsAndEnumerationAcrossReplay() throws {
        _ = try catalog.setKeep(ids: [row.id], value: true)
        row = try XCTUnwrap(catalog.item(id: row.id))
        let token = try catalog.folderPage(Catalog.rootItemID, token: nil, size: 1).next
        let anchor = try catalog.currentAnchor()
        var record = try prepare(name: "zz-renamed.txt")
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        let fingerprint = ContentFingerprint(size: 10, mtimeNs: 1_000, ctimeNs: 3_000)
        try catalog.commitFileRename(record, view: record.views[0], fingerprint: fingerprint, nativeID: 70)
        let renamed = try XCTUnwrap(catalog.item(id: row.id))
        XCTAssertEqual(renamed.name, record.name)
        XCTAssertEqual(renamed.row, row.row)
        XCTAssertEqual(renamed.contentVersion, row.contentVersion)
        XCTAssertTrue(renamed.keep && renamed.keepRequested)
        XCTAssertEqual(try catalog.folderPage(Catalog.rootItemID, token: token, size: 10).rows.map(\.name), ["z.txt"])
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100).deletedIDs, [])
        try catalog.commitFileRename(record, view: record.views[0], fingerprint: fingerprint, nativeID: 70)
        XCTAssertEqual(try catalog.item(id: row.id), renamed)
    }

    func testRepeatedRenameKeepsTheBaseAndDoesNotReapplyAnOldCallback() throws {
        let firstRequest = try request()
        var first = try prepare()
        try FileRenameTransaction.publish(&first, outbox: outbox, remote: remote)
        let fingerprint = ContentFingerprint(size: 10, mtimeNs: 1_000, ctimeNs: 3_000)
        try catalog.commitFileRename(first, view: first.views[0], fingerprint: fingerprint, nativeID: 7)
        first.state = .completed
        try outbox.save(first)
        _ = try catalog.setKeep(ids: [row.id], value: true)
        row = try XCTUnwrap(catalog.item(id: row.id))
        XCTAssertNotEqual(row.metadataVersion, firstRequest.metadataVersion)
        let next = try request(name: "last.txt", metadata: firstRequest.metadataVersion)
        let view = try FileRenameView(domain: domain, folder: .root, row: row,
                                      path: XCTUnwrap(RelativePath(row.name)), nativeID: 7)
        var second = try outbox.prepare(owner: domain, request: next, base: base,
                                        source: XCTUnwrap(RelativePath(row.name)), views: [view])
        try FileRenameTransaction.publish(&second, outbox: outbox, remote: remote)
        try catalog.commitFileRename(second, view: view, fingerprint: fingerprint, nativeID: 7)
        second.state = .completed
        try outbox.save(second)
        var replay = try XCTUnwrap(outbox.replay(owner: domain, request: firstRequest))
        try FileRenameTransaction.publish(&replay, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.moves, 2)
        XCTAssertEqual(remote.files[NameKey("last.txt")]?.version, base.version)
        XCTAssertEqual(try catalog.item(id: row.id)?.contentVersion, base.contentVersion)
        XCTAssertEqual(try catalog.item(id: row.id)?.keepRequested, true)
    }

    func testPendingIntentGuardsEveryAffectedLocation() throws {
        let otherDomain = UUID().uuidString
        let views = try [domain, otherDomain].map { domain in
            try FileRenameView(domain: domain, folder: .root, row: row,
                                      path: XCTUnwrap(RelativePath(row.name)), nativeID: 7)
        }
        let record = try outbox.prepare(owner: domain, request: request(), base: base,
                                        source: XCTUnwrap(RelativePath(row.name)), views: views)
        XCTAssertEqual(try outbox.pendingCount(domain: otherDomain), 1)
        XCTAssertThrowsError(try outbox.removeCompleted(owner: otherDomain))
        XCTAssertEqual(try outbox.records(), [record])
    }

    func testInvalidRequestsAndMovesWithoutParentEvidenceNeverEnterTheOutbox() throws {
        for name in ["../x", "a/b", "x\\y", "x:y", "*", "a?", ".tinymounter-owned", "x.db"] {
            XCTAssertThrowsError(try request(name: name))
        }
        for version in ["", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try FileRenameRequest(item: row.id, parent: Catalog.rootItemID, name: "new",
                                                       contentVersion: version, metadataVersion: "1"))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepare())) as? [String: Any])
        object["destination"] = "elsewhere/new.txt"
        let url = directory.appending(path: "Renames/\(try XCTUnwrap(outbox.records().first).id.uuidString).rename")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try outbox.records())
        XCTAssertThrowsError(try outbox.removeCompleted(owner: domain))
    }

    private func prepareMove(unverified: Bool = false) throws -> PendingFileRename {
        try catalog.reconcile(folder: Catalog.rootItemID, listing: DirectoryListing([
            .entry(.init(name: "original.txt", kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: 7)),
            .entry(.init(name: "z.txt", kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: 2_000, fileID: 8)),
            .entry(.init(name: "Archive", kind: .folder, size: 0, mtimeNs: 1_000, ctimeNs: 2_000, fileID: 50))
        ])) { _ in true }
        let destination = try XCTUnwrap(catalog.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Archive")))
        try catalog.reconcile(folder: destination.id, listing: DirectoryListing([])) { _ in true }
        if unverified {
            row = try XCTUnwrap(catalog.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("z.txt")))
            base = try EditBaseReceipt(item: row.id, version: version(identity: 88))
            remote.files[NameKey(row.name)] = FileRenameEvidence(version: base.version, name: row.name)
        }
        let request = try FileRenameRequest(item: row.id, parent: destination.id, name: "moved.txt",
                                            contentVersion: row.contentVersion, metadataVersion: row.metadataVersion)
        let view = try FileRenameView(domain: domain, folder: .root, row: row,
                                      path: XCTUnwrap(RelativePath(row.name)),
                                      nativeID: unverified ? 8 : 7, destinationParent: destination.id)
        remote.parents = [
            FileRenameParent(path: "", name: "", identity: try EditFileIdentity(fileID: 90, birthMicroseconds: 10)),
            FileRenameParent(path: "Archive", name: "Archive", identity: try EditFileIdentity(fileID: 50, birthMicroseconds: 20))
        ]
        return try outbox.prepare(owner: domain, request: request, base: base,
                                  source: XCTUnwrap(RelativePath(row.name)), views: [view],
                                  destination: XCTUnwrap(RelativePath("Archive/moved.txt")), parents: remote.parents)
    }

    func testUnverifiedMoveKeepsItsEvidenceLevelAndDepartureAcrossReplay() throws {
        var record = try prepareMove(unverified: true)
        let version = row.contentVersion
        XCTAssertTrue(version.hasPrefix("f1:"))
        XCTAssertNotEqual(record.base.contentVersion, version)
        XCTAssertEqual(try outbox.records(), [record])
        let anchor = try catalog.currentAnchor()
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        let view = try XCTUnwrap(record.views.first)
        let move = try CatalogFileMove(item: view.item, sourceParent: view.parent, sourceName: row.name,
                                       contentVersion: view.contentVersion, sourceNativeID: view.nativeID,
                                       destinationParent: view.targetParent, destinationName: record.name)
        let fingerprint = ContentFingerprint(size: 10, mtimeNs: 1_000, ctimeNs: 3_000)
        try catalog.commitFileMove(move, fingerprint: fingerprint, nativeID: 88)
        XCTAssertEqual(try catalog.item(id: row.id)?.contentVersion, version)
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .parent(view.parent)).updated.map(\.id), [row.id])
        record.state = .completed
        try outbox.save(record)
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(remote.files[NameKey(record.destination)]?.version, base.version)
    }

    func testCrossFolderMoveRecoversBeforeAndAfterTheServerRequest() throws {
        var record = try prepareMove()
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote) { state in
            if state == .attempting { throw UploadError.unresolved }
        })
        XCTAssertEqual(remote.moves, 0)
        record = try XCTUnwrap(outbox.records().first)
        remote.failAfterMove = true
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.moves, 1)
        remote.failAfterMove = false
        record = try XCTUnwrap(outbox.records().first)
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(record.state, .verified)
        XCTAssertEqual(record.parents, remote.parents)
    }

    func testReplacedOrRenamedParentStopsRecoveryBeforeAnyFileRequest() throws {
        var record = try prepareMove()
        let parents = remote.parents
        for replacement in [
            FileRenameParent(path: "Archive", name: "Archive", identity: try EditFileIdentity(fileID: 51, birthMicroseconds: 20)),
            FileRenameParent(path: "Archive", name: "ARCHIVE", identity: parents[1].identity)
        ] {
            remote.parents = [parents[0], replacement]
            XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
            XCTAssertEqual(remote.inspections, 0)
            XCTAssertEqual(remote.moves, 0)
            XCTAssertTrue(record.isPending)
        }
    }

    func testUnverifiedMoveStillRejectsAReplacementAfterAdmission() throws {
        var record = try prepareMove(unverified: true)
        remote.files[NameKey(record.source)] = FileRenameEvidence(version: try version(identity: 89), name: record.oldName)
        XCTAssertThrowsError(try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote))
        XCTAssertEqual(record.state, .refused)
        XCTAssertEqual(remote.moves, 0)
    }

    func testMoveReplayIncludesTheDestinationParent() throws {
        let record = try prepareMove()
        let view = try XCTUnwrap(record.views.first)
        let request = try FileRenameRequest(item: row.id, parent: view.targetParent, name: record.name,
                                            contentVersion: row.contentVersion, metadataVersion: row.metadataVersion)
        XCTAssertEqual(try outbox.replay(owner: domain, request: request), record)
        let wrongParent = try FileRenameRequest(item: row.id, parent: view.parent, name: record.name,
                                                contentVersion: row.contentVersion, metadataVersion: row.metadataVersion)
        XCTAssertThrowsError(try outbox.replay(owner: domain, request: wrongParent))
    }

    func testStaleSingleFieldCallbacksCannotUndoAnotherViewOrganization() throws {
        var record = try prepareMove()
        let view = try XCTUnwrap(record.views.first)
        let rename = try FileRenameRequest(item: row.id, parent: view.parent, name: "renamed.txt",
                                           contentVersion: row.contentVersion, metadataVersion: row.metadataVersion,
                                           changesName: true, changesParent: false)
        let moveOnly = try FileRenameRequest(item: row.id, parent: view.targetParent, name: row.name,
                                             contentVersion: row.contentVersion, metadataVersion: row.metadataVersion,
                                             changesName: false, changesParent: true)
        try rename.validateUnchangedFields(in: row)
        try moveOnly.validateUnchangedFields(in: row)
        try FileRenameTransaction.publish(&record, outbox: outbox, remote: remote)
        let move = try CatalogFileMove(item: row.id, sourceParent: view.parent, sourceName: row.name,
                                       contentVersion: row.contentVersion, sourceNativeID: view.nativeID,
                                       destinationParent: view.targetParent, destinationName: record.name)
        try catalog.commitFileMove(move, fingerprint: ContentFingerprint(size: 10, mtimeNs: 1_000, ctimeNs: 3_000),
                                    nativeID: 88)
        let current = try XCTUnwrap(catalog.item(id: row.id))
        let decodedRename = try JSONDecoder().decode(FileRenameRequest.self, from: JSONEncoder().encode(rename))
        let decodedMove = try JSONDecoder().decode(FileRenameRequest.self, from: JSONEncoder().encode(moveOnly))
        XCTAssertThrowsError(try decodedRename.validateUnchangedFields(in: current))
        XCTAssertThrowsError(try decodedMove.validateUnchangedFields(in: current))
        XCTAssertEqual(current.parentID, view.targetParent)
        XCTAssertEqual(current.name, record.name)
        record.state = .completed
        try outbox.save(record)
        let replay = try FileRenameRequest(item: row.id, parent: view.targetParent, name: record.name,
                                           contentVersion: row.contentVersion, metadataVersion: row.metadataVersion)
        XCTAssertEqual(try outbox.replay(owner: domain, request: replay), record)
        XCTAssertEqual(remote.moves, 1)
    }

    func testLegacyOrganizationMessagesMeanRenameOnly() throws {
        var message = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
        message["changesName"] = nil
        message["changesParent"] = nil
        let decoded = try JSONDecoder().decode(FileRenameRequest.self, from: JSONSerialization.data(withJSONObject: message))
        XCTAssertTrue(decoded.changesName)
        XCTAssertFalse(decoded.changesParent)
        XCTAssertThrowsError(try FileRenameRequest(item: row.id, parent: Catalog.rootItemID, name: "new.txt",
                                                   contentVersion: row.contentVersion, metadataVersion: row.metadataVersion,
                                                   changesName: false, changesParent: false))
    }

    func testIncompleteParentEvidenceFailsClosedOnDisk() throws {
        var record = try prepareMove()
        record.parents = Array(remote.parents.prefix(1))
        XCTAssertThrowsError(try outbox.save(record))
        record.parents = remote.parents + [remote.parents[0]]
        XCTAssertThrowsError(try outbox.save(record))
        XCTAssertEqual(try outbox.records().first?.parents, remote.parents)
    }
}

private final class RenameRemote: FileRenameRemote {
    var files: [NameKey: FileRenameEvidence] = [:]
    var moves = 0
    var failAfterMove = false
    var beforeMove: (() -> Void)?
    var parents: [FileRenameParent] = []
    var inspections = 0

    func protectRenameParents(source: String, destination: String) throws -> [FileRenameParent] { parents }
    func inspectRename(path: String) throws -> FileRenameEvidence? {
        inspections += 1
        return files[NameKey(path)]
    }
    func releaseRename(path: String) throws {}

    func move(source: String, destination: String) throws {
        beforeMove?()
        let old = NameKey(source), new = NameKey(destination)
        guard let file = files[old] else { throw posixError("rename", code: ENOENT) }
        guard old == new || files[new] == nil else { throw posixError("rename", code: EEXIST) }
        files[old] = nil
        files[new] = FileRenameEvidence(version: file.version, name: RelativePath(destination)!.components.last!)
        moves += 1
        if failAfterMove { throw posixError("lost reply", code: EIO) }
    }
}
