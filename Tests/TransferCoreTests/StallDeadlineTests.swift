import Foundation
import XCTest
@testable import TransferCore

final class StallDeadlineTests: XCTestCase {
    private final class ManualClock: @unchecked Sendable {
        var now = Duration.seconds(1000)
    }

    func testItExpiresAfterTheLimitWithoutProgress() {
        let clock = ManualClock()
        var deadline = StallDeadline(now: { clock.now })
        deadline.started()
        clock.now += StallDeadline.limit
        XCTAssertFalse(deadline.hasExpired)
        clock.now += .milliseconds(1)
        XCTAssertTrue(deadline.hasExpired)
        XCTAssertEqual(StallDeadline.limit, .seconds(60))
    }

    func testTimeBeforeTheStartIsNoStall() {
        let clock = ManualClock()
        var deadline = StallDeadline(now: { clock.now })
        // Queued behind two long downloads in another location.
        clock.now += .seconds(600)
        XCTAssertFalse(deadline.hasExpired)
        XCTAssertTrue(deadline.progressed(completedBytes: 4096), "progress before the start doesn't arm it")
        clock.now += .seconds(600)
        XCTAssertFalse(deadline.hasExpired)

        deadline.started()
        clock.now += StallDeadline.limit
        XCTAssertFalse(deadline.hasExpired)
        clock.now += .milliseconds(1)
        XCTAssertTrue(deadline.hasExpired)
    }

    func testARepeatedStartDoesNotRestartIt() {
        let clock = ManualClock()
        var deadline = StallDeadline(now: { clock.now })
        deadline.started()
        clock.now += .seconds(40)
        deadline.started()
        clock.now += .seconds(20) + .milliseconds(1)
        XCTAssertTrue(deadline.hasExpired)
    }

    func testProgressRestartsItForAsLongAsTheFetchRuns() {
        let clock = ManualClock()
        var deadline = StallDeadline(now: { clock.now })
        deadline.started()
        // 50 minutes of a slow, healthy download: far past the old absolute 300 s.
        for step in 1...100 {
            clock.now += .seconds(30)
            XCTAssertTrue(deadline.progressed(completedBytes: Int64(step) << 20))
            XCTAssertFalse(deadline.hasExpired)
        }
        clock.now += StallDeadline.limit + .milliseconds(1)
        XCTAssertTrue(deadline.hasExpired)
    }

    func testOnlyNewBytesCountAsProgress() {
        let clock = ManualClock()
        var deadline = StallDeadline(now: { clock.now })
        deadline.started()
        clock.now += .seconds(40)
        XCTAssertFalse(deadline.progressed(completedBytes: 0))
        XCTAssertTrue(deadline.progressed(completedBytes: 4096))
        clock.now += .seconds(40)
        XCTAssertFalse(deadline.progressed(completedBytes: 4096))
        XCTAssertFalse(deadline.progressed(completedBytes: 1))
        clock.now += .seconds(20) + .milliseconds(1)
        XCTAssertTrue(deadline.hasExpired)
    }
}
