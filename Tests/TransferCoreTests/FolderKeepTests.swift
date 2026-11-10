import Foundation
import XCTest
@testable import TransferCore

final class FolderKeepTests: XCTestCase {
    private let root = Catalog.rootItemID
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testFolderKeepIncludesKnownAndNewDescendantsAndPreservesIndependentRequests() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree"), file("outside")])
        let tree = try child(catalog, root, "tree")
        try list(catalog, tree.id, [folder("nested"), file("independent"), file("inherited")])
        let nested = try child(catalog, tree.id, "nested")
        let independent = try child(catalog, tree.id, "independent")
        let inherited = try child(catalog, tree.id, "inherited")
        try catalog.setKeep(ids: [independent.id], value: true)
        try catalog.setKeep(ids: [nested.id], value: true)
        try catalog.setKeep(ids: [tree.id], value: true)
        XCTAssertTrue(try catalog.item(id: inherited.id)!.keep)
        XCTAssertFalse(try catalog.item(id: inherited.id)!.keepRequested)
        XCTAssertEqual(try catalog.setKeep(ids: [inherited.id], value: false), 0)
        XCTAssertEqual(Set(try catalog.keepRequests().map(\.id)), [tree.id, nested.id, independent.id])

        try list(catalog, nested.id, [file("new")])
        let new = try child(catalog, nested.id, "new")
        XCTAssertTrue(new.keep)
        XCTAssertFalse(new.keepRequested)
        XCTAssertFalse(try child(catalog, root, "outside").keep)
        XCTAssertTrue(try catalog.storage(materialized: [inherited.id, new.id]).removable.isEmpty)

        let anchor = try catalog.currentAnchor()
        try catalog.setKeep(ids: [tree.id], value: false)
        XCTAssertFalse(try catalog.item(id: inherited.id)!.keep)
        XCTAssertTrue(try catalog.item(id: independent.id)!.keep)
        XCTAssertTrue(try catalog.item(id: nested.id)!.keep)
        XCTAssertTrue(try catalog.item(id: new.id)!.keep)
        XCTAssertEqual(Set(try catalog.changes(after: anchor, limit: 100).updated.map(\.id)), [tree.id, inherited.id])
        try catalog.setKeep(ids: [nested.id], value: false)
        XCTAssertFalse(try catalog.item(id: new.id)!.keep)
        XCTAssertTrue(try catalog.item(id: independent.id)!.keep)
    }

    func testFoldersNeedCompleteListingsAndMaterializationAndEveryFile() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree")])
        let tree = try child(catalog, root, "tree")
        try catalog.setKeep(ids: [tree.id], value: true)
        XCTAssertEqual(try catalog.keepSnapshot().states(files: [:], folders: [tree.id])[tree.id], .requested)
        try list(catalog, tree.id, [folder("empty"), file("data")])
        let empty = try child(catalog, tree.id, "empty"), data = try child(catalog, tree.id, "data")
        let complete: [String: OfflineState] = [data.id: .availableOffline]
        XCTAssertEqual(try catalog.keepSnapshot().states(files: complete, folders: [tree.id, empty.id])[tree.id],
                       .requested)
        try list(catalog, empty.id, [])
        let snapshot = try catalog.keepSnapshot()
        XCTAssertEqual(snapshot.states(files: complete, folders: [tree.id])[tree.id], .requested)
        XCTAssertEqual(snapshot.states(files: [:], folders: [tree.id, empty.id])[tree.id], .requested)
        XCTAssertEqual(snapshot.states(files: [data.id: .updateInProgress], folders: [tree.id, empty.id])[tree.id],
                       .updateInProgress)
        XCTAssertEqual(snapshot.states(files: complete, folders: [tree.id, empty.id])[tree.id], .availableOffline)
        try catalog.updateFingerprint(item: data.id, fingerprint: ContentFingerprint(size: 1, mtimeNs: 1, ctimeNs: 2),
                                      fileID: 1)
        XCTAssertNotEqual(try catalog.keepSnapshot(), snapshot)
    }

    func testSkippedAndUnreadableContentsPreventPositiveFolderStatus() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree")])
        let tree = try child(catalog, root, "tree")
        try catalog.setKeep(ids: [tree.id], value: true)
        let cases: [[DirectoryListing.Parsed]] = [
            [.otherKind], [.invalidName], [.unreadable(.init(name: "data", error: 13))],
            [file("same"), file("SAME")]
        ]
        for parsed in cases {
            try list(catalog, tree.id, parsed)
            XCTAssertFalse(try catalog.item(id: tree.id)!.listingComplete)
            let snapshot = try catalog.keepSnapshot()
            let complete = Dictionary(uniqueKeysWithValues: snapshot.items.filter { $0.kind == .file }
                .map { ($0.id, OfflineState.availableOffline) })
            XCTAssertEqual(snapshot.states(files: complete, folders: [tree.id])[tree.id], .requested)
        }
    }

    func testNewKeepRequestDoesNotResetAnUnchangedVerifiedFile() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [file("first"), file("second")])
        let first = try child(catalog, root, "first"), second = try child(catalog, root, "second")
        try catalog.setKeep(ids: [first.id], value: true)
        var verification = OfflineVerification()
        let complete: [String: OfflineState] = [first.id: .availableOffline, second.id: .availableOffline]
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete, folders: [], synchronized: true)
        try catalog.setKeep(ids: [second.id], value: true)
        let states = verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                         folders: [], synchronized: false)
        XCTAssertEqual(states[first.id], .availableOffline)
        XCTAssertEqual(states[second.id], .requested)
        XCTAssertEqual(verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                           folders: [], synchronized: true)[second.id], .availableOffline)
    }

    func testChangedVersionNeedsSynchronizationEvenWhenLocalSizeAndDateMatch() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [file("changed"), file("unchanged")])
        let changed = try child(catalog, root, "changed"), unchanged = try child(catalog, root, "unchanged")
        try catalog.setKeep(ids: [changed.id, unchanged.id], value: true)
        var verification = OfflineVerification()
        let complete: [String: OfflineState] = [changed.id: .availableOffline, unchanged.id: .availableOffline]
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete, folders: [], synchronized: true)
        try catalog.updateFingerprint(item: changed.id, fingerprint: .init(size: 1, mtimeNs: 1, ctimeNs: 2), fileID: 1)
        let states = verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                         folders: [], synchronized: false)
        XCTAssertEqual(states[changed.id], .requested)
        XCTAssertEqual(states[unchanged.id], .availableOffline)
    }

    func testMissingOrUpdatingLocalCopyLosesItsPreviousVerification() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [file("data")])
        let data = try child(catalog, root, "data")
        try catalog.setKeep(ids: [data.id], value: true)
        let snapshot = try catalog.keepSnapshot()
        let complete: [String: OfflineState] = [data.id: .availableOffline]
        for observed: [String: OfflineState] in [[:], [data.id: .requested], [data.id: .updateInProgress]] {
            var verification = OfflineVerification()
            _ = verification.states(snapshot: snapshot, files: complete, folders: [], synchronized: true)
            XCTAssertNotEqual(verification.states(snapshot: snapshot, files: observed,
                                                  folders: [], synchronized: false)[data.id], .availableOffline)
            XCTAssertEqual(verification.states(snapshot: snapshot, files: complete,
                                               folders: [], synchronized: false)[data.id], .requested)
        }
    }

    func testRemovedKeepRequestAndNewVerifierCannotReusePreviousVerification() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [file("data")])
        let data = try child(catalog, root, "data")
        try catalog.setKeep(ids: [data.id], value: true)
        var verification = OfflineVerification()
        let complete: [String: OfflineState] = [data.id: .availableOffline]
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete, folders: [], synchronized: true)
        try catalog.setKeep(ids: [data.id], value: false)
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete, folders: [], synchronized: false)
        try catalog.setKeep(ids: [data.id], value: true)
        XCTAssertEqual(verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                           folders: [], synchronized: false)[data.id], .requested)
        verification = OfflineVerification()
        XCTAssertEqual(verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                           folders: [], synchronized: false)[data.id], .requested)
    }

    func testVerifiedFolderRechecksMembershipListingsAndMaterialization() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree"), file("outside")])
        let tree = try child(catalog, root, "tree"), outside = try child(catalog, root, "outside")
        try list(catalog, tree.id, [file("data")])
        let data = try child(catalog, tree.id, "data")
        try catalog.setKeep(ids: [tree.id, outside.id], value: true)
        var verification = OfflineVerification()
        var complete: [String: OfflineState] = [data.id: .availableOffline, outside.id: .availableOffline]
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                folders: [tree.id], synchronized: true)
        XCTAssertEqual(verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                           folders: [], synchronized: false)[tree.id], .requested)
        try list(catalog, tree.id, [file("data"), file("new")])
        let new = try child(catalog, tree.id, "new")
        complete[new.id] = .availableOffline
        let states = verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                         folders: [tree.id], synchronized: false)
        XCTAssertEqual(states[tree.id], .requested)
        XCTAssertEqual(states[outside.id], .availableOffline)
        _ = verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                folders: [tree.id], synchronized: true)
        try list(catalog, tree.id, [file("data"), file("new"), .otherKind])
        XCTAssertEqual(verification.states(snapshot: try catalog.keepSnapshot(), files: complete,
                                           folders: [tree.id], synchronized: false)[tree.id], .requested)
    }

    func testEmptyFolderCanBeAvailableAndPausePreservesRequests() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("empty")])
        let empty = try child(catalog, root, "empty")
        try list(catalog, empty.id, [])
        try catalog.setKeep(ids: [empty.id], value: true)
        try catalog.setPaused(true)
        XCTAssertTrue(try catalog.item(id: empty.id)!.paused)
        XCTAssertTrue(try catalog.item(id: empty.id)!.keepRequested)
        XCTAssertEqual(try catalog.keepSnapshot().states(files: [:], folders: [empty.id])[empty.id], .availableOffline)
        try catalog.setPaused(false)
        XCTAssertFalse(try catalog.item(id: empty.id)!.paused)
        XCTAssertTrue(try catalog.item(id: empty.id)!.keep)
    }

    func testObservedFolderChangeInvalidatesItsPreviousCompleteListing() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree")])
        let tree = try child(catalog, root, "tree")
        try list(catalog, tree.id, [])
        try catalog.setKeep(ids: [tree.id], value: true)
        XCTAssertEqual(try catalog.keepSnapshot().states(files: [:], folders: [tree.id])[tree.id], .availableOffline)
        try list(catalog, root, [.entry(.init(name: "tree", kind: .folder, size: 0,
                                            mtimeNs: 2, ctimeNs: 2, fileID: 1))])
        XCTAssertEqual(try child(catalog, root, "tree").id, tree.id)
        XCTAssertFalse(try catalog.item(id: tree.id)!.listingComplete)
        XCTAssertEqual(try catalog.keepSnapshot().states(files: [:], folders: [tree.id])[tree.id], .requested)
        try list(catalog, tree.id, [])
        XCTAssertEqual(try catalog.keepSnapshot().states(files: [:], folders: [tree.id])[tree.id], .availableOffline)
    }

    func testTypedSavedRequestsRoundTrip() throws {
        let file = KeepPath(path: "tree/data", kind: .file)
        let folder = KeepPath(path: "tree", kind: .folder)
        var record = LocationRecord(name: "test", shareID: UUID(), folder: .root)
        record.pendingKeeps = [file, folder]
        let settings = AppSettings(locations: [record], savedKeeps: [.init(host: "home-nas", share: "share",
                                                                        paths: [file, folder])])
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(folder.below(RelativePath("tree")!), .root)
        XCTAssertNil(KeepPath(path: "tree", kind: .file).below(RelativePath("tree")!))
    }

    private func makeCatalog() throws -> Catalog {
        try Catalog.create(at: directory.appending(path: "catalog.sqlite"), domainID: "test", rootName: "test")
    }

    func testLowSpaceReachesKeptParentAndDoesNotResetVerifiedIndependentFile() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [folder("tree"), file("independent")])
        let tree = try child(catalog, root, "tree"), independent = try child(catalog, root, "independent")
        try list(catalog, tree.id, [file("waiting"), file("blocked")])
        let blocked = try child(catalog, tree.id, "blocked")
        try catalog.setKeep(ids: [tree.id, independent.id], value: true)
        let snapshot = try catalog.keepSnapshot()
        var verification = OfflineVerification()
        let states = verification.states(snapshot: snapshot, files: [independent.id: .availableOffline],
                                         folders: [tree.id], synchronized: true, spaceBlocked: [blocked.id])
        XCTAssertEqual(states[tree.id], .notSufficientSpace)
        XCTAssertEqual(states[independent.id], .availableOffline)
        let repeated = verification.states(snapshot: snapshot, files: [independent.id: .availableOffline],
                                           folders: [tree.id], synchronized: false, spaceBlocked: [blocked.id])
        XCTAssertEqual(repeated[independent.id], .availableOffline)
        XCTAssertEqual(repeated[tree.id], .notSufficientSpace)
        let completed = Dictionary(uniqueKeysWithValues: snapshot.items.filter { $0.kind == .file }
            .map { ($0.id, OfflineState.availableOffline) })
        let recovered = verification.states(snapshot: snapshot, files: completed, folders: [tree.id],
                                            synchronized: true, spaceBlocked: [blocked.id])
        XCTAssertEqual(recovered[tree.id], .availableOffline)
    }

    func testRestoredVersionsAreTrustedOnlyForMatchingLocalCopiesAndVersions() throws {
        let catalog = try makeCatalog()
        try list(catalog, root, [file("same"), file("updating"), file("changed"), file("new")])
        let same = try child(catalog, root, "same"), updating = try child(catalog, root, "updating")
        let changed = try child(catalog, root, "changed"), new = try child(catalog, root, "new")
        try catalog.setKeep(ids: [same.id, updating.id, changed.id], value: true)
        var earlier = OfflineVerification()
        let complete: [String: OfflineState] = [same.id: .availableOffline, updating.id: .availableOffline,
                                                changed.id: .availableOffline, new.id: .availableOffline]
        _ = earlier.states(snapshot: try catalog.keepSnapshot(), files: complete, folders: [], synchronized: true)
        let domain = UUID().uuidString, url = directory.appending(path: VerifiedVersions.fileName)
        try VerifiedVersions.save([domain: earlier.versions], to: url)

        var restored = OfflineVerification(versions: try VerifiedVersions.load(from: url)[domain] ?? [:])
        let local: [String: OfflineState] = [same.id: .availableOffline, changed.id: .availableOffline]
        XCTAssertEqual(restored.states(snapshot: try catalog.keepSnapshot(), files: local,
                                       folders: [], synchronized: false)[same.id], .availableOffline)

        try catalog.updateFingerprint(item: changed.id, fingerprint: .init(size: 1, mtimeNs: 1, ctimeNs: 2), fileID: 1)
        try catalog.setKeep(ids: [new.id], value: true)
        var observed = complete
        observed[updating.id] = .updateInProgress
        let states = restored.states(snapshot: try catalog.keepSnapshot(), files: observed,
                                     folders: [], synchronized: false)
        XCTAssertEqual(states[same.id], .availableOffline)
        XCTAssertEqual(states[updating.id], .updateInProgress)
        XCTAssertEqual(states[changed.id], .requested)
        XCTAssertEqual(states[new.id], .requested)
        XCTAssertEqual(restored.versions, [same.id: same.contentVersion])
    }

    func testVerifiedVersionsRoundTripAndRejectCorruptFiles() throws {
        let url = directory.appending(path: VerifiedVersions.fileName)
        XCTAssertEqual(try VerifiedVersions.load(from: url), [:])
        let kept = UUID().uuidString, empty = UUID().uuidString
        try VerifiedVersions.save([kept: [Catalog.rootItemID: "f1:1:1:1", UUID().uuidString: "f1:2:2:2"],
                                   empty: [:]], to: url)
        let loaded = try VerifiedVersions.load(from: url)
        XCTAssertEqual(loaded.keys.sorted(), [kept])
        XCTAssertEqual(loaded[kept]?.count, 2)
        for corrupt in [Data("{".utf8), Data(#"{"test":{}}"#.utf8),
                        Data(#"{"\#(kept)":{"../data":"f1:1:1:1"}}"#.utf8),
                        Data(#"{"\#(kept)":{"\#(UUID().uuidString)":""}}"#.utf8)] {
            try corrupt.write(to: url)
            XCTAssertThrowsError(try VerifiedVersions.load(from: url))
        }
        XCTAssertThrowsError(try VerifiedVersions.save(["test": [:]], to: url))
    }

    private func child(_ catalog: Catalog, _ parent: String, _ name: String) throws -> CatalogRow {
        try XCTUnwrap(catalog.liveChild(parent: parent, nameKey: NameKey(name)))
    }

    private func list(_ catalog: Catalog, _ parent: String, _ entries: [DirectoryListing.Parsed]) throws {
        try catalog.reconcile(folder: parent, listing: DirectoryListing(entries)) { _ in true }
    }

    private func file(_ name: String) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .file, size: 1, mtimeNs: 1, ctimeNs: 1, fileID: 1))
    }

    private func folder(_ name: String) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: .folder, size: 0, mtimeNs: 1, ctimeNs: 1, fileID: 1))
    }
}
