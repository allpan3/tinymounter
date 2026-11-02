import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class FolderCreationTests: XCTestCase {
    private var directory: URL!
    private var outbox: UploadOutbox!
    private let identity = try! RemoteFolderIdentity(fileID: 42, birthMicroseconds: 100)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        outbox = try UploadOutbox(directory: directory)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func prepared() throws -> PendingUpload {
        let request = try CreateRequest(template: UUID().uuidString, parent: Catalog.rootItemID,
                                        name: "untitled folder", kind: .folder, staging: nil)
        return try outbox.prepare(request, path: XCTUnwrap(RelativePath(request.name)), contents: nil, progress: Progress())
    }

    func testCreationPersistsServerIdentityBeforeNativeBinding() throws {
        var record = try prepared()
        try outbox.createFolder(&record, progress: Progress()) { path, expected, persist in
            XCTAssertEqual(path.string, "untitled folder")
            XCTAssertNil(expected)
            try persist(identity)
            let saved = try XCTUnwrap(outbox.records().first)
            XCTAssertEqual(saved.serverFolder, identity)
            XCTAssertEqual(saved.state, .created)
            XCTAssertNil(saved.remoteID)
            return 999
        }
        XCTAssertEqual(record.serverFolder, identity)
        XCTAssertEqual(record.remoteID, 999)
        XCTAssertEqual(record.state, .verified)
    }

    func testInterruptedAttemptWithoutReceiptCreatesOnlyWhileTheNameIsAbsent() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress(), checkpoint: { state in
            if state == .attempting { throw TransferError.cancelled }
        }) { _, _, _ in XCTFail("Stopped before send"); return 0 })
        // A folder at the name may be the one the interrupted attempt created.
        record = try XCTUnwrap(outbox.records().first)
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, expected, _ in
            XCTAssertNil(expected)
            throw FolderMutationFailure(code: EEXIST, mayHaveChanged: false)
        }) { XCTAssertEqual($0 as? UploadError, .unresolved) }
        XCTAssertEqual(try outbox.records().first?.state, .attempting)
        record = try XCTUnwrap(outbox.records().first)
        try outbox.createFolder(&record, progress: Progress()) { _, expected, persist in
            XCTAssertNil(expected)
            try persist(identity)
            return 999
        }
        XCTAssertEqual(record.state, .verified)
    }

    func testStoppedFolderIsNotPending() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, _ in
            throw FolderMutationFailure(code: EACCES, mayHaveChanged: false)
        })
        XCTAssertEqual(try outbox.records().first?.state, .prepared)
        try outbox.stop(record.id)
        XCTAssertEqual(try outbox.pendingCount, 0)
        XCTAssertTrue(try outbox.takeStopped(template: record.template))
    }

    func testSavedReceiptRecoversWithAnIdentityCheck() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, persist in
            try persist(identity)
            throw FolderMutationFailure(code: EIO, mayHaveChanged: true)
        })
        record = try XCTUnwrap(outbox.records().first)
        try outbox.createFolder(&record, progress: Progress()) { _, expected, persist in
            XCTAssertEqual(expected, identity)
            try persist(identity)
            return 999
        }
        try outbox.complete(&record, item: UUID().uuidString)
        XCTAssertEqual(try outbox.pendingCount, 0)
    }

    func testReplacementIdentityCannotReplaceTheReceipt() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, persist in
            try persist(identity)
            throw TransferError.cancelled
        })
        record = try XCTUnwrap(outbox.records().first)
        let replacement = try RemoteFolderIdentity(fileID: identity.fileID, birthMicroseconds: 101)
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, persist in
            try persist(replacement)
            return 999
        })
        XCTAssertEqual(try outbox.records().first?.serverFolder, identity)
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testDefiniteNoSendCanRetryButCollisionStaysPending() throws {
        var record = try prepared()
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, _ in
            throw FolderMutationFailure(code: EAUTH, mayHaveChanged: false)
        })
        XCTAssertEqual(record.state, .prepared)
        XCTAssertThrowsError(try outbox.createFolder(&record, progress: Progress()) { _, _, _ in
            throw FolderMutationFailure(code: EEXIST, mayHaveChanged: false)
        })
        XCTAssertEqual(record.state, .collision)
        XCTAssertEqual(try outbox.pendingCount, 1)
    }

    func testMalformedIdentityIsRejectedWithoutAFormatVersion() throws {
        let record = try prepared()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        value["serverFolder"] = ["fileID": 0, "birthMicroseconds": 100]
        try JSONSerialization.data(withJSONObject: value).write(to: directory.appending(path: record.id.uuidString + ".json"))
        XCTAssertThrowsError(try outbox.records())
    }
}
