import XCTest
@testable import TransferCore

final class PreviousSessionsTests: XCTestCase {
    func testEachNewSessionNamesOneDroppedSessionOldestFirst() {
        var sessions = PreviousSessions()
        XCTAssertNil(sessions.take())
        sessions.dropped(0)
        sessions.dropped(7)
        sessions.dropped(9)
        sessions.dropped(7)
        XCTAssertEqual(sessions.take(), 7)
        XCTAssertEqual(sessions.take(), 9)
        XCTAssertNil(sessions.take())
    }

    func testAFailedSignInReturnsItsIDFirst() {
        var sessions = PreviousSessions()
        sessions.dropped(7)
        sessions.dropped(9)
        let taken = sessions.take()
        XCTAssertEqual(taken, 7)
        sessions.unsent(7)
        XCTAssertEqual(sessions.take(), 7)
        XCTAssertEqual(sessions.take(), 9)
    }

    func testTheOldestIDsGoPastTheLimit() {
        var sessions = PreviousSessions()
        for id in 1...UInt64(PreviousSessions.limit + 2) { sessions.dropped(id) }
        XCTAssertEqual(sessions.take(), 3)
    }
}
