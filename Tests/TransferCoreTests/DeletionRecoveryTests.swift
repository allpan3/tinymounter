import Foundation
import XCTest
@testable import TransferCore

final class DeletionRecoveryTests: XCTestCase {
    func testCompletionWaitsForCancellationWhoseKVOCallbackHasNotRun() {
        var state = DeletionCancellationState()
        let operation = UUID(), primary = UUID(), joined = UUID()
        state.register(primary, operation: operation)
        state.register(joined, operation: operation)
        XCTAssertEqual(state.complete(operation, tokens: [primary, joined], cancelled: [joined]), .stop([joined]))
        XCTAssertTrue(state.requestStop(operation, cancellation: joined))
        XCTAssertFalse(state.requestStop(operation, cancellation: joined))
        XCTAssertEqual(state.complete(operation, tokens: [primary, joined], cancelled: [joined]), .waiting)
        state.finishedStop(operation)
        XCTAssertEqual(state.complete(operation, tokens: [primary, joined], cancelled: [joined]), .ready)
        XCTAssertFalse(state.requestStop(operation, cancellation: primary))
    }

    func testCompletionBeforeCancellationRetiresTheCallbackToken() {
        var state = DeletionCancellationState()
        let operation = UUID(), token = UUID()
        state.register(token, operation: operation)
        XCTAssertFalse(state.requestStop(UUID(), cancellation: token))
        XCTAssertEqual(state.complete(operation, tokens: [token], cancelled: []), .ready)
        XCTAssertFalse(state.requestStop(operation, cancellation: token))
        XCTAssertFalse(state.isStopping(operation))
    }

    func testCloseDuringSettingsWaitSuppressesNewCancellationButDrainsCountedStops() {
        var state = DeletionCancellationState()
        let operation = UUID(), token = UUID()
        state.register(token, operation: operation)
        XCTAssertTrue(state.requestStop(operation))
        XCTAssertTrue(state.requestStop(operation))
        state.close()
        XCTAssertTrue(state.isClosed)
        XCTAssertFalse(state.requestStop(operation, cancellation: token))
        state.finishedStop(operation)
        XCTAssertEqual(state.complete(operation, tokens: [token], cancelled: [token]), .waiting)
        state.finishedStop(operation)
        XCTAssertEqual(state.complete(operation, tokens: [token], cancelled: [token]), .ready)
    }

    func testProgressNamesEveryAdmittedNodeInEachView() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare()
        XCTAssertEqual(try record.selectedPath(in: fixture.owner), "Tree")
        XCTAssertEqual(try record.selectedPath(in: fixture.neighbor), "Docs/Tree")
        XCTAssertThrowsError(try record.itemProgress(in: UUID().uuidString))
        fixture.server.lostCloses = ["Docs/Tree/Sub/c"]
        XCTAssertThrowsError(try fixture.run(&record))
        let items = try record.itemProgress(in: fixture.owner)
        XCTAssertEqual(items.map(\.path), ["Tree/Empty", "Tree/Sub/c", "Tree/Sub/d", "Tree/Sub", "Tree/a", "Tree/b", "Tree"])
        XCTAssertEqual(items.map(\.outcome), [.deleted, nil, nil, nil, nil, nil, nil])
        XCTAssertEqual(items.filter(\.mayHaveBeenRequested).map(\.path), ["Tree/Sub/c"])
        XCTAssertTrue(record.needsAttention)
        XCTAssertFalse(record.canDismiss)
        try fixture.outbox.stop(&record)
        XCTAssertEqual(try record.itemProgress(in: fixture.owner).map(\.outcome),
                       [.deleted, .unconfirmed, .stopped, .stopped, .stopped, .stopped, .stopped])
    }

    func testDismissKeepsPartialOutcomesAndCannotAuthorizeAFreshTraversal() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare()
        fixture.server.objects["Docs/Tree/a"] = .file(try DeletionFixture.version(99))
        try fixture.run(&record)
        XCTAssertThrowsError(try fixture.outbox.dismiss(&record))
        try fixture.outbox.finishDomain(fixture.owner, record: &record)
        XCTAssertFalse(record.canDismiss)
        try fixture.outbox.finishDomain(fixture.neighbor, record: &record)
        XCTAssertTrue(record.needsAttention)
        XCTAssertTrue(record.canDismiss)
        XCTAssertFalse(record.isPending)
        let summary = record.summary, marks = fixture.server.marks
        try fixture.outbox.dismiss(&record)
        try fixture.outbox.dismiss(&record)
        XCTAssertFalse(record.needsAttention)
        XCTAssertFalse(record.canDismiss)
        XCTAssertEqual(record.summary, summary)
        fixture.server.objects["Docs/Tree/new"] = .file(try DeletionFixture.version(100))
        fixture.outbox = try fixture.makeOutbox()
        var replay = try fixture.prepare()
        XCTAssertEqual(replay, record)
        try fixture.run(&replay)
        XCTAssertEqual(fixture.server.marks, marks)
        XCTAssertNotNil(fixture.server.objects["Docs/Tree/new"])
        XCTAssertThrowsError(try replay.requireConfirmedDeletion()) {
            XCTAssertEqual($0 as? ItemDeletionError, .directoryNotEmpty)
        }
    }

    func testDismissUncertaintyNeverTurnsAbsenceIntoSuccess() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare("Docs/Tree/a", recursive: false)
        fixture.server.lostCloses = ["Docs/Tree/a"]
        XCTAssertThrowsError(try fixture.run(&record))
        try fixture.run(&record)
        XCTAssertEqual(record.selectedOutcome, .unconfirmed)
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        try fixture.outbox.dismiss(&record)
        XCTAssertFalse(record.isPending)
        XCTAssertThrowsError(try record.requireConfirmedDeletion()) {
            XCTAssertEqual($0 as? ItemDeletionError, .unresolved)
        }
        XCTAssertEqual(try fixture.outbox.records(), [record])
    }

    func testStoppedNoticeCanBeDismissedOnlyAfterAllViewsFinish() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare()
        try fixture.outbox.stop(&record)
        XCTAssertFalse(record.canDismiss)
        for domain in [fixture.owner, fixture.neighbor] { try fixture.outbox.finishDomain(domain, record: &record) }
        XCTAssertTrue(record.canDismiss)
        try fixture.outbox.dismiss(&record)
        XCTAssertThrowsError(try record.requireConfirmedDeletion()) { XCTAssertEqual($0 as? TransferError, .cancelled) }
        try fixture.run(&record)
        XCTAssertTrue(fixture.server.marks.isEmpty)
    }

    func testRetryUnsettledRecordUsesItsOriginalEvidenceAndLeavesArrivingChildren() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare()
        fixture.server.inspectFailures["Docs/Tree/Sub/c"] = SourceFailure.serverUnreachable
        XCTAssertThrowsError(try fixture.run(&record))
        fixture.server.inspectFailures = [:]
        fixture.server.objects["Docs/Tree/Sub/c"] = .file(try DeletionFixture.version(99))
        fixture.server.objects["Docs/Tree/new"] = .file(try DeletionFixture.version(100))
        fixture.outbox = try fixture.makeOutbox()
        record = try XCTUnwrap(fixture.outbox.records().first)
        try fixture.run(&record)
        XCTAssertEqual(record.summary, [.deleted: 4, .replaced: 1, .directoryNotEmpty: 2])
        XCTAssertNotNil(fixture.server.objects["Docs/Tree/new"])
        XCTAssertNotNil(fixture.server.objects["Docs/Tree/Sub/c"])
        XCTAssertFalse(fixture.server.marks.contains("Docs/Tree/Sub/c"))
    }

    func testCancellationInsideProtectedNodeThenStopPreservesUncertainty() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        var record = try fixture.prepare()
        let progress = Progress()
        XCTAssertThrowsError(try RecursiveDeletionTransaction.run(&record, outbox: fixture.outbox,
            endpoint: fixture.endpoint, owner: fixture.owner) { body in
            try fixture.server.session { remote in
                let cancelling = CancelAfterMark(remote: remote, progress: progress)
                defer { cancelling.endSession() }
                try body(cancelling)
            }
        }) { XCTAssertEqual($0 as? TransferError, .cancelled) }
        XCTAssertTrue(progress.isCancelled)
        XCTAssertEqual(record.progress.current, .attempting)
        try fixture.outbox.stop(&record)
        XCTAssertEqual(record.summary, [.unconfirmed: 1, .stopped: 6])
        XCTAssertEqual(fixture.server.marks, ["Docs/Tree/Empty"])
        XCTAssertNil(fixture.server.objects["Docs/Tree/Empty"])
        try fixture.run(&record)
        XCTAssertEqual(fixture.server.marks.count, 1)
    }

    func testDeletionFailureClassificationPreservesUnknownOutcomes() {
        for error in [ItemDeletionError.absentUnconfirmed, .deletePending, .pathNotFound, .unresolved] {
            XCTAssertEqual(DeletionFailure.classify(error), .unconfirmed)
        }
        XCTAssertEqual(DeletionFailure.classify(SourceFailure.missing), .unconfirmed)
        XCTAssertEqual(DeletionFailure.classify(SourceFailure.versionChanged), .changed)
        XCTAssertEqual(DeletionFailure.classify(ItemDeletionError.replaced), .replaced)
        XCTAssertEqual(DeletionFailure.classify(ItemDeletionError.directoryNotEmpty), .directoryNotEmpty)
        XCTAssertEqual(DeletionFailure.classify(SourceFailure.serverUnreachable), .connection)
        XCTAssertEqual(DeletionFailure.classify(SourceFailure.notAuthenticated), .authentication)
        XCTAssertEqual(DeletionFailure.classify(UploadError.pendingWrites), .pendingChanges)
        XCTAssertEqual(DeletionFailure.classify(ItemDeletionError.busy), .busy)
        XCTAssertEqual(DeletionFailure.classify(UploadError.readOnly), .readOnly)
        XCTAssertEqual(DeletionFailure.classify(TransferError.cancelled), .cancelled)
        XCTAssertEqual(DeletionFailure.classify(CocoaError(.userCancelled)), .cancelled)
        XCTAssertEqual(DeletionFailure.classify(CocoaError(.fileWriteOutOfSpace)), .storage)
    }
}

private final class CancelAfterMark: DeletionRemote {
    let remote: DeletionRemote
    let progress: Progress
    var marked: String?

    init(remote: DeletionRemote, progress: Progress) { self.remote = remote; self.progress = progress }
    func protectParents(of path: String) throws -> [ItemDeletionParent] { try remote.protectParents(of: path) }
    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup { try remote.inspect(path: path, kind: kind) }
    func list(path: String) throws -> ItemDeletionListing { try remote.list(path: path) }
    func markDeletion(path: String) throws {
        try remote.markDeletion(path: path)
        marked = path
        progress.cancel()
    }
    func closeTarget(path: String) throws { throw TransferError.cancelled }
    func endSession() { if let marked { try? remote.closeTarget(path: marked) } }
}
