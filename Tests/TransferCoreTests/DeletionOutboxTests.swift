import Darwin
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

    func testReplayUsesTheEventWhenItemVersionsChange() throws {
        let record = try fixture.prepare()
        let refreshed = DeletionRequest(item: record.plan.request.item, contentVersion: "refreshed",
            metadataVersion: "309", eventVersion: record.plan.request.eventVersion)
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: refreshed), record)
        XCTAssertEqual(try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: refreshed, traversal: fixture.traversal(), views: fixture.views(), protectedRoots: [],
            recursive: true), record)
        fixture.outbox = try fixture.makeOutbox()
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: refreshed)?.plan.request, record.plan.request)
        XCTAssertTrue(fixture.server.marks.isEmpty)
    }

    func testNewEventWithUnchangedItemVersionsAdmitsASeparateRequestAfterCompletion() throws {
        var first = try fixture.prepare()
        try fixture.outbox.stop(&first)
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &first) }
        let request = DeletionRequest(item: first.plan.request.item, contentVersion: first.plan.request.contentVersion,
            metadataVersion: first.plan.request.metadataVersion, eventVersion: Data([2]))
        XCTAssertNil(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner, request: request))
        let second = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: request, traversal: fixture.traversal(), views: fixture.views(), protectedRoots: [], recursive: true)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.plan.request, request)
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: first.plan.request), first)
        XCTAssertThrowsError(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: request, sameEvent: { _, _ in true })) {
            XCTAssertEqual($0 as? ItemDeletionError, .unresolved)
        }
    }

    func testSemanticEventComparisonCanMatchDistinctArchivesAndPropagatesFailure() throws {
        let record = try fixture.prepare()
        let request = DeletionRequest(item: record.plan.request.item, contentVersion: "refreshed",
            metadataVersion: "309", eventVersion: Data([1, 2]))
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: request, sameEvent: { stored, incoming in
                stored.first == incoming.first
            }), record)
        XCTAssertThrowsError(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
            request: request, sameEvent: { _, _ in throw DeletionFixture.Fault.persistence })) {
            XCTAssertEqual($0 as? DeletionFixture.Fault, .persistence)
        }
    }

    func testDeletionEventsAreRequiredAndBoundedInStoredRequests() throws {
        let original = fixture.request
        let encoded = try JSONEncoder().encode(original)
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        values["eventVersion"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(DeletionRequest.self,
            from: JSONSerialization.data(withJSONObject: values)))
        for invalid in [Data(), Data(repeating: 1, count: 4097)] {
            let request = DeletionRequest(item: original.item, contentVersion: original.contentVersion,
                metadataVersion: original.metadataVersion, eventVersion: invalid)
            XCTAssertThrowsError(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
                request: request))
            XCTAssertThrowsError(try JSONDecoder().decode(DeletionRequest.self,
                from: JSONEncoder().encode(request)))
        }
        let largest = DeletionRequest(item: original.item, contentVersion: original.contentVersion,
            metadataVersion: original.metadataVersion, eventVersion: Data(repeating: 1, count: 4096))
        XCTAssertEqual(try JSONDecoder().decode(DeletionRequest.self, from: JSONEncoder().encode(largest)), largest)
    }

    func testRecordStaysPendingUntilEveryViewSettles() throws {
        var record = try fixture.prepare()
        XCTAssertEqual(try fixture.storedFiles(), [record.id.uuidString + ".deletion", record.id.uuidString + ".progress"])
        try fixture.run(&record)
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        XCTAssertTrue(record.isPending)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        XCTAssertFalse(record.isPending)
        XCTAssertThrowsError(try fixture.outbox.remove(record, removedOwner: fixture.neighbor)) {
            XCTAssertEqual($0 as? ItemDeletionError, .invalidRequest)
        }
        try fixture.outbox.remove(record, removedOwner: fixture.owner)
        XCTAssertEqual(try fixture.storedFiles(), [])
        XCTAssertEqual(try fixture.outbox.records(), [])
    }

    func testParentCheckpointsCannotRetargetOrPrecedeConfirmedDeletion() throws {
        let plan = try fixture.prepare().plan, initial = DeletionProgress()
        let item = try plan.item(at: 0, state: .prepared, directories: plan.directoryIdentities())
        let refreshed = try item.parents.map {
            ItemDeletionParent(path: $0.path, name: $0.name, identity: try RemoteFileIdentity(
                fileID: $0.identity.fileID, birthMicroseconds: $0.identity.birthMicroseconds + 1))
        }
        XCTAssertThrowsError(try fixture.outbox.advance(plan, from: initial,
            to: initial.recording(.attempting).recordingParents(refreshed)))
        let attempting = initial.recording(.attempting)
        try fixture.outbox.advance(plan, from: initial, to: attempting)
        let acknowledged = attempting.recording(.closeAcknowledged)
        try fixture.outbox.advance(plan, from: attempting, to: acknowledged)
        let confirmed = acknowledged.recording(.deleted)
        let foreign = ItemDeletionParent(path: "Docs/Tree/Sub", name: "Sub",
            identity: try DeletionFixture.identity(14))
        XCTAssertThrowsError(try fixture.outbox.advance(plan, from: acknowledged,
            to: confirmed.recordingParents(refreshed + [foreign])))
        let replaced = ItemDeletionParent(path: refreshed[0].path, name: refreshed[0].name,
            identity: try DeletionFixture.identity(999))
        XCTAssertThrowsError(try fixture.outbox.advance(plan, from: acknowledged,
            to: confirmed.recordingParents([replaced])))
        let saved = confirmed.recordingParents(refreshed)
        try fixture.outbox.advance(plan, from: acknowledged, to: saved)
        var discarded = saved.recording(.attempting)
        discarded.parentUpdates = nil
        XCTAssertThrowsError(try fixture.outbox.advance(plan, from: saved, to: discarded))
        fixture.outbox = try fixture.makeOutbox()
        XCTAssertEqual(try fixture.outbox.durableProgress(of: plan), saved)
    }

    func testParentCheckpointPreservesAdmittedServerSpelling() throws {
        let encoded = try JSONEncoder().encode(fixture.prepare().plan)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: "Docs", with: "Cafe\u{301}")
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var parents = try XCTUnwrap(values["parents"] as? [[String: Any]])
        parents[1]["name"] = "Caf\u{e9}"
        values["parents"] = parents
        let plan = try JSONDecoder().decode(DeletionPlan.self, from: JSONSerialization.data(withJSONObject: values))
        let item = try plan.item(at: 0, state: .prepared, directories: plan.directoryIdentities())
        let acknowledged = DeletionProgress().recording(.attempting).recording(.closeAcknowledged)
        let confirmed = acknowledged.recording(.deleted).recordingParents(item.parents)
        try confirmed.validate(for: plan)
        try confirmed.validateUpdate(from: acknowledged, plan: plan)
        let respelled = ItemDeletionParent(path: item.parents[1].path, name: "Cafe\u{301}",
                                          identity: item.parents[1].identity)
        XCTAssertThrowsError(try confirmed.recordingParents([respelled]).validate(for: plan))
    }

    func testDuplicatePersistedParentsAreRejected() throws {
        let encoded = try JSONEncoder().encode(fixture.prepare().plan)
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var parents = try XCTUnwrap(values["parents"] as? [[String: Any]])
        parents[1] = parents[0]
        values["parents"] = parents
        XCTAssertThrowsError(try JSONDecoder().decode(DeletionPlan.self,
            from: JSONSerialization.data(withJSONObject: values)))
    }

    func testReplayReturnsTheOperationAndOverlappingRequestsWaitForEveryCatalog() throws {
        var record = try fixture.prepare()
        XCTAssertEqual(try fixture.prepare(), record)
        XCTAssertEqual(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.owner,
                                                 request: fixture.request), record)
        XCTAssertNil(try fixture.outbox.replay(endpoint: fixture.endpoint, owner: fixture.neighbor,
                                               request: fixture.request))
        XCTAssertThrowsError(try fixture.prepare("Docs/Tree/a")) { XCTAssertEqual($0 as? ItemDeletionError, .busy) }
        XCTAssertThrowsError(try fixture.outbox.prepare(endpoint: XCTUnwrap(ShareAddress("//other@fixture/share")),
            owner: fixture.owner, request: fixture.request, traversal: fixture.traversal(), views: fixture.views(),
            protectedRoots: [], recursive: true)) { XCTAssertEqual($0 as? ItemDeletionError, .busy) }
        try fixture.run(&record)
        XCTAssertThrowsError(try fixture.prepare("Docs/neighbor")) {
            XCTAssertEqual($0 as? ItemDeletionError, .busy)
        }
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        fixture.outbox = try fixture.makeOutbox()
        XCTAssertThrowsError(try fixture.prepare("Docs/neighbor")) {
            XCTAssertEqual(DeletionFailure.classify($0), .busy)
        }
        XCTAssertEqual(try fixture.outbox.records(), [record])
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
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

    func testUnconfirmedOutcomeKeepsTheRecordUntilDismissed() throws {
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
        XCTAssertThrowsError(try fixture.outbox.remove(record, removedOwner: fixture.owner)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        XCTAssertThrowsError(try fixture.outbox.removeSettled(domain: fixture.owner)) {
            XCTAssertEqual($0 as? UploadError, .pendingWrites)
        }
        try fixture.outbox.dismiss(&record)
        XCTAssertFalse(record.isPending)
        try fixture.outbox.removeSettled(domain: UUID().uuidString)
        XCTAssertEqual(try fixture.outbox.records(), [record])
        try fixture.outbox.removeSettled(domain: fixture.neighbor)
        XCTAssertEqual(try fixture.outbox.records(), [record])
        try fixture.outbox.removeSettled(domain: fixture.owner)
        XCTAssertEqual(try fixture.outbox.records(), [])
        XCTAssertEqual(try fixture.storedFiles(), [])
    }

    func testSecondaryRemovalKeepsStoppedAndPartialReplayWhenChildrenArrive() throws {
        for partial in [false, true] {
            var record = try fixture.prepare()
            if partial {
                fixture.server.inspectFailures["Docs/Tree/Sub/c"] = DeletionFixture.Fault.connection
                XCTAssertThrowsError(try fixture.run(&record))
                fixture.server.inspectFailures = [:]
                XCTAssertEqual(record.progress.next, 1)
            }
            try fixture.outbox.stop(&record)
            for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
            try fixture.outbox.removeSettled(domain: fixture.neighbor)
            XCTAssertEqual(try fixture.outbox.records(), [record])
            fixture.outbox = try fixture.makeOutbox()
            let arrival = ItemDeletionEvidence.file(try DeletionFixture.version(95))
            fixture.server.objects["Docs/Tree/new"] = arrival
            let owner = try XCTUnwrap(fixture.views().first { $0.domain == fixture.owner })
            let view = DeletionView(domain: owner.domain, folder: try XCTUnwrap(RelativePath(owner.folder)),
                items: owner.items.filter { !partial || $0.item != fixture.items["Docs/Tree/Empty"] })
            var replayed = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
                request: fixture.request, traversal: fixture.traversal(), views: [view], protectedRoots: [], recursive: true)
            XCTAssertEqual(replayed, record)
            let sessions = fixture.server.sessions, marks = fixture.server.marks
            try fixture.run(&replayed)
            XCTAssertEqual(replayed, record)
            XCTAssertEqual(fixture.server.sessions, sessions)
            XCTAssertEqual(fixture.server.marks, marks)
            XCTAssertEqual(fixture.server.objects["Docs/Tree/new"], arrival)
            XCTAssertEqual(replayed.summary, partial ? [.deleted: 1, .stopped: 6] : [.stopped: 7])
            try fixture.outbox.removeSettled(domain: fixture.owner)
            XCTAssertEqual(try fixture.outbox.records(), [])
            fixture.remove()
            fixture = try DeletionFixture()
        }
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
        for state in [PendingItemDeletion.State.attempting, .closeAcknowledged] {
            var skipped = initial.finishing([.cannotDelete])
            skipped.current = state
            refuse(initial, skipped)
        }
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
        for state in [PendingItemDeletion.State.attempting, .closeAcknowledged] {
            var skipped = acknowledged.finishing([.unconfirmed])
            skipped.current = state
            refuse(acknowledged, skipped)
            var advanced = deleted
            advanced.current = state
            refuse(acknowledged, advanced)
        }
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

    func testCatalogAdmissionSurvivesStorageAndCannotBeReplacedOnReplay() throws {
        let evidence = DeletionCatalogAdmission(epoch: Data(repeating: 1, count: 16), sequence: 7, listingGeneration: 3)
        let views = try fixture.views().map {
            try DeletionView(domain: $0.domain, folder: XCTUnwrap(RelativePath($0.folder)), items: $0.items,
                             catalogAdmission: evidence)
        }
        let record = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner, request: fixture.request,
            traversal: fixture.traversal(), views: views, protectedRoots: [], recursive: true)
        fixture.outbox = try fixture.makeOutbox()
        XCTAssertEqual(try fixture.outbox.records(), [record])
        XCTAssertEqual(record.plan.views.map(\.catalogAdmission), [evidence, evidence])
        XCTAssertEqual(try fixture.prepare(), record)
    }

    func testOlderViewDecodesWithoutInventingCatalogEvidence() throws {
        let record = try fixture.prepare()
        let encoded = try JSONEncoder().encode(record.plan)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let views = try XCTUnwrap(values["views"] as? [[String: Any]])
        XCTAssertTrue(views.allSatisfy { $0["catalogAdmission"] == nil })
        XCTAssertTrue(try JSONDecoder().decode(DeletionPlan.self, from: encoded).views
            .allSatisfy { $0.catalogAdmission == nil })
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
        for evidence in [
            ["epoch": Data(repeating: 1, count: 15).base64EncodedString(), "sequence": 7, "listingGeneration": 3],
            ["epoch": Data(repeating: 1, count: 16).base64EncodedString(), "sequence": -1, "listingGeneration": 3],
            ["epoch": Data(repeating: 1, count: 16).base64EncodedString(), "sequence": Catalog.maxLastSeq + 1, "listingGeneration": 3],
            ["epoch": Data(repeating: 1, count: 16).base64EncodedString(), "sequence": 7, "listingGeneration": -1],
            ["sequence": 7, "listingGeneration": 3]
        ] as [[String: Any]] {
            try rewrite(planURL) { values in
                var views = values["views"] as! [[String: Any]]
                views[0]["catalogAdmission"] = evidence
                values["views"] = views
            }
            try assertRejected()
        }
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
