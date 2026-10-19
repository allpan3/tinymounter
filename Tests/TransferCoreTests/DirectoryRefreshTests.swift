import XCTest
@testable import TransferCore

final class DirectoryRefreshTests: XCTestCase {
    func testSilentFolderIsListedAgainWithoutAnEvent() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["folder"], now: .zero)
        XCTAssertEqual(refresh.next(now: .zero), "folder")
        XCTAssertNil(refresh.next(now: .seconds(1)))
        refresh.finished("folder", succeeded: true, now: .seconds(1))
        XCTAssertNil(refresh.next(now: .seconds(60)))
        XCTAssertEqual(refresh.next(now: .seconds(61)), "folder")
    }

    func testEventBurstsCoalesceAndRespectTheMinimumInterval() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["folder"], now: .zero)
        _ = refresh.next(now: .zero)
        refresh.finished("folder", succeeded: true, now: .seconds(1))
        refresh.changed("folder", now: .seconds(1))
        refresh.changed("folder", now: .seconds(2))
        XCTAssertNil(refresh.next(now: .milliseconds(2999)))
        XCTAssertEqual(refresh.next(now: .seconds(3)), "folder")
        XCTAssertNil(refresh.next(now: .seconds(4)))
    }

    func testEventDuringListingSchedulesAnotherPass() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["folder"], now: .zero)
        _ = refresh.next(now: .zero)
        refresh.changed("folder", now: .seconds(1))
        refresh.finished("folder", succeeded: true, now: .seconds(2))
        XCTAssertNil(refresh.next(now: .seconds(3)))
        XCTAssertEqual(refresh.next(now: .seconds(4)), "folder")
    }

    func testOldPeriodicWorkCannotBeStarvedByNewEvents() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["busy", "quiet"], now: .zero)
        XCTAssertEqual(refresh.next(now: .zero), "busy")
        refresh.finished("busy", succeeded: true, now: .seconds(1))
        refresh.changed("busy", now: .seconds(2))
        XCTAssertEqual(refresh.next(now: .seconds(3)), "quiet")
        refresh.finished("quiet", succeeded: true, now: .seconds(3))
        XCTAssertEqual(refresh.next(now: .seconds(3)), "busy")
    }

    func testMembershipChangesPreserveDueTimesAndDiscardRemovedFolders() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["first"], now: .zero)
        _ = refresh.next(now: .zero)
        refresh.finished("first", succeeded: true, now: .zero)
        refresh.replaceFolders(["first", "second"], now: .seconds(10))
        XCTAssertEqual(refresh.next(now: .seconds(10)), "second")
        refresh.replaceFolders(["first"], now: .seconds(11))
        refresh.finished("second", succeeded: true, now: .seconds(12))
        refresh.changed("second", now: .seconds(12))
        XCTAssertNil(refresh.next(now: .seconds(59)))
        XCTAssertEqual(refresh.next(now: .seconds(60)), "first")
    }

    func testFailedFolderBacksOffEvenWhenItKeepsSendingEvents() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["folder"], now: .zero)
        var now = Duration.zero
        for delay in [30, 60, 120, 240, 240] {
            XCTAssertEqual(refresh.next(now: now), "folder")
            refresh.finished("folder", succeeded: false, now: now)
            refresh.changed("folder", now: now + .seconds(1))
            XCTAssertNil(refresh.next(now: now + .seconds(delay - 1)))
            now += .seconds(delay)
        }
        XCTAssertEqual(refresh.next(now: now), "folder")
        refresh.finished("folder", succeeded: true, now: now)
        refresh.changed("folder", now: now + .seconds(10))
        XCTAssertEqual(refresh.next(now: now + .seconds(11)), "folder")
    }

    func testWakeRequestsRefreshWithoutOverlappingARunningListing() {
        var refresh = DirectoryRefresh()
        refresh.replaceFolders(["first", "second"], now: .zero)
        XCTAssertEqual(refresh.next(now: .zero), "first")
        refresh.refreshAll(now: .seconds(1))
        XCTAssertEqual(refresh.next(now: .seconds(1)), "second")
        XCTAssertNil(refresh.next(now: .seconds(1)))
        refresh.finished("first", succeeded: true, now: .seconds(2))
        XCTAssertEqual(refresh.next(now: .seconds(4)), "first")
    }
}
