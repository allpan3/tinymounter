import Darwin
import Foundation
import SQLite3
import XCTest
@testable import TransferCore

final class CatalogTests: XCTestCase {
    private typealias Parsed = DirectoryListing.Parsed
    private let root = Catalog.rootItemID
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testProviderDomainVersionPersistsWithoutChangingCatalogItems() throws {
        var catalog: Catalog? = try makeCatalog()
        XCTAssertNil(try catalog!.providerDomainVersion())
        try reconcile(catalog!, [file("data")])
        let before = try dump(catalog!), anchor = try catalog!.currentAnchor()
        let archive = Data(repeating: 0xa5, count: 4096)
        try catalog!.setProviderDomainVersion(archive)
        XCTAssertEqual(try dump(catalog!), before)
        XCTAssertEqual(try catalog!.currentAnchor(), anchor)
        catalog = nil
        let reader = try Catalog.open(at: url("catalog"), domainID: "domain-A")
        XCTAssertEqual(try reader.providerDomainVersion(), archive)
        catalog = try Catalog.openWriter(at: url("catalog"), domainID: "domain-A")
        XCTAssertEqual(try catalog!.providerDomainVersion(), archive)
        let next = Data([0x01])
        try catalog!.setProviderDomainVersion(next)
        XCTAssertEqual(try reader.providerDomainVersion(), next)
        XCTAssertEqual(try dump(catalog!), before)
        XCTAssertEqual(try catalog!.currentAnchor(), anchor)
    }

    func testInvalidProviderDomainVersionsAndReadOnlyWritesPreserveStoredValue() throws {
        let catalog = try makeCatalog(), archive = Data([0x01, 0x02])
        try catalog.setProviderDomainVersion(archive)
        for invalid in [Data(), Data(repeating: 1, count: 4097)] {
            XCTAssertThrowsError(try catalog.setProviderDomainVersion(invalid)) {
                XCTAssertEqual($0 as? CatalogError, .unsupportedSchema)
            }
            XCTAssertEqual(try catalog.providerDomainVersion(), archive)
        }
        let reader = try Catalog.open(at: url("catalog"), domainID: "domain-A")
        XCTAssertThrowsError(try reader.setProviderDomainVersion(Data([0x03])))
        XCTAssertEqual(try catalog.providerDomainVersion(), archive)
    }

    func testMalformedPersistedProviderDomainVersionsAreUnavailable() throws {
        let catalog = try makeCatalog()
        for value in ["X''", "zeroblob(4097)", "'not-a-blob'"] {
            try catalog.database.execute("UPDATE meta SET provider_domain_version = \(value)", operation: "test")
            XCTAssertThrowsError(try catalog.providerDomainVersion(), value)
            XCTAssertThrowsError(try Catalog.open(at: url("catalog"), domainID: "domain-A"), value)
            XCTAssertThrowsError(try Catalog.openWriter(at: url("catalog"), domainID: "domain-A"), value)
        }
    }

    func testCatalogWithoutProviderDomainVersionColumnIsUnavailable() throws {
        let catalog = try makeCatalog()
        try catalog.database.execute("ALTER TABLE meta DROP COLUMN provider_domain_version", operation: "test")
        XCTAssertThrowsError(try Catalog.open(at: url("catalog"), domainID: "domain-A"))
        XCTAssertThrowsError(try Catalog.openWriter(at: url("catalog"), domainID: "domain-A"))
    }

    func testSaveAcceptsChangedVersionUnlessConflictFailureWasRequested() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("data")])
        try catalog.setAllowsWriting(true)
        let row = try child(catalog, "data")
        func request(_ fail: Bool) throws -> EditRequest {
            try EditRequest(item: row.id, parent: root, name: row.name, baseVersion: row.contentVersion,
                            staging: UUID(), failOnConflict: fail)
        }
        try catalog.updateFingerprint(item: row.id, fingerprint: ContentFingerprint(size: 24, mtimeNs: 80, ctimeNs: 90),
                                      fileID: 17)
        XCTAssertEqual(try catalog.editTarget(request(false)).1.string, "data")
        XCTAssertThrowsError(try catalog.editTarget(request(true))) {
            XCTAssertEqual($0 as? UploadError, .editConflict)
        }
    }

    func testSaveRefusesReadOnlyDeletedAndReplacedBindings() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("data")])
        let row = try child(catalog, "data")
        let request = try EditRequest(item: row.id, parent: root, name: row.name, baseVersion: row.contentVersion,
                                      staging: UUID(), failOnConflict: false)
        XCTAssertThrowsError(try catalog.editTarget(request))
        try catalog.setAllowsWriting(true)
        XCTAssertEqual(try catalog.editTarget(request).0.id, row.id)
        try reconcile(catalog, [])
        XCTAssertThrowsError(try catalog.editTarget(request))
        try reconcile(catalog, [file("data")])
        XCTAssertNotEqual(try child(catalog, "data").id, row.id)
        XCTAssertThrowsError(try catalog.editTarget(request))
    }

    func testSaveUpdatesVersionAndPreservesIdentityAndKeep() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("data")])
        let before = try child(catalog, "data")
        try catalog.setKeep(ids: [before.id], value: true)
        let fingerprint = ContentFingerprint(size: 37, mtimeNs: 500, ctimeNs: 600)
        try catalog.updateFingerprint(item: before.id, fingerprint: fingerprint, fileID: 17)
        let after = try child(catalog, "data")
        XCTAssertEqual(after.id, before.id)
        XCTAssertTrue(after.keepRequested)
        XCTAssertEqual(after.contentVersion, fingerprint.contentVersion)
        let anchor = try catalog.currentAnchor()
        XCTAssertFalse(try catalog.updateFingerprint(item: before.id, fingerprint: fingerprint, fileID: 17))
        XCTAssertEqual(try catalog.currentAnchor(), anchor)
    }

    func testInitialFolderNameKeepsIdentityChildrenAndPageOrder() throws {
        let catalog = try makeCatalog()
        try catalog.reconcile(folder: root, listing: DirectoryListing([
            .entry(.init(name: "untitled folder", kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 2, fileID: 10)),
            .entry(.init(name: "other", kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 2, fileID: 20))])) { _ in true }
        let folder = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("untitled folder")))
        try catalog.reconcile(folder: folder.id, listing: DirectoryListing([
            .entry(.init(name: "child", kind: .file, size: 7, mtimeNs: 1, ctimeNs: 2, fileID: 11))])) { _ in true }
        let child = try XCTUnwrap(catalog.liveChild(parent: folder.id, nameKey: NameKey("child")))
        try catalog.setKeep(ids: [child.id], value: true)
        let anchor = try catalog.currentAnchor()
        let before = try catalog.children(of: root, limit: 100).map(\.id)
        try catalog.nameCreatedFolder(id: folder.id, name: "chosen", expectedIdentity: 10, newIdentity: 110)
        XCTAssertEqual(try catalog.liveChild(parent: root, nameKey: NameKey("chosen"))?.id, folder.id)
        XCTAssertNil(try catalog.liveChild(parent: root, nameKey: NameKey("untitled folder")))
        XCTAssertEqual(try catalog.item(id: folder.id)?.row, folder.row)
        XCTAssertEqual(try catalog.remoteIdentity(folder.id), 110)
        try catalog.nameCreatedFolder(id: folder.id, name: "chosen", expectedIdentity: 10, newIdentity: 110)
        XCTAssertEqual(try catalog.relativePath(of: child.id)?.string, "chosen/child")
        XCTAssertEqual(try catalog.keepRequests().map(\.id), [child.id])
        XCTAssertEqual(try catalog.children(of: root, limit: 100).map(\.id), before)
        XCTAssertTrue(try catalog.changes(after: anchor, limit: 100).updated.contains { $0.id == folder.id })
        XCTAssertThrowsError(try catalog.nameCreatedFolder(id: folder.id, name: "other", expectedIdentity: 10))
        XCTAssertThrowsError(try catalog.nameCreatedFolder(id: folder.id, name: "wrong", expectedIdentity: 99))
        XCTAssertEqual(try catalog.item(id: folder.id)?.name, "chosen")
        try catalog.reconcile(folder: root, listing: DirectoryListing([
            .entry(.init(name: "chosen", kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 2, fileID: 110)),
            .entry(.init(name: "other", kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 2, fileID: 20)),
            .entry(.init(name: "untitled folder", kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 2, fileID: 30))])) { _ in true }
        var ids: [String] = []
        var cursor: Int64?
        while let item = try catalog.children(of: root, afterRow: cursor, limit: 1).first {
            ids.append(item.id)
            cursor = item.row
        }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(Array(ids.prefix(2)), before)
    }

    func testCreateWritesSchemaPragmasMetaAndRoot() throws {
        let catalog = try makeCatalog()
        XCTAssertEqual(try scalar(catalog, "PRAGMA journal_mode"), "wal")
        XCTAssertEqual(try scalar(catalog, "PRAGMA synchronous"), "2") // FULL
        XCTAssertEqual(try scalar(catalog, "PRAGMA fullfsync"), "1")
        XCTAssertEqual(try scalar(catalog, "PRAGMA busy_timeout"), "2000")
        let meta = "SELECT id || '|' || domain_id || '|' || length(epoch) || '|' || last_seq || '|' || listing_gen"
            + " || '|' || paused FROM meta"
        XCTAssertEqual(try rows(catalog, meta), ["1|domain-A|16|0|0|0"])
        XCTAssertEqual(try rows(catalog, "SELECT name FROM pragma_table_info('meta')"),
                       ["id", "domain_id", "epoch", "last_seq", "listing_gen", "paused", "allows_writing",
                        "provider_domain_version"])
        XCTAssertEqual(try rows(catalog, "SELECT name FROM pragma_table_info('items')"),
                       ["row", "id", "parent_id", "name", "name_key", "kind", "size", "mtime_ns", "ctime_ns", "file_id",
                        "keep", "list_gen", "listed_at", "deleted", "change_seq", "keep_request", "listing_complete", "enumeration_key", "edit_version"])
        XCTAssertEqual(try rows(catalog, "SELECT name FROM pragma_table_info('departures')"), ["item", "parent", "seq"])
        let indexes = "SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name"
        XCTAssertEqual(try rows(catalog, indexes),
                       ["CREATE INDEX departures_parent ON departures(parent, seq)",
                        "CREATE INDEX items_kept ON items(row) WHERE keep = 1 AND deleted = 0",
                        "CREATE INDEX items_listing ON items(parent_id, enumeration_key, row) WHERE deleted = 0",
                        "CREATE UNIQUE INDEX items_live_name ON items(parent_id, name_key) WHERE deleted = 0"])

        let top = try XCTUnwrap(catalog.item(id: root))
        XCTAssertEqual(top.row, 1)
        XCTAssertNil(top.parentID)
        XCTAssertEqual(top.name, "Movies")
        XCTAssertEqual(top.kind, .folder)
        XCTAssertEqual(top.changeSeq, 0)
        XCTAssertEqual(top.metadataVersion, "0")
        XCTAssertEqual(top.contentVersion, "d1")
        XCTAssertNil(top.listGen)
        XCTAssertFalse(top.deleted || top.keep || top.paused)
        XCTAssertEqual(try catalog.counts(), CatalogCounts(live: 1, tombstones: 0, listedFolders: 0, kept: 0,
                                                           lastSeq: 0, listingGen: 0))
        let epoch = try catalog.database.prepare("SELECT epoch FROM meta") { try $0.step() ? $0.blob(0) : Data() }
        XCTAssertEqual(epoch.count, 16)
        XCTAssertEqual(try catalog.currentAnchor(), Data([0x01]) + epoch + Data(repeating: 0, count: 8))

        let before = try dump(catalog)
        XCTAssertThrowsError(try Catalog.create(at: url(), domainID: "domain-A", rootName: "Other")) {
            XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual(($0 as NSError).code, Int(EEXIST))
        }
        XCTAssertEqual(try dump(catalog), before)
        XCTAssertEqual(try dump(Catalog.open(at: url(), domainID: "domain-A")), before)
    }

    func testOpenChecksDomainAndSchemaAndNeverCreates() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("a.mkv")])
        let before = try dump(catalog)
        for open in openers {
            XCTAssertThrowsError(try open(url(), "domain-B")) {
                XCTAssertEqual($0 as? CatalogError, .otherDomain)
            }
            XCTAssertEqual(try dump(open(url(), "domain-A")), before)
            XCTAssertThrowsError(try open(url("missing"), "domain-A")) {
                XCTAssertEqual($0 as? SQLiteError, SQLiteError(code: SQLITE_CANTOPEN, operation: "open"))
            }
        }

        try Data().write(to: url("empty"))
        for open in openers { XCTAssertThrowsError(try open(url("empty"), "domain-A")) }
        // Nothing was created, and the empty file was not switched to WAL.
        XCTAssertEqual(try fileNames(), ["catalog.sqlite", "catalog.sqlite-shm", "catalog.sqlite-wal", "empty.sqlite"])
        XCTAssertEqual(try Data(contentsOf: url("empty")).count, 0)

    }

    func testOpenRejectsDamagedCountersAndRoot() throws {
        let damage = [
            "UPDATE meta SET last_seq = 9223372036854775807", "UPDATE meta SET last_seq = \(Catalog.maxLastSeq + 1)",
            "UPDATE meta SET last_seq = -3", "UPDATE meta SET last_seq = 2", "UPDATE meta SET listing_gen = -1",
            "UPDATE items SET deleted = 1 WHERE row = 1", "UPDATE items SET kind = 2 WHERE row = 1",
            "UPDATE items SET parent_id = id WHERE row = 1", "UPDATE items SET id = 'other' WHERE row = 1"
        ]
        for (index, sql) in damage.enumerated() {
            let name = "damaged-\(index)"
            let catalog = try makeCatalog(name)
            try reconcile(catalog, [file("a"), file("b"), file("c")])
            try catalog.database.execute(sql, operation: "test")
            for open in openers {
                XCTAssertThrowsError(try open(url(name), "domain-A"), sql) {
                    XCTAssertEqual($0 as? CatalogError, .unsupportedSchema, sql)
                }
            }
        }

        let edge = try makeCatalog("edge")
        try edge.database.execute("UPDATE meta SET last_seq = \(Catalog.maxLastSeq)", operation: "test")
        for open in openers {
            XCTAssertEqual(try open(url("edge"), "domain-A").counts().lastSeq, Catalog.maxLastSeq)
        }
    }

    func testFirstReconcileAssignsIDsAndSequences() throws {
        let catalog = try makeCatalog()
        let plan = try reconcile(catalog, [folder("Season 1"), file("b.mkv", size: 5), file("a.mkv"), folder("Extras")])
        XCTAssertEqual(plan, ReconcilePlan(inserted: 4, updated: 0, tombstoned: 0, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 0))

        let children = try catalog.children(of: root, limit: 100)
        // Pages use name-key order, which folds case, so "a.mkv" comes before "Extras".
        XCTAssertEqual(children.map(\.name), ["a.mkv", "b.mkv", "Extras", "Season 1"])
        XCTAssertEqual(Set(children.map(\.id)).count, 4)
        for child in children {
            XCTAssertNotNil(UUID(uuidString: child.id), child.name)
            XCTAssertEqual(child.parentID, root)
            XCTAssertNil(child.listGen)
            XCTAssertFalse(child.deleted || child.keep)
            XCTAssertEqual(child.metadataVersion, String(child.changeSeq))
        }
        // Sequences follow the listing's name-byte order: "E", "S", "a", "b".
        XCTAssertEqual(try ["Extras", "Season 1", "a.mkv", "b.mkv"].map { try child(catalog, $0).changeSeq }, [1, 2, 3, 4])
        XCTAssertEqual(try child(catalog, "b.mkv").contentVersion, "f1:5:1000:2000")
        XCTAssertEqual(try child(catalog, "Extras").contentVersion, "d1")
        XCTAssertEqual(try child(catalog, "Extras").size, 0)

        let top = try XCTUnwrap(catalog.item(id: root))
        XCTAssertEqual(top.listGen, 1)
        XCTAssertEqual(top.changeSeq, 0)
        XCTAssertLessThan(abs(try XCTUnwrap(top.listedAt).timeIntervalSinceNow), 60)
        XCTAssertEqual(try catalog.counts(), CatalogCounts(live: 5, tombstones: 0, listedFolders: 1, kept: 0,
                                                           lastSeq: 4, listingGen: 1))
    }

    func testIdenticalRelistingChangesNothing() throws {
        let catalog = try makeCatalog()
        let entries = [folder("Season 1"), file("a.mkv"), file("b.mkv")]
        try reconcile(catalog, entries)
        let before = try dump(catalog, listingState: false)

        XCTAssertEqual(try reconcile(catalog, entries), ReconcilePlan(
            inserted: 0, updated: 0, tombstoned: 0, removesEveryChild: false, keptFilesRemoved: 0, unreadableSkipped: 0))
        XCTAssertEqual(try dump(catalog, listingState: false), before)
        XCTAssertEqual(try catalog.counts().lastSeq, 3)
        XCTAssertEqual(try catalog.item(id: root)?.listGen, 2)
        XCTAssertEqual(try catalog.counts().listingGen, 2)
    }

    func testChangedFilesKeepIDAndKeepAndGetNewVersions() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("size.bin"), file("mtime.bin"), file("ctime.bin"), file("same.bin")])
        let names = ["size.bin", "mtime.bin", "ctime.bin"]
        try catalog.setKeep(ids: try (names + ["same.bin"]).map { try child(catalog, $0).id }, value: true)
        let before = try Dictionary(uniqueKeysWithValues: (names + ["same.bin"]).map { ($0, try child(catalog, $0)) })

        let plan = try reconcile(catalog, [file("size.bin", size: 11), file("mtime.bin", mtime: 1_001),
                                           file("ctime.bin", ctime: 2_001), file("same.bin")])
        XCTAssertEqual(plan.updated, 3)
        XCTAssertEqual(plan.inserted + plan.tombstoned, 0)
        for name in names {
            let after = try child(catalog, name)
            let old = try XCTUnwrap(before[name])
            XCTAssertEqual(after.id, old.id, name)
            XCTAssertNotEqual(after.contentVersion, old.contentVersion, name)
            XCTAssertNotEqual(after.metadataVersion, old.metadataVersion, name)
            XCTAssertTrue(after.keep, name)
        }
        XCTAssertEqual(try child(catalog, "same.bin").changeSeq, before["same.bin"]?.changeSeq)
    }

    func testCaseRenameKeyCollisionAndKindChange() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("Movie.mkv"), file("Caf\u{E9}.txt"), file("notes"), folder("Photos")])
        let photos = try child(catalog, "Photos")
        try reconcile(catalog, [file("p1.jpg")], in: photos.id)
        let movie = try child(catalog, "Movie.mkv"), cafe = try child(catalog, "Caf\u{E9}.txt")
        let notes = try child(catalog, "notes"), p1 = try child(catalog, "p1.jpg", in: photos.id)
        let lastSeq = try catalog.counts().lastSeq

        let listing = DirectoryListing([file("movie.MKV"), file("Cafe\u{301}.txt"), folder("notes"), file("Photos"),
                                        file("report.txt"), file("Report.txt")])
        XCTAssertEqual(listing.skipped.collisions, 1)
        let plan = try XCTUnwrap(catalog.reconcile(folder: root, listing: listing) { _ in true })
        XCTAssertEqual(plan, ReconcilePlan(inserted: 3, updated: 2, tombstoned: 3, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 0))

        let renamed = try child(catalog, "MOVIE.mkv")
        XCTAssertEqual(renamed.id, movie.id)
        XCTAssertEqual(Array(renamed.name.utf8), Array("movie.MKV".utf8))
        // A rename that only changes normalization is seen too: String == would call these equal.
        let decomposed = try child(catalog, "cafe\u{301}.txt")
        XCTAssertEqual(decomposed.id, cafe.id)
        XCTAssertEqual(Array(decomposed.name.utf8), Array("Cafe\u{301}.txt".utf8))
        XCTAssertGreaterThan(decomposed.changeSeq, lastSeq)
        // Byte order keeps "Report.txt" (0x52) over "report.txt" (0x72).
        XCTAssertEqual(Array(try child(catalog, "report.txt").name.utf8), Array("Report.txt".utf8))

        for (old, kind) in [(notes, CatalogRow.Kind.folder), (photos, .file)] {
            let tombstone = try XCTUnwrap(catalog.item(id: old.id))
            let replacement = try child(catalog, old.name)
            XCTAssertTrue(tombstone.deleted)
            XCTAssertNotEqual(replacement.id, old.id)
            XCTAssertEqual(replacement.kind, kind)
            // The tombstone comes first, so the system never sees two live items with one name.
            XCTAssertLessThan(tombstone.changeSeq, replacement.changeSeq)
        }
        XCTAssertEqual(try catalog.item(id: p1.id)?.deleted, true)
    }

    func testTheExistingNameWinsAKeyCollision() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("notes.txt"), folder("photos"), file("Caf\u{E9}.txt"), file("readme")])
        let photos = try child(catalog, "photos")
        try reconcile(catalog, [file("a.jpg"), file("b.jpg")], in: photos.id)
        let notes = try child(catalog, "notes.txt")
        try catalog.setKeep(ids: [notes.id], value: true)
        let before = try dump(catalog, listingState: false)

        // Every twin sorts before the stored name, so byte order alone would pick the twin.
        let listings: [[Parsed]] = [
            [file("notes.txt"), folder("Notes.txt"), folder("photos"), file("Caf\u{E9}.txt"), file("readme")],
            [file("notes.txt"), file("Notes.txt", size: 99), folder("photos"), file("Caf\u{E9}.txt"), file("readme")],
            [file("notes.txt"), folder("photos"), folder("Photos"), file("Caf\u{E9}.txt"), file("readme")],
            [file("notes.txt"), folder("photos"), file("Caf\u{E9}.txt"), file("Cafe\u{301}.txt", size: 5), file("readme")],
            [unreadable("notes.txt"), folder("Notes.txt"), folder("photos"), file("Caf\u{E9}.txt"), unreadable("readme"),
             file("README")]
        ]
        for entries in listings {
            let listing = DirectoryListing(entries)
            XCTAssertGreaterThan(listing.skipped.collisions, 0)
            XCTAssertEqual(try catalog.missingChildren(of: root, listing: listing), [])
            XCTAssertEqual(try reconcile(catalog, entries), ReconcilePlan(
                inserted: 0, updated: 0, tombstoned: 0, removesEveryChild: false, keptFilesRemoved: 0,
                unreadableSkipped: 0))
            XCTAssertEqual(try dump(catalog, listingState: false), before)
        }
        XCTAssertEqual(try catalog.relativePath(of: photos.id)?.string, "photos")
        XCTAssertEqual(try reconcile(catalog, [file("a.jpg"), file("b.jpg")], in: photos.id).updated, 0)
        XCTAssertEqual(try child(catalog, "notes.txt").contentVersion, "f1:10:1000:2000")

        // The stored name decides even when an unreadable twin sorts first.
        let changed = try reconcile(catalog, [unreadable("NOTES.TXT"), file("notes.txt", size: 11), folder("photos"),
                                              file("Caf\u{E9}.txt"), file("readme")])
        XCTAssertEqual(changed.updated, 1)
        XCTAssertEqual(changed.inserted + changed.tombstoned + changed.unreadableSkipped, 0)
        XCTAssertEqual(try child(catalog, "notes.txt").id, notes.id)
        XCTAssertEqual(try child(catalog, "notes.txt").contentVersion, "f1:11:1000:2000")

        // A kind change of the stored name itself still replaces the row, whatever its twin is.
        let replaced = try reconcile(catalog, [folder("notes.txt"), file("Notes.txt"), folder("photos"),
                                               file("Caf\u{E9}.txt"), file("readme")])
        XCTAssertEqual(replaced, ReconcilePlan(inserted: 1, updated: 0, tombstoned: 1, removesEveryChild: false,
                                               keptFilesRemoved: 1, unreadableSkipped: 0))
        let folderRow = try child(catalog, "notes.txt")
        XCTAssertNotEqual(folderRow.id, notes.id)
        XCTAssertEqual(folderRow.kind, .folder)
        XCTAssertEqual(Array(folderRow.name.utf8), Array("notes.txt".utf8))
    }

    func testACaseOnlyRenameAmongTwinsTakesTheFirstNameInByteOrder() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("notes.txt")])
        let notes = try child(catalog, "notes.txt")
        let plan = try reconcile(catalog, [file("Notes.txt"), file("NOTES.TXT", size: 3)])
        XCTAssertEqual(plan, ReconcilePlan(inserted: 0, updated: 1, tombstoned: 0, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 0))
        let renamed = try child(catalog, "notes.txt")
        XCTAssertEqual(renamed.id, notes.id)
        XCTAssertEqual(Array(renamed.name.utf8), Array("NOTES.TXT".utf8))
        XCTAssertEqual(renamed.size, 3)
    }

    func testMissingChildrenAreRowsThatLoseTheirStoredName() throws {
        let catalog = try makeCatalog()
        let entries = [file("a.txt"), file("b.txt"), file("c.txt"), folder("Dir"), file("m.txt"), file("u.txt")]
        try reconcile(catalog, entries + [file("gone")])
        try reconcile(catalog, entries)
        let listing = DirectoryListing([file("A.TXT", fileID: 41), unreadable("b.txt"), file("M.TXT"), file("m.txt"),
                                        file("new"), unreadable("U.TXT")])
        // "a.txt" goes to its twin, so its own name must be gone too; an unreadable twin changes nothing.
        XCTAssertEqual(try catalog.missingChildren(of: root, listing: listing),
                       [MissingChild(name: "Dir"), MissingChild(name: "a.txt", twinFileID: 41),
                        MissingChild(name: "c.txt")])
        XCTAssertEqual(try catalog.missingChildren(of: "unknown", listing: listing), [])

        let plan = try XCTUnwrap(catalog.reconcile(folder: root, listing: listing) { _ in true })
        XCTAssertEqual(plan, ReconcilePlan(inserted: 1, updated: 1, tombstoned: 2, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 0))
        XCTAssertEqual(try catalog.missingChildren(of: root, listing: listing), [])
        XCTAssertEqual(try catalog.missingChildren(of: root, listing: DirectoryListing([])).map(\.name),
                       ["A.TXT", "b.txt", "m.txt", "u.txt", "new"])
    }

    func testATwinOfAMissingStoredNameNeedsConfirmation() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("notes.txt"), folder("photos"), file("Caf\u{E9}")])
        // Each stored name is absent, and a twin that sorts first would take or replace its row.
        let listing = DirectoryListing([folder("Notes.txt"), unreadable("notes.TXT"), file("Photos", fileID: 9),
                                        file("Cafe\u{301}", fileID: 10), file("CAF\u{C9}", fileID: 11)])
        XCTAssertEqual(try catalog.missingChildren(of: root, listing: listing),
                       [MissingChild(name: "Caf\u{E9}", twinFileID: 11), MissingChild(name: "notes.txt", twinFileID: 8),
                        MissingChild(name: "photos", twinFileID: 9)])
        XCTAssertEqual(try catalog.missingChildren(of: root, listing: listing).first.map { Array($0.name.utf8) },
                       Array("Caf\u{E9}".utf8))
    }

    func testMissingChildrenAndEveryLiveDescendantAreTombstoned() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [folder("A"), file("x")])
        let a = try child(catalog, "A")
        try reconcile(catalog, [folder("B"), file("d")], in: a.id)
        let b = try child(catalog, "B", in: a.id)
        try reconcile(catalog, [file("c"), file("e")], in: b.id)
        let c = try child(catalog, "c", in: b.id), d = try child(catalog, "d", in: a.id)
        let e = try child(catalog, "e", in: b.id), x = try child(catalog, "x")

        XCTAssertEqual(try reconcile(catalog, [file("c")], in: b.id).tombstoned, 1)
        let eTombstone = try XCTUnwrap(catalog.item(id: e.id))
        XCTAssertTrue(eTombstone.deleted)
        let anchor = try catalog.currentAnchor()
        let lastSeq = try catalog.counts().lastSeq

        let plan = try reconcile(catalog, [file("x")])
        XCTAssertEqual(plan.tombstoned, 4)
        XCTAssertFalse(plan.removesEveryChild)
        let tombstones = try [a, b, c, d].map { try XCTUnwrap(catalog.item(id: $0.id)) }
        XCTAssertTrue(tombstones.allSatisfy(\.deleted))
        XCTAssertEqual(Set(tombstones.map(\.changeSeq)), Set((lastSeq + 1)...(lastSeq + 4)))
        XCTAssertEqual(try catalog.item(id: e.id)?.changeSeq, eTombstone.changeSeq)
        XCTAssertEqual(try catalog.item(id: x.id)?.changeSeq, x.changeSeq)
        XCTAssertEqual(try catalog.counts().tombstones, 5)

        let batch = try catalog.changes(after: anchor, limit: 100)
        XCTAssertTrue(batch.updated.isEmpty)
        XCTAssertEqual(Set(batch.deletedIDs), Set([a.id, b.id, c.id, d.id]))
        XCTAssertEqual(batch.deletedIDs.count, 4)
    }

    func testUnreadableEntriesKeepTheirRowOrAreSkipped() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("old.bin"), folder("Dir")])
        let before = try dump(catalog, listingState: false)

        let plan = try reconcile(catalog, [unreadable("old.bin"), unreadable("Dir"), unreadable("new.bin")])
        XCTAssertEqual(plan, ReconcilePlan(inserted: 0, updated: 0, tombstoned: 0, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 1))
        XCTAssertEqual(try dump(catalog, listingState: false), before)
        XCTAssertNil(try catalog.liveChild(parent: root, nameKey: NameKey("new.bin")))
    }

    func testReconcileRefusesNonFoldersAndARefusedPlanWritesNothing() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [folder("Gone"), file("f")])
        let gone = try child(catalog, "Gone"), f = try child(catalog, "f")
        try reconcile(catalog, [file("f")])
        let before = try dump(catalog)

        let listing = DirectoryListing([file("z")])
        for target in [gone.id, f.id, "unknown"] {
            XCTAssertThrowsError(try catalog.reconcile(folder: target, listing: listing) { _ in true }) {
                XCTAssertEqual($0 as? CatalogError, .notALiveFolder)
            }
            XCTAssertEqual(try dump(catalog), before)
        }

        // accept runs inside the write transaction: another writer can't start meanwhile.
        let other = try SQLiteDatabase(path: path(), flags: SQLITE_OPEN_READWRITE)
        var seen: ReconcilePlan?
        var otherWriter: Int32?
        let applied = try catalog.reconcile(folder: root, listing: DirectoryListing([file("f"), file("new")])) { plan in
            seen = plan
            do { try other.execute("BEGIN IMMEDIATE", operation: "test") } catch {
                otherWriter = (error as? SQLiteError)?.code
            }
            return false
        }
        XCTAssertNil(applied)
        XCTAssertEqual(otherWriter, SQLITE_BUSY)
        XCTAssertEqual(seen, ReconcilePlan(inserted: 1, updated: 0, tombstoned: 0, removesEveryChild: false,
                                           keptFilesRemoved: 0, unreadableSkipped: 0))
        XCTAssertEqual(try dump(catalog), before)
    }

    func testAFailureInsideReconcileRollsBackEveryWrite() throws {
        let catalog = try makeCatalog()
        // The third insert takes sequence 3, which the root now holds: it fails after two writes.
        try catalog.database.execute("UPDATE items SET change_seq = 3 WHERE row = 1", operation: "test")
        let before = try dump(catalog)
        let listing = DirectoryListing(["a", "b", "c", "d"].map { file($0) })
        let sqliteConstraintUnique = SQLITE_CONSTRAINT | 8 << 8
        XCTAssertThrowsError(try catalog.reconcile(folder: root, listing: listing) { _ in true }) {
            XCTAssertEqual(($0 as? SQLiteError)?.code, sqliteConstraintUnique)
        }
        XCTAssertEqual(try dump(catalog), before)
        XCTAssertNotNil(try catalog.reconcile(folder: root, listing: DirectoryListing([])) { _ in true })
    }

    func testOtherMutatorsNeverChangeDeleted() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("live"), file("dead"), folder("Dir")])
        let live = try child(catalog, "live"), dead = try child(catalog, "dead"), dir = try child(catalog, "Dir")
        try catalog.setKeep(ids: [dead.id], value: true)
        try reconcile(catalog, [file("live"), folder("Dir")])
        let deadSeq = try XCTUnwrap(catalog.item(id: dead.id)).changeSeq
        let flags = try rows(catalog, "SELECT id || '|' || deleted FROM items ORDER BY row")

        XCTAssertTrue(try catalog.updateFingerprint(item: live.id, fingerprint: ContentFingerprint(
            size: 99, mtimeNs: 5, ctimeNs: 6), fileID: 7))
        for id in [dead.id, dir.id, "unknown"] {
            XCTAssertThrowsError(try catalog.updateFingerprint(item: id, fingerprint: ContentFingerprint(
                size: 1, mtimeNs: 1, ctimeNs: 1), fileID: 1)) { XCTAssertEqual($0 as? CatalogError, .notALiveFile) }
        }
        XCTAssertEqual(try catalog.setKeep(ids: [live.id, dead.id, dir.id, "unknown"], value: true), 2)
        XCTAssertEqual(try catalog.setPaused(true), 2)
        XCTAssertEqual(try catalog.setPaused(false), 2)
        XCTAssertTrue(try catalog.setRootName("TV"))
        XCTAssertEqual(try catalog.setKeep(ids: [live.id, dead.id], value: false), 1)

        XCTAssertEqual(try rows(catalog, "SELECT id || '|' || deleted FROM items ORDER BY row"), flags)
        XCTAssertEqual(try catalog.item(id: dead.id)?.changeSeq, deadSeq)
        XCTAssertEqual(try catalog.item(id: dead.id)?.keep, true)
    }

    func testUpdateFingerprintChangesVersionsOnlyWhenTheFileChanged() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("a.bin", size: 10, mtime: 1_000, ctime: 2_000, fileID: 7)])
        let a = try child(catalog, "a.bin")
        try catalog.setKeep(ids: [a.id], value: true)
        let kept = try child(catalog, "a.bin")

        XCTAssertFalse(try catalog.updateFingerprint(item: a.id, fingerprint: ContentFingerprint(
            size: 10, mtimeNs: 1_000, ctimeNs: 2_000), fileID: 7))
        XCTAssertEqual(try child(catalog, "a.bin").changeSeq, kept.changeSeq)

        XCTAssertTrue(try catalog.updateFingerprint(item: a.id, fingerprint: ContentFingerprint(
            size: 12, mtimeNs: 1_500, ctimeNs: 2_500), fileID: 7))
        let changed = try child(catalog, "a.bin")
        XCTAssertEqual(changed.id, a.id)
        XCTAssertEqual(changed.contentVersion, "f1:12:1500:2500")
        XCTAssertEqual(changed.changeSeq, kept.changeSeq + 1)
        XCTAssertEqual(try catalog.counts().lastSeq, changed.changeSeq)
        XCTAssertTrue(changed.keep)
    }

    func testStorageSumsMaterializedFilesAndLeavesKeptFiles() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("a", size: 100), file("b", size: 200), file("kept", size: 300), folder("Dir"),
                                file("gone", size: 50), file("other", size: 1_000)])
        let a = try child(catalog, "a"), b = try child(catalog, "b"), kept = try child(catalog, "kept")
        let dir = try child(catalog, "Dir"), gone = try child(catalog, "gone")
        try catalog.setKeep(ids: [kept.id], value: true)
        try reconcile(catalog, [file("a", size: 100), file("b", size: 200), file("kept", size: 300), folder("Dir"),
                                file("other", size: 1_000)])

        let usage = try catalog.storage(materialized: [b.id, a.id, kept.id, dir.id, gone.id, root, "unknown", a.id])
        XCTAssertEqual(usage.bytes, 650)
        XCTAssertEqual(usage.files, 4)
        XCTAssertEqual(usage.removable, [a.id, b.id])
        XCTAssertEqual(usage.removableBytes, 300)
        XCTAssertEqual(try catalog.storage(materialized: []), try catalog.storage(materialized: [dir.id]))
        XCTAssertEqual(try catalog.storage(materialized: []).bytes, 0)
    }

    func testSetKeepAndSetPausedTakeOneSequencePerChangedRow() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("k1"), file("k2"), file("plain"), folder("Dir"), file("gone")])
        let k1 = try child(catalog, "k1"), k2 = try child(catalog, "k2"), plain = try child(catalog, "plain")
        let dir = try child(catalog, "Dir"), gone = try child(catalog, "gone")
        try catalog.setKeep(ids: [gone.id], value: true)
        try reconcile(catalog, [file("k1"), file("k2"), file("plain"), folder("Dir")])
        var last = try catalog.counts().lastSeq

        XCTAssertEqual(try catalog.setKeep(ids: [k1.id, k2.id, dir.id, gone.id, "unknown", k1.id], value: true), 3)
        XCTAssertEqual(try [k1, k2].map { try XCTUnwrap(catalog.item(id: $0.id)).changeSeq }, [last + 1, last + 2])
        XCTAssertEqual(try catalog.item(id: dir.id)?.keep, true)
        last += 3
        XCTAssertEqual(try catalog.counts().lastSeq, last)
        XCTAssertEqual(try catalog.setKeep(ids: [k1.id], value: true), 0)
        XCTAssertEqual(try catalog.counts().lastSeq, last)
        XCTAssertEqual(try catalog.keptItems().map(\.id), [dir.id, k1.id, k2.id])

        let plainSeq = try XCTUnwrap(catalog.item(id: plain.id)).changeSeq
        let goneSeq = try XCTUnwrap(catalog.item(id: gone.id)).changeSeq
        XCTAssertEqual(try catalog.setPaused(true), 3)
        XCTAssertEqual(try [dir, k1, k2].map { try XCTUnwrap(catalog.item(id: $0.id)).changeSeq },
                       [last + 1, last + 2, last + 3])
        XCTAssertEqual(try catalog.item(id: plain.id)?.changeSeq, plainSeq)
        XCTAssertEqual(try catalog.item(id: gone.id)?.changeSeq, goneSeq)
        XCTAssertTrue(try catalog.children(of: root, limit: 10).allSatisfy(\.paused))
        last += 3
        XCTAssertEqual(try catalog.setPaused(true), 0)
        XCTAssertEqual(try catalog.counts().lastSeq, last)

        XCTAssertEqual(try catalog.setPaused(false), 3)
        XCTAssertFalse(try XCTUnwrap(catalog.item(id: k1.id)).paused)
        XCTAssertEqual(try catalog.counts().lastSeq, last + 3)
        XCTAssertEqual(try catalog.setKeep(ids: [k1.id], value: false), 1)
        XCTAssertEqual(try catalog.keptItems().map(\.id), [dir.id, k2.id])
        XCTAssertEqual(try catalog.counts().kept, 2)
    }

    func testSetRootNameTakesASequence() throws {
        let catalog = try makeCatalog()
        let anchor = try catalog.currentAnchor()
        XCTAssertFalse(try catalog.setRootName("Movies"))
        XCTAssertEqual(try catalog.currentAnchor(), anchor)
        XCTAssertTrue(try catalog.setRootName("Films"))
        let batch = try catalog.changes(after: anchor, limit: 10)
        XCTAssertEqual(batch.updated.map(\.id), [root])
        XCTAssertEqual(batch.updated.first?.name, "Films")
        XCTAssertEqual(batch.updated.first?.changeSeq, 1)
    }

    func testChangesReportOrderLimitScopesAndDeletions() throws {
        let catalog = try makeCatalog()
        let start = try catalog.currentAnchor()
        try reconcile(catalog, [folder("A"), file("x"), file("y")])        // A 1, x 2, y 3
        let a = try child(catalog, "A"), x = try child(catalog, "x"), y = try child(catalog, "y")
        try reconcile(catalog, [file("a1"), file("a2")], in: a.id)         // a1 4, a2 5
        let a1 = try child(catalog, "a1", in: a.id), a2 = try child(catalog, "a2", in: a.id)
        try reconcile(catalog, [folder("A"), file("x")])                   // y 6, deleted
        try catalog.setKeep(ids: [x.id], value: true)                      // x 7

        let first = try catalog.changes(after: start, limit: 3)
        XCTAssertEqual(first.updated.map(\.id), [a.id, a1.id, a2.id])
        XCTAssertTrue(first.deletedIDs.isEmpty)
        XCTAssertTrue(first.moreComing)
        XCTAssertEqual(seq(first.anchor, catalog), 5)
        let second = try catalog.changes(after: first.anchor, limit: 3)
        XCTAssertEqual(second.updated.map(\.id), [x.id])
        XCTAssertEqual(second.deletedIDs, [y.id])
        XCTAssertFalse(second.moreComing)
        XCTAssertEqual(second.anchor, try catalog.currentAnchor())
        let upToDate = try catalog.changes(after: second.anchor, limit: 3)
        XCTAssertTrue(upToDate.updated.isEmpty && upToDate.deletedIDs.isEmpty)
        XCTAssertFalse(upToDate.moreComing)
        XCTAssertEqual(upToDate.anchor, second.anchor)

        let full = try catalog.changes(after: start, limit: 5)
        XCTAssertTrue(full.moreComing)
        XCTAssertEqual(seq(full.anchor, catalog), 7)
        XCTAssertFalse(try catalog.changes(after: full.anchor, limit: 5).moreComing)

        let inA = try catalog.changes(after: start, limit: 10, scope: .parent(a.id))
        XCTAssertEqual(inA.updated.map(\.id), [a1.id, a2.id])
        XCTAssertEqual(inA.anchor, try catalog.currentAnchor())
        let inRoot = try catalog.changes(after: start, limit: 10, scope: .parent(root))
        XCTAssertEqual(inRoot.updated.map(\.id), [a.id, x.id])
        XCTAssertEqual(inRoot.deletedIDs, [y.id])
        let rootPage = try catalog.changes(after: start, limit: 1, scope: .parent(root))
        XCTAssertTrue(rootPage.moreComing)
        XCTAssertEqual(seq(rootPage.anchor, catalog), 1)
        XCTAssertEqual(try catalog.changes(after: start, limit: 10, scope: .item(x.id)).updated.map(\.changeSeq), [7])
        XCTAssertEqual(try catalog.changes(after: start, limit: 10, scope: .item(y.id)).deletedIDs, [y.id])
        XCTAssertTrue(try catalog.changes(after: first.anchor, limit: 10, scope: .item(a1.id)).updated.isEmpty)
    }

    func testAnchorsRoundTripAndExpire() throws {
        let catalog = try makeCatalog()
        let other = try makeCatalog("other", domainID: "domain-B")
        try reconcile(catalog, [file("a"), file("b"), file("c")])
        let anchor = try catalog.currentAnchor()
        XCTAssertEqual(anchor.count, 25)
        XCTAssertEqual(anchor.first, 0x01)
        XCTAssertEqual(anchor.dropFirst().prefix(16), catalog.epoch)
        XCTAssertEqual(Array(anchor.suffix(8)), [0, 0, 0, 0, 0, 0, 0, 3])
        XCTAssertEqual(try catalog.changes(after: anchor, limit: 10).anchor, anchor)
        let older = CatalogCursor.anchor(epoch: catalog.epoch, changeSeq: 1)
        XCTAssertEqual(try catalog.changes(after: older, limit: 10).updated.count, 2)

        var wrongTag = anchor
        wrongTag[wrongTag.startIndex] = 0x02
        var random = Data(count: 25)
        for index in random.indices { random[index] = .random(in: .min ... .max) }
        random[random.startIndex] = 0x01
        let expired = [
            wrongTag, try other.currentAnchor(), CatalogCursor.anchor(epoch: catalog.epoch, changeSeq: 4),
            CatalogCursor.anchor(epoch: catalog.epoch, changeSeq: -1), Data(), Data([0x01]), anchor.prefix(24),
            anchor + Data([0]), random, CatalogCursor.folderPage(after: 2)
        ]
        for bad in expired {
            XCTAssertThrowsError(try catalog.changes(after: bad, limit: 10)) {
                XCTAssertEqual($0 as? CatalogError, .anchorExpired)
            }
        }
        // A slice keeps its outer indices; decoding must not depend on them.
        let padded = Data([0xFF]) + anchor
        XCTAssertEqual(try catalog.changes(after: padded.dropFirst(), limit: 10).anchor, anchor)
    }

    func testFolderPagesReturnEachLiveChildOnceAcrossAReconcile() throws {
        let catalog = try makeCatalog()
        let names = (0..<40).map { String(format: "item-%02d", $0) }
        try reconcile(catalog, names.map { file($0) })
        let anchor = try catalog.currentAnchor()
        var seen: [String] = []
        var token: Data?
        func nextPage() throws -> Bool {
            let row = try token.map { try XCTUnwrap(CatalogCursor.folderPageRow($0)) }
            let page = try catalog.children(of: root, afterRow: row, limit: 7)
            seen += page.map(\.name)
            token = page.last.map { CatalogCursor.folderPage(after: $0.row) }
            return page.count == 7
        }
        XCTAssertTrue(try nextPage())
        XCTAssertTrue(try nextPage())
        XCTAssertEqual(seen.last, "item-13")

        // The cursor's own row becomes a tombstone, and its name key still marks the place.
        let kept = names.filter { !["item-03", "item-13", "item-20"].contains($0) }
        try reconcile(catalog, (kept + ["item-05a", "item-30a"]).map { file($0) })
        while try nextPage() {}

        let expected = Array(names[0...13]) + names[14...].filter { $0 != "item-20" }.flatMap {
            $0 == "item-30" ? [$0, "item-30a"] : [$0]
        }
        XCTAssertEqual(seen, expected)
        let changes = try catalog.changes(after: anchor, limit: 100)
        XCTAssertEqual(Set(changes.updated.map(\.name)), ["item-05a", "item-30a"])
        XCTAssertEqual(changes.deletedIDs.count, 3)
    }

    func testPagesOverAThousandChildrenGiveTheLiveSetAndItsCount() throws {
        let catalog = try makeCatalog()
        let names = (0..<1_100).map { String(format: "n%04d", $0) }
        try reconcile(catalog, names.map { file($0) } + [folder("Sub")])
        let sub = try child(catalog, "Sub")
        try reconcile(catalog, [file("inner")], in: sub.id)
        let live = names.enumerated().filter { $0.offset % 10 != 3 }.map(\.element)
        try reconcile(catalog, live.map { file($0) } + [folder("Sub")])

        var seen: [String] = []
        var after: Int64?
        repeat {
            let page = try catalog.children(of: root, afterRow: after, limit: 200)
            seen += page.map(\.name)
            after = page.count == 200 ? page.last?.row : nil
        } while after != nil
        XCTAssertEqual(seen, live + ["Sub"])
        XCTAssertEqual(try catalog.liveChildCount(of: root), live.count + 1)
        XCTAssertEqual(try catalog.liveChildCount(of: sub.id), 1)
        XCTAssertEqual(try catalog.liveChildCount(of: "unknown"), 0)
    }

    func testMalformedPageTokensAreRejected() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [folder("A"), file("b")])
        let a = try child(catalog, "A")
        try reconcile(catalog, [file("inner")], in: a.id)
        let inner = try child(catalog, "inner", in: a.id)

        let page = CatalogCursor.folderPage(after: inner.row)
        XCTAssertEqual(page.count, 9)
        XCTAssertEqual(CatalogCursor.folderPageRow(page), inner.row)
        XCTAssertEqual(CatalogCursor.workingSetPageRow(CatalogCursor.workingSetPage(after: 3)), 3)
        for bad in [Data(), page.prefix(8), page + Data([0]), CatalogCursor.workingSetPage(after: inner.row),
                    CatalogCursor.folderPage(after: 0), CatalogCursor.folderPage(after: -5), try catalog.currentAnchor()] {
            XCTAssertNil(CatalogCursor.folderPageRow(bad))
        }
        XCTAssertNil(CatalogCursor.workingSetPageRow(page))
        for row in [inner.row, 1, 999_999] {
            XCTAssertThrowsError(try catalog.children(of: root, afterRow: row, limit: 10)) {
                XCTAssertEqual($0 as? CatalogError, .pageExpired)
            }
        }
        XCTAssertTrue(try catalog.children(of: a.id, afterRow: inner.row, limit: 10).isEmpty)
    }

    func testWorkingSetPagesEveryLiveRowExceptTheRoot() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, (0..<10).map { file("f\($0)") } + [folder("D")])
        let d = try child(catalog, "D")
        try reconcile(catalog, [file("inner")], in: d.id)
        try reconcile(catalog, (1..<10).map { file("f\($0)") } + [folder("D")]) // f0 goes

        var rows: [Int64] = []
        var token: Data?
        repeat {
            let after = try token.map { try XCTUnwrap(CatalogCursor.workingSetPageRow($0)) }
            let page = try catalog.workingSet(afterRow: after, limit: 4)
            XCTAssertTrue(page.allSatisfy { !$0.deleted && $0.parentID != nil })
            rows += page.map(\.row)
            token = page.count == 4 ? CatalogCursor.workingSetPage(after: page[3].row) : nil
        } while token != nil
        XCTAssertEqual(rows, try self.rows(catalog, "SELECT row FROM items WHERE deleted = 0 AND row > 1 ORDER BY row")
            .map { Int64($0)! })
        XCTAssertEqual(rows.count, 11)
    }

    func testCursorsHoldNoNames() throws {
        let catalog = try makeCatalog()
        let names = (0..<30).map { _ in randomName() }
        try reconcile(catalog, names.prefix(20).map { file($0) } + names.suffix(10).map { folder($0) })
        for name in names.suffix(10) {
            try reconcile(catalog, [file(randomName())], in: try child(catalog, name).id)
        }
        let items = try catalog.workingSet(limit: 1_000)
        XCTAssertEqual(items.count, 40)

        var tokens = [try catalog.currentAnchor()]
        tokens += items.flatMap { [CatalogCursor.folderPage(after: $0.row), CatalogCursor.workingSetPage(after: $0.row)] }
        var anchor = CatalogCursor.anchor(epoch: catalog.epoch, changeSeq: 0)
        var more = true
        while more {
            let batch = try catalog.changes(after: anchor, limit: 1)
            anchor = batch.anchor
            more = batch.moreComing
            tokens.append(anchor)
        }
        for token in tokens {
            XCTAssertTrue([9, 25].contains(token.count))
            for item in items {
                for bytes in [Array(item.name.utf8), Array(NameKey(item.name).value.utf8)] {
                    XCTAssertFalse(contains(Array(token), bytes), "a cursor holds a name")
                }
            }
        }
    }

    func testReadOnlyConnectionSeesCommitsAndCannotWrite() throws {
        var writer: Catalog? = try makeCatalog()
        let reader = try Catalog.open(at: url(), domainID: "domain-A")
        XCTAssertTrue(try reader.children(of: root, limit: 10).isEmpty)
        try reconcile(try XCTUnwrap(writer), [file("a"), folder("B")])
        XCTAssertEqual(try reader.children(of: root, limit: 10).map(\.name), ["a", "B"])
        XCTAssertEqual(try reader.currentAnchor(), try writer?.currentAnchor())
        let a = try child(reader, "a")

        let before = try dump(reader)
        let writes: [() throws -> Void] = [
            { try reader.setKeep(ids: [a.id], value: true) },
            { try reader.reconcile(folder: self.root, listing: DirectoryListing([])) { _ in true } },
            { try reader.setRootName("Other") },
            { try reader.setPaused(true) },
            { try reader.updateFingerprint(item: a.id, fingerprint: ContentFingerprint(size: 1, mtimeNs: 1, ctimeNs: 1),
                                           fileID: 1) }
        ]
        for write in writes {
            XCTAssertThrowsError(try write()) { XCTAssertEqual(($0 as? SQLiteError)?.code, SQLITE_READONLY) }
        }
        XCTAssertEqual(try dump(reader), before)
        try reconcile(try XCTUnwrap(writer), [file("a"), folder("B"), file("c")])
        XCTAssertEqual(try reader.children(of: root, limit: 10).map(\.name), ["a", "B", "c"])

        let saved = try dump(reader)
        writer = nil
        let reopened = try Catalog.openWriter(at: url(), domainID: "domain-A")
        XCTAssertEqual(try scalar(reopened, "PRAGMA synchronous"), "2")
        XCTAssertEqual(try scalar(reopened, "PRAGMA fullfsync"), "1")
        XCTAssertEqual(try dump(reopened), saved)
        XCTAssertEqual(try dump(Catalog.open(at: url(), domainID: "domain-A")), saved)
        try reconcile(reopened, [file("a"), folder("B"), file("c"), file("d")])
        XCTAssertEqual(try child(reopened, "d").changeSeq, 4)
        XCTAssertEqual(try child(reader, "d").changeSeq, 4)
    }

    func testRelativePathsFollowParentsAndStopAtTombstones() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [folder("Movies"), file("top.txt")])
        let movies = try child(catalog, "Movies")
        try reconcile(catalog, [folder("Season 1")], in: movies.id)
        let season = try child(catalog, "Season 1", in: movies.id)
        try reconcile(catalog, [file("Ep 1.mkv")], in: season.id)
        let episode = try child(catalog, "Ep 1.mkv", in: season.id)

        XCTAssertEqual(try catalog.relativePath(of: root), .root)
        XCTAssertEqual(try catalog.relativePath(of: child(catalog, "top.txt").id)?.string, "top.txt")
        XCTAssertEqual(try catalog.relativePath(of: season.id)?.string, "Movies/Season 1")
        XCTAssertEqual(try catalog.relativePath(of: episode.id)?.string, "Movies/Season 1/Ep 1.mkv")
        XCTAssertNil(try catalog.relativePath(of: "unknown"))

        try catalog.database.execute("UPDATE items SET name = 'a/b' WHERE name = 'Season 1'", operation: "test")
        XCTAssertThrowsError(try catalog.relativePath(of: episode.id)) {
            XCTAssertEqual($0 as? SourceFailure, .pathRejected)
        }
        try reconcile(catalog, [], in: movies.id)
        XCTAssertNil(try catalog.relativePath(of: season.id))
        XCTAssertNil(try catalog.relativePath(of: episode.id))
    }

    func testRelativePathLimitsDepthAndLength() throws {
        let catalog = try makeCatalog()
        var parent = root
        var ids: [String] = []
        for _ in 0..<257 {
            try reconcile(catalog, [folder("d")], in: parent)
            parent = try child(catalog, "d", in: parent).id
            ids.append(parent)
        }
        XCTAssertEqual(try catalog.relativePath(of: ids[255])?.string,
                       Array(repeating: "d", count: 256).joined(separator: "/"))
        XCTAssertThrowsError(try catalog.relativePath(of: ids[256])) {
            XCTAssertEqual($0 as? SourceFailure, .pathRejected)
        }

        let wide = try makeCatalog("wide")
        let long = String(repeating: "x", count: 255)
        parent = root
        ids = []
        for _ in 0..<5 {
            try reconcile(wide, [folder(long)], in: parent)
            parent = try child(wide, long, in: parent).id
            ids.append(parent)
        }
        XCTAssertEqual(try wide.relativePath(of: ids[3])?.string.utf8.count, 1_023)
        XCTAssertThrowsError(try wide.relativePath(of: ids[4])) {
            XCTAssertEqual($0 as? SourceFailure, .pathRejected)
        }
    }

    func testContentVersionsAreBoundedAndIgnoreFileID() throws {
        let catalog = try makeCatalog()
        let other = try makeCatalog("other", domainID: "domain-B")
        try reconcile(catalog, [file("max", size: .max, mtime: .min, ctime: .min), file("same", fileID: 1), folder("D")])
        try reconcile(other, [file("same", fileID: 2)])
        XCTAssertLessThanOrEqual(try child(catalog, "max").contentVersion.utf8.count, 128)
        XCTAssertEqual(try child(catalog, "D").contentVersion, "d1")
        XCTAssertEqual(try child(catalog, "same").contentVersion, try child(other, "same").contentVersion)

        let before = try child(catalog, "same")
        XCTAssertEqual(try reconcile(catalog, [file("max", size: .max, mtime: .min, ctime: .min), file("same", fileID: 3),
                                               folder("D")]).updated, 1)
        let relisted = try child(catalog, "same")
        XCTAssertEqual(relisted.contentVersion, before.contentVersion)
        XCTAssertNotEqual(relisted.metadataVersion, before.metadataVersion)
        XCTAssertTrue(try catalog.updateFingerprint(item: relisted.id, fingerprint: ContentFingerprint(
            size: 10, mtimeNs: 1_000, ctimeNs: 2_000), fileID: 4))
        let fetched = try child(catalog, "same")
        XCTAssertEqual(fetched.contentVersion, before.contentVersion)
        XCTAssertNotEqual(fetched.metadataVersion, relisted.metadataVersion)
    }

    func testD5PolicyHoldsBackMassAndKeptRemovals() throws {
        func plan(removesEveryChild: Bool = false, keptFilesRemoved: Int = 0) -> ReconcilePlan {
            ReconcilePlan(inserted: 5, updated: 2, tombstoned: 3, removesEveryChild: removesEveryChild,
                          keptFilesRemoved: keptFilesRemoved, unreadableSkipped: 1)
        }
        XCTAssertFalse(Catalog.needsConfirmation(plan()))
        XCTAssertTrue(Catalog.needsConfirmation(plan(removesEveryChild: true)))
        XCTAssertTrue(Catalog.needsConfirmation(plan(keptFilesRemoved: 1)))
        XCTAssertEqual(Catalog.confirmationDelay, .seconds(15))

        let catalog = try makeCatalog()
        let children = [file("kept.mkv"), file("other"), folder("Dir"), folder("Empty")]
        try reconcile(catalog, children)
        let dir = try child(catalog, "Dir")
        try reconcile(catalog, [file("deep.mkv")], in: dir.id)
        try reconcile(catalog, [], in: try child(catalog, "Empty").id)
        try catalog.setKeep(ids: [try child(catalog, "kept.mkv").id, try child(catalog, "deep.mkv", in: dir.id).id],
                            value: true)
        let before = try dump(catalog)

        let cases: [([Parsed], removesEveryChild: Bool, kept: Int, tombstoned: Int)] = [
            ([file("other"), folder("Dir"), folder("Empty")], false, 1, 1),
            ([file("kept.mkv"), file("other"), folder("Empty")], false, 1, 2),
            ([], true, 2, 5),
            ([file("new")], true, 2, 5)
        ]
        for (entries, removesEveryChild, kept, tombstoned) in cases {
            var seen: ReconcilePlan?
            XCTAssertNil(try catalog.reconcile(folder: root, listing: DirectoryListing(entries)) {
                seen = $0
                return !Catalog.needsConfirmation($0)
            })
            XCTAssertEqual(seen?.removesEveryChild, removesEveryChild)
            XCTAssertEqual(seen?.keptFilesRemoved, kept)
            XCTAssertEqual(seen?.tombstoned, tombstoned)
            XCTAssertEqual(try dump(catalog), before)
        }
        XCTAssertNotNil(try catalog.reconcile(folder: root, listing: DirectoryListing(children + [file("new")])) {
            !Catalog.needsConfirmation($0)
        })
        let empty = try XCTUnwrap(catalog.reconcile(folder: try child(catalog, "Empty").id,
                                                    listing: DirectoryListing([])) { !Catalog.needsConfirmation($0) })
        XCTAssertFalse(empty.removesEveryChild)

        // The confirming listing is applied as it is.
        let confirmed = try reconcile(catalog, [file("other")])
        XCTAssertEqual(confirmed.keptFilesRemoved, 2)
        XCTAssertTrue(try catalog.keptItems().isEmpty)
    }

    func testTwoCatalogsForOneFolderStayIndependent() throws {
        let first = try makeCatalog("first", domainID: "domain-A")
        let second = try makeCatalog("second", domainID: "domain-B")
        let entries = [file("a.mkv"), file("b.mkv"), folder("C")]
        try reconcile(first, entries)
        try reconcile(second, entries)
        let firstIDs = try first.children(of: root, limit: 10).map(\.id)
        let secondIDs = try second.children(of: root, limit: 10).map(\.id)
        XCTAssertTrue(Set(firstIDs).isDisjoint(with: secondIDs))
        XCTAssertNotEqual(first.epoch, second.epoch)
        XCTAssertThrowsError(try second.changes(after: first.currentAnchor(), limit: 10)) {
            XCTAssertEqual($0 as? CatalogError, .anchorExpired)
        }

        let secondBefore = try dump(second)
        try first.setKeep(ids: [try child(first, "a.mkv").id], value: true)
        try reconcile(first, [file("a.mkv")])
        try first.setRootName("First")
        XCTAssertEqual(try dump(second), secondBefore)
        XCTAssertEqual(try first.counts().tombstones, 2)
        XCTAssertEqual(try second.counts().tombstones, 0)
        XCTAssertThrowsError(try Catalog.open(at: url("second"), domainID: "domain-A")) {
            XCTAssertEqual($0 as? CatalogError, .otherDomain)
        }
    }

    func testDeleteRemovesTheWALFilesThenTheCatalog() throws {
        try reconcile(makeCatalog(), [file("a.mkv")])
        _ = try makeCatalog("other")
        // Closed, yet the system SQLite can keep its WAL files, and a crash leaves them too.
        for suffix in ["-wal", "-shm"] { XCTAssertTrue(FileManager.default.createFile(atPath: path() + suffix, contents: nil)) }
        try Catalog.delete(at: url())
        XCTAssertEqual(try fileNames().filter { !$0.hasPrefix("other.") }, [])
        try Catalog.delete(at: url())

        _ = try makeCatalog()
        unlink(path() + "-wal")
        try FileManager.default.createDirectory(atPath: path() + "-wal", withIntermediateDirectories: false)
        XCTAssertThrowsError(try Catalog.delete(at: url()))
        try FileManager.default.removeItem(atPath: path() + "-wal")
        XCTAssertNoThrow(try Catalog.openWriter(at: url(), domainID: "domain-A"))
    }

    // MARK: - Helpers

    private let openers: [(URL, String) throws -> Catalog] = [Catalog.open(at:domainID:),
                                                               Catalog.openWriter(at:domainID:)]

    private func url(_ name: String = "catalog") -> URL { directory.appending(path: name + ".sqlite") }

    private func path(_ name: String = "catalog") -> String {
        url(name).withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }

    private func makeCatalog(_ name: String = "catalog", domainID: String = "domain-A") throws -> Catalog {
        try Catalog.create(at: url(name), domainID: domainID, rootName: "Movies")
    }

    private func file(_ name: String, size: Int64 = 10, mtime: Int64 = 1_000, ctime: Int64 = 2_000,
                      fileID: UInt64 = 7) -> Parsed {
        .entry(.init(name: name, kind: .file, size: size, mtimeNs: mtime, ctimeNs: ctime, fileID: fileID))
    }

    private func folder(_ name: String) -> Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 3_000, ctimeNs: 3_000, fileID: 8))
    }

    private func unreadable(_ name: String) -> Parsed { .unreadable(.init(name: name, error: EIO)) }

    @discardableResult
    private func reconcile(_ catalog: Catalog, _ entries: [Parsed], in folder: String? = nil) throws -> ReconcilePlan {
        try XCTUnwrap(catalog.reconcile(folder: folder ?? root, listing: DirectoryListing(entries)) { _ in true })
    }

    private func child(_ catalog: Catalog, _ name: String, in folder: String? = nil) throws -> CatalogRow {
        try XCTUnwrap(catalog.liveChild(parent: folder ?? root, nameKey: NameKey(name)), name)
    }

    private func rows(_ catalog: Catalog, _ sql: String) throws -> [String] {
        try catalog.database.prepare(sql) { statement in
            var rows: [String] = []
            while try statement.step() { rows.append(statement.text(0)) }
            return rows
        }
    }

    private func scalar(_ catalog: Catalog, _ sql: String) throws -> String? { try rows(catalog, sql).first }

    /// Every row and column; names in hex, because String == treats NFC and NFD as equal.
    private func dump(_ catalog: Catalog, listingState: Bool = true) throws -> [String] {
        let items = ["row", "quote(id)", "quote(parent_id)", "hex(name)", "hex(name_key)", "kind", "size", "mtime_ns",
                     "ctime_ns", "quote(file_id)", "keep", "deleted", "change_seq"]
            + (listingState ? ["quote(list_gen)", "quote(listed_at)"] : [])
        let meta = ["id", "domain_id", "hex(epoch)", "last_seq", "paused"] + (listingState ? ["listing_gen"] : [])
        return try rows(catalog, "SELECT \(items.joined(separator: " || '|' || ")) FROM items ORDER BY row")
            + rows(catalog, "SELECT \(meta.joined(separator: " || '|' || ")) FROM meta")
    }

    private func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
    }

    private func seq(_ anchor: Data, _ catalog: Catalog) -> Int64? {
        CatalogCursor.anchorSeq(anchor, epoch: catalog.epoch, lastSeq: .max)
    }

    private func randomName() -> String {
        let ranges: [ClosedRange<UInt32>] = [0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x391...0x3C9, 0x4E00...0x9FFF,
                                             0x1F600...0x1F64F]
        var name = ""
        while name.utf8.count < 12 {
            name.unicodeScalars.append(Unicode.Scalar(UInt32.random(in: ranges.randomElement()!))!)
        }
        return name
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}
