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
        var location = LocationRecord(name: "Location", serverID: grant.id, folder: .root)
        location.pendingKeeps = [old, new, folder, neighbor]
        var otherLocation = LocationRecord(name: "Other", serverID: other.id, folder: .root)
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

    func testExistingWriteGrantDoesNotEnableEditingDuringUpgrade() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://home-nas")))
        let address = try XCTUnwrap(ShareAddress("//account@home-nas/share"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@home-nas/share", address: address)
        var location = LocationRecord(name: "Location", serverID: grant.id, folder: .root)
        location.writeBookmark = Data([2])
        location.readOnly = false
        location.pendingKeeps = [KeepPath(path: "file", kind: .file)]
        let settings = AppSettings(servers: [server], shares: [grant], locations: [location])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["version"] = 4
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "Settings.json")
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        let upgraded = try AppSettings.load(from: path)
        XCTAssertEqual(upgraded.locations, settings.locations)
        XCTAssertEqual(upgraded.shares, settings.shares)
        XCTAssertNil(upgraded.locations[0].smbOnlyEditing)
        XCTAssertEqual(upgraded.locations[0].writeBookmark, Data([2]))
        XCTAssertEqual(upgraded.version, 6)
        XCTAssertEqual(try AppSettings.load(from: path), upgraded)
    }

    func testVersionThreeLocationsStayReadOnlyWithIDsAndKeepsIntact() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://home-nas")))
        let address = try XCTUnwrap(ShareAddress("//account@home-nas/share"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1, 2]), mountFrom: "//account@home-nas/share", address: address)
        var location = LocationRecord(name: "Location", serverID: grant.id, folder: .root)
        location.pendingKeeps = [KeepPath(path: "file", kind: .file)]
        let settings = AppSettings(servers: [server], shares: [grant], locations: [location])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object["version"] = 3
        let upgraded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(upgraded.locations, settings.locations)
        XCTAssertEqual(upgraded.shares, settings.shares)
        XCTAssertNil(upgraded.locations[0].writeBookmark)
        XCTAssertEqual(upgraded.version, 6)
    }

    func testVersionFiveMigrationKeepsEachLocationsAccessAndIdentity() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "smb://home-nas")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@home-nas/share",
                                address: try XCTUnwrap(ShareAddress("//account@home-nas/share")))
        var readOnly = LocationRecord(name: "Read", serverID: grant.id, folder: .root)
        readOnly.pendingKeeps = [KeepPath(path: "file", kind: .file)]
        var legacy = LocationRecord(name: "Create", serverID: grant.id, folder: .root)
        legacy.writeBookmark = Data([2])
        var confirmed = LocationRecord(name: "Write", serverID: grant.id, folder: .root)
        confirmed.writeBookmark = Data([3])
        confirmed.smbOnlyEditing = true
        let old = AppSettings(servers: [server], shares: [grant], locations: [readOnly, legacy, confirmed])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["version"] = 5
        object["locations"] = try XCTUnwrap(object["locations"] as? [[String: Any]]).map { location in
            var result = location
            result["readOnly"] = nil
            return result
        }
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.locations.map(\.id), old.locations.map(\.id))
        XCTAssertEqual(migrated.locations.map(\.domainID), old.locations.map(\.domainID))
        XCTAssertEqual(migrated.locations.map(\.pendingKeeps), old.locations.map(\.pendingKeeps))
        XCTAssertEqual(migrated.locations.map(\.readOnly), [true, false, false])
        XCTAssertEqual(migrated.locations.map(\.activeWriteBookmark), [nil, Data([2]), Data([3])])
        XCTAssertEqual(migrated.locations.map(\.needsWriteConfirmation), [false, true, false])
        XCTAssertEqual(migrated.locations.map(\.smbOnlyEditing), [nil, nil, true])
    }

    func testReadOnlyRetainsInactiveGrantAndConfirmationAcrossRelaunch() throws {
        var location = LocationRecord(name: "Read", serverID: UUID(), folder: .root)
        location.writeBookmark = Data([4])
        location.smbOnlyEditing = true
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
        XCTAssertFalse(enabled.needsWriteConfirmation)
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

    func testSettingsRoundTripThroughAPrivateFile() throws {
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "account@nas.local")))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1, 2, 3]), mountFrom: "//account@nas.local/Media", address: address)
        var record = LocationRecord(name: "Movies", serverID: grant.id, folder: try XCTUnwrap(RelativePath("Movies/2024")))
        record.retiredDomainID = UUID().uuidString
        record.pendingKeeps = fileKeeps(["Movies/2024/a.mkv"])
        var settings = AppSettings(servers: [server], shares: [grant], locations: [record, LocationRecord(name: "Media", serverID: grant.id, folder: .root)],
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
        XCTAssertEqual(empty.version, 6)
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

    func testAnUnknownVersionIsRejected() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 6)
        for version in [0, 7] {
            object["version"] = version
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data)) {
                XCTAssertEqual($0 as? SettingsError, .unsupportedVersion(version))
            }
        }
        object["version"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testVersionOneMigrationKeepsLocationsAndGrantsAndSavesVersionThree() throws {
        let previous = Data("""
        {
          "version": 1,
          "servers": [
            {"id":"11111111-1111-1111-1111-111111111111", "bookmark":"AQID",
             "mountFrom":"//account@nas.local/Media", "host":"nas.local", "account":"account", "share":"Media"},
            {"id":"22222222-2222-2222-2222-222222222222", "bookmark":"BAUG",
             "mountFrom":"//account@NAS.local/Photos", "host":"NAS.local", "account":"account", "share":"Photos"},
            {"id":"33333333-3333-3333-3333-333333333333", "bookmark":"BwgJ",
             "mountFrom":"//other@nas.local/Media", "host":"nas.local", "account":"other", "share":"Media"}
          ],
          "locations": [
            {"id":"44444444-4444-4444-4444-444444444444", "name":"Movies",
             "serverID":"11111111-1111-1111-1111-111111111111", "folder":"Movies",
             "domainID":"55555555-5555-5555-5555-555555555555", "removing":false,
             "pendingKeeps":["Movies/a.mkv"]}
          ],
          "savedKeeps":[{"host":"nas.local", "share":"Media", "paths":["Music/b.flac"]}]
        }
        """.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Settings.json")
        try previous.write(to: url)
        let migrated = try AppSettings.load(from: url)
        XCTAssertEqual(migrated.version, 6)
        XCTAssertEqual(migrated.servers.count, 2)
        XCTAssertEqual(migrated.shares.count, 3)
        XCTAssertEqual(migrated.shares[0].id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(migrated.shares[0].bookmark, Data([1, 2, 3]))
        XCTAssertEqual(migrated.shares[0].mountFrom, "//account@nas.local/Media")
        XCTAssertEqual(migrated.shares[0].serverID, migrated.shares[1].serverID)
        XCTAssertNotEqual(migrated.shares[0].serverID, migrated.shares[2].serverID)
        XCTAssertEqual(migrated.locations[0].serverID, migrated.shares[0].id)
        XCTAssertEqual(migrated.locations[0].domainID, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(migrated.locations[0].pendingKeeps, fileKeeps(["Movies/a.mkv"]))
        XCTAssertEqual(migrated.savedKeeps[0].paths, fileKeeps(["Music/b.flac"]))
        XCTAssertEqual(try AppSettings.load(from: url), migrated)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(saved["version"] as? Int, 6)
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testFailedMigrationDoesNotReplaceThePreviousSettings() throws {
        let previous = Data(#"{"version":1,"servers":[],"locations":[],"savedKeeps":[]}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Settings.json")
        try previous.write(to: url)
        try FileManager.default.createDirectory(at: url.appendingPathExtension("new"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try AppSettings.load(from: url))
        XCTAssertEqual(try Data(contentsOf: url), previous)
    }

    func testRemovingAServerInUseDoesNotChangeSettings() throws {
        let server = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "nas.local")))
        let other = ServerRecord(address: try XCTUnwrap(ServerAddress(typed: "other.local")))
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let grant = ServerGrant(serverID: server.id, bookmark: Data([1]), mountFrom: "//account@nas.local/Media", address: address)
        let record = LocationRecord(name: "Media", serverID: grant.id, folder: .root)
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

    func testVersionTwoRejectsASeparateShareWithoutItsServer() throws {
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
