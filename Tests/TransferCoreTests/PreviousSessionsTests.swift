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

    func testTheNextRunNamesTakenAndDroppedSessionsAndOnEndingOpenOnes() {
        var sessions = PreviousSessions()
        sessions.dropped(7)
        sessions.dropped(9)
        XCTAssertEqual(sessions.take(), 7)
        sessions.signedIn(11, previous: nil)
        sessions.signedIn(12, previous: nil)
        sessions.closed(12)
        XCTAssertEqual(sessions.saved(ending: false), [7, 9])
        XCTAssertEqual(sessions.saved(ending: true), [7, 9, 11])
        sessions.signedIn(13, previous: 7)
        sessions.dropped(11)
        XCTAssertEqual(sessions.saved(ending: false), [9, 11])
        XCTAssertEqual(sessions.saved(ending: true), [9, 11, 13])
    }

    func testTheFileKeepsEachSharesSessionsAcrossARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try PreviousSessionsFile.load(from: url), [:])
        let share = UUID(), idle = UUID()
        var sessions = PreviousSessions()
        sessions.dropped(UInt64.max)
        sessions.dropped(5)
        sessions.signedIn(0xabc, previous: nil)
        try PreviousSessionsFile.save([share: sessions, idle: PreviousSessions()], ending: true, to: url)
        var loaded = try PreviousSessionsFile.load(from: url)
        XCTAssertEqual(Array(loaded.keys), [share])
        XCTAssertEqual(loaded[share]?.take(), UInt64.max)
        XCTAssertEqual(loaded[share]?.take(), 5)
        XCTAssertEqual(loaded[share]?.take(), 0xabc)
        XCTAssertNil(loaded[share]?.take())
    }

    func testASavedListPastTheLimitKeepsTheNewest() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let share = UUID()
        let ids = (1...UInt64(PreviousSessions.limit + 4)).map(String.init).joined(separator: ",")
        try Data(#"{"\#(share.uuidString)":[\#(ids)]}"#.utf8).write(to: url)
        let loaded = try PreviousSessionsFile.load(from: url)
        XCTAssertEqual(loaded[share]?.saved(ending: false), Array(5...UInt64(PreviousSessions.limit + 4)))
    }

    func testACorruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        for content in ["{", #"{"not-a-share":[1]}"#, #"{"\#(UUID().uuidString)":[-1]}"#] {
            try Data(content.utf8).write(to: url)
            XCTAssertThrowsError(try PreviousSessionsFile.load(from: url), content)
        }
    }
}
