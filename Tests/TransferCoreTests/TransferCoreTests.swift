import Foundation
import XCTest
@testable import TransferCore

final class TransferCoreTests: XCTestCase {
    private func withFixture(_ body: (URL, URL, Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("fixture.bin")
        // Nonzero pattern with a tail that is not aligned to our buffer size.
        let bytes = Data((0..<131_173).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 8)) })
        try bytes.write(to: sourceURL)
        try body(sourceURL, directory, bytes)
    }

    func testFullAndOffsetStagingContainExactBytes() throws {
        try withFixture { url, directory, bytes in
            let source = try ReadOnlyFile(url: url)
            for (offset, length) in [(0, bytes.count), (12_345, 51_119), (bytes.count - 7, 7)] {
                let range = try ByteRange(offset: Int64(offset), length: Int64(length), fileSize: source.snapshot.size)
                let result = try Transfer.run(source: source, range: range, blockSize: 4096, stagingDirectory: directory)
                let stage = try XCTUnwrap(result.stagingURL)
                let stagedBytes = try Data(contentsOf: stage)
                XCTAssertEqual(stagedBytes.count, offset + length)
                XCTAssertEqual(stagedBytes[offset..<(offset + length)], bytes[offset..<(offset + length)])
                XCTAssertTrue(stagedBytes.prefix(offset).allSatisfy { $0 == 0 })
                XCTAssertEqual(result.metrics.bytes, Int64(length))
                try FileManager.default.removeItem(at: stage)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testAlignmentCoversRangeAndOnlyEOFMayBeUnaligned() throws {
        for size: Int64 in [1, 4096, 12_345, Int64.max] {
            for offset in [Int64(0), max(0, size - 1)] {
                let minimum = try ByteRange(offset: offset, length: 1, fileSize: size)
                let range = try ByteRange.aligned(minimum: minimum, alignment: 4096, fileSize: size)
                XCTAssertLessThanOrEqual(range.offset, minimum.offset)
                XCTAssertGreaterThanOrEqual(range.end, minimum.end)
                XCTAssertLessThanOrEqual(range.end, size)
                XCTAssertEqual(range.offset % 4096, 0)
                XCTAssertTrue(range.end == size || range.length % 4096 == 0)
            }
        }
        XCTAssertThrowsError(try ByteRange(offset: Int64.max, length: 1, fileSize: Int64.max))
        XCTAssertThrowsError(try ByteRange(offset: -1, length: 1, fileSize: 1))
        let small = try ByteRange(offset: 0, length: 1, fileSize: 10)
        XCTAssertThrowsError(try ByteRange.aligned(minimum: small, alignment: 3, fileSize: 10))
    }

    func testEmptyFileAndRange() throws {
        try withFixture { url, directory, _ in
            try Data().write(to: url)
            let source = try ReadOnlyFile(url: url)
            let range = try ByteRange(offset: 0, length: 0, fileSize: 0)
            let result = try Transfer.run(source: source, range: range, stagingDirectory: directory)
            XCTAssertEqual(result.metrics.bytes, 0)
            XCTAssertNil(result.metrics.firstReadSeconds)
            XCTAssertNil(result.metrics.megabytesPerSecond)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.stagingURL)), Data())
        }
    }

    func testCancellationLeavesNoStagingFile() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let progress = Progress()
            progress.cancel()
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                stagingDirectory: directory, progress: progress)) { error in
                XCTAssertEqual(error as? TransferError, .cancelled)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture.bin"])
        }
    }

    func testChangedSourceRejectedBeforeTransfer() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 3)
            try handle.close()
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                stagingDirectory: directory)) { error in
                XCTAssertEqual(error as? TransferError, .sourceChanged)
            }
        }
    }

    func testMidTransferCancellationRemovesPartialStaging() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let progress = Progress()
            let observation = progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
                if progress.completedUnitCount >= 4096 { progress.cancel() }
            }
            defer { observation.invalidate() }
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                blockSize: 4096, stagingDirectory: directory, progress: progress)) { error in
                XCTAssertEqual(error as? TransferError, .cancelled)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture.bin"])
        }
    }

    func testSymlinkAndDirectoryRejected() throws {
        try withFixture { url, directory, _ in
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try ReadOnlyFile(url: link))
            XCTAssertThrowsError(try ReadOnlyFile(url: directory))
        }
    }

    func testSHA256KnownVector() throws {
        try withFixture { url, _, _ in
            try Data("abc".utf8).write(to: url)
            let source = try ReadOnlyFile(url: url)
            XCTAssertEqual(try source.checksum(range: ByteRange(offset: 0, length: 3, fileSize: 3)),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }
}
