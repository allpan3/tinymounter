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

    func testOnlyEquivalentUnpublishedGenerationCanResolveFromLaterCompletion() throws {
        var earlier = try prepare(base: "old", failOnConflict: true)
        var completed = try prepare(base: "new")
        completed.state = .published
        completed.previous = try version(for: completed)
        completed.published = try EditBaseReceipt(item: item, version: version(for: completed))
        try outbox.complete(&completed, item: item)
        earlier.state = .copying
        XCTAssertThrowsError(try outbox.resolveEquivalent(&earlier, with: completed))
        try outbox.validateContents(earlier)
        earlier.state = .prepared
        try outbox.resolveEquivalent(&earlier, with: completed)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(earlier.published, completed.published)
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
