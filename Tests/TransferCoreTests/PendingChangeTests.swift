import Foundation
import XCTest
@testable import TransferCore

final class PendingChangeTests: XCTestCase {
    private var directory: URL!
    private var catalog: Catalog!
    private var folder: CatalogRow!
    private var file: CatalogRow!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        catalog = try Catalog.create(at: directory.appending(path: "catalog.sqlite"),
                                     domainID: "pending-test", rootName: "Location")
        try reconcile(Catalog.rootItemID, [entry("Folder", kind: .folder)])
        folder = try XCTUnwrap(catalog.liveChild(parent: Catalog.rootItemID, nameKey: NameKey("Folder")))
        try reconcile(folder.id, [entry("Original.txt", kind: .file)])
        file = try XCTUnwrap(catalog.liveChild(parent: folder.id, nameKey: NameKey("Original.txt")))
    }

    override func tearDownWithError() throws {
        catalog = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testRefusedRenameShowsBothPathsWithoutChangingTheCatalog() throws {
        let anchor = try catalog.currentAnchor()
        let pending = try change(file, name: "Renamed.txt", parent: folder.id)
        XCTAssertEqual(pending.path, "Folder/Renamed.txt")
        XCTAssertEqual(pending.originalPath, "Folder/Original.txt")
        XCTAssertEqual(try catalog.currentAnchor(), anchor)
        XCTAssertEqual(try catalog.item(id: file.id), file)
    }

    func testMoveAndFolderRenameHaveRecoveryPaths() throws {
        XCTAssertEqual(try change(file, name: file.name, parent: Catalog.rootItemID).originalPath,
                       "Folder/Original.txt")
        XCTAssertEqual(try change(folder, name: "NewFolder", parent: Catalog.rootItemID).originalPath,
                       "Folder")
    }

    func testContentOnlyAndUnresolvedChangesHaveNoOrganizationGuidance() throws {
        XCTAssertNil(try change(file, name: file.name, parent: folder.id, refused: false).originalPath)
        XCTAssertNil(try change(file, name: "Renamed.txt", parent: folder.id, unresolved: true).originalPath)
        XCTAssertNil(try change(file, name: "Renamed.txt", parent: folder.id, trashed: true).originalPath)
    }

    func testMissingOrRetiredBindingsNeverSuggestRestoringAPath() throws {
        let unknown = try PendingChange(item: UUID().uuidString, name: "New.txt", parent: UUID().uuidString,
                                        trashed: false, organizationRefused: true,
                                        hasUnresolvedRename: false, catalog: catalog)
        XCTAssertEqual(unknown.path, "New.txt")
        XCTAssertNil(unknown.originalPath)
        try reconcile(folder.id, [])
        XCTAssertNil(try change(file, name: "Renamed.txt", parent: folder.id).originalPath)
    }

    func testSystemServerMetadataStillShowsTheRestorePath() throws {
        XCTAssertEqual(try change(file, name: file.name, parent: folder.id).originalPath,
                       "Folder/Original.txt")
    }

    private func change(_ row: CatalogRow, name: String, parent: String,
                        unresolved: Bool = false, trashed: Bool = false, refused: Bool = true) throws -> PendingChange {
        try PendingChange(item: row.id, name: name, parent: parent, trashed: trashed, organizationRefused: refused,
                          hasUnresolvedRename: unresolved, catalog: catalog)
    }

    private func entry(_ name: String, kind: CatalogRow.Kind) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: kind == .folder ? .folder : .file,
                     size: 0, mtimeNs: 1_000, ctimeNs: 1_000, fileID: kind == .folder ? 1 : 2))
    }

    private func reconcile(_ parent: String, _ entries: [DirectoryListing.Parsed]) throws {
        _ = try catalog.reconcile(folder: parent, listing: DirectoryListing(entries)) { _ in true }
    }
}
