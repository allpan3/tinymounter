import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class DownloadSpaceTests: XCTestCase {
    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64) { self.bytes = bytes }
        func read() -> Int64 { lock.withLock { bytes } }
        func set(_ bytes: Int64) { lock.withLock { self.bytes = bytes } }
    }

    func testChangingReserveAffectsActiveAndWaitingDownloads() throws {
        XCTAssertEqual(DownloadSpace.reserveBytes(gigabytes: DownloadSpace.defaultReserveGB), 20_000_000_000)
        for invalid in [0, -1, Int.max] {
            XCTAssertNil(DownloadSpace.reserveBytes(gigabytes: invalid))
        }
        let reserve = Capacity(20_000_000_000)
        let space = DownloadSpace(reserve: { reserve.read() }) { 25_000_000_000 }
        let active = UUID()
        try space.begin(active, bytes: 1000)
        reserve.set(30_000_000_000)
        assertFull { try space.check(active, completedBytes: 0) }
        assertFull { try space.begin(UUID(), bytes: 1000) }
        XCTAssertFalse(try space.canRetry(bytes: 1000))
        reserve.set(10_000_000_000)
        try space.check(active, completedBytes: 1000)
        XCTAssertTrue(try space.canRetry(bytes: 1000))
    }

    func testConcurrentDownloadsShareCapacityAndReleaseReservations() throws {
        let capacity = Capacity(300000)
        let space = DownloadSpace(reserve: { 100000 }, capacity: { capacity.read() })
        let first = UUID(), second = UUID()
        try space.begin(first, bytes: 50000)
        assertFull { try space.begin(second, bytes: 50000) }
        space.end(first)
        try space.begin(second, bytes: 50000)
        space.end(second)
        space.end(second)
        try space.begin(first, bytes: 50000)
    }

    func testWrittenBytesAreNotReservedTwiceAndHandoffSpaceStaysReserved() throws {
        let capacity = Capacity(500000)
        let space = DownloadSpace(reserve: { 100000 }, checkStride: 1, capacity: { capacity.read() })
        let id = UUID()
        try space.begin(id, bytes: 100000)
        capacity.set(400000)
        try space.check(id, completedBytes: 100000)
        assertFull { try space.begin(UUID(), bytes: 50000) }
        space.end(id)
        try space.begin(UUID(), bytes: 50000)
    }

    func testRecoveryNeedsHeadroomAndAnOversizedRequestCannotOverflow() throws {
        let capacity = Capacity(100000)
        let space = DownloadSpace(reserve: { 100000 }, capacity: { capacity.read() })
        assertFull { try space.begin(UUID(), bytes: Int64.max) }
        XCTAssertFalse(try space.canRetry(bytes: 4096))
        capacity.set(100000 + 65536 + 8192 + DownloadSpace.recoveryBytes - 1)
        XCTAssertFalse(try space.canRetry(bytes: 4096))
        capacity.set(capacity.read() + 1)
        XCTAssertTrue(try space.canRetry(bytes: 4096))
    }

    func testCapacityQueryFailureDoesNotGrantAReservation() throws {
        let space = DownloadSpace { throw CocoaError(.fileReadUnknown) }
        XCTAssertThrowsError(try space.begin(UUID(), bytes: 1)) { error in
            XCTAssertFalse(DownloadSpace.isFull(error))
        }
    }

    func testQueuedWorkRechecksTheReserveWithoutChangingItsReservation() throws {
        let bytes: Int64 = 4096
        let required: Int64 = 20_000_000_000 + 2 * bytes + 65536
        let capacity = Capacity(required - 1)
        let space = DownloadSpace { capacity.read() }, id = UUID()
        assertFull { try space.begin(id, bytes: bytes) }
        capacity.set(required)
        try space.begin(id, bytes: bytes)
        capacity.set(required - 1)
        assertFull { try space.check(id, completedBytes: 0) }
        capacity.set(required)
        try space.check(id, completedBytes: 0)
        capacity.set(required - bytes)
        try space.check(id, completedBytes: bytes)
        space.end(id)
    }

    func testLastShortBlockStillChecksCapacityBelowTheStride() throws {
        let bytes: Int64 = 4096
        let capacity = Capacity(20_000_000_000 + 2 * bytes + 65536)
        let space = DownloadSpace { capacity.read() }, id = UUID()
        try space.begin(id, bytes: bytes)
        capacity.set(20_000_000_000 - 1)
        assertFull { try space.check(id, completedBytes: bytes) }
        space.end(id)
    }

    func testCapacityLossDuringTransferRemovesPartialOutputAndPreservesSource() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "source.bin")
        let bytes = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: url)
        let file = try ReadOnlyFile(url: url), id = UUID()
        let capacity = Capacity(1000000)
        let space = DownloadSpace(reserve: { 100000 }, checkStride: 4096, capacity: { capacity.read() })
        try space.begin(id, bytes: file.snapshot.size)
        let progress = Progress()
        let observer = progress.observe(\.completedUnitCount) { value, _ in
            if value.completedUnitCount >= 4096 { capacity.set(0) }
        }
        defer { observer.invalidate(); space.end(id) }
        assertFull {
            _ = try Transfer.run(source: file, range: ByteRange(offset: 0, length: file.snapshot.size,
                                                               fileSize: file.snapshot.size),
                                 blockSize: 4096, stagingDirectory: directory, progress: progress) {
                try space.check(id, completedBytes: $0)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.bin"])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        capacity.set(1000000)
        space.end(id)
        try space.begin(id, bytes: file.snapshot.size)
        let result = try Transfer.run(source: file,
            range: ByteRange(offset: 0, length: file.snapshot.size, fileSize: file.snapshot.size),
            stagingDirectory: directory) { try space.check(id, completedBytes: $0) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.stagingURL)), bytes)
    }

    func testLocalFullErrorsAreRecognizedWithoutConfusingRemoteQuota() {
        for code in [ENOSPC, EDQUOT] {
            XCTAssertTrue(DownloadSpace.isFull(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
            XCTAssertTrue(DownloadSpace.isFull(SourceFailure.unknown(domain: NSPOSIXErrorDomain, code: Int(code))))
        }
        XCTAssertTrue(DownloadSpace.isFull(CocoaError(.fileWriteOutOfSpace)))
        let pendingError = NSError(domain: "NSFileProviderErrorDomain", code: -2005,
                                   userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteOutOfSpace)])
        XCTAssertTrue(DownloadSpace.isFull(pendingError))
        XCTAssertFalse(DownloadSpace.isFull(NSError(domain: "NSFileProviderErrorDomain", code: -1003)))
        XCTAssertFalse(DownloadSpace.isFull(SourceFailure.serverUnreachable))
    }

    func testSparseRangeReservesPayloadRatherThanItsLogicalOffset() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "source.bin"), offset: Int64 = 128 << 20
        let bytes = Data(repeating: 73, count: 4096)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: bytes)
        try handle.close()
        let source = try ReadOnlyFile(url: url), id = UUID()
        let space = DownloadSpace(reserve: { 100000 }) { 100000 + 65536 + 8192 }
        try space.begin(id, bytes: Int64(bytes.count))
        defer { space.end(id) }
        let range = try ByteRange(offset: offset, length: Int64(bytes.count), fileSize: source.snapshot.size)
        let output = try Transfer.run(source: source, range: range, stagingDirectory: directory) {
            try space.check(id, completedBytes: $0)
        }
        let staged = try ReadOnlyFile(url: XCTUnwrap(output.stagingURL))
        XCTAssertEqual(staged.snapshot.size, range.end)
        XCTAssertEqual(try staged.checksum(range: range), try source.checksum(range: range))
    }

    func testBlockedRequestsSurviveRelaunchAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: DownloadRecovery.fileName)
        XCTAssertEqual(try DownloadRecovery.load(from: url), [:])
        let domain = UUID().uuidString, item = UUID().uuidString
        let request = try SourceReadRequest(id: UUID(), item: item, version: "observed-version",
            range: ByteRange(offset: 4096, length: 8192, fileSize: 16384), background: true)
        let requests = [domain: [item: request]]
        try DownloadRecovery.save(requests, to: url)
        XCTAssertEqual(try DownloadRecovery.load(from: url), requests)
        try DownloadRecovery.save([domain: [:]], to: url)
        XCTAssertEqual(try DownloadRecovery.load(from: url), [:])
    }

    func testInvalidRetryRecordsDoNotReplaceSavedRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: DownloadRecovery.fileName)
        let domain = UUID().uuidString, item = UUID().uuidString
        let request = try SourceReadRequest(id: UUID(), item: item, version: "version",
            range: ByteRange(offset: 0, length: 1, fileSize: 1), background: true)
        let requests = [domain: [item: request]]
        try DownloadRecovery.save(requests, to: url)
        for invalid in [["invalid-domain": [item: request]], [domain: [UUID().uuidString: request]]] {
            XCTAssertThrowsError(try DownloadRecovery.save(invalid, to: url))
            XCTAssertEqual(try DownloadRecovery.load(from: url), requests)
            try JSONEncoder().encode(invalid).write(to: url)
            XCTAssertThrowsError(try DownloadRecovery.load(from: url))
            try DownloadRecovery.save(requests, to: url)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var body = try XCTUnwrap((object[domain] as? [String: Any])?[item] as? [String: Any])
        for range in [["offset": -1, "length": 1], ["offset": Int64.max, "length": 1]] {
            body["range"] = range
            object[domain] = [item: body]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try DownloadRecovery.load(from: url))
        }
    }

    private func assertFull(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertTrue(DownloadSpace.isFull(error), file: file, line: line)
        }
    }
}
