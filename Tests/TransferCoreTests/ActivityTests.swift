import Foundation
import XCTest
@testable import TransferCore

final class ActivityTests: XCTestCase {
    private func event(_ kind: ActivityEvent.Kind = .uploaded, at seconds: TimeInterval,
                       domain: String? = "A") -> ActivityEvent {
        ActivityEvent(kind: kind, domain: domain, name: "file", date: Date(timeIntervalSince1970: seconds))
    }

    func testKeepsTheNewestHundred() {
        var history = ActivityHistory()
        for second in 0..<150 { history.add(event(at: TimeInterval(second))) }
        XCTAssertEqual(history.events.count, ActivityHistory.limit)
        XCTAssertEqual(history.events.first?.date, Date(timeIntervalSince1970: 149))
        XCTAssertEqual(history.events.last?.date, Date(timeIntervalSince1970: 50))
    }

    func testInsertsAnOlderEventInDateOrder() {
        var history = ActivityHistory()
        for second in [10.0, 30, 20] { history.add(event(at: second)) }
        XCTAssertEqual(history.events.map(\.date.timeIntervalSince1970), [30, 20, 10])
    }

    func testRemovingALocationRemovesItsEvents() {
        var history = ActivityHistory(events: [event(at: 1, domain: "A"), event(at: 2, domain: "B"),
                                               event(at: 3, domain: nil)])
        history.removeEvents(domain: "A")
        XCTAssertEqual(history.events.map(\.domain), [nil, "B"])
    }

    func testAFailedUploadStaysFailedUntilItSucceeds() {
        func upload(_ kind: ActivityEvent.Kind, _ item: String, at seconds: TimeInterval) -> ActivityEvent {
            ActivityEvent(kind: kind, domain: "A", name: "file", item: item, date: Date(timeIntervalSince1970: seconds))
        }
        var history = ActivityHistory(events: [upload(.uploadFailed, "1", at: 1), upload(.uploaded, "2", at: 2)])
        XCTAssertTrue(history.uploadFailed(domain: "A", item: "1"))
        XCTAssertFalse(history.uploadFailed(domain: "B", item: "1"))
        XCTAssertFalse(history.uploadFailed(domain: "A", item: "2"))
        history.add(event(.connectionLost, at: 3, domain: nil))
        XCTAssertTrue(history.uploadFailed(domain: "A", item: "1"))
        history.add(upload(.uploaded, "1", at: 4))
        XCTAssertFalse(history.uploadFailed(domain: "A", item: "1"))
    }

    func testSurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try ActivityHistory.load(from: url).events.isEmpty)
        let history = ActivityHistory(events: [event(.uploadFailed, at: 5), event(.connectionLost, at: 6, domain: nil)])
        try history.save(to: url)
        XCTAssertEqual(try ActivityHistory.load(from: url), history)
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try ActivityHistory.load(from: url))
    }

    func testSuccessfulUploadRemovesOnlyEarlierFailuresOfTheSameItemAndLocation() {
        func failure(_ domain: String, _ item: String?, at seconds: TimeInterval) -> ActivityEvent {
            ActivityEvent(kind: .uploadFailed, domain: domain, name: "same name", item: item,
                          date: Date(timeIntervalSince1970: seconds))
        }
        let resolved = failure("A", "1", at: 1)
        let otherItem = failure("A", "2", at: 2), otherLocation = failure("B", "1", at: 3)
        let unknownItem = failure("A", nil, at: 4), laterFailure = failure("A", "1", at: 6)
        let success = ActivityEvent(kind: .uploaded, domain: "A", name: "renamed", item: "1",
                                    date: Date(timeIntervalSince1970: 5))
        var history = ActivityHistory(events: [resolved, otherItem, otherLocation, unknownItem, laterFailure])
        history.add(success)
        XCTAssertEqual(history.events, [laterFailure, success, unknownItem, otherLocation, otherItem])
        XCTAssertTrue(history.uploadFailed(domain: "A", item: "1"))
    }

    func testLoadingHistoryDropsFailuresAlreadyFollowedBySuccess() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let failure = ActivityEvent(kind: .uploadFailed, domain: "A", name: "file", item: "1",
                                    date: Date(timeIntervalSince1970: 1))
        let success = ActivityEvent(kind: .uploaded, domain: "A", name: "file", item: "1",
                                    date: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode([success, failure]).write(to: url)
        XCTAssertEqual(try ActivityHistory.load(from: url).events, [success])
    }

    func testLoadingEqualDatesPreservesTheRecordedOutcomeOrder() {
        let date = Date(timeIntervalSince1970: 1)
        let failure = ActivityEvent(kind: .uploadFailed, domain: "A", name: "file", item: "1", date: date)
        let success = ActivityEvent(kind: .uploaded, domain: "A", name: "file", item: "1", date: date)
        XCTAssertEqual(ActivityHistory(events: [success, failure]).events, [success])
        XCTAssertEqual(ActivityHistory(events: [failure, success]).events, [failure, success])
    }

    func testProblemsNotifyByDefaultAndEverythingShowsInThePanel() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-tests-\(UUID().uuidString)"))
        XCTAssertEqual(NotificationKind.allCases.filter { $0.route(in: defaults).notify },
                       [.signInNeeded, .uploadFailed, .downloadFailed, .conflictCopy, .lowDiskSpace])
        XCTAssertTrue(NotificationKind.allCases.allSatisfy { $0.route(in: defaults).panel })
        defaults.set(false, forKey: NotificationKind.uploadFailed.notifyKey)
        defaults.set(true, forKey: NotificationKind.connection.notifyKey)
        XCTAssertEqual(NotificationKind.uploadFailed.route(in: defaults), NotificationRoute(notify: false, panel: true))
        XCTAssertEqual(NotificationKind.connection.route(in: defaults), NotificationRoute(notify: true, panel: true))
    }

    func testFinishedTransfersHaveNoNotificationSetting() {
        XCTAssertNil(event(.uploaded, at: 0).notification)
        XCTAssertNil(event(.downloaded, at: 0).notification)
        XCTAssertEqual(event(.connectionRestored, at: 0).notification, .connection)
    }
}
