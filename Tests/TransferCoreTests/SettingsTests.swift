import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class SettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testServerVolumeExcludesProviderLocationsAcrossAccounts() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let first = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//one@fixture/Share",
                                address: try XCTUnwrap(ShareAddress("//one@fixture/Share")))
        let second = ServerGrant(serverID: server.id, bookmark: Data([2]), mountFrom: "//two@FIXTURE/share",
                                 address: try XCTUnwrap(ShareAddress("//two@FIXTURE/share")))
        let other = ServerGrant(serverID: server.id, bookmark: Data([3]), mountFrom: "//one@fixture/other",
                                address: try XCTUnwrap(ShareAddress("//one@fixture/other")))
        var location = LocationRecord(name: "Provider", grantID: first.id, folder: .root)
        location.removing = true
        var settings = AppSettings(servers: [server], shares: [first, second, other], locations: [location])
        XCTAssertThrowsError(try settings.requireMode(.serverVolume, for: second.id)) {
            XCTAssertEqual($0 as? SettingsError, .shareModeConflict)
        }
        XCTAssertNoThrow(try settings.requireMode(.fileProvider, for: second.id))
        XCTAssertNoThrow(try settings.requireMode(.serverVolume, for: other.id))
        settings.locations.removeAll()
        XCTAssertNoThrow(try settings.requireMode(.serverVolume, for: second.id))
        settings.serverVolumes = [ServerVolumeRecord(grantID: second.id)]
        XCTAssertThrowsError(try settings.requireMode(.fileProvider, for: first.id))
        XCTAssertThrowsError(try settings.requireMode(.serverVolume, for: first.id))
        XCTAssertTrue(settings.serverIsUsed(server.id))
        XCTAssertThrowsError(try settings.removeServer(server.id))
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), settings)
        settings.serverVolumes.removeAll()
        XCTAssertNoThrow(try settings.requireMode(.fileProvider, for: first.id))
    }

    func testServerVolumeSettingsRejectConflictingOrMissingGrants() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//one@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//one@fixture/share")))
        let volume = ServerVolumeRecord(grantID: grant.id)
        let location = LocationRecord(name: "Provider", grantID: grant.id, folder: .root)
        for settings in [
            AppSettings(servers: [server], serverVolumes: [volume]),
            AppSettings(servers: [server], shares: [grant], locations: [location], serverVolumes: [volume]),
            AppSettings(servers: [server], shares: [grant], serverVolumes: [volume, ServerVolumeRecord(grantID: grant.id)])
        ] {
            XCTAssertThrowsError(try settings.save(to: directory.appending(path: "Settings.json")))
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        }
    }

    func testDeletionRemovesOnlyConfirmedTypedKeepsOnTheSameShare() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/share")))
        let other = ServerGrant(serverID: server.id, bookmark: Data([2]), mountFrom: "//account@fixture/other",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/other")))
        let folder = KeepPath(path: "Tree/Café", kind: .folder)
        let deleted = KeepPath(path: "Tree/Café/deleted", kind: .file)
        let uncertain = KeepPath(path: "Tree/Café/unconfirmed", kind: .file)
        let replacementKind = KeepPath(path: folder.path, kind: .file)
        let neighbor = KeepPath(path: "Tree/Café-other", kind: .folder)
        let paths = [folder, deleted, uncertain, replacementKind, neighbor]
        var location = LocationRecord(name: "Location", grantID: grant.id, folder: .root)
        location.pendingKeeps = paths
        var otherLocation = LocationRecord(name: "Other", grantID: other.id, folder: .root)
        otherLocation.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [grant, other], locations: [location, otherLocation], savedKeeps: [
            SavedKeepList(host: "FIXTURE", share: "SHARE", paths: paths),
            SavedKeepList(host: "fixture", share: "other", paths: paths)])
        let removed = [KeepPath(path: "tree/Cafe\u{301}", kind: .folder), deleted]
        try settings.removeKeptItems(removed, host: grant.host, share: grant.share)
        let expected = [uncertain, replacementKind, neighbor]
        XCTAssertEqual(settings.locations[0].pendingKeeps, expected)
        XCTAssertEqual(settings.locations[0].domainID, location.domainID)
        XCTAssertEqual(settings.locations[1], otherLocation)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [expected, paths])
        let completed = settings
        try settings.removeKeptItems(removed, host: grant.host, share: grant.share)
        XCTAssertEqual(settings, completed)
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), completed)
    }

    func testDeletionKeepCleanupRejectsInvalidPathsWithoutPartialChanges() throws {
        let file = KeepPath(path: "Tree/file", kind: .file)
        let original = AppSettings(savedKeeps: [SavedKeepList(host: "fixture", share: "share", paths: [file])])
        for path in ["", "../file"] {
            var settings = original
            XCTAssertThrowsError(try settings.removeKeptItems([file, KeepPath(path: path, kind: .folder)],
                                                            host: "fixture", share: "share"))
            XCTAssertEqual(settings, original)
        }
        var settings = original
        try settings.removeKeptItems([file], host: "fixture", share: "share")
        XCTAssertEqual(settings.savedKeeps, [])
    }

    func testFileMoveRewritesOnlyMatchingKeepsOnTheSameShareAndIsIdempotent() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/share")))
        let other = ServerGrant(serverID: server.id, bookmark: Data([2]), mountFrom: "//account@fixture/other",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/other")))
        let old = KeepPath(path: "Inbox/file.txt", kind: .file)
        let new = KeepPath(path: "Archive/file.txt", kind: .file)
        let folder = KeepPath(path: "Inbox/file.txt", kind: .folder)
        let neighbor = KeepPath(path: "Inbox/file.txt/child", kind: .file)
        var location = LocationRecord(name: "Location", grantID: grant.id, folder: .root)
        location.pendingKeeps = [old, new, folder, neighbor]
        var otherLocation = LocationRecord(name: "Other", grantID: other.id, folder: .root)
        otherLocation.pendingKeeps = [old]
        var settings = AppSettings(servers: [server], shares: [grant, other], locations: [location, otherLocation],
                                   savedKeeps: [SavedKeepList(host: "FIXTURE", share: "SHARE", paths: [old]),
                                                SavedKeepList(host: "fixture", share: "other", paths: [old])])
        try settings.moveKeptFile(from: old.path, to: new.path, host: grant.host, share: grant.share)
        XCTAssertEqual(settings.locations[0].pendingKeeps, [new, folder, neighbor])
        XCTAssertEqual(settings.locations[1], otherLocation)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [[new], [old]])
        XCTAssertEqual(settings.locations[0].domainID, location.domainID)
        let completed = settings
        try settings.moveKeptFile(from: old.path, to: new.path, host: grant.host, share: grant.share)
        XCTAssertEqual(settings, completed)
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), completed)
    }

    func testFolderMoveRewritesTypedDescendantsAndPreservesOtherShares() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let address = try XCTUnwrap(ShareAddress("//account@fixture/share"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@fixture/share",
                                address: address)
        let paths = [KeepPath(path: "Inbox/Café", kind: .folder),
                     KeepPath(path: "inbox/Cafe\u{301}/Nested/file.txt", kind: .file),
                     KeepPath(path: "Inbox/Café/Nested", kind: .folder),
                     KeepPath(path: "Archive/Report/Nested/file.txt", kind: .file),
                     KeepPath(path: "Inbox/Café", kind: .file),
                     KeepPath(path: "Inbox/Café-other/file.txt", kind: .file)]
        var location = LocationRecord(name: "Location", grantID: grant.id, folder: .root)
        location.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [grant], locations: [location], savedKeeps: [
            SavedKeepList(host: "FIXTURE", share: "SHARE", paths: paths),
            SavedKeepList(host: "fixture", share: "other", paths: paths)])
        try settings.moveKeptFolder(from: "Inbox/Café", to: "Archive/Report", host: "fixture", share: "share")
        let expected = [KeepPath(path: "Archive/Report", kind: .folder),
                        KeepPath(path: "Archive/Report/Nested/file.txt", kind: .file),
                        KeepPath(path: "Archive/Report/Nested", kind: .folder), paths[4], paths[5]]
        XCTAssertEqual(settings.locations[0].pendingKeeps, expected)
        XCTAssertEqual(settings.locations[0].domainID, location.domainID)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [expected, paths])
        let completed = settings
        try settings.moveKeptFolder(from: "Inbox/Café", to: "Archive/Report", host: "fixture", share: "share")
        XCTAssertEqual(settings, completed)
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), completed)
    }

    func testRootRetirementClearsSubtreeKeepsWithoutChangingAncestorsOrOtherShares() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://fixture")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/share")))
        let paths = [KeepPath(path: "Archive", kind: .folder), KeepPath(path: "Archive/Café", kind: .folder),
                     KeepPath(path: "archive/Cafe\u{301}/Nested/file", kind: .file),
                     KeepPath(path: "Archive/Café-other/file", kind: .file)]
        var location = LocationRecord(name: "Location", grantID: grant.id, folder: .root)
        location.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [grant], locations: [location], savedKeeps: [
            SavedKeepList(host: "fixture", share: "share", paths: paths),
            SavedKeepList(host: "fixture", share: "other", paths: paths)])
        let original = settings
        for invalid in ["", "../Archive"] {
            XCTAssertThrowsError(try settings.removeKeptFolder(at: invalid, host: grant.host, share: grant.share))
            XCTAssertEqual(settings, original)
        }
        try settings.removeKeptFolder(at: "Archive/Café", host: grant.host, share: grant.share)
        let retained = [paths[0], paths[3]]
        XCTAssertEqual(settings.locations[0].pendingKeeps, retained)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [retained, paths])
        let completed = settings
        try settings.removeKeptFolder(at: "Archive/Café", host: grant.host, share: grant.share)
        XCTAssertEqual(settings, completed)
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), completed)
    }

    func testFolderKeepCaseRenamePreservesCombiningMarkComponentsAndReplays() throws {
        let paths = [KeepPath(path: "Folder/\u{301}child/file", kind: .file),
                     KeepPath(path: "Folder", kind: .folder), KeepPath(path: "Neighbor/file", kind: .file)]
        var settings = AppSettings(savedKeeps: [SavedKeepList(host: "fixture", share: "share", paths: paths)])
        try settings.moveKeptFolder(from: "Folder", to: "FOLDER", host: "fixture", share: "share")
        XCTAssertEqual(settings.savedKeeps[0].paths, [KeepPath(path: "FOLDER/\u{301}child/file", kind: .file),
                                                    KeepPath(path: "FOLDER", kind: .folder), paths[2]])
        let completed = settings
        try settings.moveKeptFolder(from: "Folder", to: "FOLDER", host: "fixture", share: "share")
        XCTAssertEqual(settings, completed)
    }

    func testFolderKeepRewriteRefusesInvalidOrOverlongTargetsWithoutPartialChanges() throws {
        let grant = ServerGrant(serverID: UUID(), bookmark: Data([1]), mountFrom: "//account@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/share")))
        var location = LocationRecord(name: "Location", grantID: grant.id, folder: .root)
        location.pendingKeeps = [KeepPath(path: "a/short", kind: .file)]
        let component = String(repeating: "x", count: 250)
        let long = "a/" + Array(repeating: component, count: 4).joined(separator: "/")
        let original = AppSettings(shares: [grant], locations: [location], savedKeeps: [
            SavedKeepList(host: "fixture", share: "share", paths: [KeepPath(path: long, kind: .file)])])
        for (source, target) in [("", "b"), ("a", ""), ("a", "a/sub"), ("a/sub", "a"),
                                  ("a", "../b"), ("a", String(repeating: "z", count: 30))] {
            var settings = original
            XCTAssertThrowsError(try settings.moveKeptFolder(from: source, to: target, host: "fixture", share: "share"))
            XCTAssertEqual(settings, original)
        }
    }

    func testReadOnlyRetainsInactiveGrantAcrossRelaunch() throws {
        var location = LocationRecord(name: "Read", grantID: UUID(), folder: .root)
        location.writeBookmark = Data([4])
        location.readOnly = true
        let settings = AppSettings(locations: [location])
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        let restored = try AppSettings.load(from: url)
        XCTAssertEqual(restored, settings)
        XCTAssertNil(restored.locations[0].activeWriteBookmark)
        var enabled = restored.locations[0]
        enabled.readOnly = false
        XCTAssertEqual(enabled.activeWriteBookmark, Data([4]))
    }

    func testShareWritePermissionSurvivesRelaunchWithoutEnablingLocations() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "account@fixture")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), writeBookmark: Data([2]),
                                mountFrom: "//account@fixture/share",
                                address: try XCTUnwrap(ShareAddress("//account@fixture/share")))
        let location = LocationRecord(name: "Read", grantID: grant.id, folder: .root)
        let settings = AppSettings(servers: [server], shares: [grant], locations: [location])
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        let restored = try AppSettings.load(from: url)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.writeBookmark(for: grant.id), Data([2]))
        XCTAssertTrue(restored.locations[0].readOnly)
        XCTAssertNil(restored.locations[0].activeWriteBookmark)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testEarlierSettingsReuseOnlyTheSameGrantsLocationPermission() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "fixture")))
        let grants = try ["//account@fixture/share", "//other@fixture/share", "//account@fixture/other"].map {
            ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: $0,
                        address: try XCTUnwrap(ShareAddress($0)))
        }
        let readOnly = LocationRecord(name: "Read", grantID: grants[0].id, folder: .root)
        var previouslyWritable = LocationRecord(name: "Retained", grantID: grants[0].id, folder: .root)
        previouslyWritable.writeBookmark = Data([4])
        let settings = AppSettings(servers: [server], shares: grants, locations: [readOnly, previouslyWritable])
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let shares = try XCTUnwrap(json["shares"] as? [[String: Any]])
        XCTAssertTrue(shares.allSatisfy { $0["writeBookmark"] == nil })
        var restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.writeBookmark(for: grants[0].id), Data([4]))
        XCTAssertNil(restored.writeBookmark(for: grants[1].id))
        XCTAssertNil(restored.writeBookmark(for: grants[2].id))
        XCTAssertTrue(restored.locations.allSatisfy { $0.activeWriteBookmark == nil })
        restored.shares[0].writeBookmark = Data([5])
        XCTAssertEqual(restored.writeBookmark(for: grants[0].id), Data([5]))
        restored.shares.removeFirst()
        XCTAssertNil(restored.writeBookmark(for: grants[0].id))
    }

    func testNormalizedFolderTrimsSlashesAndRejectsInvalidComponents() {
        for (text, folder) in [("", ""), ("/", ""), ("///", ""), ("/Movies/", "Movies"), ("Movies/2024", "Movies/2024"),
                               ("//Movies/2024//", "Movies/2024"), ("/\u{301}a/", "\u{301}a"), (" a ", " a ")] {
            XCTAssertEqual(LocationRecord.normalizedFolder(text)?.string, folder, text)
        }
        XCTAssertEqual(LocationRecord.normalizedFolder("/"), .root)
        for invalid in [".", "..", "/../", "a/./b", "a/../b", "a//b", "a\0b", "/a/\0/", String(repeating: "x", count: 256)] {
            XCTAssertNil(LocationRecord.normalizedFolder(invalid), invalid)
        }
    }

    func testShareAddressParsesBothFormsAndRejectsOtherSchemesAndPasswords() throws {
        let mounted = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        XCTAssertEqual(mounted.account, "account")
        XCTAssertEqual(mounted.host, "nas.local")
        XCTAssertEqual(mounted.share, "Media")
        XCTAssertEqual(ShareAddress("smb://account@nas.local/Media"), mounted)
        XCTAssertEqual(ShareAddress("SMB://account@nas.local/Media/"), mounted)

        let encoded = try XCTUnwrap(ShareAddress("smb://DOMAIN;user%40x@nas.local/My%20Media"))
        XCTAssertEqual(encoded.account, "DOMAIN;user@x")
        XCTAssertEqual(encoded.share, "My Media")
        XCTAssertEqual(ShareAddress("//DOMAIN;user%40x@nas.local/My%20Media"), encoded)

        for invalid in ["afp://account@nas.local/Media", "cifs://account@nas.local/Media", "file:///Volumes/Media",
                        "smb://account:secret@nas.local/Media", "//account:secret@nas.local/Media",
                        "//GUEST:@nas.local/Media", "smb://nas.local/Media", "//@nas.local/Media",
                        "smb://account@nas.local:445/Media", "smb://account@nas.local/Media/Movies",
                        "smb://account@nas.local/", "smb://account@nas.local", "smb://account@nas.local/%2E%2E",
                        "smb://account@nas.local/a%2Fb", "smb://account@nas.local/a%00b", "smb://account@nas.local/Media?x=1",
                        "smb://account@nas.local/Media#x", "account@nas.local/Media", "smb:account@nas.local/Media", ""] {
            XCTAssertNil(ShareAddress(invalid), invalid)
        }
    }

    func testServerAddressAcceptsWhatConnectToServerAccepts() throws {
        let full = try XCTUnwrap(ServerAddress(typed: " smb://nas.local/Media/ "))
        XCTAssertEqual(full.url.absoluteString, "smb://nas.local/Media")
        XCTAssertEqual(full.host, "nas.local")
        XCTAssertNil(full.account)
        XCTAssertEqual(full.share, "Media")
        XCTAssertEqual(ServerAddress(typed: "nas.local/Media"), full)
        XCTAssertEqual(ServerAddress(typed: "//nas.local/Media"), full)
        XCTAssertEqual(ServerAddress(typed: "SMB://nas.local/Media"), full)

        let spaced = try XCTUnwrap(ServerAddress(typed: "smb://account@nas.local/My Media"))
        XCTAssertEqual(spaced.url.absoluteString, "smb://account@nas.local/My%20Media")
        XCTAssertEqual(spaced.account, "account")
        XCTAssertEqual(spaced.share, "My Media")

        let server = try XCTUnwrap(ServerAddress(typed: "nas.local"))
        XCTAssertEqual(server.url.absoluteString, "smb://nas.local")
        XCTAssertNil(server.share)
        XCTAssertEqual(ServerAddress(typed: "smb://nas.local/"), server)

        for invalid in ["", "smb://", "afp://nas.local/Media", "smb://account:secret@nas.local/Media",
                        "smb://:secret@nas.local/Media", "smb://@nas.local/Media", "smb://nas.local:445/Media",
                        "smb://nas.local/Media/Movies", "smb://nas.local/%2E%2E", "smb://nas.local/a%2Fb",
                        "smb://nas.local/Media?x=1", "smb://nas.local/Media#x", "smb://nas.local//Media"] {
            XCTAssertNil(ServerAddress(typed: invalid), invalid)
        }
    }

    func testOSGuestAddressesLoseOnlyAnEmptyPasswordField() {
        for address in ["//guest:@nas.local/Media", "smb://guest:@nas.local/Media"] {
            let clean = ShareAddress.withoutEmptyPassword(address)
            XCTAssertNotNil(clean.flatMap(ShareAddress.init))
            XCTAssertFalse(clean?.contains(":@") ?? true)
        }
        let normal = "//DOMAIN;user%40x@nas.local/My%20Media"
        XCTAssertEqual(ShareAddress.withoutEmptyPassword(normal), normal)
        XCTAssertNil(ShareAddress.withoutEmptyPassword("//guest:secret@nas.local/Media"))
        XCTAssertNil(ShareAddress.withoutEmptyPassword("//guest:%00@nas.local/Media"))
        XCTAssertNil(ServerAddress(typed: "smb://guest:@nas.local/Media"))
        XCTAssertEqual(MountIdentity(typeName: "smbfs", fsid: 1, mountFrom: "//guest:@nas.local/Media").mountFrom,
                       "//guest@nas.local/Media")
    }

    func testServerAddressMatchesTheMountedShare() throws {
        let mounted = try XCTUnwrap(ShareAddress("//account@NAS.local/Media"))
        XCTAssertEqual(ServerAddress(typed: "nas.local/media")?.matches(mounted), true)
        XCTAssertEqual(ServerAddress(typed: "account@nas.local/Media")?.matches(mounted), true)
        XCTAssertEqual(ServerAddress(typed: "nas.local")?.matches(mounted), true)
        XCTAssertEqual(ServerAddress(typed: "other@nas.local/Media")?.matches(mounted), false)
        XCTAssertEqual(ServerAddress(typed: "nas.local/Photos")?.matches(mounted), false)
        XCTAssertEqual(ServerAddress(typed: "other.local/Media")?.matches(mounted), false)
    }

    func testUniqueNameAddsANumber() {
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X"]), "X copy")
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X", "X copy"]), "X copy 2")
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X", "x COPY", "X copy 2"]), "X copy 3")
        XCTAssertEqual(LocationRecord.uniqueName("Caf\u{e9}", among: ["Cafe\u{301}"]), "Caf\u{e9} 2")
        XCTAssertEqual(LocationRecord.uniqueName("Media", among: []), "Media")
    }

    func testCopyNameFollowsFinder() {
        XCTAssertEqual(LocationRecord.copyName("Documents", among: ["Documents"]), "Documents copy")
        XCTAssertEqual(LocationRecord.copyName("Documents", among: ["Documents", "documents copy"]), "Documents copy 2")
    }

    func testPathInsideAFolderIsBelowItAndNeverTheFolderItself() {
        let movies = RelativePath("Movies")!
        XCTAssertEqual(LocationRecord.path("Movies/2024/a.mkv", inside: movies)?.string, "2024/a.mkv")
        XCTAssertEqual(LocationRecord.path("Movies/a.mkv", inside: .root)?.string, "Movies/a.mkv")
        XCTAssertEqual(LocationRecord.path("a.mkv", inside: RelativePath("Movies/2024")!), nil)
        for outside in ["Movies", "Movies/", "Movies2/a.mkv", "movies/a.mkv", "Other/Movies/a.mkv", "Movies//a.mkv"] {
            XCTAssertNil(LocationRecord.path(outside, inside: movies), outside)
        }
    }

    func testANewLocationTakesOnlyTheSavedPathsInsideItsFolder() {
        var settings = AppSettings(savedKeeps: [
            SavedKeepList(host: "NAS.local", share: "media", paths: fileKeeps(["Movies/a.mkv", "Movies/2024/b.mkv", "Music/c.flac"])),
            SavedKeepList(host: "other.local", share: "Media", paths: fileKeeps(["Movies/d.mkv"])),
        ])
        XCTAssertEqual(settings.savedKeeps(host: "nas.local", share: "Media", inside: RelativePath("Movies")!),
                       fileKeeps(["Movies/a.mkv", "Movies/2024/b.mkv"]))
        XCTAssertEqual(settings.takeSavedKeeps(host: "nas.local", share: "Media", inside: RelativePath("Movies")!),
                       fileKeeps(["Movies/a.mkv", "Movies/2024/b.mkv"]))
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [fileKeeps(["Music/c.flac"]), fileKeeps(["Movies/d.mkv"])])
        XCTAssertEqual(settings.takeSavedKeeps(host: "nas.local", share: "Media", inside: .root), fileKeeps(["Music/c.flac"]))
        XCTAssertEqual(settings.savedKeeps.map(\.host), ["other.local"], "an empty list is removed")
        XCTAssertEqual(settings.takeSavedKeeps(host: "nas.local", share: "Media", inside: .root), [])
    }

    func testSavedKeepsAreAddedOnceToTheShareList() {
        var settings = AppSettings()
        settings.saveKeeps([], host: "nas.local", share: "Media")
        XCTAssertTrue(settings.savedKeeps.isEmpty)
        settings.saveKeeps(fileKeeps(["a.mkv", "b.mkv", "a.mkv"]), host: "nas.local", share: "Media")
        settings.saveKeeps(fileKeeps(["b.mkv", "c.mkv"]), host: "NAS.local", share: "MEDIA")
        settings.saveKeeps(fileKeeps(["a.mkv"]), host: "nas.local", share: "Other")
        XCTAssertEqual(settings.savedKeeps, [SavedKeepList(host: "nas.local", share: "Media", paths: fileKeeps(["a.mkv", "b.mkv", "c.mkv"])),
                                             SavedKeepList(host: "nas.local", share: "Other", paths: fileKeeps(["a.mkv"]))])
    }

    func testServerAcceptsOnlyItsOwnAccount() throws {
        let named = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "Account@nas.local")))
        XCTAssertTrue(named.accepts(account: "account"))
        XCTAssertFalse(named.accepts(account: "other"), "a reused mount of another account must not join this server")
        let open = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "nas.local")))
        XCTAssertTrue(open.accepts(account: "other"))
    }

    func testSettingsRoundTripThroughAPrivateFile() throws {
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "account@nas.local")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1, 2, 3]), mountFrom: "//account@nas.local/Media", address: address)
        var record = LocationRecord(name: "Movies", grantID: grant.id, folder: try XCTUnwrap(RelativePath("Movies/2024")))
        record.retiredDomainID = UUID().uuidString
        record.pendingKeeps = fileKeeps(["Movies/2024/a.mkv"])
        var settings = AppSettings(servers: [server], shares: [grant], locations: [record, LocationRecord(name: "Media", grantID: grant.id, folder: .root)],
                                   savedKeeps: [SavedKeepList(host: address.host, share: address.share, paths: fileKeeps(["Movies/a.mkv"]))])
        let url = directory.appending(path: "tinymounter/Settings.json")

        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), settings)
        XCTAssertEqual(try mode(url), 0o600)

        settings.locations.removeFirst()
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), settings)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path(percentEncoded: false)),
                       ["Settings.json"])

        // A file left by a failed save is replaced, with mode 0600 again.
        let leftover = url.appendingPathExtension("new")
        try Data("x".utf8).write(to: leftover)
        XCTAssertEqual(chmod(leftover.path(percentEncoded: false), 0o644), 0)
        try settings.save(to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
    }

    func testOnlyAMissingFileLoadsAsEmptySettings() throws {
        let empty = try AppSettings.load(from: directory.appending(path: "Settings.json"))
        XCTAssertEqual(empty, AppSettings())
        XCTAssertTrue(empty.servers.isEmpty && empty.shares.isEmpty && empty.locations.isEmpty && empty.savedKeeps.isEmpty)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Settings.json")
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        var missingKey = valid
        missingKey["locations"] = nil
        var wrongType = valid
        wrongType["servers"] = "none"
        for data in [Data(), Data("{".utf8), Data("null".utf8), Data("[]".utf8), Data([0xff, 0xfe]),
                     try JSONSerialization.data(withJSONObject: missingKey),
                     try JSONSerialization.data(withJSONObject: wrongType)] {
            try data.write(to: url)
            XCTAssertThrowsError(try AppSettings.load(from: url), String(decoding: data, as: UTF8.self))
        }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppSettings.load(from: url))
    }

    func testRemovingAServerInUseDoesNotChangeSettings() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "nas.local")))
        let other = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "other.local")))
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@nas.local/Media", address: address)
        let record = LocationRecord(name: "Media", grantID: grant.id, folder: .root)
        var settings = AppSettings(servers: [server, other], shares: [grant], locations: [record])
        let before = settings
        XCTAssertTrue(settings.serverIsUsed(server.id))
        XCTAssertThrowsError(try settings.removeServer(server.id)) {
            XCTAssertEqual($0 as? SettingsError, .serverInUse)
        }
        XCTAssertEqual(settings, before)
        settings.locations.removeAll()
        try settings.removeServer(server.id)
        XCTAssertEqual(settings.servers, [other])
        XCTAssertTrue(settings.shares.isEmpty)
    }

    func testASeparateShareWithoutItsServerIsRejected() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "nas.local")))
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@nas.local/Media", address: address)
        let invalid = AppSettings(shares: [grant])
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(invalid))) {
            XCTAssertEqual($0 as? SettingsError, .invalidServer)
        }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { throw posixError("stat") }
        return info.st_mode & 0o777
    }

    private func fileKeeps(_ paths: [String]) -> [KeepPath] {
        paths.map { KeepPath(path: $0, kind: .file) }
    }
}
