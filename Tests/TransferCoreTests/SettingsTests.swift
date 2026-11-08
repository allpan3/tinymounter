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

    private func serverRecord(_ host: String) -> ServerRecord {
        ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: host, account: "account"))
    }

    func testServerVolumeExcludesProviderLocationsAcrossAccounts() throws {
        let server = ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: "fixture", account: "one"))
        let otherAccount = ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: "FIXTURE", account: "two"))
        let first = ShareRecord(serverID: server.id, name: "Share")
        let second = ShareRecord(serverID: otherAccount.id, name: "share")
        let other = ShareRecord(serverID: server.id, name: "other")
        var location = LocationRecord(name: "Provider", shareID: first.id, folder: .root)
        location.removing = true
        var settings = AppSettings(servers: [server, otherAccount], shares: [first, second, other], locations: [location])
        XCTAssertThrowsError(try settings.requireMode(.serverVolume, for: second.id)) {
            XCTAssertEqual($0 as? SettingsError, .shareModeConflict)
        }
        XCTAssertNoThrow(try settings.requireMode(.fileProvider, for: second.id))
        XCTAssertNoThrow(try settings.requireMode(.serverVolume, for: other.id))
        settings.locations.removeAll()
        XCTAssertNoThrow(try settings.requireMode(.serverVolume, for: second.id))
        settings.serverVolumes = [ServerVolumeRecord(shareID: second.id)]
        XCTAssertThrowsError(try settings.requireMode(.fileProvider, for: first.id))
        XCTAssertThrowsError(try settings.requireMode(.serverVolume, for: first.id))
        XCTAssertTrue(settings.serverIsUsed(otherAccount.id))
        XCTAssertFalse(settings.serverIsUsed(server.id))
        XCTAssertThrowsError(try settings.removeServer(otherAccount.id))
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), settings)
        settings.serverVolumes.removeAll()
        XCTAssertNoThrow(try settings.requireMode(.fileProvider, for: first.id))
    }

    func testServerVolumeSettingsRejectConflictingOrMissingShares() throws {
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        let volume = ServerVolumeRecord(shareID: share.id)
        let location = LocationRecord(name: "Provider", shareID: share.id, folder: .root)
        for settings in [
            AppSettings(servers: [server], serverVolumes: [volume]),
            AppSettings(servers: [server], shares: [share], locations: [location], serverVolumes: [volume]),
            AppSettings(servers: [server], shares: [share], serverVolumes: [volume, ServerVolumeRecord(shareID: share.id)])
        ] {
            XCTAssertThrowsError(try settings.save(to: directory.appending(path: "Settings.json")))
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)))
        }
    }

    func testDeletionRemovesOnlyConfirmedTypedKeepsOnTheSameShare() throws {
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        let other = ShareRecord(serverID: server.id, name: "other")
        let folder = KeepPath(path: "Tree/Café", kind: .folder)
        let deleted = KeepPath(path: "Tree/Café/deleted", kind: .file)
        let uncertain = KeepPath(path: "Tree/Café/unconfirmed", kind: .file)
        let replacementKind = KeepPath(path: folder.path, kind: .file)
        let neighbor = KeepPath(path: "Tree/Café-other", kind: .folder)
        let paths = [folder, deleted, uncertain, replacementKind, neighbor]
        var location = LocationRecord(name: "Location", shareID: share.id, folder: .root)
        location.pendingKeeps = paths
        var otherLocation = LocationRecord(name: "Other", shareID: other.id, folder: .root)
        otherLocation.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [share, other], locations: [location, otherLocation], savedKeeps: [
            SavedKeepList(host: "FIXTURE", share: "SHARE", paths: paths),
            SavedKeepList(host: "fixture", share: "other", paths: paths)])
        let removed = [KeepPath(path: "tree/Cafe\u{301}", kind: .folder), deleted]
        try settings.removeKeptItems(removed, host: "fixture", share: "share")
        let expected = [uncertain, replacementKind, neighbor]
        XCTAssertEqual(settings.locations[0].pendingKeeps, expected)
        XCTAssertEqual(settings.locations[0].domainID, location.domainID)
        XCTAssertEqual(settings.locations[1], otherLocation)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [expected, paths])
        let completed = settings
        try settings.removeKeptItems(removed, host: "fixture", share: "share")
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
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        let other = ShareRecord(serverID: server.id, name: "other")
        let old = KeepPath(path: "Inbox/file.txt", kind: .file)
        let new = KeepPath(path: "Archive/file.txt", kind: .file)
        let folder = KeepPath(path: "Inbox/file.txt", kind: .folder)
        let neighbor = KeepPath(path: "Inbox/file.txt/child", kind: .file)
        var location = LocationRecord(name: "Location", shareID: share.id, folder: .root)
        location.pendingKeeps = [old, new, folder, neighbor]
        var otherLocation = LocationRecord(name: "Other", shareID: other.id, folder: .root)
        otherLocation.pendingKeeps = [old]
        var settings = AppSettings(servers: [server], shares: [share, other], locations: [location, otherLocation],
                                   savedKeeps: [SavedKeepList(host: "FIXTURE", share: "SHARE", paths: [old]),
                                                SavedKeepList(host: "fixture", share: "other", paths: [old])])
        try settings.moveKeptFile(from: old.path, to: new.path, host: "fixture", share: "share")
        XCTAssertEqual(settings.locations[0].pendingKeeps, [new, folder, neighbor])
        XCTAssertEqual(settings.locations[1], otherLocation)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [[new], [old]])
        XCTAssertEqual(settings.locations[0].domainID, location.domainID)
        let completed = settings
        try settings.moveKeptFile(from: old.path, to: new.path, host: "fixture", share: "share")
        XCTAssertEqual(settings, completed)
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url), completed)
    }

    func testFolderMoveRewritesTypedDescendantsAndPreservesOtherShares() throws {
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        let paths = [KeepPath(path: "Inbox/Café", kind: .folder),
                     KeepPath(path: "inbox/Cafe\u{301}/Nested/file.txt", kind: .file),
                     KeepPath(path: "Inbox/Café/Nested", kind: .folder),
                     KeepPath(path: "Archive/Report/Nested/file.txt", kind: .file),
                     KeepPath(path: "Inbox/Café", kind: .file),
                     KeepPath(path: "Inbox/Café-other/file.txt", kind: .file)]
        var location = LocationRecord(name: "Location", shareID: share.id, folder: .root)
        location.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [share], locations: [location], savedKeeps: [
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
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        let paths = [KeepPath(path: "Archive", kind: .folder), KeepPath(path: "Archive/Café", kind: .folder),
                     KeepPath(path: "archive/Cafe\u{301}/Nested/file", kind: .file),
                     KeepPath(path: "Archive/Café-other/file", kind: .file)]
        var location = LocationRecord(name: "Location", shareID: share.id, folder: .root)
        location.pendingKeeps = paths
        var settings = AppSettings(servers: [server], shares: [share], locations: [location], savedKeeps: [
            SavedKeepList(host: "fixture", share: "share", paths: paths),
            SavedKeepList(host: "fixture", share: "other", paths: paths)])
        let original = settings
        for invalid in ["", "../Archive"] {
            XCTAssertThrowsError(try settings.removeKeptFolder(at: invalid, host: "fixture", share: "share"))
            XCTAssertEqual(settings, original)
        }
        try settings.removeKeptFolder(at: "Archive/Café", host: "fixture", share: "share")
        let retained = [paths[0], paths[3]]
        XCTAssertEqual(settings.locations[0].pendingKeeps, retained)
        XCTAssertEqual(settings.savedKeeps.map(\.paths), [retained, paths])
        let completed = settings
        try settings.removeKeptFolder(at: "Archive/Café", host: "fixture", share: "share")
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
        let share = ShareRecord(serverID: UUID(), name: "share")
        var location = LocationRecord(name: "Location", shareID: share.id, folder: .root)
        location.pendingKeeps = [KeepPath(path: "a/short", kind: .file)]
        let component = String(repeating: "x", count: 250)
        let long = "a/" + Array(repeating: component, count: 4).joined(separator: "/")
        let original = AppSettings(shares: [share], locations: [location], savedKeeps: [
            SavedKeepList(host: "fixture", share: "share", paths: [KeepPath(path: long, kind: .file)])])
        for (source, target) in [("", "b"), ("a", ""), ("a", "a/sub"), ("a/sub", "a"),
                                  ("a", "../b"), ("a", String(repeating: "z", count: 30))] {
            var settings = original
            XCTAssertThrowsError(try settings.moveKeptFolder(from: source, to: target, host: "fixture", share: "share"))
            XCTAssertEqual(settings, original)
        }
    }

    func testReadOnlyIsAPlainSettingPerLocation() throws {
        let server = serverRecord("fixture")
        let share = ShareRecord(serverID: server.id, name: "share")
        var writable = LocationRecord(name: "Write", shareID: share.id, folder: .root)
        XCTAssertTrue(writable.readOnly)
        writable.readOnly = false
        let settings = AppSettings(servers: [server], shares: [share],
                                   locations: [LocationRecord(name: "Read", shareID: share.id, folder: .root), writable])
        let url = directory.appending(path: "Settings.json")
        try settings.save(to: url)
        XCTAssertEqual(try AppSettings.load(from: url).locations.map(\.readOnly), [true, false])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let shares = try XCTUnwrap(json["shares"] as? [[String: Any]])
        XCTAssertEqual(shares.map { Set($0.keys) }, [["id", "serverID", "name"]])
    }

    func testEarlierSettingsAreRejectedNotConverted() throws {
        let server = UUID().uuidString, grant = UUID().uuidString
        let earlier = #"""
            {"servers":[{"id":"\#(server)","login":{"remoteProtocol":"smb","host":"nas.local","account":"account"}}],
             "shares":[{"id":"\#(grant)","serverID":"\#(server)","bookmark":"AQ==","mountFrom":"//account@nas.local/Media",
                        "host":"nas.local","account":"account","share":"Media"}],
             "locations":[{"id":"\#(UUID().uuidString)","name":"Media","grantID":"\#(grant)","folder":"",
                           "domainID":"\#(UUID().uuidString)","removing":false,"pendingKeeps":[],"readOnly":true}],
             "savedKeeps":[]}
            """#
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: Data(earlier.utf8)))
    }

    func testAShareAddressIsItsServersSignInAndItsName() throws {
        let server = ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: "NAS.local", account: "account"))
        let otherAccount = ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: "nas.local", account: "other"))
        let media = ShareRecord(serverID: server.id, name: "Media")
        let same = ShareRecord(serverID: otherAccount.id, name: "MEDIA")
        let photos = ShareRecord(serverID: server.id, name: "Photos")
        let settings = AppSettings(servers: [server, otherAccount], shares: [media, same, photos])
        let address = try XCTUnwrap(settings.address(of: media.id))
        XCTAssertEqual(address, ShareAddress(server.login, share: "Media"))
        XCTAssertEqual(address.login, server.login)
        XCTAssertEqual(DeletionEndpoint(address).remoteProtocol, .smb)
        XCTAssertNil(settings.address(of: UUID()))
        XCTAssertEqual(settings.relatedShareIDs(host: "nas.local", share: "media"), [media.id, same.id])
        for name in ["", "..", "a/b"] {
            let json = #"{"id":"\#(UUID().uuidString)","serverID":"\#(server.id.uuidString)","name":"\#(name)"}"#
            XCTAssertThrowsError(try JSONDecoder().decode(ShareRecord.self, from: Data(json.utf8))) {
                XCTAssertEqual($0 as? SettingsError, .invalidServer)
            }
        }
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
                        "smb://nas.local/Media?x=1", "smb://nas.local/Media#x", "smb://nas.local//Media",
                        "smb://guest:@nas.local/Media"] {
            XCTAssertNil(ServerAddress(typed: invalid), invalid)
        }
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

    func testServerAccountsMatchWithoutCaseAndKeepAccountsApart() {
        let account = ServerAccount(remoteProtocol: .smb, host: "NAS.local", account: "Account")
        XCTAssertTrue(account.matches(ServerAccount(remoteProtocol: .smb, host: "nas.local", account: "account")))
        XCTAssertFalse(account.matches(ServerAccount(remoteProtocol: .smb, host: "nas.local", account: "other")),
                       "two accounts on one host are two servers")
        XCTAssertFalse(account.matches(ServerAccount(remoteProtocol: .smb, host: "other.local", account: "Account")))
    }

    func testServerRecordSavesItsSignInAndNoPassword() throws {
        let server = ServerRecord(login: ServerAccount(remoteProtocol: .smb, host: "nas.local", account: "account"))
        let data = try JSONEncoder().encode(server)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "login"])
        XCTAssertEqual(json["login"] as? [String: String],
                       ["remoteProtocol": "smb", "host": "nas.local", "account": "account"])
        XCTAssertEqual(try JSONDecoder().decode(ServerRecord.self, from: data), server)
    }

    func testServerRecordRejectsTheEarlierAddressAndAnEmptySignIn() throws {
        let id = UUID().uuidString
        let earlier = #"{"id":"\#(id)","address":"smb://account@nas.local"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ServerRecord.self, from: Data(earlier.utf8)))
        for (host, account) in [("", "account"), ("nas.local", "")] {
            let json = #"{"id":"\#(id)","login":{"remoteProtocol":"smb","host":"\#(host)","account":"\#(account)"}}"#
            XCTAssertThrowsError(try JSONDecoder().decode(ServerRecord.self, from: Data(json.utf8))) {
                XCTAssertEqual($0 as? SettingsError, .invalidServer)
            }
        }
        let unknown = #"{"id":"\#(id)","login":{"remoteProtocol":"afp","host":"nas.local","account":"account"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ServerRecord.self, from: Data(unknown.utf8)))
    }

    func testSettingsRoundTripThroughAPrivateFile() throws {
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let server = serverRecord("nas.local")
        let share = ShareRecord(serverID: server.id, name: "Media")
        var record = LocationRecord(name: "Movies", shareID: share.id, folder: try XCTUnwrap(RelativePath("Movies/2024")))
        record.retiredDomainID = UUID().uuidString
        record.pendingKeeps = fileKeeps(["Movies/2024/a.mkv"])
        var settings = AppSettings(servers: [server], shares: [share], locations: [record, LocationRecord(name: "Media", shareID: share.id, folder: .root)],
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
        let server = serverRecord("nas.local")
        let other = serverRecord("other.local")
        let share = ShareRecord(serverID: server.id, name: "Media")
        let record = LocationRecord(name: "Media", shareID: share.id, folder: .root)
        var settings = AppSettings(servers: [server, other], shares: [share], locations: [record])
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

    func testForgettingAShareKeepsUsedSharesAndDropsAnEmptyServer() throws {
        let server = serverRecord("nas.local")
        let used = ShareRecord(serverID: server.id, name: "Media")
        let unused = ShareRecord(serverID: server.id, name: "Backup")
        let volume = ServerVolumeRecord(shareID: used.id)
        var settings = AppSettings(servers: [server], shares: [used, unused], serverVolumes: [volume])
        XCTAssertThrowsError(try settings.removeShare(used.id)) {
            XCTAssertEqual($0 as? SettingsError, .shareInUse)
        }
        try settings.removeShare(unused.id)
        XCTAssertEqual(settings.shares, [used])
        XCTAssertEqual(settings.servers, [server])
        settings.serverVolumes.removeAll()
        try settings.removeShare(used.id)
        XCTAssertTrue(settings.shares.isEmpty)
        XCTAssertTrue(settings.servers.isEmpty)
    }

    func testASeparateShareWithoutItsServerIsRejected() throws {
        let server = serverRecord("nas.local")
        let share = ShareRecord(serverID: server.id, name: "Media")
        let invalid = AppSettings(shares: [share])
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
