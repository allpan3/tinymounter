import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class UploadRetryTests: XCTestCase {
    func testNamespaceSignalsRepeatUntilTheItemIsResent() {
        var schedule = UploadRetrySchedule()
        XCTAssertEqual(schedule.failed("create:a", waitingForNamespace: true), .seconds(2))
        XCTAssertFalse(schedule.hasTransientFailures)
        XCTAssertEqual(schedule.fired(), .seconds(4))
        XCTAssertEqual(schedule.fired(), .seconds(8))
        XCTAssertFalse(schedule.started("create:b"))
        XCTAssertTrue(schedule.isWaiting)
        XCTAssertTrue(schedule.started("create:a"))
        XCTAssertFalse(schedule.isWaiting)
        XCTAssertNil(schedule.fired())
    }

    func testAResendStillBlockedBacksOffAndSuccessResetsTheDelay() {
        var schedule = UploadRetrySchedule()
        XCTAssertEqual(schedule.failed("edit:a", waitingForNamespace: true), .seconds(2))
        XCTAssertTrue(schedule.started("edit:a"))
        XCTAssertEqual(schedule.failed("edit:a", waitingForNamespace: true), .seconds(4))
        XCTAssertTrue(schedule.started("edit:a"))
        XCTAssertFalse(schedule.settled("edit:a"))
        XCTAssertEqual(schedule.failed("edit:a", waitingForNamespace: true), .seconds(2))
    }

    func testReconnectDoesNotLoseAnUnacknowledgedNamespaceSignal() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("create:a", waitingForNamespace: true)
        _ = schedule.failed("edit:b")
        XCTAssertTrue(schedule.hasTransientFailures)
        XCTAssertFalse(schedule.connected())
        XCTAssertFalse(schedule.hasTransientFailures)
        XCTAssertTrue(schedule.isWaiting)
        XCTAssertNotNil(schedule.fired())
        XCTAssertTrue(schedule.started("create:a"))
    }

    func testStoppingOneBlockedItemKeepsTheOtherItemsRetry() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("create:a", waitingForNamespace: true)
        _ = schedule.failed("edit:b", waitingForNamespace: true)
        XCTAssertFalse(schedule.settled("create:a"))
        XCTAssertEqual(schedule.fired(), .seconds(4))
        XCTAssertTrue(schedule.settled("edit:b"))
        XCTAssertNil(schedule.fired())
    }

    func testNamespaceWakeupsBackOffToTheLimitWithoutAnAcknowledgment() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("create:a", waitingForNamespace: true)
        let delays = (0..<10).map { _ in schedule.fired() }
        XCTAssertEqual(delays, [4, 8, 16, 32, 64, 128, 256, 300, 300, 300].map { .seconds($0) })
        XCTAssertTrue(schedule.isWaiting)
    }

    func testConnectionFailureAfterResendUsesOnlyConnectionRecovery() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("edit:a", waitingForNamespace: true)
        XCTAssertTrue(schedule.started("edit:a"))
        XCTAssertEqual(schedule.failed("edit:a"), .seconds(4))
        XCTAssertTrue(schedule.hasTransientFailures)
        XCTAssertNil(schedule.fired())
        XCTAssertFalse(schedule.isWaiting)
    }

    func testResendingOneBlockedItemKeepsTheOtherItemsWakeup() {
        var schedule = UploadRetrySchedule()
        _ = schedule.failed("create:a", waitingForNamespace: true)
        _ = schedule.failed("edit:b", waitingForNamespace: true)
        XCTAssertFalse(schedule.started("create:a"))
        XCTAssertFalse(schedule.settled("create:a"))
        XCTAssertEqual(schedule.fired(), .seconds(4))
        XCTAssertTrue(schedule.started("edit:b"))
    }

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
                             UploadError.unresolved, UploadError.pendingWrites, TransferError.cancelled] {
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
