import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class StagingTests: XCTestCase {
    func testSweepRemovesOnlyOldMatchingRegularFiles() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = base.appending(path: "staging")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func stageName() -> String { Staging.stageFileName(UUID()) }
        func make(_ name: String, age: TimeInterval? = 3600) throws {
            let url = directory.appending(path: name)
            try Data("x".utf8).write(to: url)
            guard let age else { return }
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: url.path(percentEncoded: false))
        }

        let old = [stageName(), stageName()]
        let fresh = stageName()
        let excluded = stageName()
        let otherNames = ["tinymounter-\(UUID().uuidString.lowercased()).stage", "tinymounter-foo.stage",
                          stageName() + ".part", "x" + stageName(), "notes.txt"]
        for name in old + [excluded] + otherNames { try make(name) }
        try make(fresh, age: nil)

        let target = base.appending(path: "target.bin")
        try Data("keep".utf8).write(to: target)
        let link = stageName(), folder = stageName(), fifo = stageName()
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
        try FileManager.default.createSymbolicLink(atPath: path(directory.appending(path: link)),
                                                   withDestinationPath: path(target))
        try FileManager.default.createDirectory(at: directory.appending(path: folder),
                                                withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(path(directory.appending(path: fifo)), 0o600), 0)

        let sourceURL = base.appending(path: "source.bin")
        try Data(repeating: 7, count: 5000).write(to: sourceURL)
        let source = try ReadOnlyFile(url: sourceURL)
        let staged = try Transfer.run(source: source, range: ByteRange(offset: 0, length: 5000, fileSize: 5000),
                                      stagingDirectory: directory)
        let stagedName = try XCTUnwrap(staged.stagingURL).lastPathComponent

        func remaining() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: path(directory))) }
        let everything = try remaining()

        XCTAssertEqual(try Staging.removeLeftoverStageFiles(in: directory, createdBefore: Date(timeIntervalSinceNow: -60),
                                                            excluding: [excluded]), 2)
        XCTAssertEqual(try remaining(), everything.subtracting(old))

        // With a later cutoff the fresh and Transfer.run's files go; other kinds and names stay.
        XCTAssertEqual(try Staging.removeLeftoverStageFiles(in: directory, createdBefore: Date(timeIntervalSinceNow: 60),
                                                            excluding: [excluded]), 2)
        XCTAssertEqual(try remaining(), Set([excluded, link, folder, fifo] + otherNames))
        XCTAssertFalse(try remaining().contains(stagedName))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try Staging.removeLeftoverStageFiles(in: directory, createdBefore: Date(timeIntervalSinceNow: 60)), 1)
        XCTAssertFalse(try remaining().contains(excluded))
    }

    func testStageNameMatchesOnlyTheTransferFormat() {
        let id = UUID()
        XCTAssertTrue(Staging.isStageFileName("tinymounter-\(id.uuidString).stage"))
        XCTAssertFalse(Staging.isStageFileName("tinymounter-\(id.uuidString.lowercased()).stage"))
        XCTAssertFalse(Staging.isStageFileName("tinymounter-\(id.uuidString).stage\u{301}"))
        XCTAssertFalse(Staging.isStageFileName("tinymounter-\(id.uuidString)"))
        XCTAssertFalse(Staging.isStageFileName("tinymounter-.stage"))
    }

    func testSweepOfMissingDirectoryThrowsWithoutPath() {
        let name = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appending(path: name)
        XCTAssertThrowsError(try Staging.removeLeftoverStageFiles(in: directory, createdBefore: Date())) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(ENOENT))
            XCTAssertFalse("\(error)".contains(name))
        }
    }
}
