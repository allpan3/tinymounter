import Foundation
import XCTest
@testable import TransferCore

final class ReadPrefetchTests: XCTestCase {
    private static let extent: Int64 = 4096
    private static let fileSize: Int64 = 4 * extent
    private let item = UUID().uuidString
    private var staging: URL!
    /// Room for exactly one extent's reservation, so a leaked one makes `isIdle` false.
    private let space = DownloadSpace(reserve: 0, capacity: { 2 * ReadPrefetchTests.extent + 65536 })

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: staging)
    }

    func testClaimTakesOnlyTheExactNextExtent() throws {
        let prefetch = ReadPrefetch(space: space)
        let ran = expectation(description: "prefetch read")
        try start(prefetch) { request, progress in
            defer { ran.fulfill() }
            return try self.read(request, progress)
        }
        wait(for: [ran], timeout: 2)
        let output = try XCTUnwrap(prefetch.claim(request(at: 2), isCancelled: { false }))
        let url = try XCTUnwrap(output.stagingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(isIdle(), "a claim hands the reservation to the claiming fetch")
        try FileManager.default.removeItem(at: url)

        let again = expectation(description: "second prefetch read")
        prefetch.completed(try request(at: 2), next: { try? self.range(at: 3) }, enqueue: enqueue) { request, progress in
            defer { again.fulfill() }
            return try self.read(request, progress)
        }
        wait(for: [again], timeout: 2)
        XCTAssertNil(prefetch.claim(try request(at: 0), isCancelled: { false }))
        try waitUntilClean()
    }

    func testFailedPrefetchReleasesItsReservationAndSlot() throws {
        let prefetch = ReadPrefetch(space: space, lifetime: .seconds(60))
        let failed = expectation(description: "prefetch failed")
        try start(prefetch) { _, _ in
            defer { failed.fulfill() }
            throw SourceFailure.notConnected
        }
        wait(for: [failed], timeout: 2)
        try waitUntilClean()

        let ran = expectation(description: "next prefetch read")
        prefetch.completed(try request(at: 2), next: { try? self.range(at: 3) }, enqueue: enqueue) { request, progress in
            defer { ran.fulfill() }
            return try self.read(request, progress)
        }
        wait(for: [ran], timeout: 2)
        let url = try XCTUnwrap(prefetch.claim(try request(at: 3), isCancelled: { false })?.stagingURL)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(isIdle())
    }

    func testUnclaimedPrefetchExpires() throws {
        let prefetch = ReadPrefetch(space: space, lifetime: .milliseconds(50))
        let ran = expectation(description: "prefetch read")
        try start(prefetch) { request, progress in
            defer { ran.fulfill() }
            return try self.read(request, progress)
        }
        wait(for: [ran], timeout: 2)
        try waitUntilClean()
        XCTAssertNil(prefetch.claim(try request(at: 2), isCancelled: { false }))
    }

    func testCancelledClaimAndCloseStopARunningRead() throws {
        for closing in [false, true] {
            let prefetch = ReadPrefetch(space: space, lifetime: .seconds(60))
            let started = DispatchSemaphore(value: 0)
            try start(prefetch) { request, progress in
                started.signal()
                while !progress.isCancelled { usleep(1000) }
                return try self.read(request, progress)
            }
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            if closing {
                prefetch.close()
            } else {
                XCTAssertNil(prefetch.claim(try request(at: 2), isCancelled: { true }))
            }
            try waitUntilClean()
        }
    }

    // MARK: - Helpers

    private func range(at index: Int64) throws -> ByteRange {
        try ByteRange(offset: index * Self.extent, length: Self.extent, fileSize: Self.fileSize)
    }

    private func request(at index: Int64) throws -> SourceReadRequest {
        try SourceReadRequest(id: UUID(), item: item, version: "v1", range: range(at: index), background: false)
    }

    private func enqueue(_ work: @escaping @Sendable () -> Void) { DispatchQueue.global().async(execute: work) }

    /// Two sequential fetches, so the second schedules a prefetch of the third extent.
    private func start(_ prefetch: ReadPrefetch, transfer: @escaping ReadPrefetch.Transfer) throws {
        prefetch.completed(try request(at: 0), next: { nil }, enqueue: enqueue) { _, _ in
            XCTFail("the first fetch has no predecessor")
            throw TransferError.cancelled
        }
        prefetch.completed(try request(at: 1), next: { try? self.range(at: 2) }, enqueue: enqueue, transfer: transfer)
    }

    private func read(_ request: SourceReadRequest, _ progress: Progress) throws -> TransferOutput {
        try Transfer.run(size: Self.fileSize, range: request.range, blockSize: 4096, stagingDirectory: staging,
                         progress: progress, validate: {}) { _, buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 7)
            return buffer.count
        }
    }

    private func isIdle() -> Bool {
        let probe = UUID()
        guard (try? space.begin(probe, bytes: Self.extent)) != nil else { return false }
        space.end(probe)
        return true
    }

    private func waitUntilClean(file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date.now.addingTimeInterval(2)
        while Date.now < deadline {
            if isIdle(), try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty { return }
            usleep(10_000)
        }
        XCTFail("prefetch left a reservation or staging file", file: file, line: line)
    }
}
