import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class FolderNamingTests: XCTestCase {
    private var directory: URL!
    private var remote: URL!
    private var outbox: UploadOutbox!
    private var root: Int32 = -1

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        remote = directory.appending(path: "remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        outbox = try UploadOutbox(directory: directory.appending(path: "pending"))
        root = open(remote.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(root, 0)
    }

    override func tearDownWithError() throws {
        if root >= 0 { close(root) }
        try FileManager.default.removeItem(at: directory)
    }

    private func created(name: String = "untitled folder") throws -> PendingUpload {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: name, kind: .folder, staging: nil)
        var record = try outbox.prepare(request, path: XCTUnwrap(RelativePath(request.name)),
                                       contents: nil, progress: Progress())
        try outbox.createFolder(&record, progress: Progress()) { path, expected, persist in
            let target = remote.appending(path: path.string)
            if expected == nil { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            var info = stat()
            guard stat(target.path, &info) == 0 else { throw UploadError.unresolved }
            let identity = try RemoteFolderIdentity(fileID: info.st_ino, birthMicroseconds: 1)
            if let expected { XCTAssertEqual(expected, identity) }
            try persist(identity)
            return info.st_ino
        }
        try outbox.complete(&record, item: UUID().uuidString)
        return record
    }

    private func rename(_ source: RelativePath, _ destination: RelativePath, _ identity: RemoteFolderIdentity,
                        _ recovering: Bool) throws -> UInt64 {
        let target = remote.appending(path: destination.string)
        if recovering {
            var info = stat()
            guard stat(target.path, &info) == 0, info.st_ino == identity.fileID else {
                throw FolderMutationFailure(code: EAGAIN, mayHaveChanged: false)
            }
            return info.st_ino
        }
        guard renameatx_np(root, source.string, root, destination.string, UInt32(RENAME_EXCL)) == 0 else {
            throw FolderMutationFailure(code: errno, mayHaveChanged: false)
        }
        var info = stat()
        guard stat(target.path, &info) == 0 else { throw UploadError.unresolved }
        return info.st_ino
    }

    func testInitialNameKeepsReceiptAndReplaysOriginalCreate() throws {
        var record = try created()
        let original = record
        try outbox.nameFolder(&record, name: "chosen", rename: rename)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.completeFolderName(&record)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(record.item, original.item)
        XCTAssertEqual(record.remoteID, original.remoteID)
        XCTAssertEqual(record.path, "chosen")
        let replay = try CreateRequest(template: original.template, parent: original.parent, name: original.name,
                                       kind: .folder, staging: nil)
        let receipt = try outbox.prepare(replay, path: XCTUnwrap(RelativePath(original.path)),
                                        contents: nil, progress: Progress())
        XCTAssertEqual(receipt.item, original.item)
        try outbox.nameFolder(&record, name: "chosen") { _, _, _, _ in XCTFail("Must not rename twice"); return 0 }
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "other", rename: rename)) {
            XCTAssertEqual($0 as? UploadError, .readOnly)
        }
    }

    func testCollisionPreservesBothFoldersAndAllowsAnotherInitialName() throws {
        var record = try created()
        let existing = remote.appending(path: "existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = Data("existing contents".utf8)
        try marker.write(to: existing.appending(path: "child"))
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "existing", rename: rename)) {
            XCTAssertEqual($0 as? UploadError, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: existing.appending(path: "child")), marker)
        XCTAssertNil(record.initialName)
        XCTAssertEqual(try outbox.pendingCount, 0)
        try outbox.nameFolder(&record, name: "available", rename: rename)
        try outbox.completeFolderName(&record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appending(path: "available").path))
    }

    func testConfirmedNoSendCanRetryAndStillBlocksRemoval() throws {
        var record = try created()
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { _, _, _, _ in
            throw FolderMutationFailure(code: EAUTH, mayHaveChanged: false)
        })
        XCTAssertEqual(record.initialName?.state, .prepared)
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertThrowsError(try outbox.removeIfCompleted())
        try outbox.nameFolder(&record, name: "changed-after-no-send", rename: rename)
        try outbox.completeFolderName(&record)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(record.name, "changed-after-no-send")
    }

    func testAmbiguousResultOnlyChecksTheDestinationOnReplay() throws {
        var record = try created()
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { source, destination, identity, recovering in
            _ = try rename(source, destination, identity, recovering)
            throw FolderMutationFailure(code: EIO, mayHaveChanged: true)
        })
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertEqual(record.initialName?.state, .attempting)
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.nameFolder(&record, name: "chosen") { source, destination, identity, recovering in
            XCTAssertTrue(recovering)
            return try rename(source, destination, identity, recovering)
        }
        try outbox.completeFolderName(&record)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), ["chosen"])
    }

    func testOriginalNameClearsAnIntentThatWasNeverSent() throws {
        var record = try created()
        let original = record.name
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { _, _, _, _ in
            throw FolderMutationFailure(code: EAUTH, mayHaveChanged: false)
        })
        XCTAssertEqual(try outbox.pendingCount, 1)
        record = try XCTUnwrap(outbox.records().first)
        try outbox.nameFolder(&record, name: original) { _, _, _, _ in
            XCTFail("Reverting an unsent intent must not rename")
            return 0
        }
        XCTAssertNil(try outbox.records().first?.initialName)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appending(path: original).path))
    }

    func testNormalizationOnlyNameNeedsNoRename() throws {
        var record = try created(name: "Cafe\u{301}")
        try outbox.nameFolder(&record, name: "Caf\u{e9}") { _, _, _, _ in
            XCTFail("SMB clients send both spellings as one name")
            return 0
        }
        XCTAssertNil(try outbox.records().first?.initialName)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testUnknownAttemptDoesNotRenameOnReplay() throws {
        var record = try created()
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen", checkpoint: { state in
            if state == .attempting { throw TransferError.cancelled }
        }, rename: rename))
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { source, destination, identity, recovering in
            XCTAssertTrue(recovering)
            return try rename(source, destination, identity, recovering)
        })
        XCTAssertEqual(try outbox.pendingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appending(path: "untitled folder").path))
    }

    func testVerifiedRenameSurvivesBeforeCatalogAcknowledgement() throws {
        var record = try created()
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen", checkpoint: { state in
            if state == .verified { throw TransferError.cancelled }
        }, rename: rename))
        record = try XCTUnwrap(outbox.records().first)
        try outbox.nameFolder(&record, name: "chosen") { _, _, _, _ in XCTFail("Already verified"); return 0 }
        try outbox.completeFolderName(&record)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testStaleNativeListingCannotReverseCompletedNaming() throws {
        var record = try created()
        try outbox.nameFolder(&record, name: "chosen", rename: rename)
        try outbox.completeFolderName(&record)
        let stale = DirectoryListing([.entry(.init(name: "untitled folder", kind: .folder, size: 0,
                                                   mtimeNs: 1, ctimeNs: 2, fileID: record.remoteID!))])
        XCTAssertThrowsError(try outbox.observeFolderNames(parent: record.parent, listing: stale) { _, _ in }) {
            XCTAssertEqual($0 as? SourceFailure, .listingIncomplete)
        }
        let fresh = DirectoryListing([.entry(.init(name: "chosen", kind: .folder, size: 0,
                                                   mtimeNs: 1, ctimeNs: 2, fileID: record.remoteID!))])
        try outbox.observeFolderNames(parent: record.parent, listing: fresh) { _, _ in XCTFail("Already applied") }
        XCTAssertEqual(try outbox.records().first?.initialName?.state, .observed)
    }

    func testNativeListingCannotResolveLostRenameAcknowledgement() throws {
        var record = try created()
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { source, destination, identity, recovering in
            _ = try rename(source, destination, identity, recovering)
            throw FolderMutationFailure(code: EIO, mayHaveChanged: true)
        })
        let fresh = DirectoryListing([.entry(.init(name: "chosen", kind: .folder, size: 0,
                                                   mtimeNs: 1, ctimeNs: 2, fileID: record.remoteID!))])
        XCTAssertThrowsError(try outbox.observeFolderNames(parent: record.parent, listing: fresh) { _, _ in
            XCTFail("A native identifier cannot prove direct SMB ownership")
        })
        XCTAssertEqual(try outbox.pendingCount, 1)
        try outbox.nameFolder(&record, name: "chosen", rename: rename)
        try outbox.completeFolderName(&record)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testNativeIdentityCanChangeWhileServerIdentityStaysFixed() throws {
        var record = try created()
        let server = try XCTUnwrap(record.serverFolder), original = record.remoteID
        let item = record.item
        try outbox.nameFolder(&record, name: "chosen") { _, _, identity, recovering in
            XCTAssertEqual(identity, server)
            XCTAssertFalse(recovering)
            return 200
        }
        try outbox.completeFolderName(&record)
        XCTAssertEqual(record.remoteID, 200)
        XCTAssertNotEqual(record.remoteID, original)
        XCTAssertEqual(record.serverFolder, server)
        XCTAssertEqual(record.item, item)
        let stale = DirectoryListing([.entry(.init(name: "untitled folder", kind: .folder, size: 0,
                                                   mtimeNs: 1, ctimeNs: 2, fileID: original!))])
        XCTAssertThrowsError(try outbox.observeFolderNames(parent: record.parent, listing: stale) { _, _ in })
        let fresh = DirectoryListing([.entry(.init(name: "chosen", kind: .folder, size: 0,
                                                   mtimeNs: 1, ctimeNs: 2, fileID: 200))])
        try outbox.observeFolderNames(parent: record.parent, listing: fresh) { _, _ in XCTFail("Already applied") }
        XCTAssertEqual(try outbox.records().first?.initialName?.state, .observed)
    }

    func testLegacyFolderReceiptCannotAcquireRenamePermission() throws {
        var record = try created()
        record.serverFolder = nil
        try outbox.save(record)
        XCTAssertThrowsError(try outbox.initialNamingRecord(item: record.item!))
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen", rename: rename))
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testCreatingChildrenClosesTheInitialNamingWindow() throws {
        var record = try created()
        let child = try CreateRequest(template: UUID().uuidString, parent: record.item!, name: "child",
                                      kind: .folder, staging: nil)
        _ = try outbox.prepare(child, path: XCTUnwrap(RelativePath(record.path + "/child")),
                               contents: nil, progress: Progress())
        XCTAssertThrowsError(try outbox.nameFolder(&record, name: "chosen") { _, _, _, _ in
            XCTFail("A parent rename must not move a child's saved upload path")
            return 0
        }) { XCTAssertEqual($0 as? UploadError, .readOnly) }
        XCTAssertNil(record.initialName)
    }

    func testLegacyReceiptAndMalformedNamingState() throws {
        let record = try created()
        XCTAssertNil(try outbox.initialNamingRecord(item: record.item!).initialName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["initialName"] = ["source": record.path, "destination": "../escape", "name": "escape", "state": "attempting"]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appending(path: "pending/\(record.id.uuidString).json"))
        XCTAssertThrowsError(try outbox.records())
    }

    func testNamingRequestRejectsTraversalAndUnknownItems() throws {
        let item = UUID().uuidString
        for name in ["", ".", "..", "a/b", "a\\b", ".tinymounter-private"] {
            XCTAssertThrowsError(try FolderNameRequest(item: item, parent: Catalog.rootItemID, name: name))
        }
        XCTAssertThrowsError(try FolderNameRequest(item: Catalog.rootItemID, parent: Catalog.rootItemID, name: "name"))
        XCTAssertThrowsError(try outbox.initialNamingRecord(item: item))
        let request = try FolderNameRequest(item: item, parent: Catalog.rootItemID, name: "chosen")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderMessage.encode(request)) as? [String: Any])
        json["parent"] = "invalid"
        XCTAssertThrowsError(try ReaderMessage.decode(FolderNameRequest.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
