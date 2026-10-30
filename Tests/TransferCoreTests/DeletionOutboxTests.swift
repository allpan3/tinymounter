import Foundation
import XCTest
@testable import TransferCore

final class DeletionOutboxTests: XCTestCase {
    private var fixture: DeletionFixture!

    override func setUpWithError() throws { fixture = try DeletionFixture() }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    /// Older builds decode every file with their outbox's extension, so one guard closes each reader.
    private func failingOlderReaders() -> Int {
        let edit: (Data) throws -> Void = { _ = try JSONDecoder().decode(PendingEdit.self, from: $0) }
        let rename: (Data) throws -> Void = { _ = try JSONDecoder().decode(PendingFileRename.self, from: $0) }
        let readers = [(fixture.directory.appending(path: "Edits/\(fixture.owner)"), edit),
                       (fixture.directory.appending(path: "Edits/\(fixture.neighbor)"), edit),
                       (fixture.directory.appending(path: "Renames"), rename)]
        return readers.filter { folder, decode in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.contains { (try? decode(Data(contentsOf: $0))) == nil }
        }.count
    }

    func testGuardsPrecedeThePlanAndCloseOlderReadersUntilEveryViewSettles() throws {
        var record = try fixture.prepare()
        XCTAssertEqual(try fixture.storedFiles(), [record.id.uuidString + ".deletion", record.id.uuidString + ".progress"])
        XCTAssertEqual(failingOlderReaders(), 3)
        try fixture.run(&record)
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        XCTAssertTrue(record.isPending)
        XCTAssertEqual(failingOlderReaders(), 3)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        XCTAssertFalse(record.isPending)
        XCTAssertEqual(failingOlderReaders(), 0)
        XCTAssertFalse((fixture.guardURLs(fixture.owner) + fixture.guardURLs(fixture.neighbor))
            .contains { FileManager.default.fileExists(atPath: $0.path) })
        try fixture.outbox.remove(record)
        XCTAssertEqual(try fixture.storedFiles(), [])
        XCTAssertEqual(try fixture.outbox.records(), [])
    }

    func testGuardFailureLeavesNoDurableRequestAndReconcilingRemovesItsLeftovers() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.directory.appending(path: "Renames").path,
                                                     contents: Data()))
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(try fixture.storedFiles(), [])
        XCTAssertEqual(try fixture.outbox.records(), [])
        let created = fixture.guardURLs(fixture.owner)[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        try fixture.outbox.reconcileGuards(domains: [fixture.owner])
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(fixture.server.sessions, 0)
    }

    func testReplayReturnsTheOperationAndOverlappingRequestsWaitForEveryCatalog() throws {
        var record = try fixture.prepare()
        XCTAssertEqual(try fixture.prepare(), record)
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
                                                 request: fixture.request), record)
        XCTAssertNil(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.neighbor,
                                               request: fixture.request))
        XCTAssertThrowsError(try fixture.prepare("Docs/Tree/a")) { XCTAssertEqual($0 as? UploadError, .pendingWrites) }
        XCTAssertThrowsError(try fixture.outbox.prepare(endpoint: XCTUnwrap(ShareAddress("//other@fixture/share")),
            owner: fixture.owner, request: fixture.request, traversal: fixture.traversal(), views: fixture.views(),
            protectedRoots: [], recursive: true)) { XCTAssertEqual($0 as? UploadError, .pendingWrites) }
        try fixture.run(&record)
        XCTAssertThrowsError(try fixture.prepare("Docs/neighbor")) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        XCTAssertEqual(try fixture.prepare(), record)
        let other = try fixture.prepare("Docs/neighbor", recursive: false)
        XCTAssertNotEqual(other.id, record.id)
        XCTAssertEqual(try fixture.outbox.records().count, 2)
        XCTAssertEqual(fixture.server.marks.count, 7)
    }

    func testOverlappingViewsFinishSeparatelyAcrossRestarts() throws {
        var record = try fixture.prepare()
        XCTAssertThrowsError(try fixture.outbox.finishDomain(fixture.owner, record: &record))
        try fixture.run(&record)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        fixture.outbox = try fixture.makeOutbox()
        var restarted = try XCTUnwrap(fixture.outbox.records().first)
        XCTAssertEqual(restarted, record)
        XCTAssertTrue(restarted.blocksWrites)
        XCTAssertEqual(try fixture.outbox.pendingCount(domain: fixture.owner), 1)
        XCTAssertEqual(try fixture.outbox.pendingCount(domain: fixture.neighbor), 1)
        XCTAssertThrowsError(try fixture.outbox.finishDomain(UUID().uuidString, record: &restarted))
        try fixture.outbox.finishDomain(fixture.neighbor, record: &restarted)
        XCTAssertEqual(restarted.progress.finishedDomains, [fixture.neighbor])
        try fixture.outbox.finishDomain(fixture.owner, record: &restarted)
        XCTAssertTrue(restarted.isComplete)
        XCTAssertFalse(restarted.isPending)
        XCTAssertEqual(try fixture.outbox.pendingCount(domain: fixture.owner), 0)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        XCTAssertEqual(record, restarted)
    }

    func testUnconfirmedOutcomeKeepsTheRecordAndGuardsUntilDismissed() throws {
        var record = try fixture.prepare()
        fixture.server.lostCloses = ["Docs/Tree/b"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.run(&record)
        XCTAssertTrue(record.hasUnconfirmed)
        XCTAssertThrowsError(try fixture.outbox.dismiss(&record))
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        XCTAssertTrue(record.isComplete)
        XCTAssertFalse(record.blocksWrites)
        XCTAssertTrue(record.isPending)
        XCTAssertEqual(failingOlderReaders(), 3)
        XCTAssertThrowsError(try fixture.outbox.remove(record)) { XCTAssertEqual($0 as? UploadError, .pendingWrites) }
        XCTAssertThrowsError(try fixture.outbox.removeSettled(domain: fixture.owner)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        try fixture.outbox.dismiss(&record)
        XCTAssertFalse(record.isPending)
        XCTAssertEqual(failingOlderReaders(), 0)
        try fixture.outbox.removeSettled(domain: UUID().uuidString)
        XCTAssertEqual(try fixture.outbox.records(), [record])
        try fixture.outbox.removeSettled(domain: fixture.neighbor)
        XCTAssertEqual(try fixture.outbox.records(), [])
        XCTAssertEqual(try fixture.storedFiles(), [])
    }

    func testProgressUpdatesMustFollowTheDurableStateMonotonically() throws {
        let plan = try fixture.prepare().plan, initial = DeletionProgress()
        func refuse(_ previous: DeletionProgress, _ next: DeletionProgress, line: UInt = #line) {
            XCTAssertThrowsError(try fixture.outbox.advance(plan, from: previous, to: next), line: line)
        }
        var attempting = initial
        attempting.current = .attempting
        var acknowledged = initial
        acknowledged.current = .closeAcknowledged
        var deleted = initial
        deleted.next = 1
        refuse(initial, acknowledged)
        refuse(initial, deleted)
        try fixture.outbox.advance(plan, from: initial, to: attempting)
        refuse(initial, attempting)
        refuse(attempting, initial)
        var finishedEarly = attempting
        finishedEarly.finishedDomains = [fixture.owner]
        refuse(attempting, finishedEarly)
        var unconfirmedPair = attempting
        unconfirmedPair.next = 2
        unconfirmedPair.current = .prepared
        unconfirmedPair.exceptions = [.init(node: 0, outcome: .unconfirmed), .init(node: 1, outcome: .unconfirmed)]
        refuse(attempting, unconfirmedPair)
        try fixture.outbox.advance(plan, from: attempting, to: acknowledged)
        try fixture.outbox.advance(plan, from: acknowledged, to: deleted)
        var rewritten = deleted
        rewritten.exceptions = [.init(node: 0, outcome: .changed)]
        refuse(deleted, rewritten)
        var stopped = deleted
        stopped.stopped = 1
        refuse(deleted, stopped)
        stopped.next = plan.nodes.count
        try fixture.outbox.advance(plan, from: deleted, to: stopped)
        var resumed = stopped
        resumed.stopped = nil
        refuse(stopped, resumed)
        var dismissed = stopped
        dismissed.dismissed = true
        refuse(stopped, dismissed)
        var finished = stopped
        finished.finishedDomains = [fixture.owner, fixture.neighbor]
        try fixture.outbox.advance(plan, from: stopped, to: finished)
        var unfinished = finished
        unfinished.finishedDomains = [fixture.owner]
        refuse(finished, unfinished)
        XCTAssertEqual(try fixture.outbox.records().first?.progress, finished)
        XCTAssertEqual(fixture.server.sessions, 0)
    }

    func testMalformedStorageFailsClosed() throws {
        let record = try fixture.prepare()
        let planURL = fixture.outboxDirectory.appending(path: record.id.uuidString + ".deletion")
        let progressURL = fixture.outboxDirectory.appending(path: record.id.uuidString + ".progress")
        let plan = try Data(contentsOf: planURL), progress = try Data(contentsOf: progressURL)
        func rewrite(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
            var values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            change(&values)
            try JSONSerialization.data(withJSONObject: values).write(to: url)
        }
        func assertRejected(line: UInt = #line) throws {
            XCTAssertThrowsError(try fixture.outbox.records(), line: line)
            XCTAssertThrowsError(try fixture.outbox.pendingCount(domain: fixture.owner), line: line)
            XCTAssertThrowsError(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
                                                           request: fixture.request), line: line)
            try plan.write(to: planURL)
            try progress.write(to: progressURL)
            XCTAssertEqual(try fixture.outbox.records(), [record], line: line)
        }
        try Data("{".utf8).write(to: planURL)
        try assertRejected()
        try rewrite(planURL) { $0["owner"] = "not-a-domain" }
        try assertRejected()
        try rewrite(planURL) { $0["id"] = UUID().uuidString }
        try assertRejected()
        try rewrite(planURL) { values in
            var nodes = values["nodes"] as! [Any]
            nodes.swapAt(1, 3)
            values["nodes"] = nodes
        }
        try assertRejected()
        try rewrite(planURL) { values in
            var views = values["views"] as! [[String: Any]]
            views[0]["folder"] = "Other"
            values["views"] = views
        }
        try assertRejected()
        try FileManager.default.removeItem(at: progressURL)
        try assertRejected()
        try rewrite(progressURL) { $0["next"] = 8 }
        try assertRejected()
        try rewrite(progressURL) { $0["current"] = "deleted" }
        try assertRejected()
        try rewrite(progressURL) { $0["exceptions"] = [["node": 0, "outcome": "unconfirmed"]] }
        try assertRejected()
        // An interrupted preparation leaves progress without a plan, which authorizes nothing.
        try progress.write(to: fixture.outboxDirectory.appending(path: UUID().uuidString + ".progress"))
        XCTAssertEqual(try fixture.outbox.records(), [record])
    }
}
