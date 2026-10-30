import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class EditOutboxTests: XCTestCase {
    private var directory: URL!
    private var input: URL!
    private var outbox: EditOutbox!
    private let item = UUID().uuidString

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

    private func unordered(_ record: PendingEdit) throws -> PendingEdit {
        var record = record
        record.sequence = nil
        try outbox.save(record)
        return record
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

    /// Mirrors the M19 and M20 listing: every .edit file must decode as a record named by its ID.
    private func olderBuildRecords() throws -> [PendingEdit] {
        try FileManager.default.contentsOfDirectory(at: directory.appending(path: "Edits"),
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "edit" }.map { url in
                let record = try JSONDecoder().decode(PendingEdit.self, from: Data(contentsOf: url))
                guard record.id.uuidString == url.deletingPathExtension().lastPathComponent else {
                    throw UploadError.invalidRequest
                }
                return record
            }
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
        XCTAssertEqual(try outbox.pendingCount, 0)
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

    func testOrphanPayloadBlocksRemoval() throws {
        let orphan = directory.appending(path: "Edits/Contents/\(UUID().uuidString).data")
        try Data("retained".utf8).write(to: orphan)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
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

    func testOlderPendingRecordWithoutDocumentMetadataDigestStillReplays() throws {
        var first = try prepare()
        first.documentMetadataDigest = nil
        try outbox.save(first)
        let value = Data("0081;12345678;Test;".utf8)
        XCTAssertEqual(value.withUnsafeBytes {
            setxattr(input.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        XCTAssertEqual(try prepare().id, first.id)
        try outbox.validateContents(first)
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
            contents: input, progress: Progress(), checkSpace: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
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
        let sequences = try [first, second, third].map { try XCTUnwrap($0.sequence) }
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
        XCTAssertGreaterThan(try XCTUnwrap(reverted.sequence), try XCTUnwrap(intermediate.sequence))
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

    func testInterruptedNewerSaveKeepsEarlierCompleteGenerationAsHead() throws {
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
        XCTAssertThrowsError(try outbox.discard(earlier))
        let resumed = try prepare("newer save")
        XCTAssertEqual(resumed.id, newer.id)
        XCTAssertEqual(resumed.sequence, newer.sequence)
        XCTAssertEqual(resumed.state, .prepared)
        order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, newer.id)
        XCTAssertEqual(order.superseded.map(\.id), [earlier.id])
    }

    func testCompleteNewerPayloadWithoutDurableRecordIsConsolidatedOnlyByALaterSave() throws {
        let earlier = try prepare("complete earlier save")
        var staged = try prepare("payload staged before crash")
        staged.state = .preparing
        try outbox.save(staged)
        XCTAssertEqual(try outbox.order(item: item).head?.id, earlier.id)
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
        XCTAssertThrowsError(try prepare("newer save", checkSpace: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, previous.id)
        XCTAssertEqual(order.superseded, [])
        XCTAssertEqual(try outbox.pendingCount, 2)
        try outbox.validateContents(previous)
        let exported = directory.appending(path: "exported.txt")
        try outbox.export(previous, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("previous save".utf8))
        XCTAssertEqual(getxattr(exported.path, "dev.tinymounter.test", nil, 0, 0, 0), "previous metadata".utf8.count)
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

    func testRetiredLegacySaveKeepsDowngradeGuardAndExportAfterSuccessorCompletes() throws {
        var old = try unordered(prepare("older build save"))
        old.state = .creatingStage
        try outbox.save(old)
        var latest = try prepare("latest save")
        try outbox.retainSuperseded(&old)
        try completeAsPublished(&latest)
        try outbox.releaseOrderingGuardIfSettled()
        XCTAssertThrowsError(try olderBuildRecords())
        outbox = try EditOutbox(directory: directory.appending(path: "Edits"))
        XCTAssertNil(try outbox.order(item: item).head)
        XCTAssertEqual(try outbox.order(item: item).unordered, [])
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertEqual(try prepare("latest save").id, latest.id)
        let newSave = try prepare("older build save")
        XCTAssertNotEqual(newSave.id, old.id)
        XCTAssertEqual(try outbox.order(item: item).head?.id, newSave.id)
        try FileManager.default.removeItem(at: directory.appending(path: "Edits/" + EditOutbox.orderingGuardName))
        XCTAssertThrowsError(try outbox.order(item: item))
        let exported = directory.appending(path: "retained.txt")
        try outbox.export(old, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("older build save".utf8))
    }

    func testRetirementRequiresDurableCompleteSuccessorAndOrderingEvidence() throws {
        var old = try prepare("older save")
        old.state = .creatingStage
        try outbox.save(old)
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        XCTAssertThrowsError(try prepare("failed save", checkSpace: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        let latest = try prepare("latest save")
        let payload = outbox.contentURL(latest)
        XCTAssertEqual(chmod(payload.path, 0o600), 0)
        try Data("damaged".utf8).write(to: payload)
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        XCTAssertEqual(try stored(old).state, .creatingStage)
        _ = try prepare("another complete save")
        try FileManager.default.removeItem(at: directory.appending(path: "Edits/" + EditOutbox.orderingGuardName))
        XCTAssertThrowsError(try outbox.retainSuperseded(&old))
        XCTAssertEqual(try stored(old).state, .creatingStage)
        try outbox.validateContents(old)
    }

    func testUnorderedRecordsFromAnOlderBuildStayBlockedAndExportable() throws {
        let first = try unordered(prepare("older build first"))
        let second = try unordered(prepare("older build second"))
        let stored = try Data(contentsOf: directory.appending(path: "Edits/\(first.id.uuidString).edit"))
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])["sequence"])
        XCTAssertEqual(try outbox.records().map(\.sequence), [nil, nil])
        var order = try outbox.order(item: item)
        XCTAssertNil(order.head)
        XCTAssertEqual(Set(order.unordered.map(\.id)), [first.id, second.id])
        XCTAssertEqual(order.superseded, [])
        for record in [first, second] {
            let exported = directory.appending(path: record.id.uuidString)
            try outbox.export(record, to: exported)
            XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: outbox.contentURL(record)))
        }
        let latest = try prepare("first save after upgrade")
        order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, latest.id)
        XCTAssertEqual(Set(order.superseded.map(\.id)), [first.id, second.id])
        XCTAssertEqual(order.unordered, [])
    }

    func testSoleUnorderedRecordStaysHeadButAMatchingCallbackIsANewGeneration() throws {
        let older = try unordered(prepare("older build save"))
        XCTAssertEqual(try outbox.order(item: item).head?.id, older.id)
        let callback = try prepare("older build save")
        XCTAssertNotEqual(callback.id, older.id)
        XCTAssertNotNil(callback.sequence)
        XCTAssertNil(try stored(older).sequence)
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, callback.id)
        XCTAssertEqual(order.superseded.map(\.id), [older.id])
    }

    func testReplayOfOneUnorderedSaveDoesNotPlaceItAmongTheOthers() throws {
        let first = try unordered(prepare("older build first"))
        let second = try unordered(prepare("older build second"))
        let callback = try prepare("older build first")
        XCTAssertFalse([first.id, second.id].contains(callback.id))
        XCTAssertNil(try stored(first).sequence)
        XCTAssertNil(try stored(second).sequence)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(callback)), Data("older build first".utf8))
        let order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, callback.id)
        XCTAssertEqual(Set(order.superseded.map(\.id)), [first.id, second.id])
    }

    func testUnfinishedUnorderedSaveBesideACompletedOrderedSaveIsNewer() throws {
        var ordered = try prepare("ordered save")
        try completeAsPublished(&ordered)
        // An older build wrote this once the ordering guard was released.
        let later = try unordered(prepare("older build save after downgrade"))
        var order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, later.id)
        XCTAssertEqual(order.superseded, [])
        XCTAssertThrowsError(try outbox.discard(later))
        let callback = try prepare("ordered save")
        XCTAssertNotEqual(callback.id, ordered.id)
        order = try outbox.order(item: item)
        XCTAssertEqual(order.head?.id, callback.id)
        XCTAssertEqual(order.superseded.map(\.id), [later.id])
    }

    func testEquivalentUnorderedSavesNeedNoOrderAndResolveWithoutPublishing() throws {
        let first = try unordered(prepare(failOnConflict: false))
        let second = try unordered(prepare(failOnConflict: true))
        let order = try outbox.order(item: item)
        let head = try XCTUnwrap(order.head)
        XCTAssertEqual(order.unordered, [])
        XCTAssertTrue([first.id, second.id].contains(head.id))
        var completed = try stored(head)
        try completeAsPublished(&completed)
        var other = try stored(head.id == first.id ? second : first)
        try outbox.resolveEquivalent(&other, with: completed)
        XCTAssertEqual(other.state, .completed)
        XCTAssertEqual(other.published, completed.published)
        XCTAssertEqual(try outbox.pendingCount, 0)
        var ordered = try prepare(base: "other")
        XCTAssertThrowsError(try outbox.resolveEquivalent(&ordered, with: completed))
    }

    func testOlderBuildCannotReadTheOutboxWhileAnOrderedSaveIsUnfinished() throws {
        XCTAssertEqual(try olderBuildRecords(), [])
        XCTAssertThrowsError(try prepare("interrupted save", checkSpace: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertThrowsError(try olderBuildRecords())
        var record = try prepare("interrupted save")
        XCTAssertEqual(record.state, .prepared)
        XCTAssertThrowsError(try olderBuildRecords())
        try completeAsPublished(&record)
        XCTAssertEqual(try olderBuildRecords().map(\.id), [record.id])
        XCTAssertEqual(try outbox.records().map(\.id), [record.id])
    }

    func testMissingOrderingGuardFailsClosedButKeepsTheSaveExportable() throws {
        let first = try prepare("first save")
        try FileManager.default.removeItem(at: directory.appending(path: "Edits/" + EditOutbox.orderingGuardName))
        XCTAssertThrowsError(try outbox.order(item: item))
        XCTAssertThrowsError(try outbox.ownPublications(before: first))
        XCTAssertThrowsError(try prepare("second save"))
        var changed = first
        changed.state = .creatingStage
        XCTAssertThrowsError(try outbox.save(changed))
        XCTAssertEqual(try outbox.records(), [first])
        let exported = directory.appending(path: "exported.txt")
        try outbox.export(first, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("first save".utf8))
    }

    func testDuplicateSequencesBlockTheFileWhileANewSaveStaysDurable() throws {
        let first = try prepare("first save")
        var second = try prepare("second save")
        second.sequence = first.sequence
        try outbox.save(second)
        XCTAssertThrowsError(try outbox.order(item: item))
        let third = try prepare("second save")
        XCTAssertNotEqual(third.id, second.id)
        XCTAssertGreaterThan(try XCTUnwrap(third.sequence), try XCTUnwrap(first.sequence))
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

    func testDiscardNeverRemovesTheNewestOrAnIncompleteNewerGeneration() throws {
        let first = try prepare("first save")
        let second = try prepare("second save")
        XCTAssertThrowsError(try prepare("interrupted save", checkSpace: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let interrupted = try XCTUnwrap(outbox.records().last)
        XCTAssertEqual(interrupted.state, .preparing)
        XCTAssertThrowsError(try outbox.discard(second))
        XCTAssertThrowsError(try outbox.discard(interrupted))
        try outbox.discard(first)
        let third = try prepare("third save")
        XCTAssertGreaterThan(try XCTUnwrap(third.sequence), try XCTUnwrap(interrupted.sequence))
        XCTAssertEqual(try Set(outbox.order(item: item).superseded.map(\.id)), [second.id, interrupted.id])
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
        var legacy = published
        legacy.sequence = nil
        try outbox.save(legacy)
        XCTAssertEqual(try outbox.ownPublications(before: successor), [accepted])
        XCTAssertEqual(try outbox.ownPublications(before: unordered(successor)), [])
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
}
