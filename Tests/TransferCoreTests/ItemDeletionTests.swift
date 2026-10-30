import Foundation
import XCTest
@testable import TransferCore

final class ItemDeletionTests: XCTestCase {
    private enum Fault: Error { case connection, persistence }

    private var record: PendingItemDeletion!
    private var store: Store!
    private var remote: Remote!

    override func setUpWithError() throws { try setUpTarget(.file(version())) }

    private func version(identity: UInt64 = 30, digest: Character = "a",
                         modified: UInt64 = 20, security: Data = Data([1]),
                         quarantine: Data? = nil) throws -> EditFileVersion {
        try EditFileVersion(identity: EditFileIdentity(fileID: identity, birthMicroseconds: 10), size: 12,
                            digest: String(repeating: String(digest), count: 64), modifiedMicroseconds: modified,
                            changedMicroseconds: 40, attributes: 32, security: security,
                            artifactQuarantine: quarantine)
    }

    private func setUpTarget(_ selected: ItemDeletionEvidence) throws {
        let parents = [
            ItemDeletionParent(path: "", name: "", identity: try EditFileIdentity(fileID: 1, birthMicroseconds: 2)),
            ItemDeletionParent(path: "folder", name: "folder",
                               identity: try EditFileIdentity(fileID: 3, birthMicroseconds: 4))
        ]
        record = try PendingItemDeletion(path: XCTUnwrap(RelativePath("folder/item")), selected: selected,
                                         parents: parents)
        store = try Store(record)
        remote = Remote(record: record)
        remote.files["folder/neighbor"] = .file(try version(identity: 99, digest: "b"))
    }

    private func remove(_ current: inout PendingItemDeletion) throws {
        try ItemDeletionTransaction.remove(&current, remote: remote, load: store.load,
                                            checkpoint: store.checkpoint)
    }

    private func remove() throws { try remove(&record) }

    func testConfirmedFileDeletionPersistsEachBoundaryAndKeepsItsNeighbor() throws {
        let neighbor = remote.files["folder/neighbor"]
        try remove()
        XCTAssertEqual(record.state, .deleted)
        XCTAssertFalse(record.isPending)
        XCTAssertEqual(try store.load(), record)
        XCTAssertEqual(store.saved, [.attempting, .closeAcknowledged, .deleted])
        XCTAssertEqual(remote.markCalls, 1)
        XCTAssertEqual(remote.closeCalls, 1)
        XCTAssertEqual(remote.listPaths, ["folder", "folder"])
        XCTAssertNil(remote.files[record.path])
        XCTAssertEqual(remote.files["folder/neighbor"], neighbor)
    }

    func testWholeObjectPolicyDoesNotCompareChangedAttachedMetadata() throws {
        remote.files[record.path] = .file(try version(modified: 80, security: Data([9]),
                                                     quarantine: Data("changed".utf8)))
        remote.attached = Data("existing attached data".utf8)
        remote.beforeMark = { self.remote.attached = Data("new attached data".utf8) }
        try remove()
        XCTAssertEqual(record.state, .deleted)
        XCTAssertNil(remote.attached)
        XCTAssertEqual(remote.markCalls, 1)
    }

    func testChangedMainContentsAndIdenticalByteReplacementAreRefused() throws {
        for (replacement, expected) in [(try version(digest: "c"), ItemDeletionError.changed),
                                         (try version(identity: 31), .replaced)] {
            remote.files[record.path] = .file(replacement)
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, expected) }
            XCTAssertEqual(remote.files[record.path], .file(replacement))
            XCTAssertEqual(remote.markCalls, 0)
            XCTAssertEqual(try store.load().state, .prepared)
        }
    }

    func testWrongKindAndReparsePointEvidenceAreRefused() throws {
        remote.files[record.path] = .directory(record.selected.identity)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .changed) }
        let ordinary = try version()
        remote.files[record.path] = .file(try EditFileVersion(identity: ordinary.identity, size: ordinary.size,
            digest: ordinary.digest, modifiedMicroseconds: ordinary.modifiedMicroseconds,
            changedMicroseconds: ordinary.changedMicroseconds, attributes: 0x400, security: ordinary.security))
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unsupported) }
        XCTAssertEqual(remote.markCalls, 0)
    }

    func testChangedParentIdentityOrSpellingRefusesBeforeOpeningTheTarget() throws {
        for changed in [ItemDeletionParent(path: "folder", name: "folder",
                                           identity: try EditFileIdentity(fileID: 50, birthMicroseconds: 4)),
                        ItemDeletionParent(path: "folder", name: "FOLDER", identity: record.parents[1].identity)] {
            remote.parents[1] = changed
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .parentChanged) }
            XCTAssertEqual(remote.inspectCalls, 0)
            XCTAssertEqual(remote.markCalls, 0)
        }
    }

    func testCompleteParentListingMustBindTheExactNameToTheHeldObject() throws {
        for entries in [[], [ItemDeletionEntry(name: "ITEM", identity: record.selected.identity)],
                        [ItemDeletionEntry(name: "item", identity: record.selected.identity),
                         ItemDeletionEntry(name: "elsewhere", identity: record.selected.identity)]] {
            remote.parentEntries = entries
            XCTAssertThrowsError(try remove())
            XCTAssertEqual(remote.markCalls, 0)
            XCTAssertEqual(try store.load().state, .prepared)
        }
    }

    func testIncompleteAndAmbiguousListingsNeverAuthorizeDeletion() throws {
        remote.incomplete.insert(record.parentPath)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        remote.incomplete = []
        remote.parentEntries = [ItemDeletionEntry(name: "item", identity: record.selected.identity),
                                ItemDeletionEntry(name: "ITEM", identity: record.selected.identity)]
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(remote.markCalls, 0)
        XCTAssertEqual(store.saved, [])
    }

    func testDeletePendingAndPathNotFoundNeverBecomeAbsence() throws {
        remote.files[record.path] = nil
        for (lookup, expected) in [(ItemDeletionLookup.deletePending, ItemDeletionError.deletePending),
                                   (.pathNotFound, .pathNotFound)] {
            remote.lookup = lookup
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, expected) }
            XCTAssertEqual(try store.load().state, .prepared)
        }
        remote.inspectFailure = NSError(domain: NSPOSIXErrorDomain, code: 2)
        XCTAssertThrowsError(try remove())
        XCTAssertEqual(store.saved, [])
        XCTAssertEqual(remote.markCalls, 0)
        XCTAssertEqual(remote.listPaths, [])
    }

    func testNameAbsenceWithoutAnAcknowledgedCloseStaysUnconfirmed() throws {
        remote.files[record.path] = nil
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .absentUnconfirmed) }
        XCTAssertEqual(try store.load().state, .absentUnconfirmed)
        XCTAssertTrue(record.isPending)
        XCTAssertEqual(remote.markCalls, 0)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .absentUnconfirmed) }
        XCTAssertEqual(try store.load().state, .absentUnconfirmed)
    }

    func testAbsentNameWithTheIdentityElsewhereIsNotFollowed() throws {
        remote.files["folder/moved"] = remote.files.removeValue(forKey: record.path)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .moved) }
        XCTAssertNotNil(remote.files["folder/moved"])
        XCTAssertEqual(try store.load().state, .prepared)
        XCTAssertEqual(remote.markCalls, 0)
    }

    func testRacingReplacementAfterNameLookupDoesNotCountAsAbsence() throws {
        remote.lookup = .nameNotFound
        remote.files[record.path] = .file(try version(identity: 90))
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .replaced) }
        XCTAssertEqual(remote.markCalls, 0)
        XCTAssertEqual(store.saved, [])
    }

    func testPersistenceFailureBeforeRequestNeverSendsTheRequest() throws {
        for afterWrite in [false, true] {
            try setUpWithError()
            store.failure = (.attempting, afterWrite)
            XCTAssertThrowsError(try remove())
            XCTAssertEqual(remote.markCalls, 0)
            XCTAssertEqual(record.state, .prepared)
            XCTAssertEqual(try store.load().state, afterWrite ? .attempting : .prepared)
            try remove()
            XCTAssertEqual(record.state, .deleted)
            XCTAssertEqual(remote.markCalls, 1)
        }
    }

    func testInterruptedBeforeRequestRevalidatesBeforeRetry() throws {
        store.failure = (.attempting, true)
        XCTAssertThrowsError(try remove())
        remote.files[record.path] = .file(try version(digest: "c"))
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .changed) }
        XCTAssertEqual(record.state, .attempting)
        XCTAssertEqual(remote.markCalls, 0)
    }

    func testLostMarkReplyAndLostCloseReplyRemainUnconfirmed() throws {
        for afterMark in [true, false] {
            try setUpWithError()
            remote.loseMarkReply = afterMark
            remote.loseCloseReply = !afterMark
            XCTAssertThrowsError(try remove())
            XCTAssertEqual(try store.load().state, .attempting)
            XCTAssertNil(remote.files[record.path])
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .absentUnconfirmed) }
            XCTAssertEqual(record.state, .absentUnconfirmed)
            XCTAssertEqual(remote.markCalls, 1)
        }
    }

    func testPersistenceFailureAfterCloseDistinguishesDurableAcknowledgment() throws {
        for afterWrite in [false, true] {
            try setUpWithError()
            store.failure = (.closeAcknowledged, afterWrite)
            XCTAssertThrowsError(try remove())
            XCTAssertNil(remote.files[record.path])
            XCTAssertEqual(record.state, .attempting)
            XCTAssertEqual(remote.inspectCalls, 1)
            if afterWrite {
                try remove()
                XCTAssertEqual(record.state, .deleted)
            } else {
                XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .absentUnconfirmed) }
                XCTAssertEqual(record.state, .absentUnconfirmed)
            }
            XCTAssertEqual(remote.markCalls, 1)
            XCTAssertEqual(remote.closeCalls, 1)
        }
    }

    func testFailureSavingFinalResultNeverReturnsSameCallSuccess() throws {
        for afterWrite in [false, true] {
            try setUpWithError()
            store.failure = (.deleted, afterWrite)
            XCTAssertThrowsError(try remove())
            XCTAssertEqual(record.state, .closeAcknowledged)
            XCTAssertEqual(try store.load().state, afterWrite ? .deleted : .closeAcknowledged)
            let inspections = remote.inspectCalls
            try remove()
            XCTAssertEqual(record.state, .deleted)
            XCTAssertEqual(remote.inspectCalls, inspections + (afterWrite ? 0 : 1))
            XCTAssertEqual(remote.markCalls, 1)
        }
    }

    func testAcknowledgedCloseStillNeedsExactAbsenceAndACompleteListing() throws {
        remote.afterClose = { self.remote.lookup = .deletePending }
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .deletePending) }
        XCTAssertEqual(record.state, .closeAcknowledged)
        remote.lookup = .pathNotFound
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .pathNotFound) }
        remote.lookup = nil
        remote.incomplete.insert(record.parentPath)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(record.state, .closeAcknowledged)
        remote.incomplete = []
        try remove()
        XCTAssertEqual(record.state, .deleted)
        XCTAssertEqual(remote.markCalls, 1)
        XCTAssertEqual(remote.closeCalls, 1)
    }

    func testAcknowledgedCloseNeverDeletesANewOccupantOrFollowsAMovedIdentity() throws {
        store.failure = (.closeAcknowledged, true)
        XCTAssertThrowsError(try remove())
        let replacement = ItemDeletionEvidence.file(try version(identity: 90))
        remote.files[record.path] = replacement
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .replaced) }
        XCTAssertEqual(remote.files[record.path], replacement)
        remote.files[record.path] = nil
        remote.files["folder/moved"] = record.selected
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .moved) }
        XCTAssertEqual(record.state, .closeAcknowledged)
        XCTAssertEqual(remote.markCalls, 1)
    }

    func testSurvivingObjectAfterAcknowledgedCloseIsNeverMarkedAgain() throws {
        let path = record.path, selected = record.selected
        remote.afterClose = { self.remote.files[path] = selected }
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(record.state, .closeAcknowledged)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(remote.markCalls, 1)
        XCTAssertEqual(remote.closeCalls, 1)
        XCTAssertNotNil(remote.files[record.path])
    }

    func testAcknowledgedCloseRequiresTheRecordedParentOnRecovery() throws {
        store.failure = (.closeAcknowledged, true)
        XCTAssertThrowsError(try remove())
        remote.parents[0] = ItemDeletionParent(path: "", name: "",
                                              identity: try EditFileIdentity(fileID: 80, birthMicroseconds: 81))
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .parentChanged) }
        XCTAssertEqual(record.state, .closeAcknowledged)
        XCTAssertEqual(remote.inspectCalls, 1)
        XCTAssertEqual(remote.markCalls, 1)
    }

    func testStaleCallerLoadsCompletedStateBeforeAnyRemoteAccess() throws {
        var stale = record!
        try remove()
        let inspections = remote.inspectCalls, protections = remote.protectCalls
        remote.files[record.path] = .file(try version(identity: 90))
        try remove(&stale)
        XCTAssertEqual(stale, record)
        XCTAssertEqual(remote.inspectCalls, inspections)
        XCTAssertEqual(remote.protectCalls, protections)
        XCTAssertEqual(remote.markCalls, 1)
        XCTAssertNotNil(remote.files[record.path])
    }

    func testLoadFailureAndMismatchedDurableSelectionNeverReachTheServer() throws {
        store.loadFails = true
        XCTAssertThrowsError(try remove())
        store.loadFails = false
        let other = try PendingItemDeletion(id: record.id, path: XCTUnwrap(RelativePath(record.path)),
                                            selected: .file(version(identity: 90)), parents: record.parents)
        try store.checkpoint(other)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .invalidRequest) }
        XCTAssertEqual(remote.protectCalls, 0)
        XCTAssertEqual(remote.markCalls, 0)
    }

    func testEmptyDirectoryDeletionAndPopulatedDirectoryRefusal() throws {
        try setUpTarget(.directory(EditFileIdentity(fileID: 30, birthMicroseconds: 10)))
        let child = ItemDeletionEvidence.file(try version(identity: 45))
        remote.files[record.path + "/child"] = child
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .directoryNotEmpty) }
        XCTAssertEqual(remote.markCalls, 0)
        XCTAssertEqual(remote.files[record.path + "/child"], child)
        remote.files[record.path + "/child"] = nil
        remote.incomplete.insert(record.path)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .unresolved) }
        XCTAssertEqual(remote.markCalls, 0)
        remote.incomplete = []
        try remove()
        XCTAssertEqual(record.state, .deleted)
        XCTAssertEqual(remote.markCalls, 1)
    }

    func testChildArrivalBeforeMarkOrCloseKeepsBothDirectoryAndChild() throws {
        for beforeMark in [true, false] {
            try setUpTarget(.directory(EditFileIdentity(fileID: 30, birthMicroseconds: 10)))
            let path = record.path + "/child", child = ItemDeletionEvidence.file(try version(identity: 45))
            let arrival = { self.remote.files[path] = child }
            if beforeMark { remote.beforeMark = arrival } else { remote.beforeClose = arrival }
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .directoryNotEmpty) }
            XCTAssertNotNil(remote.files[record.path])
            XCTAssertEqual(remote.files[path], child)
            XCTAssertEqual(record.state, .attempting)
            remote.beforeMark = nil
            remote.beforeClose = nil
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .directoryNotEmpty) }
            XCTAssertEqual(remote.files[path], child)
            XCTAssertEqual(remote.markCalls, 1)
        }
    }

    func testDirectoryLostCloseReplyRemainsUnconfirmed() throws {
        try setUpTarget(.directory(EditFileIdentity(fileID: 30, birthMicroseconds: 10)))
        remote.loseCloseReply = true
        XCTAssertThrowsError(try remove())
        XCTAssertEqual(record.state, .attempting)
        XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, .absentUnconfirmed) }
        XCTAssertEqual(record.state, .absentUnconfirmed)
        XCTAssertEqual(remote.markCalls, 1)
    }

    func testServerRefusalsKeepTheObjectAndNeverClaimDeletion() throws {
        for refusal in [ItemDeletionError.sharingViolation, .accessDenied, .cannotDelete, .unsupported] {
            try setUpWithError()
            remote.markFailure = refusal
            XCTAssertThrowsError(try remove()) { XCTAssertEqual($0 as? ItemDeletionError, refusal) }
            XCTAssertEqual(record.state, .attempting)
            XCTAssertEqual(remote.files[record.path], record.selected)
            XCTAssertEqual(remote.closeCalls, 0)
            remote.markFailure = nil
            try remove()
            XCTAssertEqual(record.state, .deleted)
        }
    }

    func testInvalidIntentAndIncompleteParentChainAreRejected() throws {
        XCTAssertThrowsError(try PendingItemDeletion(path: .root, selected: record.selected, parents: []))
        XCTAssertThrowsError(try PendingItemDeletion(path: XCTUnwrap(RelativePath(record.path)),
            selected: record.selected, parents: Array(record.parents.dropFirst())))
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record!)) as? [String: Any])
        values["path"] = "folder/../item"
        XCTAssertThrowsError(try JSONDecoder().decode(PendingItemDeletion.self,
            from: JSONSerialization.data(withJSONObject: values)))
    }

    private final class Store {
        var data: Data
        var saved: [PendingItemDeletion.State] = []
        var failure: (PendingItemDeletion.State, Bool)?
        var loadFails = false

        init(_ record: PendingItemDeletion) throws { data = try JSONEncoder().encode(record) }

        func load() throws -> PendingItemDeletion {
            if loadFails { throw Fault.persistence }
            return try JSONDecoder().decode(PendingItemDeletion.self, from: data)
        }

        func checkpoint(_ record: PendingItemDeletion) throws {
            let fail = failure?.0 == record.state
            let afterWrite = failure?.1 == true
            if fail { failure = nil }
            if fail, !afterWrite { throw Fault.persistence }
            data = try JSONEncoder().encode(record)
            saved.append(record.state)
            if fail { throw Fault.persistence }
        }
    }

    private final class Remote: DeletionRemote {
        var parents: [ItemDeletionParent]
        var files: [String: ItemDeletionEvidence]
        var attached: Data?
        var lookup: ItemDeletionLookup?
        var inspectFailure: Error?
        var markFailure: Error?
        var parentEntries: [ItemDeletionEntry]?
        var incomplete: Set<String> = []
        var beforeMark: (() -> Void)?
        var beforeClose: (() -> Void)?
        var afterClose: (() -> Void)?
        var loseMarkReply = false
        var loseCloseReply = false
        var protectCalls = 0
        var inspectCalls = 0
        var markCalls = 0
        var closeCalls = 0
        var listPaths: [String] = []
        let parentPath: String

        init(record: PendingItemDeletion) {
            parents = record.parents
            files = [record.path: record.selected]
            parentPath = record.parentPath
        }

        func protectParents(of path: String) throws -> [ItemDeletionParent] {
            protectCalls += 1
            return parents
        }

        func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
            inspectCalls += 1
            if let inspectFailure { throw inspectFailure }
            return lookup ?? files[path].map(ItemDeletionLookup.present) ?? .nameNotFound
        }

        func list(path: String) throws -> ItemDeletionListing {
            listPaths.append(path)
            let entries = path == parentPath ? parentEntries ?? children(path) : children(path)
            return ItemDeletionListing(entries: entries, isComplete: !incomplete.contains(path))
        }

        private func children(_ path: String) -> [ItemDeletionEntry] {
            files.compactMap { name, evidence in
                let components = name.split(separator: "/")
                guard components.dropLast().joined(separator: "/") == path else { return nil }
                return ItemDeletionEntry(name: String(components.last!), identity: evidence.identity)
            }
        }

        func markDeletion(path: String) throws {
            markCalls += 1
            beforeMark?()
            if let markFailure { throw markFailure }
            if files[path]?.kind == .folder, !children(path).isEmpty { throw ItemDeletionError.directoryNotEmpty }
            if loseMarkReply {
                files[path] = nil
                throw Fault.connection
            }
        }

        func closeTarget(path: String) throws {
            closeCalls += 1
            beforeClose?()
            if files[path]?.kind == .folder, !children(path).isEmpty { throw ItemDeletionError.directoryNotEmpty }
            files[path] = nil
            attached = nil
            if loseCloseReply { throw Fault.connection }
            afterClose?()
        }
    }
}
