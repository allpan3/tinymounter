import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class EditOutboxTests: XCTestCase {
    private var directory: URL!
    private var input: URL!
    private var outbox: EditOutbox!
    private let item = UUID().uuidString

    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64) { self.bytes = bytes }
        func read() -> Int64 { lock.withLock { bytes } }
        func set(_ bytes: Int64) { lock.withLock { self.bytes = bytes } }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        input = directory.appending(path: "input")
        try Data("pending document".utf8).write(to: input)
        outbox = try EditOutbox(directory: directory.appending(path: "Edits"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func prepare(base: String = "legacy", failOnConflict: Bool = false) throws -> PendingEdit {
        try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("document.txt")),
                           baseVersion: base, failOnConflict: failOnConflict, contents: input, progress: Progress())
    }

    private func prepare(_ text: String, base: String = "legacy",
                         checkSpace: ((Int64) throws -> Void)? = nil) throws -> PendingEdit {
        try Data(text.utf8).write(to: input)
        return try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("document.txt")),
                                  baseVersion: base, failOnConflict: false, contents: input, progress: Progress(),
                                  checkSpace: checkSpace)
    }

    private func setAttribute(_ value: String) {
        let data = Data(value.utf8)
        XCTAssertEqual(data.withUnsafeBytes {
            setxattr(input.path, "dev.tinymounter.test", $0.baseAddress, $0.count, 0, 0)
        }, 0)
    }

    private func stored(_ record: PendingEdit) throws -> PendingEdit {
        try XCTUnwrap(outbox.records().first { $0.id == record.id })
    }

    private func completeAsPublished(_ record: inout PendingEdit) throws {
        record.state = .published
        record.previous = try version(for: record)
        record.published = try EditBaseReceipt(item: item, version: version(for: record))
        try outbox.complete(&record, item: item)
    }

    private func files(of record: PendingEdit) -> [String] {
        let edits = directory.appending(path: "Edits")
        return [record.id.uuidString + ".edit", record.id.uuidString + ".metadata",
                "Contents/\(record.id.uuidString).data", "Contents/\(record.id.uuidString).json"]
            .filter { FileManager.default.fileExists(atPath: edits.appending(path: $0).path) }
    }

    private func version(for record: PendingEdit) throws -> EditFileVersion {
        try EditFileVersion(identity: EditFileIdentity(fileID: 12, birthMicroseconds: 34),
                            size: record.size, digest: record.digest, modifiedMicroseconds: 56,
                            changedMicroseconds: 78, attributes: 32, security: Data([1, 2, 3]))
    }

    func testWorkNameStaysVisibleAndInTheOriginalParentAfterReload() throws {
        for path in ["document.txt", ".parent/nested/document.txt"] {
            let record = try outbox.prepare(item: UUID().uuidString, parent: Catalog.rootItemID,
                path: XCTUnwrap(RelativePath(path)), baseVersion: "legacy", failOnConflict: false,
                contents: input, progress: Progress())
            let restored = try XCTUnwrap(outbox.records().first { $0.id == record.id })
            let work = try XCTUnwrap(RelativePath(restored.workPath))
            XCTAssertEqual(work.components.dropLast(), RelativePath(path)!.components.dropLast())
            XCTAssertEqual(work.components.last, "tinymounter-\(record.id.uuidString).work")
            XCTAssertEqual(restored.workPath, record.workPath)
            XCTAssertNotEqual(restored.workPath, record.stagePath)
            XCTAssertNotEqual(restored.workPath, record.recoveryPath)
        }
    }

    func testReplayKeepsImmutableGenerationAndNewSaveRetainsBoth() throws {
        let first = try prepare()
        XCTAssertEqual(try prepare().id, first.id)
        try FileManager.default.removeItem(at: input)
        try outbox.validateContents(first)
        try Data("later edit".utf8).write(to: input)
        let second = try prepare()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try outbox.pendingCount, 2)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(first)), Data("pending document".utf8))
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(second)), Data("later edit".utf8))
        XCTAssertThrowsError(try outbox.removeIfCompleted())
    }

    func testRestartPreservesPublicationIntentAndBothLocalGenerations() throws {
        var first = try prepare()
        first.state = .movingOriginal
        first.previous = try version(for: first)
        first.stageIdentity = try EditFileIdentity(fileID: 90, birthMicroseconds: 91)
        try outbox.save(first)
        let reopened = try EditOutbox(directory: directory.appending(path: "Edits"))
        XCTAssertEqual(try reopened.records(), [first])
        try reopened.validateContents(first)
        XCTAssertThrowsError(try reopened.removeIfCompleted())
    }

    func testLegacyFingerprintNeverResolvesToStrongBase() throws {
        let record = try prepare()
        let receipt = try EditBaseReceipt(item: item, version: version(for: record))
        try outbox.storeBase(receipt)
        try outbox.storeBase(receipt)
        XCTAssertEqual(try outbox.base(item: item, contentVersion: receipt.contentVersion), receipt)
        XCTAssertNil(try outbox.base(item: item, contentVersion: "f1:16:56:78"))
        XCTAssertThrowsError(try outbox.base(item: UUID().uuidString, contentVersion: receipt.contentVersion))
        let different = try EditBaseReceipt(id: receipt.id, item: UUID().uuidString, version: version(for: record))
        XCTAssertThrowsError(try outbox.storeBase(different))
        XCTAssertEqual(try outbox.base(item: item, contentVersion: receipt.contentVersion), receipt)
    }

    func testCompletionRequiresVerifiedIdentityAndContentBeforeDiscardingPendingBytes() throws {
        var record = try prepare()
        XCTAssertThrowsError(try outbox.complete(&record, item: item))
        try outbox.validateContents(record)
        record.state = .published
        record.published = try EditBaseReceipt(item: item, version: version(for: record))
        XCTAssertThrowsError(try outbox.complete(&record, item: item))
        record.previous = record.published?.version
        try outbox.complete(&record, item: item)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(record).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appending(path: "Edits/\(record.id.uuidString).metadata").path))
        XCTAssertEqual(try outbox.base(item: item, contentVersion: XCTUnwrap(record.published?.contentVersion)), record.published)
        try outbox.complete(&record, item: item)
    }

    func testRecoveryArtifactsKeepLifecycleBlockedAfterRemoteCompletion() throws {
        var record = try prepare()
        record.state = .published
        record.previous = try version(for: record)
        record.published = try EditBaseReceipt(item: item, version: version(for: record))
        record.recoveryRetained = true
        try outbox.complete(&record, item: item)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(record)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        record.recoveryRetained = false
        try outbox.complete(&record, item: item)
        XCTAssertEqual(record.state, .cleaningUp)
        XCTAssertTrue(record.recoveryRetained)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(record)
    }

    func testCompletedCleanupProgressCannotRegressOrChangeReceiptEvidence() throws {
        var record = try prepare()
        record.state = .published
        record.previous = try version(for: record)
        record.stageVersion = try version(for: record)
        record.stageIdentity = record.stageVersion?.identity
        record.published = try EditBaseReceipt(item: item, version: version(for: record))
        record.recoveryRetained = true
        try outbox.complete(&record, item: item)
        let stale = record
        var changed = record
        changed.completedStageRemoved = nil
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        changed = record
        changed.completedCleanupStarted = true
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        changed = record
        changed.recoveryRetained = false
        XCTAssertThrowsError(try outbox.save(changed))
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        changed = record
        changed.completedBackupRemoved = true
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        changed = record
        changed.published = try EditBaseReceipt(item: item, version: version(for: record))
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        record.completedStageRemoved = true
        try outbox.saveCompletedProgress(record)
        XCTAssertThrowsError(try outbox.saveCompletedProgress(stale))
        XCTAssertThrowsError(try outbox.save(stale))
        record.completedCleanupStarted = true
        try outbox.saveCompletedProgress(record)
        changed = record
        changed.completedCleanupStarted = nil
        XCTAssertThrowsError(try outbox.saveCompletedProgress(changed))
        try outbox.finishCompletedCleanup(&record)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.published, stale.published)
        XCTAssertThrowsError(try outbox.save(stale))
        XCTAssertThrowsError(try outbox.saveCompletedProgress(stale))
        XCTAssertEqual(try prepare(), record)
    }

    func testDecodedNestedIdentityAndVersionCannotBypassValidation() throws {
        let record = try prepare()
        let encoded = try JSONEncoder().encode(version(for: record))
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        values["identity"] = ["fileID": 0, "birthMicroseconds": 34]
        XCTAssertThrowsError(try JSONDecoder().decode(EditFileVersion.self, from: JSONSerialization.data(withJSONObject: values)))
        values["identity"] = ["fileID": 12, "birthMicroseconds": 34]
        values["size"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(EditFileVersion.self, from: JSONSerialization.data(withJSONObject: values)))
        values["size"] = 0
        values["digest"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(EditFileVersion.self, from: JSONSerialization.data(withJSONObject: values)))
    }

    func testCorruptedPendingBytesAreRetainedAndRefuseValidation() throws {
        let record = try prepare()
        let path = outbox.contentURL(record)
        try FileManager.default.removeItem(at: path)
        try Data("corrupt".utf8).write(to: path)
        XCTAssertThrowsError(try outbox.validateContents(record))
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try Data(contentsOf: path), Data("corrupt".utf8))
    }

    func testArtifactQuarantineReceiptIsBoundedAndDistinctFromMainContents() throws {
        let base = try version(for: prepare())
        let artifact = try EditFileVersion(identity: base.identity, size: base.size, digest: base.digest,
            modifiedMicroseconds: base.modifiedMicroseconds, changedMicroseconds: base.changedMicroseconds,
            attributes: base.attributes, security: base.security, artifactQuarantine: Data("retained".utf8))
        XCTAssertTrue(base.hasSameContents(as: artifact))
        XCTAssertNotEqual(base, artifact)
        XCTAssertEqual(try JSONDecoder().decode(EditFileVersion.self, from: JSONEncoder().encode(artifact)), artifact)
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        values["artifactQuarantine"] = Data(repeating: 0, count: 65_537).base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(EditFileVersion.self,
            from: JSONSerialization.data(withJSONObject: values)))
    }

    func testLocationRemovalTakesOnlySavesThatNeverReachedTheServer() throws {
        let record = try prepare()
        XCTAssertTrue(EditOutbox.canStopForRemoval(record))
        var staged = record
        staged.state = .creatingStage
        XCTAssertFalse(EditOutbox.canStopForRemoval(staged))
        let orphan = directory.appending(path: "Edits/Contents/\(UUID().uuidString).data")
        try Data("retained".utf8).write(to: orphan)
        XCTAssertThrowsError(try outbox.removeForLocationRemoval())
        try FileManager.default.removeItem(at: orphan)
        try outbox.removeForLocationRemoval()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Edits").path))
    }

    func testStopExportsAVerifiedCopyBeforeItEndsTheSave() throws {
        let record = try prepare()
        XCTAssertTrue(EditOutbox.canStop(record, among: try outbox.records()))
        let copy = directory.appending(path: "copy.txt")
        try outbox.stop(record.id, exportingTo: copy)
        XCTAssertEqual(try Data(contentsOf: copy), Data("pending document".utf8))
        XCTAssertEqual(try stored(record).state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.contentURL(record).path))
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try outbox.contentBytes, 0)
        XCTAssertNil(try outbox.order(item: item).head)
        try outbox.removeForLocationRemoval()
    }

    func testStoppedSaveSentAgainIsAnsweredOnceAndLaterSavesUpload() throws {
        let record = try prepare()
        try outbox.stop(record.id, exportingTo: directory.appending(path: "copy.txt"))
        XCTAssertTrue(try outbox.takeStopped(item: item, contents: input))
        XCTAssertEqual(try outbox.records(), [])
        XCTAssertFalse(try outbox.takeStopped(item: item, contents: input))
        let again = try prepare()
        XCTAssertNotEqual(again.id, record.id)
        XCTAssertEqual(try outbox.order(item: item).head?.id, again.id)
    }

    func testNewerContentsEndTheStopAndUploadNormally() throws {
        let record = try prepare()
        try outbox.stop(record.id, exportingTo: directory.appending(path: "copy.txt"))
        try Data("newer document".utf8).write(to: input)
        XCTAssertFalse(try outbox.takeStopped(item: item, contents: input))
        XCTAssertEqual(try outbox.records(), [])
        let newer = try prepare()
        XCTAssertEqual(try outbox.order(item: item).head?.id, newer.id)
    }

    func testStopIsRefusedOnceTheServerCanHaveTheSave() throws {
        var record = try prepare()
        for state: PendingEdit.State in [.creatingStage, .staged, .creatingBackup, .movingOriginal, .published] {
            record.state = state
            try outbox.save(record)
            XCTAssertTrue(try stored(record).requiresNamespaceSettlement)
            XCTAssertFalse(EditOutbox.canStop(record, among: try outbox.records()))
            let copy = directory.appending(path: state.rawValue + ".txt")
            XCTAssertThrowsError(try outbox.stop(record.id, exportingTo: copy))
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        }
        try outbox.validateContents(record)
    }

    func testStopIsRefusedWhileAnotherSaveOfTheFileNeedsWork() throws {
        var older = try prepare("older document")
        older.state = .creatingStage
        try outbox.save(older)
        let newer = try prepare("newer document")
        try outbox.retainSuperseded(&older)
        XCTAssertFalse(EditOutbox.canStop(try stored(newer), among: try outbox.records()))
        XCTAssertThrowsError(try outbox.stop(newer.id, exportingTo: directory.appending(path: "copy.txt")))
        XCTAssertEqual(try stored(newer).state, .prepared)
    }

    func testFailedExportLeavesTheSaveWaiting() throws {
        let record = try prepare()
        let copy = directory.appending(path: "copy.txt")
        try Data("existing file".utf8).write(to: copy)
        XCTAssertThrowsError(try outbox.stop(record.id, exportingTo: copy))
        XCTAssertEqual(try Data(contentsOf: copy), Data("existing file".utf8))
        XCTAssertEqual(try stored(record).state, .prepared)
        try outbox.validateContents(record)
    }

    func testOrphanPayloadBlocksRemoval() throws {
        let orphan = directory.appending(path: "Edits/Contents/\(UUID().uuidString).data")
        try Data("retained".utf8).write(to: orphan)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try outbox.contentBytes, Int64("retained".utf8.count))
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDismissedConflictNoticeKeepsItsReceiptAndCompletedReplay() throws {
        var conflict = try prepare()
        conflict.conflict = true
        conflict.destination = "document conflict.txt"
        conflict.stageIdentity = try version(for: conflict).identity
        conflict.published = try EditBaseReceipt(item: conflict.id.uuidString, version: version(for: conflict))
        conflict.state = .published
        try outbox.complete(&conflict, item: conflict.id.uuidString)
        let receipt = try XCTUnwrap(conflict.published)
        try outbox.dismissConflictNotice(id: conflict.id)
        var expected = conflict
        expected.conflictNoticeDismissed = true
        XCTAssertEqual(try stored(conflict), expected)
        XCTAssertEqual(try outbox.base(item: receipt.item, contentVersion: receipt.contentVersion), receipt)
        XCTAssertEqual(try prepare(), expected)
        XCTAssertEqual(try outbox.pendingCount, 0)
        try outbox.dismissConflictNotice(id: conflict.id)
        XCTAssertEqual(try stored(conflict), expected)
    }

    func testConflictNoticeCannotBeDismissedForPendingOrRetainedWork() throws {
        var conflict = try prepare()
        conflict.conflict = true
        conflict.stageIdentity = try version(for: conflict).identity
        try outbox.save(conflict)
        XCTAssertThrowsError(try outbox.dismissConflictNotice(id: conflict.id))
        XCTAssertEqual(try stored(conflict), conflict)
        conflict.state = .published
        conflict.published = try EditBaseReceipt(item: conflict.id.uuidString, version: version(for: conflict))
        conflict.recoveryRetained = true
        try outbox.complete(&conflict, item: conflict.id.uuidString)
        XCTAssertThrowsError(try outbox.dismissConflictNotice(id: conflict.id))
        XCTAssertEqual(try stored(conflict), conflict)
        try outbox.validateContents(conflict)
        var ordinary = try prepare("ordinary completed save")
        try completeAsPublished(&ordinary)
        XCTAssertThrowsError(try outbox.dismissConflictNotice(id: ordinary.id))
        XCTAssertEqual(try stored(ordinary), ordinary)
        XCTAssertThrowsError(try outbox.dismissConflictNotice(id: UUID()))
    }

    func testConflictPolicyDoesNotReuseDifferentCallbackOutcome() throws {
        let first = try prepare(failOnConflict: false)
        let second = try prepare(failOnConflict: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try outbox.pendingCount, 2)
    }

    func testMetadataChangesGetSeparateRetainedGeneration() throws {
        let first = try prepare()
        let attribute = Data("retained metadata".utf8)
        let result = attribute.withUnsafeBytes { setxattr(input.path, "dev.tinymounter.test", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(result, 0)
        let second = try prepare()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertNotEqual(first.localMetadataDigest, second.localMetadataDigest)
        try FileManager.default.removeItem(at: input)
        try outbox.validateContents(first)
        try outbox.validateContents(second)
        XCTAssertEqual(getxattr(outbox.contentURL(second).path, "dev.tinymounter.test", nil, 0, 0, 0), attribute.count)
    }

    func testSystemAssignedSecurityMetadataDoesNotDuplicateACompletedSave() throws {
        var first = try prepare()
        first.state = .published
        first.previous = try version(for: first)
        first.published = try EditBaseReceipt(item: item, version: version(for: first))
        try outbox.complete(&first, item: item)
        let value = Data("0081;12345678;Test;".utf8)
        XCTAssertEqual(value.withUnsafeBytes {
            setxattr(input.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let replay = try prepare()
        XCTAssertEqual(replay.id, first.id)
        XCTAssertEqual(replay.state, .completed)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testInterruptedBeforeMetadataSnapshotCanReplaySystemAssignedAttributes() throws {
        var first = try prepare()
        first.state = .preparing
        try outbox.save(first)
        let edits = directory.appending(path: "Edits")
        for suffix in [first.id.uuidString + ".metadata", "Contents/\(first.id.uuidString).data",
                       "Contents/\(first.id.uuidString).json"] {
            try FileManager.default.removeItem(at: edits.appending(path: suffix))
        }
        let value = Data("0081;12345678;Test;".utf8)
        XCTAssertEqual(value.withUnsafeBytes {
            setxattr(input.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let replay = try prepare()
        XCTAssertEqual(replay.id, first.id)
        XCTAssertEqual(replay.state, .prepared)
        XCTAssertNotEqual(replay.localMetadataDigest, first.localMetadataDigest)
        try outbox.validateContents(replay)
    }

    func testInterruptedLocalStagingRemainsVisibleAndMatchingReplayFinishesIt() throws {
        XCTAssertThrowsError(try outbox.prepare(item: item, parent: Catalog.rootItemID,
            path: XCTUnwrap(RelativePath("document.txt")), baseVersion: "legacy", failOnConflict: false,
            contents: input, progress: Progress(), checkSpace: { if $0 > 0 { throw CocoaError(.fileWriteOutOfSpace) } }))
        let interrupted = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(interrupted.state, .preparing)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        let recovered = try prepare()
        XCTAssertEqual(recovered.id, interrupted.id)
        XCTAssertEqual(recovered.state, .prepared)
        try outbox.validateContents(recovered)
    }

    func testLaterCompletedGenerationSupersedesEarlierLocalCopy() throws {
        let earlier = try prepare(base: "old", failOnConflict: true)
        var completed = try prepare(base: "new")
        completed.state = .published
        completed.previous = try version(for: completed)
        completed.published = try EditBaseReceipt(item: item, version: version(for: completed))
        try outbox.complete(&completed, item: item)
        let order = try outbox.order(item: item)
        XCTAssertNil(order.head)
        XCTAssertEqual(order.superseded.map(\.id), [earlier.id])
        try outbox.discard(earlier)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(files(of: earlier), [])
        XCTAssertEqual(try outbox.records().map(\.id), [completed.id])
    }

    func testSeveralSavesAgainstOneBaseKeepArrivalOrderAndOnlyTheLatest() throws {
        let first = try prepare("first save")
        let second = try prepare("second save")
        let third = try prepare("third save")
        let sequences = [first, second, third].map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, 3)
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, third.id)
        XCTAssertEqual(order.superseded.map(\.id), [first.id, second.id])
        XCTAssertEqual(order.predecessors, [])
        XCTAssertThrowsError(try outbox.discard(third))
        for record in order.superseded { try outbox.discard(record) }
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(files(of: first), [])
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(third)), Data("third save".utf8))
        try outbox.validateContents(third)
    }

    func testDuplicateCallbacksReuseTheLatestGeneration() throws {
        let first = try prepare("same contents")
        let replay = try prepare("same contents")
        XCTAssertEqual(replay.id, first.id)
        XCTAssertEqual(replay.sequence, first.sequence)
        let second = try prepare("changed contents")
        XCTAssertEqual(try prepare("changed contents").id, second.id)
        XCTAssertEqual(try outbox.records().count, 2)
        XCTAssertEqual(try outbox.order(item: item).head?.id, second.id)
    }

    func testReturnToEarlierContentsIsTheNewestSave() throws {
        let original = try prepare("version A")
        let intermediate = try prepare("version B")
        let reverted = try prepare("version A")
        XCTAssertNotEqual(reverted.id, original.id)
        XCTAssertGreaterThan(reverted.sequence, intermediate.sequence)
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, reverted.id)
        XCTAssertEqual(Set(order.superseded.map(\.id)), [original.id, intermediate.id])
        XCTAssertEqual(try prepare("version A").id, reverted.id)
        for record in order.superseded { try outbox.discard(record) }
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(reverted)), Data("version A".utf8))
        let again = try prepare("version B")
        XCTAssertNotEqual(again.id, intermediate.id)
        XCTAssertEqual(try outbox.order(item: item).head?.id, again.id)
    }

    func testInterruptedNewerSaveIsRemovedWithoutChangingEarlierCompleteGeneration() throws {
        let earlier = try prepare("complete earlier save")
        var newer = try prepare("newer save")
        newer.state = .preparing
        try outbox.save(newer)
        for suffix in ["Contents/\(newer.id.uuidString).data", "Contents/\(newer.id.uuidString).json"] {
            try FileManager.default.removeItem(at: directory.appending(path: "Edits/" + suffix))
        }
        var order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, earlier.id)
        XCTAssertEqual(order.superseded, [])
        XCTAssertEqual(files(of: newer), [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.discard(earlier))
        let resumed = try prepare("newer save")
        XCTAssertNotEqual(resumed.id, newer.id)
        XCTAssertGreaterThan(resumed.sequence, earlier.sequence)
        XCTAssertEqual(resumed.state, .prepared)
        order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, resumed.id)
        XCTAssertEqual(order.superseded.map(\.id), [earlier.id])
    }

    func testCompleteNewerPayloadSurvivesItsFinalStateUpdateBeingLost() throws {
        let earlier = try prepare("complete earlier save")
        var staged = try prepare("payload staged before crash")
        staged.state = .preparing
        try outbox.save(staged)
        outbox = try EditOutbox(directory: directory.appending(path: "Edits"))
        XCTAssertEqual(try outbox.order(item: item).head?.id, staged.id)
        XCTAssertEqual(try stored(staged).state, .prepared)
        try outbox.validateContents(staged)
        try outbox.validateContents(earlier)
        let latest = try prepare("latest save")
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, latest.id)
        XCTAssertEqual(order.superseded.map(\.id), [earlier.id, staged.id])
        for record in order.superseded { try outbox.discard(record) }
        XCTAssertEqual(files(of: staged), [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(latest)
    }

    func testLowSpaceKeepsPreviousSaveAndItsMetadataExportable() throws {
        try Data("previous save".utf8).write(to: input)
        setAttribute("previous metadata")
        let previous = try outbox.prepare(item: item, parent: Catalog.rootItemID,
                                          path: XCTUnwrap(RelativePath("document.txt")), baseVersion: "legacy",
                                          failOnConflict: false, contents: input, progress: Progress())
        XCTAssertThrowsError(try prepare(String(repeating: "x", count: 2 * 1024 * 1024),
                                          checkSpace: { if $0 > 0 { throw CocoaError(.fileWriteOutOfSpace) } }))
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, previous.id)
        XCTAssertEqual(order.superseded, [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(previous)
        let exported = directory.appending(path: "exported.txt")
        try outbox.export(previous, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("previous save".utf8))
        XCTAssertEqual(getxattr(exported.path, "dev.tinymounter.test", nil, 0, 0, 0), "previous metadata".utf8.count)
    }

    func testCapacityLostWhileQueuedRefusesNewPreparationAndPreservesPreviousSave() throws {
        let earlier = try prepare("earlier complete save")
        let newer = String(repeating: "n", count: 4096)
        let required = DownloadSpace.reserveBytes + Int64(newer.utf8.count) * 2 + 65536
        let capacity = Capacity(required - 1)
        let space = DownloadSpace { capacity.read() }, id = UUID()
        XCTAssertThrowsError(try space.begin(id, bytes: Int64(newer.utf8.count))) {
            XCTAssertTrue(DownloadSpace.isFull($0))
        }
        XCTAssertEqual(try outbox.records(), [earlier])
        capacity.set(required)
        try space.begin(id, bytes: Int64(newer.utf8.count))
        defer { space.end(id) }
        capacity.set(required - 1)
        XCTAssertThrowsError(try prepare(newer) { try space.check(id, completedBytes: $0) }) {
            XCTAssertTrue(DownloadSpace.isFull($0))
        }
        XCTAssertEqual(try outbox.records(), [earlier])
        XCTAssertEqual(try Data(contentsOf: input), Data(newer.utf8))
        let exported = directory.appending(path: "earlier.txt")
        try outbox.export(earlier, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("earlier complete save".utf8))
        capacity.set(required)
        let latest = try prepare(newer) { completed in
            capacity.set(required - completed)
            try space.check(id, completedBytes: completed)
        }
        XCTAssertEqual(try outbox.order(item: item).head?.id, latest.id)
        try outbox.validateContents(latest)
        try outbox.validateContents(earlier)
    }

    func testFinalSmallCopySpaceFailureRetainsAndRecoversTheCompleteNewerSave() throws {
        let earlier = try prepare("earlier complete save")
        let newer = String(repeating: "n", count: 4096)
        let required = DownloadSpace.reserveBytes + Int64(newer.utf8.count) * 2 + 65536
        let capacity = Capacity(required)
        let space = DownloadSpace { capacity.read() }, id = UUID()
        try space.begin(id, bytes: Int64(newer.utf8.count))
        defer { space.end(id) }
        XCTAssertThrowsError(try prepare(newer) { completed in
            if completed > 0 { capacity.set(DownloadSpace.reserveBytes - 1) }
            try space.check(id, completedBytes: completed)
        }) {
            XCTAssertTrue(DownloadSpace.isFull($0))
        }
        let interrupted = try XCTUnwrap(outbox.records().last)
        XCTAssertEqual(interrupted.state, .preparing)
        XCTAssertNotEqual(interrupted.id, earlier.id)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(interrupted)), Data(newer.utf8))
        XCTAssertThrowsError(try prepare(newer) { try space.check(id, completedBytes: $0) })
        try outbox.validateContents(earlier)
        outbox = try EditOutbox(directory: directory.appending(path: "Edits"))
        XCTAssertEqual(try outbox.order(item: item).head?.id, interrupted.id)
        XCTAssertEqual(try stored(interrupted).state, .prepared)
        let exported = directory.appending(path: "latest.txt")
        try outbox.export(interrupted, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data(newer.utf8))
        try outbox.validateContents(earlier)
    }

    func testInterruptedPreparationCleanupFinishesAfterPayloadRemoval() throws {
        let previous = try prepare("previous save")
        XCTAssertThrowsError(try prepare(String(repeating: "x", count: 2 * 1024 * 1024),
                                          checkSpace: { if $0 > 0 { throw CocoaError(.fileWriteOutOfSpace) } }))
        let interrupted = try XCTUnwrap(outbox.records().last)
        let payloads = try UploadOutbox(directory: directory.appending(path: "Edits/Contents"))
        try payloads.discardUnpublishedPayload(interrupted.id)
        outbox = try EditOutbox(directory: directory.appending(path: "Edits"))
        XCTAssertEqual(try outbox.order(item: item).head?.id, previous.id)
        XCTAssertEqual(try outbox.order(item: item).head?.id, previous.id)
        XCTAssertEqual(files(of: interrupted), [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.validateContents(previous)
    }

    func testCompletePreparationWithUncertainMetadataRemainsRetained() throws {
        setAttribute("saved metadata")
        var record = try prepare("complete save")
        record.state = .preparing
        try outbox.save(record)
        try Data("{}".utf8).write(to: directory.appending(path: "Edits/\(record.id.uuidString).metadata"))
        XCTAssertThrowsError(try outbox.order(item: item))
        XCTAssertEqual(try stored(record).state, .preparing)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(record)), Data("complete save".utf8))
        XCTAssertEqual(files(of: record).count, 4)
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testConsolidationKeepsLatestDocumentMetadataForExport() throws {
        try Data("first save".utf8).write(to: input)
        setAttribute("first metadata")
        let first = try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("document.txt")),
                                       baseVersion: "legacy", failOnConflict: false, contents: input, progress: Progress())
        try Data("latest save".utf8).write(to: input)
        setAttribute("latest metadata")
        let latest = try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("document.txt")),
                                        baseVersion: "legacy", failOnConflict: false, contents: input, progress: Progress())
        try outbox.discard(first)
        XCTAssertEqual(files(of: first), [])
        try FileManager.default.removeItem(at: input)
        let exported = directory.appending(path: "exported.txt")
        try outbox.export(latest, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("latest save".utf8))
        var value = [UInt8](repeating: 0, count: 64)
        let count = getxattr(exported.path, "dev.tinymounter.test", &value, value.count, 0, 0)
        XCTAssertEqual(String(decoding: value.prefix(max(0, count)), as: UTF8.self), "latest metadata")
    }

    func testUncertainStageCreationIsRetainedWhenSuperseded() throws {
        var uncertain = try prepare("stage request may have reached the server")
        uncertain.state = .creatingStage
        try outbox.save(uncertain)
        let latest = try prepare("latest save")
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, latest.id)
        XCTAssertEqual(order.superseded.map(\.id), [uncertain.id])
        XCTAssertThrowsError(try outbox.discard(uncertain))
        try outbox.validateContents(uncertain)
        let exported = directory.appending(path: "exported.txt")
        try outbox.export(uncertain, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("stage request may have reached the server".utf8))
        XCTAssertEqual(try outbox.pendingCount, 2)
    }

    func testEarlierStartedPublicationResolvesBeforeNewerContents() throws {
        var started = try prepare("publication started")
        started.state = .copying
        try outbox.save(started)
        let latest = try prepare("newer local contents")
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, latest.id)
        XCTAssertEqual(order.predecessors.map(\.id), [started.id])
        XCTAssertEqual(order.superseded, [])
        XCTAssertThrowsError(try outbox.discard(started))
    }

    func testRetirementRequiresDurableCompleteSuccessor() throws {
        var old = try prepare("older save")
        old.state = .creatingStage
        try outbox.save(old)
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        XCTAssertThrowsError(try prepare(String(repeating: "x", count: 2 * 1024 * 1024),
                                          checkSpace: { if $0 > 0 { throw CocoaError(.fileWriteOutOfSpace) } }))
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        let latest = try prepare("latest save")
        let payload = outbox.contentURL(latest)
        XCTAssertEqual(chmod(payload.path, 0o600), 0)
        try Data("damaged".utf8).write(to: payload)
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        XCTAssertEqual(try stored(old).state, .creatingStage)
        XCTAssertTrue(try stored(old).requiresNamespaceSettlement)
        try outbox.validateContents(old)
    }

    func testRetiredCleanupProgressCannotRegressOrReactivatePublication() throws {
        var old = try prepare("older save")
        old.state = .staged
        old.stageVersion = try version(for: old)
        old.stageIdentity = old.stageVersion?.identity
        try outbox.save(old)
        _ = try prepare("latest save")
        try outbox.retainSuperseded(&old)
        var changed = old
        changed.stageVersion = try EditFileVersion(identity: XCTUnwrap(old.stageIdentity), size: old.size,
            digest: old.digest, modifiedMicroseconds: 99, changedMicroseconds: 78,
            attributes: 32, security: Data([1, 2, 3]))
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        changed = old
        changed.retiredCleanupStarted = true
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        changed = old
        changed.retiredBackupRemoved = true
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        old.retiredStageRemoved = true
        try outbox.saveRetiredProgress(old)
        changed = old
        changed.retiredStageRemoved = false
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        changed = old
        changed.state = .prepared
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        XCTAssertThrowsError(try outbox.save(changed))
        changed = old
        changed.published = try EditBaseReceipt(item: item, version: version(for: old))
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        changed.state = .published
        changed.previous = changed.published?.version
        XCTAssertThrowsError(try outbox.complete(&changed, item: item))
        old.retiredCleanupStarted = true
        try outbox.saveRetiredProgress(old)
        changed = old
        changed.retiredCleanupStarted = false
        XCTAssertThrowsError(try outbox.saveRetiredProgress(changed))
        XCTAssertEqual(try stored(old), old)
        XCTAssertEqual(try outbox.pendingCount, 2)
        try outbox.validateContents(old)
    }

    func testDuplicateSequencesBlockTheFileWhileANewSaveStaysDurable() throws {
        let first = try prepare("first save")
        var second = try prepare("second save")
        second.sequence = first.sequence
        try outbox.save(second)
        XCTAssertThrowsError(try outbox.order(item: item))
        let third = try prepare("second save")
        XCTAssertNotEqual(third.id, second.id)
        XCTAssertGreaterThan(third.sequence, first.sequence)
        try outbox.validateContents(third)
        XCTAssertThrowsError(try outbox.order(item: item))
        XCTAssertThrowsError(try outbox.discard(first))
        XCTAssertEqual(try outbox.pendingCount, 3)
    }

    func testSequenceOverflowAndZeroSequenceFailWithoutWriting() throws {
        var first = try prepare("first save")
        first.sequence = UInt64.max
        try outbox.save(first)
        XCTAssertThrowsError(try prepare("second save"))
        XCTAssertEqual(try outbox.records().map(\.id), [first.id])
        XCTAssertEqual(try outbox.pendingCount, 1)
        first.sequence = 0
        try outbox.save(first)
        XCTAssertThrowsError(try outbox.records())
    }

    func testDiscardKeepsTheEarlierSaveWhenTheNewerCopyIsDamaged() throws {
        let earlier = try prepare("earlier save")
        let latest = try prepare("latest save")
        let content = outbox.contentURL(latest)
        XCTAssertEqual(chmod(content.path, 0o600), 0)
        try Data("damaged".utf8).write(to: content)
        XCTAssertThrowsError(try outbox.discard(earlier))
        XCTAssertEqual(files(of: earlier).count, 4)
        try outbox.validateContents(earlier)
    }

    func testDiscardKeepsTheNewestCompleteSaveAndRecoversAnIncompletePreparation() throws {
        let first = try prepare("first save")
        let second = try prepare("second save")
        XCTAssertThrowsError(try prepare(String(repeating: "x", count: 2 * 1024 * 1024),
                                          checkSpace: { if $0 > 0 { throw CocoaError(.fileWriteOutOfSpace) } }))
        let interrupted = try XCTUnwrap(outbox.records().last)
        XCTAssertEqual(interrupted.state, .preparing)
        XCTAssertThrowsError(try outbox.discard(second))
        XCTAssertThrowsError(try outbox.discard(interrupted))
        XCTAssertEqual(files(of: interrupted), [])
        try outbox.discard(first)
        let third = try prepare("third save")
        XCTAssertGreaterThan(third.sequence, second.sequence)
        XCTAssertEqual(try outbox.order(item: item).superseded.map(\.id), [second.id])
    }

    func testOwnPublicationsCountOnlyProvenEarlierSavesOnTheSameBase() throws {
        var published = try prepare("published save", base: "base")
        try completeAsPublished(&published)
        let otherBase = try prepare("different base", base: "other")
        let successor = try prepare("successor", base: "base")
        var later = try prepare("later save", base: "base")
        try completeAsPublished(&later)
        let accepted = try XCTUnwrap(published.published?.version)
        XCTAssertEqual(try outbox.ownPublications(before: published), [])
        XCTAssertEqual(try outbox.ownPublications(before: otherBase), [])
        XCTAssertEqual(try outbox.ownPublications(before: successor), [accepted])
    }

    func testRetainedMetadataRemainsVerifiableWhenSystemChangesPayloadAttributes() throws {
        let value = Data("original metadata".utf8)
        XCTAssertEqual(value.withUnsafeBytes {
            setxattr(input.path, "dev.tinymounter.test", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let record = try prepare()
        let content = outbox.contentURL(record)
        XCTAssertEqual(chmod(content.path, 0o600), 0)
        XCTAssertEqual(removexattr(content.path, "dev.tinymounter.test", 0), 0)
        try outbox.validateContents(record)
        let metadata = directory.appending(path: "Edits/\(record.id.uuidString).metadata")
        let retained = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: metadata))
        XCTAssertEqual(retained["dev.tinymounter.test"], value)
        let destination = directory.appending(path: "exported.txt")
        try outbox.export(record, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: input))
        XCTAssertEqual(getxattr(destination.path, "dev.tinymounter.test", nil, 0, 0, 0), value.count)
        try Data("{}".utf8).write(to: metadata)
        XCTAssertThrowsError(try outbox.validateContents(record))
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testCallbackAttributesSurvivePendingSaveRestartAndExport() throws {
        setAttribute("content snapshot attribute")
        let attributes = ["com.apple.TextEncoding": Data("UTF-8;134217984".utf8),
                          "dev.tinymounter.sync#S": Data("callback attribute".utf8)]
        try Staging.retainExtendedAttributes(attributes, at: input)
        let record = try prepare()
        try FileManager.default.removeItem(at: input)
        let reopened = try EditOutbox(directory: directory.appending(path: "Edits"))
        let destination = directory.appending(path: "exported.txt")
        try reopened.export(record, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("pending document".utf8))
        for (name, expected) in attributes.merging(["dev.tinymounter.test":
            Data("content snapshot attribute".utf8)], uniquingKeysWith: { _, new in new }) {
            var actual = Data(count: expected.count)
            XCTAssertEqual(actual.withUnsafeMutableBytes {
                getxattr(destination.path, name, $0.baseAddress, $0.count, 0, 0)
            }, expected.count)
            XCTAssertEqual(actual, expected)
        }
    }

    func testCallbackAttributesRejectAliasedFilesAndInvalidNames() throws {
        let alias = directory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let attributes = ["dev.tinymounter.sync#S": Data("callback attribute".utf8)]
        XCTAssertThrowsError(try Staging.retainExtendedAttributes(attributes, at: alias))
        XCTAssertThrowsError(try Staging.retainExtendedAttributes(["invalid\0name": Data()], at: input))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: input, to: alias)
        XCTAssertThrowsError(try Staging.retainExtendedAttributes(attributes, at: input))
        XCTAssertEqual(getxattr(input.path, "dev.tinymounter.sync#S", nil, 0, 0, 0), -1)
    }
}
