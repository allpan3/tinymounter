import Darwin
import Foundation
import XCTest
@testable import TransferCore

/// The app's guard names: earlier readers fail on them; current readers skip only the exact guard.
final class DeletionGuardTests: XCTestCase {
    private var fixture: DeletionFixture!

    override func setUpWithError() throws {
        fixture = try DeletionFixture()
        let directory = fixture.directory
        fixture.outbox = try DeletionOutbox(directory: fixture.outboxDirectory, compatibilityGuards: { domain in
            [directory.appending(path: "Edits/\(domain)/" + EditOutbox.deletionGuardName),
             directory.appending(path: "Renames/" + FileRenameOutbox.deletionGuardName)]
        })
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func edits(_ domain: String) -> URL {
        fixture.directory.appending(path: "Edits/\(domain)", directoryHint: .isDirectory)
    }

    private var renames: URL { fixture.directory.appending(path: "Renames", directoryHint: .isDirectory) }

    /// The most permissive earlier reader of each outbox; ordered-save builds skip only Ordering.edit.
    private func earlierReaderFails(_ folder: URL) -> Bool {
        struct Header: Decodable { let kind: String? }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { url in
            switch url.pathExtension {
            case "edit" where url.lastPathComponent != "Ordering.edit":
                return (try? JSONDecoder().decode(PendingEdit.self, from: Data(contentsOf: url))) == nil
            case "rename":
                return (try? JSONDecoder().decode(Header.self, from: Data(contentsOf: url))) == nil
            default:
                return false
            }
        }
    }

    func testPendingDeletionClosesEarlierReadersWhileCurrentReadersContinue() throws {
        let folders = [edits(fixture.owner), edits(fixture.neighbor), renames]
        var record = try fixture.prepare()
        XCTAssertEqual(folders.filter(earlierReaderFails), folders)
        XCTAssertEqual(try EditOutbox(directory: edits(fixture.owner)).records(), [])
        XCTAssertEqual(try EditOutbox(directory: edits(fixture.neighbor)).records(), [])
        XCTAssertEqual(try FileRenameOutbox(directory: renames).intents(), [])
        try fixture.outbox.stop(&record)
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        XCTAssertEqual(folders.filter(earlierReaderFails), [])
    }

    func testAnythingButTheExactEmptyGuardKeepsCurrentReadersClosed() throws {
        let edit = edits(fixture.owner)
        let editOutbox = try EditOutbox(directory: edit), renameOutbox = try FileRenameOutbox(directory: renames)
        let target = fixture.directory.appending(path: "target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        let readers: [(URL, String, () throws -> Void)] = [
            (edit, EditOutbox.deletionGuardName, { _ = try editOutbox.records() }),
            (renames, FileRenameOutbox.deletionGuardName, { _ = try renameOutbox.intents() })
        ]
        for (folder, name, read) in readers {
            let url = folder.appending(path: name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            XCTAssertNoThrow(try read())
            try FileManager.default.removeItem(at: url)
            let other = folder.appending(path: name.lowercased())
            let variants: [(URL, () throws -> Void)] = [
                (url, { try Data("x".utf8).write(to: url) }),
                (url, { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target) }),
                (url, { guard link(target.path, url.path) == 0 else { throw posixError("link guard") } }),
                (url, { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }),
                (other, { XCTAssertTrue(FileManager.default.createFile(atPath: other.path, contents: Data())) })
            ]
            for (index, (created, create)) in variants.enumerated() {
                try create()
                XCTAssertThrowsError(try read(), "variant \(index) of \(name)")
                try FileManager.default.removeItem(at: created)
            }
            XCTAssertNoThrow(try read())
        }
    }
}
