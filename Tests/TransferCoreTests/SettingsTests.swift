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

    func testUniqueNameAddsANumber() {
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X"]), "X copy")
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X", "X copy"]), "X copy 2")
        XCTAssertEqual(LocationRecord.uniqueName("X copy", among: ["X", "x COPY", "X copy 2"]), "X copy 3")
        XCTAssertEqual(LocationRecord.uniqueName("Caf\u{e9}", among: ["Cafe\u{301}"]), "Caf\u{e9} 2")
        XCTAssertEqual(LocationRecord.uniqueName("Media", among: []), "Media")
    }

    func testSettingsRoundTripThroughAPrivateFile() throws {
        let address = try XCTUnwrap(ShareAddress("//account@nas.local/Media"))
        let grant = ServerGrant(bookmark: Data([1, 2, 3]), mountFrom: "//account@nas.local/Media", address: address)
        var record = LocationRecord(name: "Movies", serverID: grant.id, folder: try XCTUnwrap(RelativePath("Movies/2024")))
        record.retiredDomainID = UUID().uuidString
        var settings = AppSettings(servers: [grant], locations: [record, LocationRecord(name: "Media", serverID: grant.id, folder: .root)],
                                   savedKeeps: [SavedKeepList(host: address.host, share: address.share, paths: ["Movies/a.mkv"])])
        settings.showInMenuBar = false
        settings.notifications = false
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
        XCTAssertEqual(empty.version, 1)
        XCTAssertTrue(empty.servers.isEmpty && empty.locations.isEmpty && empty.savedKeeps.isEmpty)

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
        XCTAssertEqual(object["version"] as? Int, 1)
        for version in [0, 2] {
            object["version"] = version
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data)) {
                XCTAssertEqual($0 as? SettingsError, .unsupportedVersion(version))
            }
        }
        object["version"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { throw posixError("stat") }
        return info.st_mode & 0o777
    }
}
