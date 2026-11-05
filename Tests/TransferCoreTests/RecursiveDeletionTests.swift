import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class RecursiveDeletionTests: XCTestCase {
    private var fixture: DeletionFixture!
    private var server: DeletionServer { fixture.server }

    override func setUpWithError() throws { fixture = try DeletionFixture() }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func reset() throws {
        fixture.remove()
        fixture = try DeletionFixture()
    }

    private func run(_ record: inout PendingDeletion) throws { try fixture.run(&record) }

    private func outcome(_ name: String, _ record: PendingDeletion) -> DeletionNodeOutcome? {
        fixture.outcome("Docs/Tree/" + name, record)
    }

    func testPopulatedFolderDeletesEachChildBeforeItsParentInItsOwnSession() throws {
        var record = try fixture.prepare()
        XCTAssertEqual(record.plan.nodes.map(\.path), ["Docs/Tree/Empty", "Docs/Tree/Sub/c", "Docs/Tree/Sub/d",
                                                       "Docs/Tree/Sub", "Docs/Tree/a", "Docs/Tree/b", "Docs/Tree"])
        let neighbor = server.objects["Docs/neighbor"]
        try run(&record)
        XCTAssertTrue(record.isSettled)
        XCTAssertEqual(record.summary, [.deleted: 7])
        XCTAssertEqual(server.marks, record.plan.nodes.map(\.path))
        XCTAssertEqual(server.closes, server.marks)
        XCTAssertEqual(server.targets, server.marks)
        XCTAssertEqual(server.sessions, 7)
        XCTAssertEqual(Set(server.objects.keys), ["", "Docs", "Docs/neighbor"])
        XCTAssertEqual(server.objects["Docs/neighbor"], neighbor)
        XCTAssertEqual(try fixture.outbox.records(), [record])
        XCTAssertTrue(record.blocksWrites)
        XCTAssertEqual(try record.results(domain: fixture.owner).map(\.outcome), Array(repeating: .deleted, count: 7))
        XCTAssertEqual(try record.results(domain: fixture.neighbor).map(\.item.path), ["Docs/Tree", "Docs/Tree/a"])
    }

    func testDecomposedCatalogPathsSettleAgainstComposedServerNames() throws {
        server.objects["Docs/Tree/Caf\u{e9}"] = server.objects.removeValue(forKey: "Docs/Tree/b")
        let decomposed = try XCTUnwrap(RelativePath("Tree/Cafe\u{301}"))
        let views = try fixture.views().map { view in
            DeletionView(domain: view.domain, folder: try XCTUnwrap(RelativePath(view.folder)), items: view.items.map {
                $0.path != "Tree/b" ? $0 : DeletionViewItem(item: $0.item, path: decomposed, contentVersion: "v1")
            })
        }
        var record = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
                                                request: fixture.request, traversal: fixture.traversal(),
                                                views: views, protectedRoots: [], recursive: true)
        try run(&record)
        XCTAssertEqual(record.summary, [.deleted: 7])
        let results = try record.results(domain: fixture.owner)
        XCTAssertEqual(results.first { $0.item.item == fixture.items["Docs/Tree/b"] }?.outcome, .deleted)
    }

    func testProtectedParentTimeChangesSurviveRestartWithoutChangingAdmission() throws {
        var record = try fixture.prepare()
        let plan = record.plan, server = self.server
        server.changesParentCreationTimes = true
        server.afterClose["Docs/Tree/Empty"] = { [unowned server] in server.connectFailure = DeletionFixture.Fault.connection }
        XCTAssertThrowsError(try run(&record))
        XCTAssertEqual(record.progress.next, 1)
        XCTAssertEqual(record.progress.parentUpdates?.count, 3)
        fixture.outbox = try fixture.makeOutbox()
        record = try XCTUnwrap(fixture.outbox.records().first)
        server.connectFailure = nil
        try run(&record)
        XCTAssertEqual(record.plan, plan)
        XCTAssertEqual(record.summary, [.deleted: 7])
        XCTAssertEqual(server.marks, plan.nodes.map(\.path))
        XCTAssertEqual(Set(server.objects.keys), ["", "Docs", "Docs/neighbor"])
    }

    func testSameIDParentReplacementAfterCheckpointIsNotAccepted() throws {
        var record = try fixture.prepare()
        let server = self.server
        server.changesParentCreationTimes = true
        server.afterClose["Docs/Tree/Empty"] = { [unowned server] in server.connectFailure = DeletionFixture.Fault.connection }
        XCTAssertThrowsError(try run(&record))
        let parent = try XCTUnwrap(server.objects["Docs/Tree"]?.identity)
        let replacement = ItemDeletionEvidence.directory(try RemoteFileIdentity(fileID: parent.fileID,
            birthMicroseconds: parent.birthMicroseconds + 1))
        server.objects["Docs/Tree"] = replacement
        server.connectFailure = nil
        fixture.outbox = try fixture.makeOutbox()
        try run(&record)
        XCTAssertEqual(server.marks, ["Docs/Tree/Empty"])
        XCTAssertEqual(server.objects["Docs/Tree"], replacement)
        XCTAssertNotNil(server.objects["Docs/Tree/Sub/c"])
        XCTAssertNotEqual(record.selectedOutcome, .deleted)
    }

    func testLostParentCheckpointKeepsAcknowledgedDeletionUnconfirmed() throws {
        var record = try fixture.prepare()
        server.changesParentCreationTimes = true
        server.parentCheckpointFailure = DeletionFixture.Fault.connection
        XCTAssertThrowsError(try run(&record))
        XCTAssertEqual(record.progress.current, .closeAcknowledged)
        XCTAssertEqual(record.progress.next, 0)
        XCTAssertNil(record.progress.parentUpdates)
        server.parentCheckpointFailure = nil
        fixture.outbox = try fixture.makeOutbox()
        try run(&record)
        XCTAssertEqual(outcome("Empty", record), .unconfirmed)
        XCTAssertEqual(server.marks, ["Docs/Tree/Empty"])
        XCTAssertNotNil(server.objects["Docs/Tree/Sub/c"])
    }

    func testArrivingChildIsNeverAddedAndItsFoldersRemain() throws {
        var record = try fixture.prepare()
        server.changesParentCreationTimes = true
        let arrival = ItemDeletionEvidence.file(try DeletionFixture.version(40))
        let server = self.server
        server.afterClose["Docs/Tree/Sub/d"] = { [unowned server] in server.objects["Docs/Tree/Sub/new"] = arrival }
        try run(&record)
        XCTAssertEqual(record.summary, [.deleted: 5, .directoryNotEmpty: 2])
        XCTAssertEqual(outcome("Sub", record), .directoryNotEmpty)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        XCTAssertEqual(server.marks, ["Docs/Tree/Empty", "Docs/Tree/Sub/c", "Docs/Tree/Sub/d", "Docs/Tree/a",
                                      "Docs/Tree/b"])
        XCTAssertEqual(server.sessions, 6)
        XCTAssertEqual(server.objects["Docs/Tree/Sub/new"], arrival)
        XCTAssertEqual(server.objects["Docs/Tree/Sub"]?.identity.fileID, record.plan.nodes[3].evidence.identity.fileID)
        XCTAssertEqual(server.objects["Docs/Tree"]?.identity.fileID, record.plan.selected.evidence.identity.fileID)
        XCTAssertFalse(record.plan.nodes.contains { $0.path == "Docs/Tree/Sub/new" })
        let sessions = server.sessions
        try run(&record)
        XCTAssertEqual(server.sessions, sessions)
    }

    func testChangedAndReplacedChildrenSurviveWhileTheirSiblingsAreDeleted() throws {
        var record = try fixture.prepare()
        let replacement = ItemDeletionEvidence.file(try DeletionFixture.version(50))
        let changed = ItemDeletionEvidence.file(try DeletionFixture.version(16, modified: 30))
        server.objects["Docs/Tree/a"] = replacement
        server.objects["Docs/Tree/b"] = changed
        try run(&record)
        XCTAssertEqual(outcome("a", record), .replaced)
        XCTAssertEqual(outcome("b", record), .changed)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        XCTAssertEqual(record.summary, [.deleted: 4, .replaced: 1, .changed: 1, .directoryNotEmpty: 1])
        XCTAssertEqual(server.objects["Docs/Tree/a"], replacement)
        XCTAssertEqual(server.objects["Docs/Tree/b"], changed)
        XCTAssertFalse(server.marks.contains("Docs/Tree/a") || server.marks.contains("Docs/Tree/b"))
        XCTAssertEqual(try record.results(domain: fixture.neighbor).map(\.outcome), [.directoryNotEmpty, .replaced])
    }

    func testAdmissionRefusesIncompleteOrInconsistentEvidence() throws {
        let complete = try fixture.traversal()
        func path(_ value: String) -> RelativePath { RelativePath(value)! }
        func with(objects: [DeletionTraversal.Object]? = nil,
                  listings: [DeletionTraversal.Listing]? = nil) -> DeletionTraversal {
            DeletionTraversal(selected: complete.selected, parents: complete.parents,
                              objects: objects ?? complete.objects, listings: listings ?? complete.listings)
        }
        func refuse(_ traversal: DeletionTraversal, recursive: Bool = true, roots: [RelativePath] = [],
                    _ expected: ItemDeletionError, line: UInt = #line) {
            XCTAssertThrowsError(try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
                request: fixture.request, traversal: traversal, views: fixture.views(), protectedRoots: roots,
                recursive: recursive), line: line) { XCTAssertEqual($0 as? ItemDeletionError, expected, line: line) }
        }
        let sub = "Docs/Tree/Sub"
        refuse(with(listings: complete.listings.map {
            $0.path.string == sub ? DeletionTraversal.Listing(path: $0.path, listing: ItemDeletionListing(
                entries: $0.listing.entries, isComplete: false)) : $0
        }), .unresolved)
        refuse(with(listings: complete.listings.filter { $0.path.string != sub }), .unresolved)
        refuse(with(objects: complete.objects.filter { $0.path.string != sub + "/c" }), .unresolved)
        let stranger = ItemDeletionEvidence.file(try DeletionFixture.version(70))
        refuse(with(objects: complete.objects.map {
            $0.path.string == sub + "/c" ? DeletionTraversal.Object(path: $0.path, evidence: stranger) : $0
        }), .unresolved)
        refuse(with(objects: complete.objects + [DeletionTraversal.Object(path: path("Docs/neighbor"),
                                                                          evidence: server.objects["Docs/neighbor"]!)]),
               .invalidRequest)
        refuse(with(listings: complete.listings + [DeletionTraversal.Listing(path: path("Docs/Tree/a"),
            listing: ItemDeletionListing(entries: [], isComplete: true))]), .invalidRequest)
        refuse(complete, roots: [path(sub)], .invalidRequest)
        refuse(complete, roots: [path("docs/TREE")], .invalidRequest)
        refuse(complete, recursive: false, .directoryNotEmpty)
        let crowd = try (0...DeletionPlan.maxNodes).map {
            DeletionTraversal.Object(path: path("Docs/Tree/x\($0)"), evidence: .file(try DeletionFixture.version(1_000 + UInt64($0))))
        }
        XCTAssertThrowsError(try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: fixture.request, traversal: with(objects: crowd), views: fixture.views(), protectedRoots: [],
            recursive: true)) { XCTAssertEqual($0 as? SourceFailure, .tooManyEntries) }

        server.objects["Docs/Tree/link"] = server.objects["Docs/Tree/a"]
        refuse(try fixture.traversal(), .unsupported)
        server.objects["Docs/Tree/link"] = nil
        for name in [".tinymounter-\(UUID().uuidString).recovery", "notes.sqlite"] {
            server.objects[sub + "/" + name] = .file(try DeletionFixture.version(71))
            refuse(try fixture.traversal(), .unsupported)
            server.objects[sub + "/" + name] = nil
        }
        XCTAssertEqual(try fixture.storedFiles(), [])
        XCTAssertEqual(server.sessions, 0)
        // The owner's own location root and a share-root location contain the selection; neither is inside it.
        let record = try fixture.outbox.prepare(endpoint: fixture.endpoint, owner: fixture.owner,
            request: fixture.request, traversal: complete, views: fixture.views(), protectedRoots: [path("Docs"), .root],
            recursive: true)
        XCTAssertEqual(record.plan.nodes.count, 7)
    }

    func testInterruptedCheckpointResumesOnlyTheAdmittedObjectAfterRestart() throws {
        for afterWrite in [false, true] {
            try reset()
            let fixture = self.fixture!
            var record = try fixture.prepare()
            server.onList["Docs/Tree/Sub"] = { [unowned fixture] in
                if afterWrite { fixture.syncFails = true } else { fixture.setWritable(false) }
            }
            XCTAssertThrowsError(try run(&record))
            fixture.setWritable(true)
            XCTAssertEqual(record.progress.next, 1)
            XCTAssertEqual(try fixture.outbox.records().first?.progress.current, afterWrite ? .attempting : .prepared)
            XCTAssertEqual(server.marks, ["Docs/Tree/Empty"])
            fixture.outbox = try fixture.makeOutbox()
            var restarted = try XCTUnwrap(fixture.outbox.records().first)
            try fixture.run(&restarted)
            XCTAssertEqual(restarted.plan, record.plan)
            XCTAssertEqual(restarted.summary, [.deleted: 7])
            XCTAssertEqual(server.marks.filter { $0 == "Docs/Tree/Sub/c" }.count, 1)
        }
    }

    func testLostCloseReplyIsUnconfirmedAndALaterReplacementSurvives() throws {
        var record = try fixture.prepare()
        server.lostCloses = ["Docs/Tree/a", "Docs/Tree/b"]
        XCTAssertThrowsError(try run(&record))
        XCTAssertEqual(record.progress.current, .attempting)
        let replacement = ItemDeletionEvidence.file(try DeletionFixture.version(60))
        server.objects["Docs/Tree/a"] = replacement
        XCTAssertThrowsError(try run(&record))
        XCTAssertEqual(outcome("a", record), .unconfirmed)
        try run(&record)
        XCTAssertEqual(outcome("b", record), .unconfirmed)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        XCTAssertTrue(record.hasUnconfirmed)
        XCTAssertEqual(server.objects["Docs/Tree/a"], replacement)
        XCTAssertEqual(server.marks.filter { $0 == "Docs/Tree/a" }.count, 1)
        XCTAssertEqual(server.marks.filter { $0 == "Docs/Tree/b" }.count, 1)
    }

    func testPostCloseConfirmationRefusalsKeepUncertainty() throws {
        for failure in [ItemDeletionError.sharingViolation, .accessDenied, .cannotDelete, .directoryNotEmpty, .unsupported] {
            try reset()
            let server = self.server
            let path = "Docs/Tree/a"
            var record = try fixture.prepare(path, recursive: false)
            let replacement = ItemDeletionEvidence.file(try DeletionFixture.version(60))
            server.afterClose[path] = { [unowned server] in
                server.objects[path] = replacement
                server.inspectFailures[path] = failure
            }
            try run(&record)
            XCTAssertEqual(record.summary, [.unconfirmed: 1])
            XCTAssertTrue(record.hasUnconfirmed)
            XCTAssertEqual(server.marks, [path])
            XCTAssertEqual(server.closes, [path])
            XCTAssertEqual(server.objects[path], replacement)
            for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
            XCTAssertTrue(record.isComplete)
            XCTAssertTrue(record.isPending)
            XCTAssertEqual(try fixture.outbox.pendingCount(domain: fixture.owner), 1)
            fixture.outbox = try fixture.makeOutbox()
            XCTAssertEqual(try fixture.outbox.records(), [record])
            let sessions = server.sessions
            try run(&record)
            XCTAssertEqual(server.sessions, sessions)
        }
    }

    func testCloseFailureAfterSuccessfulMarkDoesNotProveSurvival() throws {
        let path = "Docs/Tree/a"
        var record = try fixture.prepare(path, recursive: false)
        server.closeFailures[path] = ItemDeletionError.sharingViolation
        try run(&record)
        XCTAssertEqual(record.summary, [.unconfirmed: 1])
        XCTAssertTrue(record.hasUnconfirmed)
        XCTAssertNil(server.objects[path])
        XCTAssertEqual(server.marks, [path])
        XCTAssertEqual(server.closes, [path])
    }

    func testRecoveryUsesFreshIdentityEvidenceToProveSurvival() throws {
        for expected in [DeletionNodeOutcome.changed, .moved, .cannotDelete] {
            try reset()
            let path = "Docs/Tree/a"
            var record = try fixture.prepare(path, recursive: false)
            server.markFailures[path] = DeletionFixture.Fault.connection
            XCTAssertThrowsError(try run(&record))
            XCTAssertEqual(record.progress.current, .attempting)
            switch expected {
            case .changed: server.objects[path] = .file(try DeletionFixture.version(15, modified: 30))
            case .moved: server.objects["Docs/Tree/moved"] = server.objects.removeValue(forKey: path)
            case .cannotDelete: server.markFailures[path] = ItemDeletionError.cannotDelete
            default: XCTFail("Unexpected survival outcome")
            }
            try run(&record)
            XCTAssertEqual(record.summary, [expected: 1])
            XCTAssertFalse(record.hasUnconfirmed)
            let surviving = try XCTUnwrap(server.objects[expected == .moved ? "Docs/Tree/moved" : path])
            XCTAssertEqual(surviving.identity, record.plan.selected.evidence.identity)
            XCTAssertEqual(server.closes, [])
        }
    }

    func testUnconfirmedChildDoesNotKeepAnEmptyParent() throws {
        var record = try fixture.prepare()
        server.lostCloses = ["Docs/Tree/b"]
        XCTAssertThrowsError(try run(&record))
        try run(&record)
        XCTAssertEqual(outcome("b", record), .unconfirmed)
        XCTAssertEqual(record.selectedOutcome, .deleted)
        XCTAssertEqual(record.summary, [.deleted: 6, .unconfirmed: 1])
        XCTAssertEqual(server.marks.count, 7)
    }

    func testCloseAcknowledgementMustBeDurableBeforeAbsenceConfirmsDeletion() throws {
        for afterWrite in [false, true] {
            try reset()
            let fixture = self.fixture!
            var record = try fixture.prepare()
            server.afterClose["Docs/Tree/a"] = { [unowned fixture] in
                if afterWrite { fixture.syncFails = true } else { fixture.setWritable(false) }
            }
            XCTAssertThrowsError(try run(&record))
            fixture.setWritable(true)
            fixture.outbox = try fixture.makeOutbox()
            var restarted = try XCTUnwrap(fixture.outbox.records().first)
            XCTAssertEqual(restarted.progress.current, afterWrite ? .closeAcknowledged : .attempting)
            try fixture.run(&restarted)
            XCTAssertEqual(outcome("a", restarted), afterWrite ? .deleted : .unconfirmed)
            XCTAssertEqual(restarted.selectedOutcome, .deleted)
            XCTAssertEqual(server.marks.filter { $0 == "Docs/Tree/a" }.count, 1)
            XCTAssertEqual(server.closes.filter { $0 == "Docs/Tree/a" }.count, 1)
        }
    }

    func testStaleCallerAdoptsDurableProgressWithoutOpeningASession() throws {
        var record = try fixture.prepare()
        var stale = record
        try run(&record)
        let sessions = server.sessions
        server.objects["Docs/Tree"] = .directory(try DeletionFixture.identity(80))
        try run(&stale)
        XCTAssertEqual(stale, record)
        XCTAssertEqual(server.sessions, sessions)
        try fixture.outbox.finishDomain(fixture.owner, record: &stale)
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        XCTAssertEqual(record, stale)
        XCTAssertEqual(record.progress.finishedDomains, [fixture.owner])
    }

    func testAnotherConnectionOrDomainCannotResumeTheOperation() throws {
        var record = try fixture.prepare()
        for (address, domain) in [("//other@fixture/share", fixture.owner), ("//account@fixture/other", fixture.owner),
                                  ("//account@elsewhere/share", fixture.owner),
                                  ("//account@fixture/share", fixture.neighbor)] {
            XCTAssertThrowsError(try RecursiveDeletionTransaction.run(&record, outbox: fixture.outbox,
                endpoint: XCTUnwrap(ShareAddress(address)), owner: domain, session: server.session)) {
                XCTAssertEqual($0 as? ItemDeletionError, .invalidRequest)
            }
        }
        XCTAssertEqual(server.sessions, 0)
        XCTAssertNil(try fixture.outbox.replay(endpoint: XCTUnwrap(ShareAddress("//account@elsewhere/share")),
                                               owner: fixture.owner, request: fixture.request))
        try RecursiveDeletionTransaction.run(&record, outbox: fixture.outbox,
                                             endpoint: XCTUnwrap(ShareAddress("//ACCOUNT@Fixture/SHARE")),
                                             owner: fixture.owner, session: server.session)
        XCTAssertEqual(record.summary, [.deleted: 7])
    }

    func testTransientFailuresStopWithoutAnOutcome() throws {
        var record = try fixture.prepare()
        server.connectFailure = DeletionFixture.Fault.connection
        XCTAssertThrowsError(try run(&record))
        server.connectFailure = nil
        server.lookups["Docs/Tree/Empty"] = .deletePending
        XCTAssertThrowsError(try run(&record)) { XCTAssertEqual($0 as? ItemDeletionError, .deletePending) }
        server.lookups = [:]
        server.incomplete = ["Docs/Tree"]
        XCTAssertThrowsError(try run(&record)) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(record.progress, DeletionProgress())
        XCTAssertEqual(server.marks, [])
        server.incomplete = []
        try run(&record)
        XCTAssertEqual(record.summary, [.deleted: 7])
    }

    func testStopLeavesTheNodeInFlightUnconfirmedAndTheRestUntouched() throws {
        var record = try fixture.prepare()
        server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try run(&record))
        var stale = record
        try fixture.outbox.stop(&record)
        XCTAssertTrue(record.isSettled)
        XCTAssertEqual(record.plan.nodes.indices.map(record.outcome(at:)),
                       [.deleted, .unconfirmed, .stopped, .stopped, .stopped, .stopped, .stopped])
        let sessions = server.sessions
        try run(&stale)
        XCTAssertEqual(stale, record)
        XCTAssertEqual(server.sessions, sessions)
        try fixture.outbox.stop(&stale)
        XCTAssertEqual(stale, record)
        XCTAssertNotNil(server.objects["Docs/Tree/Sub/d"])
        XCTAssertNotNil(server.objects["Docs/Tree"])

        try reset()
        var untouched = try fixture.prepare()
        server.connectFailure = DeletionFixture.Fault.connection
        XCTAssertThrowsError(try run(&untouched))
        try fixture.outbox.stop(&untouched)
        XCTAssertEqual(untouched.summary, [.stopped: 7])
        XCTAssertFalse(untouched.hasUnconfirmed)
    }

    func testReplacedFolderFinishesItsRemainingChildrenWithoutSessions() throws {
        let server = self.server
        server.objects["Docs/Tree/Sub/e"] = .file(try DeletionFixture.version(17))
        var record = try fixture.prepare()
        let replacement = ItemDeletionEvidence.directory(try DeletionFixture.identity(81))
        server.afterSession["Docs/Tree/Sub/c"] = { [unowned server] in server.objects["Docs/Tree/Sub"] = replacement }
        try run(&record)
        XCTAssertEqual(record.plan.nodes.map(\.path), ["Docs/Tree/Empty", "Docs/Tree/Sub/c", "Docs/Tree/Sub/d",
                                                       "Docs/Tree/Sub/e", "Docs/Tree/Sub", "Docs/Tree/a",
                                                       "Docs/Tree/b", "Docs/Tree"])
        XCTAssertEqual(record.plan.nodes.indices.map(record.outcome(at:)),
                       [.deleted, .deleted, .parentChanged, .parentChanged, .replaced, .deleted, .deleted,
                        .directoryNotEmpty])
        XCTAssertEqual(server.marks, ["Docs/Tree/Empty", "Docs/Tree/Sub/c", "Docs/Tree/a", "Docs/Tree/b"])
        XCTAssertEqual(server.targets, ["Docs/Tree/Empty", "Docs/Tree/Sub/c", "Docs/Tree/Sub/d", "Docs/Tree/Sub",
                                        "Docs/Tree/a", "Docs/Tree/b"])
        XCTAssertNotNil(server.objects["Docs/Tree/Sub/d"])
        XCTAssertNotNil(server.objects["Docs/Tree/Sub/e"])
    }

    func testServerRefusalsFinishOnlyTheirItem() throws {
        var record = try fixture.prepare()
        server.markFailures = ["Docs/Tree/a": ItemDeletionError.sharingViolation,
                               "Docs/Tree/b": ItemDeletionError.cannotDelete]
        try run(&record)
        XCTAssertEqual(outcome("a", record), .sharingViolation)
        XCTAssertEqual(outcome("b", record), .cannotDelete)
        XCTAssertEqual(record.selectedOutcome, .directoryNotEmpty)
        XCTAssertNotNil(server.objects["Docs/Tree/a"])
        XCTAssertNotNil(server.objects["Docs/Tree/b"])
        XCTAssertFalse(server.closes.contains("Docs/Tree/a") || server.closes.contains("Docs/Tree/b"))

        // After a possible request, a refusal to open the name no longer proves the original survived.
        try reset()
        var uncertain = try fixture.prepare()
        server.lostCloses = ["Docs/Tree/Empty"]
        XCTAssertThrowsError(try run(&uncertain))
        server.objects["Docs/Tree/Empty"] = .directory(try DeletionFixture.identity(82))
        server.inspectFailures["Docs/Tree/Empty"] = ItemDeletionError.sharingViolation
        try run(&uncertain)
        XCTAssertEqual(outcome("Empty", uncertain), .unconfirmed)
        XCTAssertEqual(uncertain.selectedOutcome, .directoryNotEmpty)
    }

    func testSingleFileAndEmptyFolderAreOneNodeOperations() throws {
        var file = try fixture.prepare("Docs/Tree/a", recursive: false)
        XCTAssertEqual(file.plan.nodes.map(\.path), ["Docs/Tree/a"])
        try run(&file)
        XCTAssertEqual(file.summary, [.deleted: 1])
        XCTAssertEqual(try file.results(domain: fixture.owner).map(\.item.item), [fixture.items["Docs/Tree/a"]!])
        XCTAssertEqual(try file.results(domain: fixture.neighbor).map(\.item.item), [fixture.neighborItems["Docs/Tree/a"]!])
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &file) }
        var folder = try fixture.prepare("Docs/Tree/Empty", recursive: false)
        try run(&folder)
        XCTAssertEqual(folder.selectedOutcome, .deleted)
        XCTAssertEqual(server.marks, ["Docs/Tree/a", "Docs/Tree/Empty"])
    }
}

/// Owner location "Docs" and a neighbor location at the share root both show "Docs/Tree".
final class DeletionFixture {
    enum Fault: Error { case connection, missing, persistence }

    static let tree = ["Docs/Tree", "Docs/Tree/Empty", "Docs/Tree/Sub", "Docs/Tree/Sub/c", "Docs/Tree/Sub/d",
                       "Docs/Tree/a", "Docs/Tree/b"]
    static let rows = tree + ["Docs/neighbor"]

    let owner = UUID().uuidString
    let neighbor = UUID().uuidString
    let endpoint = ShareAddress("//account@fixture/share")!
    let directory: URL
    let server = DeletionServer()
    var outbox: DeletionOutbox!
    var syncFails = false
    /// Catalog item IDs by share path, for the owner and for the neighbor.
    var items: [String: String] = [:]
    var neighborItems: [String: String] = [:]

    var outboxDirectory: URL { directory.appending(path: "Deletions", directoryHint: .isDirectory) }
    var request: DeletionRequest {
        DeletionRequest(item: items["Docs/Tree"]!, contentVersion: "v1", metadataVersion: "7", eventVersion: Data([1]))
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        server.objects = try [
            "": .directory(Self.identity(1)), "Docs": .directory(Self.identity(2)),
            "Docs/Tree": .directory(Self.identity(10)), "Docs/Tree/Empty": .directory(Self.identity(11)),
            "Docs/Tree/Sub": .directory(Self.identity(12)), "Docs/Tree/Sub/c": .file(Self.version(13)),
            "Docs/Tree/Sub/d": .file(Self.version(14)), "Docs/Tree/a": .file(Self.version(15)),
            "Docs/Tree/b": .file(Self.version(16)), "Docs/neighbor": .file(Self.version(90))
        ]
        for path in Self.rows { items[path] = UUID().uuidString }
        for path in ["Docs/Tree", "Docs/Tree/a"] { neighborItems[path] = UUID().uuidString }
        outbox = try makeOutbox()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func identity(_ id: UInt64) throws -> RemoteFileIdentity {
        try RemoteFileIdentity(fileID: id, birthMicroseconds: 10)
    }

    static func version(_ id: UInt64, modified: UInt64 = 20) throws -> RemoteFileVersion {
        try RemoteFileVersion(identity: identity(id), size: 12,
                            modifiedMicroseconds: modified, changedMicroseconds: 40, attributes: 32)
    }

    func makeOutbox() throws -> DeletionOutbox {
        try DeletionOutbox(directory: outboxDirectory, directorySync: { [unowned self] fd in
            if self.syncFails {
                self.syncFails = false
                throw Fault.persistence
            }
            guard fsync(fd) == 0 else { throw Fault.persistence }
        })
    }

    func setWritable(_ writable: Bool) { chmod(outboxDirectory.path, writable ? 0o700 : 0o500) }

    func storedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: outboxDirectory.path).sorted()
    }

    func views(selected: String = "Docs/Tree") throws -> [DeletionView] {
        func inside(_ path: String) -> Bool { path == selected || path.hasPrefix(selected + "/") }
        let owned = try Self.rows.filter(inside).map { path in
            DeletionViewItem(item: items[path]!, path: try XCTUnwrap(RelativePath(String(path.dropFirst(5)))),
                             contentVersion: "v1")
        }
        let shared = try ["Docs/Tree", "Docs/Tree/a"].filter(inside).map { path in
            DeletionViewItem(item: neighborItems[path]!, path: try XCTUnwrap(RelativePath(path)), contentVersion: "v1")
        }
        return [DeletionView(domain: owner, folder: try XCTUnwrap(RelativePath("Docs")), items: owned),
                DeletionView(domain: neighbor, folder: .root, items: shared)]
    }

    /// What the parent's protected traversal would return for the server's current state.
    func traversal(_ selected: String = "Docs/Tree") throws -> DeletionTraversal {
        let parents = try DeletionSession(server).protectParents(of: selected)
        server.targets.removeLast()
        let paths = server.objects.keys.filter { $0 == selected || $0.hasPrefix(selected + "/") }.sorted()
        let objects = try paths.map {
            DeletionTraversal.Object(path: try XCTUnwrap(RelativePath($0)), evidence: server.objects[$0]!)
        }
        let listings = try paths.filter { server.objects[$0]!.kind == .folder }.map {
            DeletionTraversal.Listing(path: try XCTUnwrap(RelativePath($0)), listing: ItemDeletionListing(
                entries: server.children($0), isComplete: !server.incomplete.contains($0)))
        }
        return DeletionTraversal(selected: try XCTUnwrap(RelativePath(selected)), parents: parents,
                                 objects: objects, listings: listings)
    }

    func prepare(_ selected: String = "Docs/Tree", recursive: Bool = true) throws -> PendingDeletion {
        let request = selected == "Docs/Tree" ? self.request
            : DeletionRequest(item: items[selected]!, contentVersion: "v1", metadataVersion: "7", eventVersion: Data([1]))
        return try outbox.prepare(endpoint: endpoint, owner: owner, request: request, traversal: traversal(selected),
                                  views: views(selected: selected), protectedRoots: [], recursive: recursive)
    }

    func run(_ record: inout PendingDeletion) throws {
        try RecursiveDeletionTransaction.run(&record, outbox: outbox, endpoint: endpoint, owner: owner,
                                             session: server.session)
    }

    func outcome(_ path: String, _ record: PendingDeletion) -> DeletionNodeOutcome? {
        record.plan.nodes.firstIndex { $0.path == path }.flatMap(record.outcome(at:))
    }
}

/// Paths are relative to the share root; each session protects one target, like the SMB adapter.
final class DeletionServer {
    var objects: [String: ItemDeletionEvidence] = [:]
    var incomplete: Set<String> = []
    var lookups: [String: ItemDeletionLookup] = [:]
    var inspectFailures: [String: Error] = [:]
    var markFailures: [String: Error] = [:]
    var closeFailures: [String: Error] = [:]
    var lostCloses: Set<String> = []
    var onList: [String: () -> Void] = [:]
    var afterClose: [String: () -> Void] = [:]
    var afterSession: [String: () -> Void] = [:]
    var connectFailure: Error?
    var parentCheckpointFailure: Error?
    var changesParentCreationTimes = false
    var sessions = 0
    var targets: [String] = []
    var marks: [String] = []
    var closes: [String] = []

    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }

    func children(_ path: String) -> [ItemDeletionEntry] {
        objects.keys.filter { !$0.isEmpty && $0 != path && Self.parent($0) == path }.sorted().map {
            ItemDeletionEntry(name: String($0.split(separator: "/").last!), identity: objects[$0]!.identity)
        }
    }

    func session(_ body: (DeletionRemote) throws -> Void) throws {
        if let connectFailure { throw connectFailure }
        sessions += 1
        let remote = DeletionSession(self)
        defer { if let target = remote.target { afterSession.removeValue(forKey: target)?() } }
        try body(remote)
    }
}

final class DeletionSession: DeletionRemote {
    private let server: DeletionServer
    fileprivate var target: String?
    private var marked = false

    init(_ server: DeletionServer) { self.server = server }

    func protectParents(of path: String) throws -> [ItemDeletionParent] {
        guard target == nil else { throw ItemDeletionError.invalidRequest }
        target = path
        server.targets.append(path)
        let components = path.split(separator: "/").map(String.init)
        return try (0..<components.count).map { depth in
            let prefix = components.prefix(depth).joined(separator: "/")
            guard case .directory(let identity)? = server.objects[prefix] else { throw DeletionFixture.Fault.missing }
            return ItemDeletionParent(path: prefix, name: depth == 0 ? "" : components[depth - 1], identity: identity)
        }
    }

    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
        guard path == target else { throw ItemDeletionError.invalidRequest }
        if let failure = server.inspectFailures[path] { throw failure }
        if let lookup = server.lookups[path] { return lookup }
        if let object = server.objects[path] { return .present(object) }
        return server.objects[DeletionServer.parent(path)] == nil ? .pathNotFound : .nameNotFound
    }

    func parentsAfterDeletion(_ parents: [ItemDeletionParent]) throws -> [ItemDeletionParent] {
        if let failure = server.parentCheckpointFailure { throw failure }
        return try parents.map { parent in
            guard case .directory(let identity)? = server.objects[parent.path] else { throw DeletionFixture.Fault.missing }
            return ItemDeletionParent(path: parent.path, name: parent.name, identity: identity)
        }
    }

    func list(path: String) throws -> ItemDeletionListing {
        guard let target, target == path || DeletionServer.parent(target) == path else {
            throw ItemDeletionError.invalidRequest
        }
        server.onList.removeValue(forKey: path)?()
        return ItemDeletionListing(entries: server.children(path), isComplete: !server.incomplete.contains(path))
    }

    func markDeletion(path: String) throws {
        guard path == target else { throw ItemDeletionError.invalidRequest }
        server.marks.append(path)
        if let failure = server.markFailures.removeValue(forKey: path) { throw failure }
        if case .directory? = server.objects[path], !server.children(path).isEmpty {
            throw ItemDeletionError.directoryNotEmpty
        }
        marked = true
    }

    func closeTarget(path: String) throws {
        guard path == target, marked else { throw ItemDeletionError.invalidRequest }
        server.closes.append(path)
        server.objects[path] = nil
        if server.changesParentCreationTimes {
            let components = path.split(separator: "/")
            for depth in 0..<components.count {
                let prefix = components.prefix(depth).joined(separator: "/")
                guard case .directory(let identity)? = server.objects[prefix] else { throw DeletionFixture.Fault.missing }
                server.objects[prefix] = .directory(try RemoteFileIdentity(fileID: identity.fileID,
                    birthMicroseconds: identity.birthMicroseconds + 1))
            }
        }
        if server.lostCloses.remove(path) != nil { throw DeletionFixture.Fault.connection }
        if let failure = server.closeFailures.removeValue(forKey: path) { throw failure }
        server.afterClose.removeValue(forKey: path)?()
    }
}
