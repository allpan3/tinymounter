import Foundation
import XCTest
@testable import TransferCore

final class ProviderCatalogTests: XCTestCase {
    private let root = Catalog.rootItemID
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUnifiedWriteModeUpdatesMetadataWithoutChangingIDsKeepsOrContents() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("a"), file("b")])
        let row = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("a")))
        _ = try catalog.setKeep(ids: [row.id], value: true)
        let initial = try XCTUnwrap(catalog.item(id: row.id))
        let cursor = try catalog.folderPage(root, token: nil, size: 1).next
        try catalog.setAllowsWriting(true)
        let writable = try XCTUnwrap(catalog.item(id: row.id))
        XCTAssertTrue(writable.allowsWriting)
        XCTAssertEqual(writable.contentVersion, initial.contentVersion)
        XCTAssertTrue(writable.keepRequested)
        XCTAssertEqual(writable.row, initial.row)
        XCTAssertGreaterThan(writable.changeSeq, initial.changeSeq)
        try catalog.setAllowsWriting(true)
        XCTAssertEqual(try catalog.item(id: row.id), writable)
        try catalog.setAllowsWriting(false)
        let readOnly = try XCTUnwrap(catalog.item(id: row.id))
        XCTAssertFalse(readOnly.allowsWriting)
        XCTAssertTrue(readOnly.keepRequested)
        XCTAssertEqual(readOnly.contentVersion, initial.contentVersion)
        XCTAssertEqual(try catalog.folderPage(root, token: cursor, size: 1).rows.count, 1)
    }

    func testPageSizeIsTheSuggestionWithinBounds() {
        XCTAssertEqual(CatalogPage.size(suggested: nil), 200)
        XCTAssertEqual(CatalogPage.size(suggested: 37), 37)
        XCTAssertEqual(CatalogPage.size(suggested: 0), 1)
        XCTAssertEqual(CatalogPage.size(suggested: -5), 1)
        XCTAssertEqual(CatalogPage.size(suggested: 100_000), 1_000)
    }

    func testFolderPagesFollowTheirTokensToTheLiveSet() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, (0..<1_001).map { file("f\($0)") } + [folder("D")])
        try reconcile(catalog, (1..<1_001).map { file("f\($0)") } + [folder("D")]) // f0 goes
        let d = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("D")))
        try reconcile(catalog, [file("inner")], in: d.id)

        for size in [1_000, 200, 7] {
            var ids: [String] = []
            var token: Data?
            var pages = 0
            repeat {
                let page = try catalog.folderPage(root, token: token, size: size)
                XCTAssertLessThanOrEqual(page.rows.count, size)
                XCTAssertTrue(page.rows.allSatisfy { !$0.deleted && $0.parentID == root })
                ids += page.rows.map(\.id)
                token = page.next
                pages += 1
            } while token != nil
            XCTAssertEqual(ids.count, 1_001)
            XCTAssertEqual(Set(ids).count, 1_001)
            XCTAssertEqual(pages, 1_001 / size + 1, "a full last page ends with an empty one")
            XCTAssertEqual(ids.count, try catalog.liveChildCount(of: root))
        }
        XCTAssertNil(try catalog.folderPage(d.id, token: nil, size: 2).next)
        XCTAssertEqual(try catalog.folderPage(d.id, token: nil, size: 1).rows.map(\.name), ["inner"])
    }

    func testMalformedOrForeignPageTokensExpire() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [file("a"), file("b"), folder("D")])
        let d = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("D")))
        try reconcile(catalog, [file("inner")], in: d.id)
        let inner = try XCTUnwrap(catalog.liveChild(parent: d.id, nameKey: NameKey("inner")))
        let first = try XCTUnwrap(catalog.folderPage(root, token: nil, size: 1).next)

        for token in [Data(), Data([0x02]), CatalogCursor.workingSetPage(after: 2), CatalogCursor.folderPage(after: 0),
                      CatalogCursor.folderPage(after: inner.row), CatalogCursor.folderPage(after: 999)] {
            XCTAssertThrowsError(try catalog.folderPage(root, token: token, size: 1)) {
                XCTAssertEqual($0 as? CatalogError, .pageExpired)
            }
        }
        XCTAssertThrowsError(try catalog.workingSetPage(token: first, size: 1)) {
            XCTAssertEqual($0 as? CatalogError, .pageExpired)
        }
        XCTAssertEqual(try catalog.folderPage(root, token: first, size: 1).rows.count, 1)
    }

    func testWorkingSetPagesEndOnAShortPage() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, (0..<9).map { file("f\($0)") })
        var rows: [Int64] = []
        var token: Data?
        repeat {
            let page = try catalog.workingSetPage(token: token, size: 4)
            rows += page.rows.map(\.row)
            token = page.next
        } while token != nil
        XCTAssertEqual(rows, Array(2...10))
    }

    func testReimportMatchesALiveRowAndDiscardsOnlyAnEmptyFileCopy() throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(isReject(try decide(catalog, parent: root, name: "new", kind: .file, hasContents: false)),
                      "a parent that was never listed proves nothing")
        try reconcile(catalog, [file("Movie.mkv"), folder("D"), file("gone")])
        try reconcile(catalog, [file("Movie.mkv"), folder("D")]) // "gone" becomes a tombstone
        let movie = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("Movie.mkv")))
        let d = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("D")))

        for hasContents in [false, true] {
            guard case .existing(let row) = try catalog.reimportDecision(
                parent: root, name: "movie.MKV", kind: .file, hasContents: hasContents, size: movie.size,
                modified: movie.modificationDate) else {
                return XCTFail("a live name key matches")
            }
            XCTAssertEqual(row.id, movie.id)
        }
        guard case .existing(let folderRow) = try decide(catalog, parent: root, name: "D", kind: .folder,
                                                                hasContents: false) else {
            return XCTFail("a live folder matches")
        }
        XCTAssertEqual(folderRow.id, d.id)

        guard case .discard = try decide(catalog, parent: root, name: "gone", kind: .file, hasContents: false) else {
            return XCTFail("a file copy without data that no live row has may go")
        }
        let rejected: [(String, String, CatalogRow.Kind?, Bool)] = [
            (root, "gone", .file, true),          // contents may be the user's only copy
            (root, "gone", .folder, false),       // a folder may hold such files
            (root, "new", .folder, false),
            (root, "D", .file, false),            // another kind is not the same item
            (root, "Movie.mkv", .folder, false),
            (root, "new", nil, false),            // neither a file nor a folder
            (d.id, "new", .file, false),          // D was never listed
            ("6D5B8B2C-7F0E-4C1D-9A47-3B1E5F0A2C11", "new", .file, false), // unknown parent
            (movie.id, "new", .file, false),      // a file is no parent
        ]
        for (parent, name, kind, hasContents) in rejected {
            XCTAssertTrue(isReject(try decide(catalog, parent: parent, name: name, kind: kind,
                                              hasContents: hasContents)), name)
        }
    }

    func testReimportUnderATombstonedFolderIsRejected() throws {
        let catalog = try makeCatalog()
        try reconcile(catalog, [folder("D")])
        let d = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("D")))
        try reconcile(catalog, [file("inner")], in: d.id)
        try reconcile(catalog, [file("other")]) // D and inner become tombstones
        XCTAssertTrue(isReject(try decide(catalog, parent: d.id, name: "inner", kind: .file, hasContents: false)))
        XCTAssertTrue(isReject(try decide(catalog, parent: d.id, name: "new", kind: .file, hasContents: false)))
    }

    func testReimportPreservesUncertainContentsInBothAccessModes() throws {
        let catalog = try makeCatalog()
        let old: Int64 = 1_760_000_000_123_456_700, new = old + 3_600_000_000_000
        try reconcile(catalog, [file("report.pdf", size: 4096, mtimeNs: old), file("neighbor")])
        let downloaded = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("report.pdf")))
        let date = downloaded.modificationDate
        for writable in [false, true] {
            try catalog.setAllowsWriting(writable)
            _ = try catalog.setKeep(ids: [downloaded.id], value: true)
            let before = try catalog.children(of: root, limit: 100)
            let uncertain: [(Int64?, Date?, String)] = [
                (4096, date + 2e-6, "an unsent edit with a newer timestamp"),
                (4096, date - 2e-6, "an older downloaded copy"),
                (4095, date, "changed size with an unchanged timestamp"),
                (nil, date, "missing size"),
                (4096, nil, "missing timestamp"),
            ]
            for (size, modified, label) in uncertain {
                XCTAssertTrue(isReject(try catalog.reimportDecision(
                    parent: root, name: "Report.PDF", kind: .file, hasContents: true,
                    size: size, modified: modified)), label)
            }
            for modified in [date, Date(timeIntervalSince1970: 1_760_000_000.123456)] {
                guard case .existing(let row) = try catalog.reimportDecision(
                    parent: root, name: "report.pdf", kind: .file, hasContents: true,
                    size: 4096, modified: modified) else {
                    return XCTFail("matching metadata keeps the local copy")
                }
                XCTAssertEqual(row.id, downloaded.id)
            }
            XCTAssertEqual(try catalog.children(of: root, limit: 100), before,
                           "recovery changes neither catalog versions, keeps nor neighbors")
        }
        guard case .existing = try decide(catalog, parent: root, name: "report.pdf", kind: .file,
                                           hasContents: false) else {
            return XCTFail("a placeholder has no local content to preserve")
        }

        try reconcile(catalog, [file("report.pdf", size: 4096, mtimeNs: new), file("neighbor")])
        XCTAssertTrue(isReject(try catalog.reimportDecision(
            parent: root, name: "report.pdf", kind: .file, hasContents: true, size: 4096, modified: date)),
            "a remote update must not cause uncertain local contents to be replaced or uploaded")
        let current = try XCTUnwrap(catalog.liveChild(parent: root, nameKey: NameKey("report.pdf")))
        XCTAssertEqual(current.id, downloaded.id)
        guard case .existing = try catalog.reimportDecision(
            parent: root, name: "report.pdf", kind: .file, hasContents: true, size: 4096,
            modified: current.modificationDate) else {
            return XCTFail("matching current metadata stays")
        }
    }

    private func decide(_ catalog: Catalog, parent: String, name: String, kind: CatalogRow.Kind?,
                        hasContents: Bool) throws -> ReimportDecision {
        try catalog.reimportDecision(parent: parent, name: name, kind: kind, hasContents: hasContents, size: nil,
                                     modified: nil)
    }

    private func isReject(_ decision: ReimportDecision) -> Bool {
        if case .reject = decision { return true }
        return false
    }

    private func makeCatalog() throws -> Catalog {
        try Catalog.create(at: directory.appending(path: "catalog.sqlite"), domainID: "domain-A", rootName: "Movies")
    }

    private func file(_ name: String, size: Int64 = 10, mtimeNs: Int64 = 1_000) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .file, size: size, mtimeNs: mtimeNs, ctimeNs: 2_000, fileID: 7))
    }

    private func folder(_ name: String) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 3_000, ctimeNs: 3_000, fileID: 8))
    }

    private func reconcile(_ catalog: Catalog, _ entries: [DirectoryListing.Parsed], in folder: String? = nil) throws {
        XCTAssertNotNil(try catalog.reconcile(folder: folder ?? root, listing: DirectoryListing(entries)) { _ in true })
    }
}
