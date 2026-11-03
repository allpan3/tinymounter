import CryptoKit
import Foundation
import XCTest
@testable import TransferCore

final class EditTransactionTests: XCTestCase {
    private var directory: URL!
    private var outbox: EditOutbox!
    private var edit: PendingEdit!
    private var remote: Remote!
    private var input: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        input = directory.appending(path: "input")
        try Data("complete new version".utf8).write(to: input)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        let item = UUID().uuidString
        let old = try Remote.version(identity: 1, size: 3, digest: String(repeating: "a", count: 64))
        let base = try EditBaseReceipt(item: item, version: old)
        try outbox.storeBase(base)
        edit = try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("file.txt")),
                                  baseVersion: base.contentVersion, failOnConflict: false,
                                  contents: input, progress: Progress())
        remote = Remote(original: old)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testOlderSameBaseSaveIsRefusedBeforeAnyServerChange() throws {
        let input = directory.appending(path: "input")
        try Data("latest version".utf8).write(to: input)
        let latest = try outbox.prepare(item: edit.item, parent: Catalog.rootItemID,
                                        path: XCTUnwrap(RelativePath("file.txt")), baseVersion: edit.baseVersion,
                                        failOnConflict: false, contents: input, progress: Progress())
        XCTAssertNotEqual(latest.id, edit.id)
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.moves, 0)
        XCTAssertEqual(remote.updates, 0)
        XCTAssertEqual(try XCTUnwrap(outbox.records().first { $0.id == edit.id }).state, .prepared)
    }

    private func save(_ text: String, failOnConflict: Bool = false) throws -> PendingEdit {
        try Data(text.utf8).write(to: input)
        return try outbox.prepare(item: edit.item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("file.txt")),
                                  baseVersion: edit.baseVersion, failOnConflict: failOnConflict,
                                  contents: input, progress: Progress())
    }

    private func stored(_ record: PendingEdit) throws -> PendingEdit {
        try XCTUnwrap(outbox.records().first { $0.id == record.id })
    }

    private func finish(_ record: inout PendingEdit) throws {
        try EditTransaction.publish(&record, outbox: outbox, remote: remote)
        try outbox.complete(&record, item: record.item)
        try EditTransaction.cleanup(&record, outbox: outbox, remote: remote)
    }

    private func completePublication() throws {
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        try outbox.complete(&edit, item: edit.item)
        XCTAssertEqual(edit.state, .cleaningUp)
        remote.inspections = []
        remote.removals = []
    }

    private func retireInterruptedBackup() throws -> PendingEdit {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        let latest = try save("latest version")
        try outbox.retainSuperseded(&edit)
        remote.inspections = []
        remote.removals = []
        return latest
    }

    private func retireInterruptedStage() throws -> PendingEdit {
        let stage = try Remote.version(identity: 300, size: edit.size, digest: edit.digest)
        remote.files[edit.stagePath] = stage
        edit.stageIdentity = stage.identity
        edit.state = .creatingStage
        try outbox.save(edit)
        let latest = try save("latest version")
        try outbox.retainSuperseded(&edit)
        return latest
    }

    func testNormalSavePublishesOriginalIdentityAndCleanupNeverDeletesIt() throws {
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(edit.published?.version.identity.fileID, 1)
        XCTAssertEqual(remote.files[edit.path]?.digest, edit.digest)
        XCTAssertEqual(remote.files[edit.recoveryPath]?.digest, String(repeating: "a", count: 64))
        try outbox.complete(&edit, item: edit.item)
        try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(Set(remote.files.keys), [edit.path])
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(remote.updates, 1)
    }

    func testSameSizeTimestampPreservingChangeCreatesConflictWithoutChangingOriginal() throws {
        remote.files[edit.path] = try Remote.version(identity: 1, size: 3, digest: String(repeating: "b", count: 64))
        let competitor = remote.files[edit.path]
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertTrue(edit.conflict)
        XCTAssertEqual(remote.files[edit.path], competitor)
        XCTAssertEqual(remote.files[edit.destination]?.digest, edit.digest)
        XCTAssertEqual(remote.updates, 0)
        XCTAssertEqual(edit.published?.item, edit.id.uuidString)
    }

    func testUncertainPartialCopyIsRetainedAndNeverRepeated() throws {
        remote.failure = .partialCopy
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .copying)
        edit = try XCTUnwrap(outbox.records().first)
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.updates, 1)
        XCTAssertNil(remote.files[edit.path])
        XCTAssertNotNil(remote.files[edit.workPath])
        XCTAssertEqual(remote.files[edit.recoveryPath]?.digest, String(repeating: "a", count: 64))
        XCTAssertEqual(remote.files[edit.stagePath]?.digest, edit.digest)
        try outbox.validateContents(edit)
    }

    func testLostPublishReplyAcknowledgesFromEvidenceWithoutWritingAgain() throws {
        remote.failure = .publication
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .publishing)
        edit = try XCTUnwrap(outbox.records().first)
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(edit.state, .published)
        XCTAssertEqual(remote.updates, 1)
        XCTAssertEqual(remote.moves, 2)
    }

    func testCompleteWorkIsRestoredExclusivelyAfterLostCopyReply() throws {
        remote.failure = .completeCopy
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(edit.state, .published)
        XCTAssertEqual(remote.files[edit.path]?.digest, edit.digest)
        XCTAssertEqual(remote.updates, 1)
    }

    func testNewDestinationWinsDuringPublication() throws {
        remote.failure = .collision
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        let winner = remote.files[edit.path]
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files[edit.path], winner)
        XCTAssertEqual(remote.files[edit.workPath]?.digest, edit.digest)
        XCTAssertNotNil(remote.files[edit.recoveryPath])
        try outbox.validateContents(edit)
    }

    func testCleanupRetainsChangedBackupAndLocalRecoveryCopy() throws {
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        try outbox.complete(&edit, item: edit.item)
        remote.files[edit.recoveryPath] = try Remote.version(identity: 3, size: 4, digest: String(repeating: "c", count: 64))
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(edit)
        XCTAssertNotNil(remote.files[edit.path])
        XCTAssertNotNil(remote.files[edit.recoveryPath])
    }

    func testCompletedCleanupPreflightsBothArtifactsBeforeAnyRemoval() throws {
        try completePublication()
        let stage = try XCTUnwrap(remote.files[edit.stagePath])
        let backup = try XCTUnwrap(remote.files[edit.recoveryPath])
        remote.files[edit.stagePath] = nil
        let absentStage = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, absentStage)
        XCTAssertEqual(remote.removals, [])
        remote.files[edit.stagePath] = stage
        let changed = try Remote.version(identity: backup.identity.fileID, size: backup.size,
                                         digest: String(repeating: "d", count: 64))
        let replaced = try Remote.version(identity: 999, size: backup.size, digest: backup.digest)
        for value in [changed, replaced, nil] {
            remote.files[edit.recoveryPath] = value
            let before = remote.files
            XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
            XCTAssertEqual(remote.files, before)
            XCTAssertEqual(remote.removals, [])
            XCTAssertEqual(try stored(edit).completedStageRemoved, false)
            XCTAssertEqual(try stored(edit).completedBackupRemoved, false)
            XCTAssertEqual(try outbox.pendingCount, 1)
            try outbox.validateContents(edit)
        }
    }

    func testCompletedCleanupKeepsLostRemovalReplyUnconfirmedAcrossRestart() throws {
        try completePublication()
        remote.loseRemovalReplyAt = edit.recoveryPath
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).completedStageRemoved, true)
        XCTAssertEqual(try stored(edit).completedBackupRemoved, false)
        XCTAssertNil(remote.files[edit.stagePath])
        XCTAssertNil(remote.files[edit.recoveryPath])
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.inspections, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [])
        XCTAssertTrue(edit.recoveryRetained)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(edit)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
    }

    func testCompletedCleanupReloadsAcknowledgmentsBeforeUsingAStaleRecord() throws {
        try completePublication()
        var stale = edit!
        remote.failRemovalAt = edit.recoveryPath
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        let occupant = try Remote.version(identity: 999, size: 4, digest: String(repeating: "d", count: 64))
        remote.files[edit.stagePath] = occupant
        stale.recoveryRetained = false
        try outbox.complete(&stale, item: stale.item)
        XCTAssertEqual(stale.completedStageRemoved, true)
        XCTAssertEqual(stale.completedBackupRemoved, false)
        XCTAssertTrue(stale.recoveryRetained)
        var reactivated = stale
        reactivated.state = .published
        XCTAssertThrowsError(try outbox.save(reactivated))
        remote.failRemovalAt = nil
        remote.inspections = []
        remote.removals = []
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try EditTransaction.cleanup(&stale, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.recoveryPath])
        XCTAssertEqual(remote.files[edit.stagePath], occupant)
        XCTAssertEqual(stale.state, .completed)
        XCTAssertFalse(stale.recoveryRetained)
        XCTAssertEqual(try outbox.pendingCount, 0)
        try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.recoveryPath])
        XCTAssertEqual(edit, stale)
    }

    func testCompletedCleanupResumesAfterTerminalCheckpointBeforeLocalRemoval() throws {
        try completePublication()
        let receipt = try XCTUnwrap(edit.published)
        let payloadRecord = directory.appending(path: "Outbox/Contents/\(edit.id.uuidString).json")
        let savedRecord = directory.appending(path: "saved-payload-record")
        try FileManager.default.moveItem(at: payloadRecord, to: savedRecord)
        try FileManager.default.createDirectory(at: payloadRecord, withIntermediateDirectories: false)
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).completedCleanupStarted, true)
        try outbox.validateContents(edit)
        try FileManager.default.removeItem(at: payloadRecord)
        try FileManager.default.moveItem(at: savedRecord, to: payloadRecord)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(edit.state, .completed)
        XCTAssertEqual(edit.published, receipt)
        XCTAssertEqual(try outbox.base(item: receipt.item, contentVersion: receipt.contentVersion), receipt)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testCompletedCleanupResumesAndReplaysAfterPayloadRemoval() throws {
        try completePublication()
        var stale = edit!
        let obstruction = directory.appending(path: "Outbox/Contents/\(edit.id.uuidString).new")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        XCTAssertThrowsError(try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).completedCleanupStarted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(edit).path))
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try save("complete new version").id, edit.id)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        try EditTransaction.publish(&stale, outbox: outbox, remote: remote)
        XCTAssertEqual(stale.completedCleanupStarted, true)
        try FileManager.default.removeItem(at: obstruction)
        try outbox.complete(&stale, item: stale.item)
        XCTAssertEqual(stale.state, .completed)
        XCTAssertEqual(stale.published, edit.published)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try save("complete new version").id, stale.id)
    }

    func testCleanupPendingPublicationRemainsAValidBaseForNewerSaves() throws {
        try completePublication()
        let stage = remote.files[edit.stagePath], backup = remote.files[edit.recoveryPath]
        XCTAssertNil(try outbox.order(item: edit.item).head)
        var latest = try save("latest version")
        XCTAssertEqual(try outbox.order(item: edit.item).predecessors, [])
        XCTAssertEqual(try outbox.order(item: edit.item).superseded, [])
        XCTAssertEqual(try outbox.ownPublications(before: latest), [try XCTUnwrap(edit.published?.version)])
        try finish(&latest)
        XCTAssertFalse(latest.conflict)
        XCTAssertEqual(remote.files[edit.path]?.digest, latest.digest)
        XCTAssertEqual(remote.files[edit.stagePath], stage)
        XCTAssertEqual(remote.files[edit.recoveryPath], backup)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.files[edit.path]?.digest, latest.digest)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testCompletedConflictCleanupNeverRevisitsThePublishedStageName() throws {
        remote.files[edit.path] = nil
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        let receipt = try XCTUnwrap(edit.published)
        XCTAssertTrue(edit.conflict)
        try outbox.complete(&edit, item: receipt.item)
        let occupant = try Remote.version(identity: 999, size: 4, digest: String(repeating: "d", count: 64))
        remote.files[edit.stagePath] = occupant
        remote.inspections = []
        remote.removals = []
        try EditTransaction.cleanup(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.files[edit.stagePath], occupant)
        XCTAssertEqual(remote.files[edit.destination], receipt.version)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try outbox.pendingCount, 0)
        try outbox.dismissConflictNotice(id: edit.id)
        XCTAssertEqual(try save("complete new version").conflictNoticeDismissed, true)
    }

    func testConflictNameCollisionChoosesAnotherPersistedNameAndKeepsWinner() throws {
        remote.files[edit.path] = nil
        remote.failure = .conflictName
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(edit.state, .published)
        XCTAssertEqual(try outbox.records().first?.destination, edit.destination)
        XCTAssertEqual(remote.files[edit.destination]?.digest, edit.digest)
        XCTAssertEqual(remote.files.values.filter { $0.identity.fileID == 99 }.count, 1)
        XCTAssertEqual(remote.updates, 0)
    }

    func testLostConflictReplyIsProvedWithoutPublishingAnotherCopy() throws {
        remote.files[edit.path] = nil
        remote.failure = .conflictReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        let destination = edit.destination
        try EditTransaction.publish(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(edit.destination, destination)
        XCTAssertEqual(remote.moves, 1)
        XCTAssertEqual(edit.state, .published)
    }

    func testSeveralSavesAgainstOneBasePublishOnlyTheLatest() throws {
        let second = try save("second version")
        var latest = try save("latest version")
        for record in try outbox.order(item: edit.item).superseded { try outbox.discard(record) }
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
        XCTAssertNil(try outbox.records().first { $0.id == second.id })
        try finish(&latest)
        XCTAssertFalse(latest.conflict)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(remote.updates, 1)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testOwnEarlierSaveWithLostReplyIsNotAnExternalConflict() throws {
        try finish(&edit)
        var latest = try save("latest version")
        XCTAssertEqual(latest.baseVersion, edit.baseVersion)
        try finish(&latest)
        XCTAssertFalse(latest.conflict)
        XCTAssertEqual(latest.destination, "file.txt")
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(remote.files["file.txt"]?.identity.fileID, 1)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(remote.updates, 2)
    }

    func testExternalChangeAfterOwnEarlierSaveStillConflicts() throws {
        try finish(&edit)
        let external = try Remote.version(identity: 1, size: 5, digest: String(repeating: "b", count: 64))
        remote.files["file.txt"] = external
        var latest = try save("latest version")
        try EditTransaction.publish(&latest, outbox: outbox, remote: remote)
        XCTAssertTrue(latest.conflict)
        XCTAssertEqual(remote.files["file.txt"], external)
        XCTAssertEqual(remote.files[latest.destination]?.digest, latest.digest)
        XCTAssertEqual(remote.updates, 1)
    }

    func testEarlierStartedPublicationResolvesBeforeNewerContents() throws {
        remote.failure = .completeCopy
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .copying)
        var latest = try save("newer local contents")
        XCTAssertEqual(try outbox.order(item: edit.item).predecessors.map(\.id), [edit.id])
        XCTAssertThrowsError(try EditTransaction.publish(&latest, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        XCTAssertEqual(try stored(latest).state, .prepared)
        XCTAssertNil(remote.files[latest.stagePath])
        XCTAssertEqual(remote.updates, 1)
        edit = try stored(edit)
        try finish(&edit)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        try finish(&latest)
        XCTAssertFalse(latest.conflict)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(remote.updates, 2)
    }

    func testUnansweredStageCreateIsSentAgainWhileItsNameIsFree() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        try finish(&edit)
        XCTAssertEqual(remote.stages, 1)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUnansweredStageCreateWithARefusalReturnsTheSaveToWaiting() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        remote.failure = .refusedStage
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).state, .prepared)
        XCTAssertTrue(EditOutbox.canStopForRemoval(try stored(edit)))
    }

    func testSupersededUnansweredStageIsDiscardedOnlyAfterItsNameIsProvedFree() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        var latest = try save("latest version")
        XCTAssertThrowsError(try EditTransaction.publish(&latest, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        try EditTransaction.retire(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [edit.stagePath])
        XCTAssertEqual(remote.stages, 0)
        XCTAssertEqual(remote.removals, [])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(edit).path))
        try finish(&latest)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUnansweredStageWithAnOccupiedNameIsRetiredWithItsData() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        let occupant = try Remote.version(identity: 77, size: 2, digest: String(repeating: "e", count: 64))
        remote.files[edit.stagePath] = occupant
        var latest = try save("latest version")
        let stale = edit!
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        XCTAssertEqual(try stored(edit).state, .retired)
        XCTAssertNotEqual(try stored(edit).retiredStageRemoved, true)
        XCTAssertEqual(try outbox.order(item: edit.item).superseded, [])
        var replay = stale
        XCTAssertThrowsError(try EditTransaction.publish(&replay, outbox: outbox, remote: remote))
        XCTAssertThrowsError(try outbox.save(stale))
        try finish(&latest)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertFalse(latest.conflict)
        XCTAssertEqual(remote.updates, 1)
        remote.removals = []
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files[edit.stagePath], occupant)
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertTrue(try stored(edit).recoveryRetained)
        let exported = directory.appending(path: "retained.txt")
        try outbox.export(edit, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: outbox.contentURL(edit)))
        XCTAssertThrowsError(try outbox.removeIfCompleted())
    }

    func testRetiredUnansweredStageIsSettledByALaterCleanup() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        var latest = try save("latest version")
        remote.failure = .probeReply
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).state, .retired)
        XCTAssertNotEqual(try stored(edit).retiredStageRemoved, true)
        try finish(&latest)
        remote.removals = []
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [edit.stagePath, edit.stagePath])
        XCTAssertEqual(remote.removals, [])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
    }

    func testProvedFreeStageNameIsNeverProbedAgainAfterRestart() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        _ = try save("latest version")
        try outbox.retainSuperseded(&edit)
        var acknowledged = try stored(edit)
        acknowledged.retiredStageRemoved = true
        try outbox.saveRetiredProgress(acknowledged)
        let occupant = try Remote.version(identity: 77, size: 2, digest: String(repeating: "e", count: 64))
        remote.files[edit.stagePath] = occupant
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(remote.files[edit.stagePath], occupant)
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
    }

    func testLeftoverOfAnUnansweredStageCreateIsRemovedAndTheStageCreatedAgain() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        try remote.plantLeftover(at: edit.stagePath)
        try finish(&edit)
        XCTAssertEqual(remote.leftoverChecks, [edit.stagePath])
        XCTAssertEqual(remote.stages, 2)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testOtherOccupantOfAnUnansweredStageNameStaysAndKeepsTheSaveUncertain() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        let occupant = try Remote.version(identity: 77, size: 0, digest: edit.digest)
        remote.files[edit.stagePath] = occupant
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(remote.leftoverChecks, [edit.stagePath])
        XCTAssertEqual(remote.files[edit.stagePath], occupant)
        XCTAssertEqual(remote.stages, 1)
        XCTAssertEqual(try stored(edit).state, .creatingStage)
        XCTAssertNil(try stored(edit).stageIdentity)
    }

    func testStageNameTakenAgainAfterTheLeftoverRemovalKeepsTheSaveUncertain() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        try remote.plantLeftover(at: edit.stagePath)
        remote.leftoverReturns = true
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(remote.leftoverChecks, [edit.stagePath])
        XCTAssertEqual(remote.stages, 2)
        XCTAssertEqual(try stored(edit).state, .creatingStage)
        XCTAssertNil(try stored(edit).stageIdentity)
    }

    func testRetiredUnansweredStageSettlesAfterItsLeftoverIsRemoved() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        try remote.plantLeftover(at: edit.stagePath)
        var latest = try save("latest version")
        try EditTransaction.retire(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [edit.stagePath, edit.stagePath])
        XCTAssertEqual(remote.leftoverChecks, [edit.stagePath])
        XCTAssertEqual(remote.removals, [])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        try finish(&latest)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testPartiallyUploadedNewestSaveKeepsTheArtifactAndCompleteLocalCopy() throws {
        remote.failure = .partialStage
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit = try stored(edit)
        XCTAssertEqual(edit.state, .creatingStage)
        XCTAssertNotNil(edit.stageIdentity)
        XCTAssertNotEqual(remote.files[edit.stagePath]?.digest, edit.digest)
        let before = remote.files
        XCTAssertThrowsError(try finish(&edit))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.stages, 1)
        XCTAssertEqual(remote.updates, 0)
        try outbox.validateContents(edit)
    }

    func testRefusedStageReturnsTheSaveToWaitingAndPublishesLater() throws {
        remote.failure = .refusedStage
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .readOnly)
        }
        edit = try stored(edit)
        XCTAssertEqual(edit.state, .prepared)
        XCTAssertNil(edit.stageIdentity)
        XCTAssertTrue(EditOutbox.canStopForRemoval(edit))
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        try finish(&edit)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        XCTAssertEqual(remote.stages, 2)
    }

    func testStageWithoutProvenIdentityIsNeverRemovedByPath() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        let unknown = try Remote.version(identity: 77, size: 2, digest: String(repeating: "e", count: 64))
        remote.files[edit.stagePath] = unknown
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit = try stored(edit)
        edit.stageIdentity = try EditFileIdentity(fileID: 88, birthMicroseconds: 10)
        try outbox.save(edit)
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files[edit.stagePath], unknown)
        XCTAssertEqual(try stored(edit).state, .creatingStage)
        XCTAssertEqual(remote.stages, 1)
        XCTAssertEqual(remote.removals, [])
        try outbox.validateContents(edit)
    }

    func testPartialBackupKeepsTheOriginalAndCompleteLocalCopy() throws {
        remote.failure = .partialBackup
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit = try stored(edit)
        XCTAssertEqual(edit.state, .creatingBackup)
        let before = remote.files
        XCTAssertThrowsError(try finish(&edit))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.backups, 1)
        XCTAssertEqual(remote.updates, 0)
        try outbox.validateContents(edit)
    }

    func testPartialSupersededStageStaysUntouchedAfterNewerSavePublishes() throws {
        remote.failure = .partialStage
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        var latest = try save("latest version")
        XCTAssertThrowsError(try EditTransaction.publish(&latest, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        XCTAssertNil(remote.files[latest.stagePath])
        edit = try stored(edit)
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertThrowsError(try finish(&latest))
        XCTAssertEqual(remote.files, before)
        try outbox.validateContents(edit)
        try outbox.validateContents(latest)
        try outbox.retainSuperseded(&edit)
        try finish(&latest)
        XCTAssertEqual(remote.files[edit.stagePath], before[edit.stagePath])
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(remote.updates, 1)
        XCTAssertEqual(try stored(edit).state, .retired)
        try outbox.validateContents(edit)
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
    }

    func testRetiredPartialBackupKeepsRecoveryDataWhileLaterSavesContinue() throws {
        remote.failure = .partialBackup
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        let stage = remote.files[edit.stagePath], backup = remote.files[edit.recoveryPath]
        var latest = try save("latest version")
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        try outbox.retainSuperseded(&edit)
        try finish(&latest)
        var next = try save("another save")
        try finish(&next)
        XCTAssertEqual(remote.files["file.txt"]?.digest, next.digest)
        XCTAssertFalse(next.conflict)
        XCTAssertEqual(remote.files[edit.stagePath], stage)
        XCTAssertEqual(remote.files[edit.recoveryPath], backup)
        XCTAssertEqual(remote.updates, 2)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(edit)
    }

    func testRetiredCompleteStageCanBeProvedAfterItsReplyWasLost() throws {
        let latest = try retireInterruptedStage()
        XCTAssertNil(edit.stageVersion)
        let original = remote.files[edit.path]
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [edit.stagePath])
        XCTAssertEqual(remote.removals, [edit.stagePath])
        XCTAssertEqual(remote.files[edit.path], original)
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(edit).path))
        try outbox.validateContents(latest)
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testRetiredCleanupPersistsCompleteProofBeforeRemovingEitherArtifact() throws {
        var latest = try retireInterruptedBackup()
        XCTAssertNil(edit.backupVersion)
        try finish(&latest)
        let before = remote.files
        remote.failRemovalAt = edit.stagePath
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        let retained = try stored(edit)
        XCTAssertEqual(retained.stageVersion, before[edit.stagePath])
        XCTAssertEqual(retained.backupVersion, before[edit.recoveryPath])
        XCTAssertNil(retained.retiredStageRemoved)
        XCTAssertNil(retained.retiredBackupRemoved)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        remote.failRemovalAt = nil
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(Set(remote.files.keys), [edit.path])
        XCTAssertEqual(remote.files[edit.path]?.digest, latest.digest)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
    }

    func testRetiredCleanupPreflightsEveryArtifactAndRetainsMissingOrChangedData() throws {
        _ = try retireInterruptedBackup()
        let stage = try XCTUnwrap(remote.files[edit.stagePath])
        let backup = try XCTUnwrap(remote.files[edit.recoveryPath])
        let partial = try Remote.version(identity: backup.identity.fileID, size: backup.size - 1,
                                         digest: String(repeating: "f", count: 64))
        let changed = try Remote.version(identity: backup.identity.fileID, size: backup.size,
                                         digest: String(repeating: "e", count: 64))
        let replaced = try Remote.version(identity: 999, size: backup.size, digest: backup.digest)
        for artifact in [partial, changed, replaced, nil] {
            remote.files[edit.recoveryPath] = artifact
            let before = remote.files
            XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
            XCTAssertEqual(remote.files, before)
            XCTAssertEqual(remote.removals, [])
            XCTAssertEqual(remote.files[edit.stagePath], stage)
            XCTAssertNil(try stored(edit).backupVersion)
            try outbox.validateContents(edit)
        }
        remote.files[edit.recoveryPath] = backup
        remote.files[edit.stagePath] = try Remote.version(identity: stage.identity.fileID, size: stage.size,
                                                         digest: String(repeating: "d", count: 64))
        let changedStage = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, changedStage)
        XCTAssertEqual(remote.removals, [])
    }

    func testRetiredCleanupRequiresRecordedIdentityEvenForCompleteContents() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        remote.files[edit.stagePath] = try Remote.version(identity: 300, size: edit.size, digest: edit.digest)
        _ = try save("latest version")
        try outbox.retainSuperseded(&edit)
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        try outbox.validateContents(edit)
    }

    func testRetiredCleanupDoesNotReplaceRecordedCompleteMetadataEvidence() throws {
        _ = try retireInterruptedBackup()
        let stage = try XCTUnwrap(edit.stageVersion)
        remote.files[edit.stagePath] = try EditFileVersion(identity: stage.identity, size: stage.size,
            digest: stage.digest, modifiedMicroseconds: stage.modifiedMicroseconds,
            changedMicroseconds: stage.changedMicroseconds, attributes: stage.attributes, security: Data([9]))
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try stored(edit).stageVersion, stage)
        try outbox.validateContents(edit)
    }

    func testLostRetiredArtifactRemovalReplyRemainsUnconfirmedAfterRestart() throws {
        _ = try retireInterruptedBackup()
        remote.loseRemovalReplyAt = edit.stagePath
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertNil(remote.files[edit.stagePath])
        XCTAssertNil(try stored(edit).retiredStageRemoved)
        XCTAssertNotNil(remote.files[edit.recoveryPath])
        let before = remote.files
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.inspections, [edit.stagePath])
        XCTAssertEqual(remote.removals, [])
        XCTAssertNil(try stored(edit).retiredCleanupStarted)
        try outbox.validateContents(edit)
    }

    func testAcknowledgedRetiredRemovalNeverTouchesANewOccupantAfterRestart() throws {
        _ = try retireInterruptedBackup()
        remote.failRemovalAt = edit.recoveryPath
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).retiredStageRemoved, true)
        XCTAssertNil(try stored(edit).retiredBackupRemoved)
        let newOccupant = try Remote.version(identity: 999, size: 4, digest: String(repeating: "d", count: 64))
        remote.files[edit.stagePath] = newOccupant
        remote.failRemovalAt = nil
        remote.inspections = []
        remote.removals = []
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.recoveryPath])
        XCTAssertEqual(remote.files[edit.stagePath], newOccupant)
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
    }

    func testRetiredCleanupResumesLocallyAfterTerminalCheckpoint() throws {
        var latest = try retireInterruptedBackup()
        try finish(&latest)
        let payloadRecord = directory.appending(path: "Outbox/Contents/\(edit.id.uuidString).json")
        let savedRecord = directory.appending(path: "saved-payload-record")
        try FileManager.default.moveItem(at: payloadRecord, to: savedRecord)
        try FileManager.default.createDirectory(at: payloadRecord, withIntermediateDirectories: false)
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).retiredCleanupStarted, true)
        try outbox.validateContents(edit)
        try FileManager.default.removeItem(at: payloadRecord)
        try FileManager.default.moveItem(at: savedRecord, to: payloadRecord)
        XCTAssertEqual(try outbox.pendingCount, 1)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(edit).path))
    }

    func testRetiredCleanupResumesAfterPayloadRemovalBeforeRecordRemoval() throws {
        var latest = try retireInterruptedBackup()
        try finish(&latest)
        let obstruction = directory.appending(path: "Outbox/Contents/\(edit.id.uuidString).new")
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: false)
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).retiredCleanupStarted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(edit).path))
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        try FileManager.default.removeItem(at: obstruction)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        remote.inspections = []
        remote.removals = []
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appending(path: "Outbox/\(edit.id.uuidString).metadata").path))
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
    }

    func testRetiredCleanupKeepsEverythingWhenTheSuccessorIsMissingOrDamaged() throws {
        let latest = try retireInterruptedStage()
        let payload = outbox.contentURL(latest)
        let contents = try Data(contentsOf: payload)
        try FileManager.default.removeItem(at: payload)
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        try Data("damaged".utf8).write(to: payload)
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        try outbox.validateContents(edit)
        try contents.write(to: payload)
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(try outbox.records().map(\.id), [latest.id])
    }

    func testRetiredCleanupRequiresTheCompletedSuccessorReceiptOnDisk() throws {
        var latest = try retireInterruptedStage()
        try finish(&latest)
        let receipt = try XCTUnwrap(latest.published)
        let receiptURL = directory.appending(path: "Outbox/\(receipt.id.uuidString).base")
        try FileManager.default.removeItem(at: receiptURL)
        remote.inspections = []
        remote.removals = []
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.inspections, [])
        XCTAssertEqual(remote.removals, [])
        try outbox.validateContents(edit)
        try outbox.storeBase(receipt)
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testReplayedContentsUseFreshStageAfterInterruptedUpload() throws {
        remote.failure = .partialStage
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        let partial = remote.files[edit.stagePath]
        var replay = try outbox.prepare(item: edit.item, parent: edit.parent,
                                        path: XCTUnwrap(RelativePath(edit.path)), baseVersion: edit.baseVersion,
                                        failOnConflict: edit.failOnConflict, contents: outbox.contentURL(edit),
                                        progress: Progress())
        XCTAssertNotEqual(replay.id, edit.id)
        XCTAssertEqual(replay.digest, edit.digest)
        XCTAssertEqual(try outbox.order(item: edit.item).superseded.map(\.id), [edit.id])
        try outbox.retainSuperseded(&edit)
        try finish(&replay)
        XCTAssertEqual(remote.files[edit.stagePath], partial)
        XCTAssertEqual(remote.files[edit.path]?.digest, edit.digest)
        XCTAssertEqual(remote.updates, 1)
        XCTAssertFalse(replay.conflict)
        try outbox.validateContents(edit)
    }

    func testRetirementNeverBypassesAnUncertainOriginalWrite() throws {
        remote.failure = .partialCopy
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        var latest = try save("latest version")
        let before = remote.files
        XCTAssertThrowsError(try outbox.retainSuperseded(&edit))
        XCTAssertThrowsError(try finish(&latest))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(try stored(edit).state, .copying)
        try outbox.validateContents(edit)
        try outbox.validateContents(latest)
    }

    func testSupersededBackupIsRemovedOnlyWithCompleteEvidence() throws {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .creatingBackup)
        var latest = try save("latest version")
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        edit.backupVersion = try XCTUnwrap(remote.files[edit.recoveryPath])
        edit.state = .backedUp
        try outbox.save(edit)
        let original = try XCTUnwrap(remote.files[edit.recoveryPath])
        remote.files[edit.recoveryPath] = try Remote.version(identity: original.identity.fileID,
                                                           size: original.size, digest: String(repeating: "f", count: 64))
        let changed = remote.files
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, changed)
        remote.files[edit.recoveryPath] = original
        try EditTransaction.retire(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        try finish(&latest)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUnansweredBackupCreateIsSentAgainWhileItsNameIsFree() throws {
        try unansweredBackup()
        try finish(&edit)
        XCTAssertEqual(remote.backups, 2)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        XCTAssertEqual(remote.files["file.txt"]?.identity.fileID, 1)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUnansweredBackupWithAnOccupiedNameNeverChangesTheOriginal() throws {
        try unansweredBackup()
        let occupant = try Remote.version(identity: 77, size: 2, digest: String(repeating: "e", count: 64))
        remote.files[edit.recoveryPath] = occupant
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.leftoverChecks, [edit.recoveryPath])
        XCTAssertEqual(remote.moves, 0)
        XCTAssertEqual(remote.updates, 0)
        XCTAssertEqual(try stored(edit).state, .creatingBackup)
        XCTAssertNil(try stored(edit).backupIdentity)
        try outbox.validateContents(edit)
    }

    func testLeftoverOfAnUnansweredBackupCreateIsRemovedAndTheBackupCreatedAgain() throws {
        try unansweredBackup()
        try remote.plantLeftover(at: edit.recoveryPath)
        try finish(&edit)
        XCTAssertEqual(remote.leftoverChecks, [edit.recoveryPath])
        XCTAssertEqual(remote.backups, 3)
        XCTAssertEqual(remote.files["file.txt"]?.digest, edit.digest)
        XCTAssertEqual(remote.files["file.txt"]?.identity.fileID, 1)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testSupersededUnansweredBackupSettlesAfterItsLeftoverIsRemoved() throws {
        try unansweredBackup()
        try remote.plantLeftover(at: edit.recoveryPath)
        var latest = try save("latest version")
        try EditTransaction.retire(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [edit.recoveryPath, edit.recoveryPath])
        XCTAssertEqual(remote.leftoverChecks, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.stagePath])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        try finish(&latest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
    }

    func testSupersededUnansweredBackupIsCleanedUpAfterItsNameIsProvedFree() throws {
        try unansweredBackup()
        var latest = try save("latest version")
        try EditTransaction.retire(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.stagePath])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
        try finish(&latest)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt"])
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testSupersededUnansweredBackupWithAnOccupiedNameKeepsTheStageAndLocalCopy() throws {
        try unansweredBackup()
        let occupant = try Remote.version(identity: 77, size: 2, digest: String(repeating: "e", count: 64))
        remote.files[edit.recoveryPath] = occupant
        let stage = remote.files[edit.stagePath]
        var latest = try save("latest version")
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.removals, [])
        XCTAssertEqual(try stored(edit).state, .retired)
        try finish(&latest)
        XCTAssertEqual(remote.files[edit.stagePath], stage)
        XCTAssertEqual(remote.files[edit.recoveryPath], occupant)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
        try outbox.validateContents(edit)
    }

    func testBackupAcknowledgementIsNotProbedAgainWhenTheStageRemovalFails() throws {
        try unansweredBackup()
        var latest = try save("latest version")
        remote.failRemovalAt = edit.stagePath
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(try stored(edit).retiredBackupRemoved, true)
        XCTAssertNotEqual(try stored(edit).retiredStageRemoved, true)
        try finish(&latest)
        remote.failRemovalAt = nil
        remote.probes = []
        remote.removals = []
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.probes, [])
        XCTAssertEqual(remote.removals, [edit.stagePath])
        XCTAssertNil(try outbox.records().first { $0.id == edit.id })
    }

    func testUnansweredBackupWithAChangedOriginalCreatesNoBackupOrConflict() throws {
        try unansweredBackup()
        remote.files["file.txt"] = try Remote.version(identity: 1, size: 5, digest: String(repeating: "b", count: 64))
        let before = remote.files
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .unresolved)
        }
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.backups, 1)
        XCTAssertEqual(try stored(edit).state, .creatingBackup)
        XCTAssertFalse(try stored(edit).conflict)
    }

    func testAcknowledgementWithoutAnIdentityMustHaveNoVersionAndNeedsTheOldVersionForABackup() throws {
        edit.state = .creatingStage
        try outbox.save(edit)
        _ = try save("latest version")
        try outbox.retainSuperseded(&edit)
        var record = try stored(edit)
        record.retiredStageRemoved = true
        XCTAssertTrue(record.validRetiredProgress)
        record.stageVersion = try Remote.version(identity: 5, size: edit.size, digest: edit.digest)
        XCTAssertFalse(record.validRetiredProgress)
        record.stageVersion = nil
        record.retiredBackupRemoved = true
        XCTAssertFalse(record.validRetiredProgress)
    }

    /// A backup create that got no answer: the stage and old version are recorded, no backup identity.
    private func unansweredBackup() throws {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        remote.files[edit.recoveryPath] = nil
        edit = try stored(edit)
        edit.backupIdentity = nil
        try outbox.save(edit)
        XCTAssertEqual(edit.state, .creatingBackup)
        XCTAssertNotNil(edit.previous)
        remote.probes = []
        remote.removals = []
    }

    func testSupersessionRecordsAcknowledgedRemovalBeforeTheNextCleanupFails() throws {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit.backupVersion = try XCTUnwrap(remote.files[edit.recoveryPath])
        edit.state = .backedUp
        try outbox.save(edit)
        var latest = try save("latest version")
        remote.failRemovalAt = edit.recoveryPath
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .retired)
        let retained = try stored(edit)
        XCTAssertEqual(retained.retiredStageRemoved, true)
        XCTAssertNotEqual(retained.retiredBackupRemoved, true)
        XCTAssertNil(remote.files[edit.stagePath])
        try outbox.validateContents(edit)
        let replacement = try Remote.version(identity: 999, size: 5, digest: String(repeating: "d", count: 64))
        remote.files[edit.stagePath] = replacement
        remote.failRemovalAt = nil
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try finish(&latest)
        remote.inspections = []
        remote.removals = []
        try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote)
        XCTAssertEqual(remote.inspections, [edit.recoveryPath])
        XCTAssertEqual(remote.removals, [edit.recoveryPath])
        XCTAssertEqual(remote.files[edit.stagePath], replacement)
        XCTAssertEqual(remote.files[edit.path]?.digest, latest.digest)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testSupersessionRetainsUnacknowledgedRemovalAndAllowsTheSuccessor() throws {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit.backupVersion = try XCTUnwrap(remote.files[edit.recoveryPath])
        edit.state = .backedUp
        try outbox.save(edit)
        var latest = try save("latest version")
        let backup = remote.files[edit.recoveryPath]
        remote.loseRemovalReplyAt = edit.stagePath
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(edit.state, .retired)
        XCTAssertNotEqual(try stored(edit).retiredStageRemoved, true)
        XCTAssertNil(remote.files[edit.stagePath])
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        try finish(&latest)
        let before = remote.files
        remote.removals = []
        XCTAssertThrowsError(try EditTransaction.cleanupRetired(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertEqual(remote.files[edit.recoveryPath], backup)
        XCTAssertTrue(remote.removals.isEmpty)
        try outbox.validateContents(edit)
        let exported = directory.appending(path: "retained.txt")
        try outbox.export(edit, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("complete new version".utf8))
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testSupersededMissingStageRetainsTheLocalSaveBeforeAnyRemoval() throws {
        try assertMissingSupersededArtifactRetained(stage: true)
    }

    func testSupersededMissingBackupRetainsTheLocalSaveBeforeAnyRemoval() throws {
        try assertMissingSupersededArtifactRetained(stage: false)
    }

    private func assertMissingSupersededArtifactRetained(stage: Bool) throws {
        remote.failure = .backupReply
        XCTAssertThrowsError(try EditTransaction.publish(&edit, outbox: outbox, remote: remote))
        edit.backupVersion = try XCTUnwrap(remote.files[edit.recoveryPath])
        edit.state = .backedUp
        try outbox.save(edit)
        var latest = try save("latest version")
        remote.files[stage ? edit.stagePath : edit.recoveryPath] = nil
        let before = remote.files
        let local = try Data(contentsOf: outbox.contentURL(edit))
        XCTAssertThrowsError(try EditTransaction.retire(&edit, outbox: outbox, remote: remote))
        XCTAssertEqual(remote.files, before)
        XCTAssertTrue(remote.removals.isEmpty)
        XCTAssertEqual(try stored(edit).state, .backedUp)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(edit)), local)
        try outbox.retainSuperseded(&edit)
        try finish(&latest)
        XCTAssertEqual(try stored(edit).state, .retired)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(edit)), local)
        XCTAssertEqual(remote.files["file.txt"]?.digest, latest.digest)
    }

    func testSupersededConflictStageIsRemovedAndOnlyLatestContentsAreCopied() throws {
        let external = try Remote.version(identity: 1, size: 5, digest: String(repeating: "b", count: 64))
        remote.files["file.txt"] = external
        var refused = try save("refused conflicting version", failOnConflict: true)
        try outbox.discard(edit)
        XCTAssertThrowsError(try EditTransaction.publish(&refused, outbox: outbox, remote: remote)) {
            XCTAssertEqual($0 as? UploadError, .editConflict)
        }
        XCTAssertEqual(refused.state, .staged)
        XCTAssertNotNil(remote.files[refused.stagePath])
        var latest = try save("latest version")
        try EditTransaction.retire(&refused, outbox: outbox, remote: remote)
        try EditTransaction.publish(&latest, outbox: outbox, remote: remote)
        XCTAssertTrue(latest.conflict)
        XCTAssertEqual(remote.files["file.txt"], external)
        XCTAssertEqual(remote.files[latest.destination]?.digest, latest.digest)
        XCTAssertEqual(Set(remote.files.keys), ["file.txt", latest.destination])
    }

    private final class Remote: EditRemote {
        enum Failure {
            case partialCopy, completeCopy, publication, collision, conflictName, conflictReply, backupReply
            case partialStage, partialBackup, refusedStage, probeReply
        }
        var failure: Failure?
        var files: [String: EditFileVersion]
        var updates = 0
        var moves = 0
        var stages = 0
        var backups = 0
        var inspections: [String] = []
        var removals: [String] = []
        var probes: [String] = []
        /// Names whose occupant is the empty private file of a create that got no answer.
        var leftovers: Set<String> = []
        var leftoverChecks: [String] = []
        /// Another lost create lands again right after the removal.
        var leftoverReturns = false
        var failRemovalAt: String?
        var loseRemovalReplyAt: String?
        private var nextIdentity: UInt64 = 200

        init(original: EditFileVersion) {
            files = ["file.txt": original]
        }

        static func version(identity: UInt64, size: Int64, digest: String) throws -> EditFileVersion {
            try EditFileVersion(identity: EditFileIdentity(fileID: identity, birthMicroseconds: 10), size: size,
                                digest: digest, modifiedMicroseconds: 20, changedMicroseconds: 30,
                                attributes: 32, security: Data([1]))
        }

        func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            let data = try Data(contentsOf: contents)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            stages += 1
            guard files[path] == nil else { throw UploadError.collision }
            if failure == .refusedStage {
                failure = nil
                throw EditStageRefusal(UploadError.readOnly)
            }
            if failure == .partialStage {
                failure = nil
                let partial = try Self.version(identity: newIdentity(), size: Int64(data.count / 2),
                                               digest: String(repeating: "e", count: 64))
                files[path] = partial
                try created(partial.identity)
                throw UploadError.unresolved
            }
            let staged = try Self.version(identity: newIdentity(), size: Int64(data.count), digest: digest)
            files[path] = staged
            try created(staged.identity)
            return staged
        }

        func inspect(path: String, original: Bool) throws -> EditFileVersion? {
            inspections.append(path)
            return files[path]
        }

        func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            let old = try XCTUnwrap(files[original])
            backups += 1
            guard files[path] == nil else { throw UploadError.collision }
            if failure == .partialBackup {
                failure = nil
                let partial = try Self.version(identity: newIdentity(), size: old.size - 1,
                                               digest: String(repeating: "f", count: 64))
                files[path] = partial
                try created(partial.identity)
                throw UploadError.unresolved
            }
            let backup = try Self.version(identity: newIdentity(), size: old.size, digest: old.digest)
            files[path] = backup
            try created(backup.identity)
            if failure == .backupReply {
                failure = nil
                throw UploadError.unresolved
            }
            return backup
        }

        func move(source: String, destination: String) throws {
            if failure == .conflictName {
                files[destination] = try Self.version(identity: 99, size: 4, digest: String(repeating: "d", count: 64))
                failure = nil
            }
            if failure == .collision, destination == "file.txt" {
                files[destination] = try Self.version(identity: 99, size: 4, digest: String(repeating: "d", count: 64))
                failure = nil
            }
            guard files[destination] == nil else { throw UploadError.collision }
            files[destination] = files.removeValue(forKey: source)
            moves += 1
            if (failure == .publication && destination == "file.txt") || failure == .conflictReply {
                failure = nil
                throw UploadError.unresolved
            }
        }

        func update(work: String, stage: String, size: Int64) throws {
            XCTAssertTrue(work.hasSuffix(".work"))
            updates += 1
            let identity = try XCTUnwrap(files[work]).identity.fileID
            let staged = try XCTUnwrap(files[stage]).digest
            files[work] = try Self.version(identity: identity, size: size,
                                           digest: failure == .partialCopy ? String(repeating: "e", count: 64) : staged)
            if failure == .partialCopy || failure == .completeCopy {
                failure = nil
                throw UploadError.unresolved
            }
        }

        private func newIdentity() -> UInt64 {
            nextIdentity += 1
            return nextIdentity
        }

        func proveAbsent(path: String) throws {
            probes.append(path)
            guard files[path] == nil else { throw UploadError.collision }
            if failure == .probeReply {
                failure = nil
                throw UploadError.unresolved
            }
        }

        func removeLeftoverCreate(path: String) throws -> Bool {
            leftoverChecks.append(path)
            guard files[path] == nil || leftovers.contains(path) else { return false }
            files[path] = nil
            leftovers.remove(path)
            if leftoverReturns { try plantLeftover(at: path) }
            return true
        }

        func plantLeftover(at path: String) throws {
            files[path] = try Self.version(identity: 88, size: 0, digest: SHA256.hash(data: Data()).map {
                String(format: "%02x", $0)
            }.joined())
            leftovers.insert(path)
        }

        func removeArtifact(path: String, version: EditFileVersion) throws {
            removals.append(path)
            if failRemovalAt == path { throw UploadError.unresolved }
            guard files[path] == version || files[path] == nil else { throw UploadError.unresolved }
            XCTAssertFalse(path.hasSuffix(".work"))
            XCTAssertNotEqual(path, "file.txt")
            files[path] = nil
            if loseRemovalReplyAt == path {
                loseRemovalReplyAt = nil
                throw UploadError.unresolved
            }
        }
    }
}
