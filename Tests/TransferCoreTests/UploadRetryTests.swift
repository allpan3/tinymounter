import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class UploadRetryTests: XCTestCase {
    func testDelaysDoubleUpToTheLongestAndStartAgainAfterReset() {
        var backoff = RetryBackoff(first: .seconds(2), longest: .seconds(300))
        let delays = (0..<10).map { _ in backoff.delay() }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300].map { .seconds($0) })
        backoff.reset()
        XCTAssertEqual(backoff.delay(), .seconds(2))
    }

    func testOnlyConnectionAndSharingFailuresAreTransient() {
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        for error: Error in [posix(ETXTBSY), posix(ETIMEDOUT), posix(ECONNRESET), SourceFailure.serverUnreachable,
                             SourceFailure.notConnected] {
            XCTAssertTrue(UploadRetrySchedule.isTransient(error), "\(error)")
        }
        for error: Error in [posix(EACCES), posix(ENOSPC), posix(EIO), SourceFailure.notAuthenticated,
                             SourceFailure.localNetworkDenied, SourceFailure.versionChanged,
                             UploadError.collision, UploadError.readOnly, UploadError.editConflict,
                             UploadError.unresolved, TransferError.cancelled] {
            XCTAssertFalse(UploadRetrySchedule.isTransient(error), "\(error)")
        }
    }

    func testOneRetryWaitsAndRepeatedFailuresWaitLonger() {
        var schedule = UploadRetrySchedule()
        XCTAssertEqual(schedule.failed("a"), .seconds(2))
        XCTAssertNil(schedule.failed("b"))
        schedule.fired()
        XCTAssertEqual(schedule.failed("a"), .seconds(4))
        schedule.fired()
        XCTAssertEqual(schedule.failed("b"), .seconds(8))
    }

    func testRetryStopsWhenNoUploadIsLeftFailing() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("a")
        _ = schedule.failed("b")
        XCTAssertFalse(schedule.settled("a"))
        XCTAssertTrue(schedule.isWaiting)
        XCTAssertTrue(schedule.settled("b"))
        XCTAssertFalse(schedule.isWaiting)
        XCTAssertFalse(schedule.settled("c"))
        XCTAssertEqual(schedule.failed("c"), .seconds(2))
    }

    func testAReconnectRetriesAtOnceAndStartsTheDelaysAgain() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("a")
        schedule.fired()
        _ = schedule.failed("a")
        schedule.connected()
        XCTAssertFalse(schedule.isWaiting)
        XCTAssertEqual(schedule.failed("a"), .seconds(2))
    }
}
