import Foundation
import XCTest
@testable import TransferCore

final class EditTransactionTests: XCTestCase {
    private var directory: URL!
    private var outbox: EditOutbox!
    private var edit: PendingEdit!
    private var remote: Remote!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appending(path: "input")
        try Data("complete new version".utf8).write(to: input)
        outbox = try EditOutbox(directory: directory.appending(path: "Outbox"))
        let item = UUID().uuidString
        let old = try Remote.version(identity: 1, size: 3, digest: String(repeating: "a", count: 64))
        let base = try EditBaseReceipt(item: item, version: old)
        try outbox.storeBase(base)
        edit = try outbox.prepare(item: item, parent: Catalog.rootItemID, path: XCTUnwrap(RelativePath("file.txt")),
                                  baseVersion: base.contentVersion, failOnConflict: false,
                                  contents: input, progress: Progress())
        remote = Remote(original: old, edited: try Remote.version(identity: 2, size: edit.size, digest: edit.digest))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

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

    private final class Remote: EditRemote {
        enum Failure { case partialCopy, completeCopy, publication, collision }
        var failure: Failure?
        var files: [String: EditFileVersion]
        let edited: EditFileVersion
        var updates = 0
        var moves = 0

        init(original: EditFileVersion, edited: EditFileVersion) {
            files = ["file.txt": original]
            self.edited = edited
        }

        static func version(identity: UInt64, size: Int64, digest: String) throws -> EditFileVersion {
            try EditFileVersion(identity: EditFileIdentity(fileID: identity, birthMicroseconds: 10), size: size,
                                digest: digest, modifiedMicroseconds: 20, changedMicroseconds: 30,
                                attributes: 32, security: Data([1]))
        }

        func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            files[path] = edited
            try created(edited.identity)
            return edited
        }

        func inspect(path: String, original: Bool) throws -> EditFileVersion? { files[path] }

        func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            let old = try XCTUnwrap(files[original])
            let backup = try Self.version(identity: 3, size: old.size, digest: old.digest)
            files[path] = backup
            try created(backup.identity)
            return backup
        }

        func move(source: String, destination: String) throws {
            if failure == .collision, destination == "file.txt" {
                files[destination] = try Self.version(identity: 99, size: 4, digest: String(repeating: "d", count: 64))
                failure = nil
            }
            guard files[destination] == nil else { throw UploadError.collision }
            files[destination] = files.removeValue(forKey: source)
            moves += 1
            if failure == .publication, destination == "file.txt" {
                failure = nil
                throw UploadError.unresolved
            }
        }

        func update(work: String, stage: String, size: Int64) throws {
            XCTAssertTrue(work.hasSuffix(".work"))
            updates += 1
            let identity = try XCTUnwrap(files[work]).identity.fileID
            files[work] = try Self.version(identity: identity, size: size,
                                           digest: failure == .partialCopy ? String(repeating: "e", count: 64) : edited.digest)
            if failure == .partialCopy || failure == .completeCopy {
                failure = nil
                throw UploadError.unresolved
            }
        }

        func removeArtifact(path: String, version: EditFileVersion) throws {
            guard files[path] == version || files[path] == nil else { throw UploadError.unresolved }
            XCTAssertFalse(path.hasSuffix(".work"))
            XCTAssertNotEqual(path, "file.txt")
            files[path] = nil
        }
    }
}
