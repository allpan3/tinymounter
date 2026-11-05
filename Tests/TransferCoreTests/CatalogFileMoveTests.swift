import Foundation
import XCTest
@testable import TransferCore

final class CatalogFileMoveTests: XCTestCase {
    private typealias Parsed = DirectoryListing.Parsed
    private let root = Catalog.rootItemID
    private var directory: URL!
    private var catalog: Catalog!
    private var inbox: CatalogRow!
    private var archive: CatalogRow!
    private var kept: CatalogRow!
    private var old: CatalogRow!
    private var unlisted: CatalogRow!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        catalog = try Catalog.create(at: directory.appending(path: "catalog.sqlite"), domainID: "domain-A",
                                     rootName: "Location")
        try reconcile(root, rootListing())
        inbox = try child(root, "Inbox")
        archive = try child(root, "Archive")
        kept = try child(root, "Kept")
        old = try child(root, "Old")
        unlisted = try child(root, "Unlisted")
        try reconcile(inbox.id, [file("a.txt", fileID: 11), file("b.txt", fileID: 12), file("c.txt", fileID: 13)])
        try reconcile(archive.id, [file("existing.txt", fileID: 21)])
        try reconcile(kept.id, [file("kept.txt", fileID: 31)])
        try reconcile(old.id, [])
        try catalog.setKeep(ids: [kept.id], value: true)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testMoveKeepsTheItemAndItsVersionAndRecordsTheDestinationLookup() throws {
        let a = try child(inbox.id, "a.txt")
        let key = try enumerationKey(a.id)
        let anchor = try catalog.currentAnchor()
        let tombstones = try catalog.counts().tombstones
        try commit(move(a, to: archive.id, name: "renamed.txt"), ctime: 3_000, nativeID: 70)

        let moved = try XCTUnwrap(catalog.item(id: a.id))
        XCTAssertEqual(moved.row, a.row)
        XCTAssertEqual(moved.parentID, archive.id)
        XCTAssertEqual(moved.name, "renamed.txt")
        XCTAssertEqual(moved.contentVersion, a.contentVersion)
        XCTAssertEqual(moved.ctimeNs, 3_000)
        XCTAssertEqual(try catalog.remoteIdentity(a.id), 70)
        XCTAssertEqual(try enumerationKey(a.id), key)
        XCTAssertEqual(moved.changeSeq, seq(anchor) + 1)
        XCTAssertEqual(try catalog.counts().lastSeq, seq(anchor) + 1)
        XCTAssertEqual(try catalog.relativePath(of: a.id)?.string, "Archive/renamed.txt")
        XCTAssertNil(try catalog.liveChild(parent: inbox.id, nameKey: NameKey("a.txt")))
        XCTAssertEqual(try catalog.liveChild(parent: archive.id, nameKey: NameKey("RENAMED.txt"))?.id, a.id)
        XCTAssertEqual(try catalog.counts().tombstones, tombstones)
        let all = try catalog.changes(after: anchor, limit: 100)
        XCTAssertEqual(all.updated, [moved])
        XCTAssertTrue(all.deletedIDs.isEmpty)
    }

    func testVerifiedRevisionStaysVerifiedAndALegacyVersionStaysLegacy() throws {
        try catalog.setAllowsWriting(true)
        let b = try child(inbox.id, "b.txt")
        let receipt = try FileRevision(item: b.id, version: RemoteFileVersion(
            identity: RemoteFileIdentity(fileID: 12, birthMicroseconds: 34), size: 10, modifiedMicroseconds: 1, changedMicroseconds: 2,
            attributes: 32))
        try catalog.rememberRevision(receipt, expectedVersion: b.contentVersion)
        try commit(move(XCTUnwrap(catalog.item(id: b.id)), to: archive.id), nativeID: 70)
        XCTAssertEqual(try catalog.item(id: b.id)?.contentVersion, receipt.contentVersion)

        let a = try child(inbox.id, "a.txt")
        try commit(move(a, to: archive.id), ctime: 3_000, nativeID: 71)
        let legacy = try XCTUnwrap(catalog.item(id: a.id))
        XCTAssertEqual(legacy.contentVersion, a.contentVersion)
        XCTAssertTrue(legacy.contentVersion.hasPrefix("f1:"))
        let native = ContentFingerprint(size: 10, mtimeNs: 1_000, ctimeNs: 3_000)
        XCTAssertNotEqual(legacy.contentVersion, native.contentVersion)
    }

    func testOldAndNewParentsSeeTheMoveWithoutATombstone() throws {
        let a = try child(inbox.id, "a.txt")
        let anchor = try catalog.currentAnchor()
        try commit(move(a, to: archive.id))
        let moved = try XCTUnwrap(catalog.item(id: a.id))

        let departed = try catalog.changes(after: anchor, limit: 100, scope: .parent(inbox.id))
        XCTAssertEqual(departed.updated, [moved])
        XCTAssertEqual(departed.updated.first?.parentID, archive.id)
        XCTAssertTrue(departed.deletedIDs.isEmpty)
        XCTAssertFalse(departed.moreComing)
        XCTAssertEqual(departed.anchor, try catalog.currentAnchor())
        let arrived = try catalog.changes(after: anchor, limit: 100, scope: .parent(archive.id))
        XCTAssertEqual(arrived.updated, [moved])
        XCTAssertTrue(arrived.deletedIDs.isEmpty)
        for other in [root, kept.id, old.id] {
            let batch = try catalog.changes(after: anchor, limit: 100, scope: .parent(other))
            XCTAssertTrue(batch.updated.isEmpty && batch.deletedIDs.isEmpty, other)
        }
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100, scope: .item(a.id)).updated, [moved])
        let caughtUp = try catalog.changes(after: departed.anchor, limit: 100, scope: .parent(inbox.id))
        XCTAssertTrue(caughtUp.updated.isEmpty && caughtUp.deletedIDs.isEmpty)
        XCTAssertEqual(try catalog.children(of: inbox.id, limit: 10).map(\.name), ["b.txt", "c.txt"])
        XCTAssertEqual(try catalog.children(of: archive.id, limit: 10).map(\.name), ["a.txt", "existing.txt"])
    }

    func testRepeatedMovesBeforeObserversCatchUpGiveEachParentTheCurrentRowOnce() throws {
        let a = try child(inbox.id, "a.txt")
        let anchor = try catalog.currentAnchor()
        var middle = anchor
        for (index, destination) in [archive.id, kept.id, inbox.id, archive.id, inbox.id, archive.id].enumerated() {
            try commit(move(XCTUnwrap(catalog.item(id: a.id)), to: destination), nativeID: UInt64(70 + index))
            if index == 2 { middle = try catalog.currentAnchor() }
        }
        let current = try XCTUnwrap(catalog.item(id: a.id))
        XCTAssertEqual(current.parentID, archive.id)
        XCTAssertEqual(current.contentVersion, a.contentVersion)
        for folder in [inbox.id, archive.id, kept.id] {
            let batch = try catalog.changes(after: anchor, limit: 100, scope: .parent(folder))
            XCTAssertEqual(batch.updated, [current], folder)
            XCTAssertTrue(batch.deletedIDs.isEmpty, folder)
        }
        // Each former folder keeps only its latest departure, and the current folder none.
        XCTAssertEqual(try rows("SELECT parent FROM departures ORDER BY seq"), [kept.id, inbox.id])
        XCTAssertEqual(try catalog.changes(after: middle, limit: 100, scope: .parent(inbox.id)).updated, [current])
        XCTAssertTrue(try catalog.changes(after: middle, limit: 100, scope: .parent(kept.id)).updated.isEmpty)
    }

    func testMoveThenDeletionReachesBothParentsAsTheRealDeletion() throws {
        let a = try child(inbox.id, "a.txt")
        let request = try move(a, to: archive.id)
        let anchor = try catalog.currentAnchor()
        try commit(request)
        let moved = try catalog.currentAnchor()
        XCTAssertTrue(try catalog.changes(after: anchor, limit: 100).deletedIDs.isEmpty)
        try reconcile(archive.id, [file("existing.txt", fileID: 21)])

        for folder in [inbox.id, archive.id] {
            let batch = try catalog.changes(after: anchor, limit: 100, scope: .parent(folder))
            XCTAssertEqual(batch.deletedIDs, [a.id], folder)
            XCTAssertTrue(batch.updated.isEmpty, folder)
        }
        XCTAssertTrue(try catalog.changes(after: moved, limit: 100, scope: .parent(inbox.id)).deletedIDs.isEmpty)
        XCTAssertEqual(try catalog.changes(after: moved, limit: 100, scope: .parent(archive.id)).deletedIDs, [a.id])
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 100).deletedIDs, [a.id])
        XCTAssertThrowsError(try commit(request)) { XCTAssertEqual($0 as? UploadError, .unresolved) }
    }

    func testFolderChangesPageAtTheDepartureSequence() throws {
        let a = try child(inbox.id, "a.txt"), b = try child(inbox.id, "b.txt"), c = try child(inbox.id, "c.txt")
        let anchor = try catalog.currentAnchor()
        try commit(move(a, to: archive.id), nativeID: 70)
        try catalog.updateFingerprint(item: b.id, fingerprint: .init(size: 10, mtimeNs: 1_500, ctimeNs: 2_000), fileID: 12)
        // A later change in its new folder must not move the old folder's cut past b.
        try catalog.updateFingerprint(item: a.id, fingerprint: .init(size: 10, mtimeNs: 1_700, ctimeNs: 3_000), fileID: 70)
        try commit(move(c, to: archive.id, name: "c2.txt"), nativeID: 71)

        let pages: [(limit: Int, ids: [[String]])] = [(1, [[a.id], [b.id], [c.id], []]), (2, [[a.id, b.id], [c.id]])]
        for (limit, expected) in pages {
            var token = anchor, more = true, seen: [[String]] = []
            while more {
                let batch = try catalog.changes(after: token, limit: limit, scope: .parent(inbox.id))
                XCTAssertTrue(batch.deletedIDs.isEmpty)
                seen.append(batch.updated.map(\.id))
                token = batch.anchor
                more = batch.moreComing
            }
            XCTAssertEqual(seen, expected, "limit \(limit)")
            XCTAssertEqual(token, try catalog.currentAnchor())
        }
        let first = try catalog.changes(after: anchor, limit: 1, scope: .parent(inbox.id))
        XCTAssertEqual(seq(first.anchor), seq(anchor) + 1)
        XCTAssertEqual(first.updated.first?.mtimeNs, 1_700)
    }

    func testRepeatedCommitWritesNothingAndStaleSourcesAreRefused() throws {
        let a = try child(inbox.id, "a.txt")
        let request = try move(a, to: archive.id)
        try commit(request, nativeID: 70)
        let committed = try dump()
        try commit(request, nativeID: 70)
        XCTAssertEqual(try dump(), committed)
        // A fresh lookup after the commit refreshes the row without another departure.
        let departures = try rows("SELECT item || '|' || parent || '|' || seq FROM departures")
        try commit(request, nativeID: 80)
        XCTAssertEqual(try catalog.remoteIdentity(a.id), 80)
        XCTAssertEqual(try catalog.item(id: a.id)?.contentVersion, a.contentVersion)
        XCTAssertEqual(try rows("SELECT item || '|' || parent || '|' || seq FROM departures"), departures)
        XCTAssertEqual(try catalog.counts().lastSeq, try XCTUnwrap(catalog.item(id: a.id)).changeSeq)

        let b = try child(inbox.id, "b.txt")
        let admitted = try move(b, to: archive.id)
        let stale = [
            try CatalogFileMove(item: b.id, sourceParent: inbox.id, sourceName: "b.txt", contentVersion: "f1:10:1000:1999",
                                sourceNativeID: 12, destinationParent: archive.id, destinationName: "b.txt"),
            try CatalogFileMove(item: b.id, sourceParent: inbox.id, sourceName: "b.txt", contentVersion: b.contentVersion,
                                sourceNativeID: 99, destinationParent: archive.id, destinationName: "b.txt"),
            try CatalogFileMove(item: b.id, sourceParent: inbox.id, sourceName: "B2.txt", contentVersion: b.contentVersion,
                                sourceNativeID: 12, destinationParent: archive.id, destinationName: "b.txt"),
            try CatalogFileMove(item: b.id, sourceParent: kept.id, sourceName: "b.txt", contentVersion: b.contentVersion,
                                sourceNativeID: 12, destinationParent: archive.id, destinationName: "b.txt")
        ]
        for move in stale { try assertRefused(move, .unresolved) }
        try assertRefused(admitted, .unresolved, size: 11)
        try assertRefused(admitted, .unresolved, nativeID: 0)

        // A same-fingerprint replacement keeps the legacy version but changes the native ID.
        try reconcile(inbox.id, [file("b.txt", fileID: 99), file("c.txt", fileID: 13)])
        XCTAssertEqual(try catalog.item(id: b.id)?.contentVersion, b.contentVersion)
        try assertRefused(admitted, .unresolved)
        let deleted = try move(child(inbox.id, "c.txt"), to: archive.id)
        try reconcile(inbox.id, [file("b.txt", fileID: 99)])
        try assertRefused(deleted, .unresolved)
    }

    func testDestinationMustBeAListedLiveFolderWithoutACollision() throws {
        let a = try child(inbox.id, "a.txt")
        try reconcile(root, rootListing(except: "Old"))
        let neighbor = try child(root, "neighbor.txt")
        for destination in [UUID().uuidString, neighbor.id, unlisted.id, old.id] {
            try assertRefused(move(a, to: destination), .unresolved)
        }
        for name in ["existing.txt", "EXISTING.txt"] {
            try assertRefused(move(a, to: archive.id, name: name), .collision)
        }
        let deep = String(repeating: "p", count: 255)
        try reconcile(archive.id, [file("existing.txt", fileID: 21), folder(deep)])
        var folderID = try child(archive.id, deep).id
        for _ in 0..<2 {
            try reconcile(folderID, [folder(deep)])
            folderID = try child(folderID, deep).id
        }
        try reconcile(folderID, [])
        try assertRefused(move(a, to: folderID, name: String(repeating: "n", count: 255)), .unresolved)

        let folderMove = try CatalogFileMove(item: kept.id, sourceParent: root, sourceName: "Kept", contentVersion: "d1",
                                             sourceNativeID: 8, destinationParent: archive.id, destinationName: "Kept")
        try assertRefused(folderMove, .unresolved)

        let anchor = try catalog.currentAnchor()
        try commit(move(a, to: inbox.id, name: "A.txt"))
        XCTAssertEqual(try catalog.item(id: a.id)?.name, "A.txt")
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 10, scope: .parent(inbox.id)).updated.map(\.id), [a.id])
        XCTAssertEqual(try rows("SELECT count(*) FROM departures"), ["0"])
    }

    func testInvalidMovesAreRejectedBeforeTheCatalog() throws {
        let a = try child(inbox.id, "a.txt")
        func make(item: String? = nil, sourceParent: String? = nil, sourceName: String = "a.txt",
                  contentVersion: String? = nil, sourceNativeID: UInt64 = 11, destinationParent: String? = nil,
                  destinationName: String = "a.txt") throws -> CatalogFileMove {
            try CatalogFileMove(item: item ?? a.id, sourceParent: sourceParent ?? inbox.id, sourceName: sourceName,
                                contentVersion: contentVersion ?? a.contentVersion, sourceNativeID: sourceNativeID,
                                destinationParent: destinationParent ?? archive.id, destinationName: destinationName)
        }
        XCTAssertNoThrow(try make())
        var invalid: [() throws -> CatalogFileMove] = [
            { try make(item: self.root) }, { try make(item: "a.txt") }, { try make(sourceParent: "Inbox") },
            { try make(destinationParent: a.id) }, { try make(destinationParent: self.inbox.id) },
            { try make(contentVersion: "") }, { try make(contentVersion: String(repeating: "v", count: 129)) },
            { try make(sourceNativeID: 0) }
        ]
        for name in ["", ".", "..", "a/b", "a:b", "a\\b", "x.db", ".tinymounter-x", String(repeating: "n", count: 256)] {
            invalid.append { try make(destinationName: name) }
        }
        for build in invalid {
            XCTAssertThrowsError(try build()) { XCTAssertEqual($0 as? UploadError, .invalidRequest) }
        }
    }

    func testExplicitKeepsFollowTheFileAndInheritedRetentionFollowsTheDestination() throws {
        let a = try child(inbox.id, "a.txt"), b = try child(inbox.id, "b.txt"), inherited = try child(kept.id, "kept.txt")
        try catalog.setKeep(ids: [a.id], value: true)
        XCTAssertTrue(inherited.keep)
        XCTAssertFalse(inherited.keepRequested)
        try commit(move(XCTUnwrap(catalog.item(id: a.id)), to: archive.id), nativeID: 70)
        try commit(move(b, to: kept.id), nativeID: 71)
        try commit(move(inherited, to: archive.id), nativeID: 72)

        let explicit = try XCTUnwrap(catalog.item(id: a.id))
        XCTAssertTrue(explicit.keep && explicit.keepRequested)
        let entered = try XCTUnwrap(catalog.item(id: b.id))
        XCTAssertTrue(entered.keep)
        XCTAssertFalse(entered.keepRequested)
        let left = try XCTUnwrap(catalog.item(id: inherited.id))
        XCTAssertFalse(left.keep || left.keepRequested)
        XCTAssertEqual(Set(try catalog.keepRequests().map(\.id)), [kept.id, a.id])
        XCTAssertEqual(Set(try catalog.keptItems().map(\.id)), [kept.id, a.id, b.id])

        try commit(move(explicit, to: kept.id), nativeID: 73)
        try catalog.setKeep(ids: [kept.id], value: false)
        XCTAssertFalse(try XCTUnwrap(catalog.item(id: b.id)).keep)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: a.id)).keep)
        XCTAssertTrue(try XCTUnwrap(catalog.item(id: a.id)).keepRequested)
    }

    func testReconcileStillTreatsNativeIDChangesAsChanges() throws {
        let a = try child(inbox.id, "a.txt")
        try commit(move(a, to: archive.id), ctime: 3_000, nativeID: 70)
        let moved = try XCTUnwrap(catalog.item(id: a.id))
        let matching = try reconcile(archive.id, [file("a.txt", ctime: 3_000, fileID: 70), file("existing.txt", fileID: 21)])
        XCTAssertEqual(matching.updated, 0)
        XCTAssertEqual(try catalog.item(id: a.id), moved)

        let changed = try reconcile(archive.id, [file("a.txt", ctime: 3_000, fileID: 77), file("existing.txt", fileID: 21)])
        XCTAssertEqual(changed.updated, 1)
        let replaced = try XCTUnwrap(catalog.item(id: a.id))
        XCTAssertNil(replaced.editVersion)
        XCTAssertNotEqual(replaced.contentVersion, moved.contentVersion)

        // A stale source listing gives the old name a new item; it never takes the moved row back.
        let stale = try reconcile(inbox.id, [file("a.txt", fileID: 11), file("b.txt", fileID: 12), file("c.txt", fileID: 13)])
        XCTAssertEqual(stale.inserted, 1)
        XCTAssertNotEqual(try child(inbox.id, "a.txt").id, a.id)
        XCTAssertEqual(try catalog.item(id: a.id)?.parentID, archive.id)
    }

    func testFolderPagesContinueAfterTheirCursorItemMoves() throws {
        let first = try catalog.folderPage(inbox.id, token: nil, size: 1)
        XCTAssertEqual(first.rows.map(\.name), ["a.txt"])
        let token = try XCTUnwrap(first.next)
        try commit(move(first.rows[0], to: archive.id))
        XCTAssertEqual(try catalog.folderPage(inbox.id, token: token, size: 10).rows.map(\.name), ["b.txt", "c.txt"])
        XCTAssertEqual(try catalog.folderPage(archive.id, token: token, size: 10).rows.map(\.name), ["existing.txt"])
        XCTAssertThrowsError(try catalog.folderPage(kept.id, token: token, size: 10)) {
            XCTAssertEqual($0 as? CatalogError, .pageExpired)
        }
        try commit(move(XCTUnwrap(catalog.item(id: first.rows[0].id)), to: inbox.id), nativeID: 71)
        XCTAssertEqual(try catalog.folderPage(inbox.id, token: token, size: 10).rows.map(\.name), ["b.txt", "c.txt"])
        XCTAssertEqual(try catalog.folderPage(archive.id, token: token, size: 10).rows.map(\.name), ["existing.txt"])
    }

    // MARK: - Helpers

    private func rootListing(except excluded: String? = nil) -> [Parsed] {
        ["Inbox", "Archive", "Kept", "Old", "Unlisted"].filter { $0 != excluded }.map { folder($0) }
            + [file("neighbor.txt", fileID: 5)]
    }

    private func move(_ row: CatalogRow, to parent: String, name: String? = nil) throws -> CatalogFileMove {
        try CatalogFileMove(item: row.id, sourceParent: XCTUnwrap(row.parentID), sourceName: row.name,
                            contentVersion: row.contentVersion,
                            sourceNativeID: XCTUnwrap(catalog.remoteIdentity(row.id)),
                            destinationParent: parent, destinationName: name ?? row.name)
    }

    private func commit(_ move: CatalogFileMove, size: Int64 = 10, ctime: Int64 = 3_000, nativeID: UInt64 = 70) throws {
        try catalog.commitFileMove(move, fingerprint: ContentFingerprint(size: size, mtimeNs: 1_000, ctimeNs: ctime),
                                   nativeID: nativeID)
    }

    private func assertRefused(_ move: CatalogFileMove, _ error: UploadError, size: Int64 = 10, nativeID: UInt64 = 70,
                               line: UInt = #line) throws {
        let before = try dump()
        XCTAssertThrowsError(try commit(move, size: size, nativeID: nativeID), line: line) {
            XCTAssertEqual($0 as? UploadError, error, line: line)
        }
        XCTAssertEqual(try dump(), before, line: line)
    }

    private func file(_ name: String, ctime: Int64 = 2_000, fileID: UInt64) -> Parsed {
        .entry(.init(name: name, kind: .file, size: 10, mtimeNs: 1_000, ctimeNs: ctime, fileID: fileID))
    }

    private func folder(_ name: String) -> Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 3_000, ctimeNs: 3_000, fileID: 8))
    }

    @discardableResult
    private func reconcile(_ folder: String, _ entries: [Parsed]) throws -> ReconcilePlan {
        try XCTUnwrap(catalog.reconcile(folder: folder, listing: DirectoryListing(entries)) { _ in true })
    }

    private func child(_ parent: String, _ name: String) throws -> CatalogRow {
        try XCTUnwrap(catalog.liveChild(parent: parent, nameKey: NameKey(name)), name)
    }

    private func enumerationKey(_ id: String) throws -> String? {
        try rows("SELECT enumeration_key FROM items WHERE id = '\(id)'").first
    }

    private func seq(_ anchor: Data) -> Int64 {
        CatalogCursor.anchorSeq(anchor, epoch: catalog.epoch, lastSeq: .max) ?? -1
    }

    private func rows(_ sql: String) throws -> [String] {
        try catalog.database.prepare(sql) { statement in
            var rows: [String] = []
            while try statement.step() { rows.append(statement.text(0)) }
            return rows
        }
    }

    /// Every stored value that a move may change, departures included.
    private func dump() throws -> [String] {
        let items = ["row", "id", "quote(parent_id)", "hex(name)", "hex(name_key)", "kind", "size", "mtime_ns",
                     "ctime_ns", "quote(file_id)", "keep", "keep_request", "deleted", "change_seq",
                     "hex(enumeration_key)", "quote(edit_version)"]
        return try rows("SELECT \(items.joined(separator: " || '|' || ")) FROM items ORDER BY row")
            + rows("SELECT item || '|' || parent || '|' || seq FROM departures ORDER BY item, parent")
            + rows("SELECT last_seq || '|' || listing_gen FROM meta")
    }
}
