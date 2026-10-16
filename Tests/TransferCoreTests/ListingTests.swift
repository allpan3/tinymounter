import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class ListingTests: XCTestCase {
    private var root: URL!
    private var rootFD: Int32 = -1
    private var identity: MountIdentity!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        // The app holds its location root as O_EVTONLY, so the tests do too.
        rootFD = open(root.path(percentEncoded: false), O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
        identity = try MountIdentity(descriptor: rootFD)
    }

    override func tearDownWithError() throws {
        if rootFD >= 0 { close(rootFD) }
        try FileManager.default.removeItem(at: root)
    }

    func testFieldsEqualFstatat() throws {
        try makeFolder("Movies")
        try makeFolder("Movies/Season 1")
        create("Movies/clip.mkv", size: 10_007)
        create("Movies/Season 1/empty.txt")
        create("notes.txt", size: 5)
        create("old.txt", size: 1)
        setModified("Movies/clip.mkv", timespec(tv_sec: 1_600_000_000, tv_nsec: 987_654_321))
        setModified("old.txt", timespec(tv_sec: -1, tv_nsec: 500_000_000))

        var checked = 0
        for folder in ["", "Movies", "Movies/Season 1"] {
            let listing = try list(folder)
            XCTAssertEqual(listing.skipped, .init(), folder)
            XCTAssertTrue(listing.unreadable.isEmpty, folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: fullPath(folder))
            XCTAssertEqual(Set(listing.entries.map { Array($0.name.utf8) }), Set(names.map { Array($0.utf8) }), folder)
            for entry in listing.entries {
                let info = fileInfo(folder.isEmpty ? entry.name : folder + "/" + entry.name)
                let isFolder = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                XCTAssertEqual(entry.kind, isFolder ? .folder : .file, entry.name)
                XCTAssertEqual(entry.size, isFolder ? 0 : info.st_size, entry.name)
                XCTAssertEqual(entry.mtimeNs, nanoseconds(info.st_mtimespec), entry.name)
                XCTAssertEqual(entry.ctimeNs, nanoseconds(info.st_ctimespec), entry.name)
                XCTAssertEqual(entry.fileID, info.st_ino, entry.name)
                XCTAssertEqual(entry.key, NameKey(entry.name), entry.name)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 6)
        let movies = try list("Movies").entries
        XCTAssertEqual(movies.first { $0.name == "clip.mkv" }?.mtimeNs, 1_600_000_000_987_654_321)
        XCTAssertEqual(movies.first { $0.name == "clip.mkv" }?.size, 10_007)
        XCTAssertEqual(try list("").entries.first { $0.name == "old.txt" }?.mtimeNs, -500_000_000)
    }

    func testFiveThousandEntriesWithSmallBufferComplete() throws {
        try makeFolder("many")
        let names = (0..<5_000).map { String(format: "file-%05d.bin", $0) }
        for name in names { create("many/" + name) }
        try FileManager.default.createSymbolicLink(atPath: fullPath("many/zz-link"), withDestinationPath: "file-00000.bin")

        // An entry takes at least 88 bytes, so 16 KiB holds under 190: the loop runs many times.
        let listing = try list("many", bufferSize: 16 * 1024)
        XCTAssertEqual(listing.entries.map(\.name), names)
        XCTAssertEqual(listing.skipped.otherKinds, 1)
        XCTAssertEqual(try list("many", limit: 5_001, bufferSize: 16 * 1024).entries.count, 5_000)
        // The limit counts every entry, skipped ones included.
        XCTAssertThrowsError(try list("many", limit: 5_000, bufferSize: 16 * 1024)) {
            XCTAssertEqual($0 as? SourceFailure, .tooManyEntries)
        }
    }

    func testSkipsOtherKindsAndInvalidNamesAndNeverFollowsSymlinks() throws {
        try makeFolder("Folder")
        create("Folder/inner.txt")
        create("file.txt", size: 3)
        for (link, target) in [("link-file", "file.txt"), ("link-dir", "Folder"), ("link-absolute", "/"),
                               ("link-dangling", "missing")] {
            try FileManager.default.createSymbolicLink(atPath: fullPath(link), withDestinationPath: target)
        }
        XCTAssertEqual(mkfifo(fullPath("fifo"), 0o600), 0)
        // APFS takes up to 255 characters, so it can hold a name over the 255-byte limit.
        let longest = String(repeating: "\u{20ac}", count: 85)
        let tooLong = String(repeating: "\u{20ac}", count: 86)
        XCTAssertEqual(longest.utf8.count, 255)
        create(longest)
        create(tooLong)

        let listing = try list("")
        XCTAssertEqual(listing.entries.map(\.name), ["Folder", "file.txt", longest])
        XCTAssertEqual(listing.entries.map(\.kind), [.folder, .file, .file])
        XCTAssertEqual(listing.skipped, .init(otherKinds: 5, invalidNames: 1, collisions: 0))
        XCTAssertFalse(listing.entries.contains { $0.name == "inner.txt" })

        let expected = [("link-dir", ELOOP), ("link-dir/inner", ELOOP), ("link-file", ELOOP), ("file.txt", ENOTDIR),
                        ("fifo", ENOTDIR), ("missing", ENOENT), ("Folder/missing", ENOENT)]
        for (path, code) in expected { XCTAssertEqual(listErrno(path), code, path) }
    }

    func testNamesAPFSCannotCreateFailTheValidator() throws {
        // APFS can't create these, so only another server's listing can return one.
        for name in ["", ".", "..", "a/b", "/", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertFalse(RelativePath.isValidComponent(name), name)
        }
        for name in ["", ".", "..", "a/b", String(repeating: "x", count: 256)] {
            XCTAssertNotEqual(createErrno(name), 0, name)
        }
        XCTAssertEqual(createErrnoBytes([0x62, 0x61, 0x64, 0xff]), EILSEQ)
    }

    func testUnicodeNamesRoundTripExactlyAndShareKeysWhereAPFSDoes() throws {
        let names = ["Cafe\u{301}.txt", "R\u{e9}sum\u{e9}.pdf", "MiXeD Case.TXT", "Stra\u{df}e", "\u{1100}\u{1161}",
                     "\u{1f3ac} clip.mkv", "a:b", "trailing "]
        for name in names { create(name) }
        // APFS treats each variant as the existing name, so the key must be the same.
        for (existing, variant) in [("Cafe\u{301}.txt", "Caf\u{e9}.txt"), ("R\u{e9}sum\u{e9}.pdf", "Re\u{301}sume\u{301}.pdf"),
                                    ("MiXeD Case.TXT", "mixed case.txt"), ("Stra\u{df}e", "STRASSE"),
                                    ("\u{1100}\u{1161}", "\u{ac00}")] {
            XCTAssertEqual(createErrno(variant), EEXIST, variant)
            XCTAssertEqual(NameKey(existing), NameKey(variant), variant)
        }

        let listing = try list("")
        let byBytes = names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        XCTAssertEqual(listing.entries.map { Array($0.name.utf8) }, byBytes)
        XCTAssertEqual(Set(listing.entries.map(\.key)), Set(names.map(NameKey.init)))
        XCTAssertEqual(Set(listing.entries.map(\.key)).count, names.count)
        XCTAssertEqual(listing.skipped, .init())
    }

    func testKeyCollisionsKeepTheFirstNameInByteOrder() {
        // APFS can't hold two names with one key; a case-sensitive server can.
        let parsed: [DirectoryListing.Parsed] = ["movie.mkv", "Movie.mkv", "MOVIE.MKV", "Caf\u{e9}", "Cafe\u{301}", "notes"]
            .map { .entry(.init(name: $0, kind: .file, size: 1, mtimeNs: 2, ctimeNs: 3, fileID: 4)) }
            + [.unreadable(.init(name: "NOTES", error: EIO)), .otherKind, .invalidName, .invalidName]
        for order in [parsed, parsed.reversed(), parsed.shuffled()] {
            let listing = DirectoryListing(order)
            XCTAssertEqual(listing.entries.map { Array($0.name.utf8) }, [Array("Cafe\u{301}".utf8), Array("MOVIE.MKV".utf8)])
            XCTAssertEqual(listing.unreadable.map(\.name), ["NOTES"])
            XCTAssertEqual(listing.unreadable.map(\.error), [EIO])
            XCTAssertEqual(listing.collisionLosers.map { Array($0.name.utf8) },
                           ["Caf\u{e9}", "Movie.mkv", "movie.mkv", "notes"].map { Array($0.utf8) })
            XCTAssertEqual(listing.collisionLosers.map(\.key),
                           [NameKey("caf\u{e9}"), NameKey("movie.mkv"), NameKey("movie.mkv"), NameKey("notes")])
            XCTAssertEqual(listing.skipped, .init(otherKinds: 1, invalidNames: 2, collisions: 4))
        }
    }

    func testListingFailsUnlessTheMountMatches() throws {
        create("file.txt")
        XCTAssertEqual(identity.typeName, "apfs")
        var info = statfs()
        XCTAssertEqual(statfs(root.path(percentEncoded: false), &info), 0)
        XCTAssertEqual(MountIdentity(info), identity)
        XCTAssertEqual(try list("").entries.count, 1)
        for other in [MountIdentity(typeName: "smbfs", fsid: identity.fsid, mountFrom: identity.mountFrom),
                      MountIdentity(typeName: identity.typeName, fsid: identity.fsid ^ 1, mountFrom: identity.mountFrom),
                      MountIdentity(typeName: identity.typeName, fsid: identity.fsid, mountFrom: identity.mountFrom + "x")] {
            // The location root is off `other` too, so even ENOENT and ENOTDIR give notConnected.
            for path in ["", "missing", "file.txt"] {
                let relative = try XCTUnwrap(RelativePath(path))
                XCTAssertThrowsError(try DirectoryListing.list(locationRoot: rootFD, relativePath: relative,
                                                               expected: other)) {
                    XCTAssertEqual($0 as? SourceFailure, .notConnected, path)
                }
            }
        }
    }

    func testConfirmMissingPassesOnlyWhenEveryNameIsGone() throws {
        try makeFolder("dir")
        create("dir/file.txt")
        try makeFolder("dir/folder")
        try FileManager.default.createSymbolicLink(atPath: fullPath("dir/link"), withDestinationPath: "missing")
        XCTAssertEqual(mkfifo(fullPath("dir/fifo"), 0o600), 0)
        try confirmMissing(["gone.txt", "Gone"], in: "dir")
        try confirmMissing([], in: "no such folder")
        for name in ["file.txt", "folder"] {
            XCTAssertThrowsError(try confirmMissing(["gone.txt", name], in: "dir")) {
                XCTAssertEqual($0 as? SourceFailure, .listingIncomplete, name)
            }
        }
        // A symlink or a FIFO is never shown, so the file or folder that had the name is gone.
        try confirmMissing(["link", "fifo"], in: "dir")
        for name in ["", ".", "..", "folder/x", "a\0b"] {
            XCTAssertThrowsError(try confirmMissing([name], in: "dir")) {
                XCTAssertEqual($0 as? SourceFailure, .pathRejected, name)
            }
        }
        for (folder, code) in [("missing", ENOENT), ("dir/file.txt", ENOTDIR), ("dir/link", ELOOP)] {
            XCTAssertThrowsError(try confirmMissing(["gone.txt"], in: folder)) {
                XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain, folder)
                XCTAssertEqual(($0 as NSError).code, Int(code), folder)
            }
        }
    }

    func testConfirmMissingGuardsReconcileAgainstASkippedEntry() throws {
        try makeFolder("dir")
        for name in ["keep.txt", "gone.txt", "clip.mkv"] { create("dir/" + name) }
        let catalogs = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: catalogs, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: catalogs) }
        let catalog = try Catalog.create(at: catalogs.appending(path: "catalog.sqlite"), domainID: "domain-A",
                                         rootName: "Location")
        _ = try catalog.reconcile(folder: Catalog.rootItemID, listing: list("dir")) { _ in true }

        XCTAssertEqual(unlink(fullPath("dir/gone.txt")), 0)
        XCTAssertEqual(unlink(fullPath("dir/clip.mkv")), 0)
        let listing = try list("dir")
        // The file comes back after the pass, so the listing lacks a name that the share holds.
        create("dir/clip.mkv")
        let missing = try catalog.missingChildren(of: Catalog.rootItemID, listing: listing)
        XCTAssertEqual(Set(missing.map(\.name)), ["gone.txt", "clip.mkv"])
        XCTAssertThrowsError(try confirmMissing(missing, in: "dir")) {
            XCTAssertEqual($0 as? SourceFailure, .listingIncomplete)
        }
        XCTAssertNoThrow(try confirmMissing(missing.filter { $0.name != "clip.mkv" }, in: "dir"))
    }

    func testATwinTakesARowOnlyIfTheStoredNameIsGoneOrFindsThatTwin() throws {
        try makeFolder("dir")
        create("dir/notes.txt", size: 5)
        try XCTSkipIf(pathconf(fullPath("dir"), _PC_CASE_SENSITIVE) == 1, "The temporary folder is case-sensitive.")
        let catalogs = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: catalogs, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: catalogs) }
        let catalog = try Catalog.create(at: catalogs.appending(path: "catalog.sqlite"), domainID: "domain-A",
                                         rootName: "Location")
        let top = Catalog.rootItemID
        _ = try catalog.reconcile(folder: top, listing: list("dir")) { _ in true }
        let notes = try XCTUnwrap(catalog.liveChild(parent: top, nameKey: NameKey("notes.txt")))

        // Like many servers, this volume finds a case-only rename's new name by the old one.
        XCTAssertEqual(rename(fullPath("dir/notes.txt"), fullPath("dir/Notes.txt")), 0)
        let renamed = try list("dir")
        let missing = try catalog.missingChildren(of: top, listing: renamed)
        XCTAssertEqual(missing, [MissingChild(name: "notes.txt", twinFileID: fileInfo("dir/Notes.txt").st_ino)])
        try confirmMissing(missing, in: "dir")
        let other = MissingChild(name: "notes.txt", twinFileID: fileInfo("dir/Notes.txt").st_ino &+ 1)
        XCTAssertThrowsError(try confirmMissing([other], in: "dir")) {
            XCTAssertEqual($0 as? SourceFailure, .listingIncomplete)
        }
        XCTAssertEqual(try catalog.reconcile(folder: top, listing: renamed) { _ in true }?.updated, 1)
        let row = try XCTUnwrap(catalog.liveChild(parent: top, nameKey: NameKey("notes.txt")))
        XCTAssertEqual(row.id, notes.id)
        XCTAssertEqual(Array(row.name.utf8), Array("Notes.txt".utf8))

        // A case-sensitive server can list a twin folder while the stored name holds a symlink.
        XCTAssertEqual(unlink(fullPath("dir/Notes.txt")), 0)
        try makeFolder("dir/NOTES.TXT")
        let twin = try list("dir")
        let held = try catalog.missingChildren(of: top, listing: twin)
        XCTAssertEqual(held, [MissingChild(name: "Notes.txt", twinFileID: fileInfo("dir/NOTES.TXT").st_ino)])
        XCTAssertEqual(rmdir(fullPath("dir/NOTES.TXT")), 0)
        try FileManager.default.createSymbolicLink(atPath: fullPath("dir/Notes.txt"), withDestinationPath: "elsewhere")
        try confirmMissing(held, in: "dir")
        XCTAssertEqual(unlink(fullPath("dir/Notes.txt")), 0)
        try confirmMissing(held, in: "dir")
        XCTAssertEqual(try catalog.reconcile(folder: top, listing: twin) { _ in true }, ReconcilePlan(
            inserted: 1, updated: 0, tombstoned: 1, removesEveryChild: true, keptFilesRemoved: 0, unreadableSkipped: 0))
        XCTAssertEqual(try catalog.item(id: notes.id)?.deleted, true)
    }

    func testListingAndConfirmationProgressPerBatchAndPerName() throws {
        try makeFolder("many")
        for index in 0..<1_000 { create(String(format: "many/file-%04d.bin", index)) }
        var batches = 0
        let listing = try DirectoryListing.list(locationRoot: rootFD, relativePath: XCTUnwrap(RelativePath("many")),
                                                expected: identity, bufferSize: 16 * 1024) { batches += 1 }
        XCTAssertEqual(listing.entries.count, 1_000)
        // An entry takes at least 88 bytes, so 16 KiB holds under 190.
        XCTAssertGreaterThanOrEqual(batches, 6)

        // One second per lookup: a 50-name confirmation outlasts the stall limit yet keeps the share.
        final class Clock: @unchecked Sendable { var now = Duration.zero }
        let clock = Clock()
        var health = ShareHealth(now: { clock.now })
        XCTAssertFalse(health.mountAppeared().isEmpty)
        let activity = health.begin()
        var lookups = 0
        try confirmMissing((0..<50).map { MissingChild(name: "gone-\($0)") }, in: "many") {
            lookups += 1
            clock.now += .seconds(1)
            health.progressed(activity)
            XCTAssertEqual(health.evaluate(), .connected)
        }
        health.end(activity)
        XCTAssertEqual(lookups, 50)
    }

    func testEmptyFolderListsCompleteWithNoEntries() throws {
        try makeFolder("empty")
        let listing = try list("empty")
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertTrue(listing.unreadable.isEmpty)
        XCTAssertEqual(listing.skipped, .init())
    }

    func testEveryPathClosesItsDescriptors() throws {
        try makeFolder("dir")
        create("dir/a")
        create("dir/b")
        try FileManager.default.createSymbolicLink(atPath: fullPath("link"), withDestinationPath: "dir")
        let before = openDescriptors()
        for _ in 0..<20 {
            _ = try list("dir")
            _ = try? list("dir", limit: 1)
            _ = try? list("link")
            _ = try? list("dir/a")
            _ = try? list("missing")
            _ = try? DirectoryListing.list(locationRoot: rootFD, relativePath: .root,
                                           expected: MountIdentity(typeName: "smbfs", fsid: 0, mountFrom: ""))
            try confirmMissing(["gone"], in: "dir")
            _ = try? confirmMissing(["a"], in: "dir")
            _ = try? confirmMissing(["gone", ".."], in: "dir")
            _ = try? confirmMissing(["gone"], in: "link")
            _ = try? DirectoryListing.confirmMissing([MissingChild(name: "gone")], locationRoot: rootFD,
                                                     relativePath: .root,
                                                     expected: MountIdentity(typeName: "smbfs", fsid: 0, mountFrom: ""))
        }
        XCTAssertEqual(openDescriptors(), before)
    }

    func testParserReadsErroredEntriesAndRejectsMalformedOnes() throws {
        let file = PackedEntry(name: Array("a.bin".utf8), type: VREG.rawValue, size: 42)
        let folder = PackedEntry(name: Array("dir".utf8), type: VDIR.rawValue)
        // XNU's get_error_attributes packs RETURNED_ATTRS, ERROR and NAME, then zeroes the rest.
        var errored = PackedEntry(name: Array("busy.bin".utf8), type: 0, error: UInt32(EIO))
        errored.returned.commonattr = ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_ERROR)
        errored.returned.fileattr = 0
        var noType = PackedEntry(name: Array("no-type".utf8), type: VREG.rawValue)
        noType.returned.commonattr &= ~attrgroup_t(ATTR_CMN_OBJTYPE)
        var noTime = PackedEntry(name: Array("no-time".utf8), type: VDIR.rawValue)
        noTime.returned.commonattr &= ~attrgroup_t(ATTR_CMN_CHGTIME)
        var noSize = PackedEntry(name: Array("no-size".utf8), type: VREG.rawValue)
        noSize.returned.fileattr = 0
        let link = PackedEntry(name: Array("link".utf8), type: VLNK.rawValue)
        let invalid = [[0x62, 0x61, 0x64, 0xff], [], Array(".".utf8), Array("..".utf8), Array("a/b".utf8),
                       [UInt8](repeating: 0x78, count: 256)].map { PackedEntry(name: $0, type: VREG.rawValue) }

        let all = [file, folder, errored, noType, noTime, noSize, link] + invalid
        var parsed: [DirectoryListing.Parsed] = []
        try pack(all) { try DirectoryListing.parse($0, count: all.count, into: &parsed) }
        XCTAssertEqual(parsed.count, all.count)
        let listing = DirectoryListing(parsed)
        XCTAssertEqual(listing.entries.map(\.name), ["a.bin", "dir"])
        XCTAssertEqual(listing.entries.map(\.kind), [.file, .folder])
        XCTAssertEqual(listing.entries.map(\.size), [42, 0])
        XCTAssertEqual(listing.entries.first?.mtimeNs, 1_700_000_000_000_000_007)
        XCTAssertEqual(listing.entries.first?.ctimeNs, 1_700_000_001_000_000_009)
        XCTAssertEqual(listing.entries.first?.fileID, 77)
        XCTAssertEqual(listing.unreadable.map(\.name), ["busy.bin", "no-size", "no-time", "no-type"])
        XCTAssertEqual(listing.unreadable.map(\.error), [EIO, ENOATTR, ENOATTR, ENOATTR])
        XCTAssertEqual(listing.skipped, .init(otherKinds: 1, invalidNames: 6, collisions: 0))

        var nameless = file
        nameless.returned.commonattr &= ~attrgroup_t(ATTR_CMN_NAME)
        var outside = file
        outside.nameOffsetAdjustment = 4_096
        var unterminated = file
        unterminated.terminated = false
        var truncated = file
        truncated.lengthAdjustment = -(truncated.bytes.count - 30)
        var overlong = file
        overlong.lengthAdjustment = 8
        for (label, entry) in [("nameless", nameless), ("outside", outside), ("unterminated", unterminated),
                               ("truncated", truncated), ("overlong", overlong)] {
            var ignored: [DirectoryListing.Parsed] = []
            XCTAssertThrowsError(try pack([entry]) { try DirectoryListing.parse($0, count: 1, into: &ignored) }, label) {
                XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain, label)
                XCTAssertEqual(($0 as NSError).code, Int(EBADMSG), label)
            }
        }
        var ignored: [DirectoryListing.Parsed] = []
        XCTAssertThrowsError(try pack([file]) { try DirectoryListing.parse($0, count: 2, into: &ignored) })
    }

    private func list(_ path: String, limit: Int = DirectoryListing.defaultLimit,
                      bufferSize: Int = DirectoryListing.defaultBufferSize) throws -> DirectoryListing {
        try DirectoryListing.list(locationRoot: rootFD, relativePath: XCTUnwrap(RelativePath(path)), expected: identity,
                                  limit: limit, bufferSize: bufferSize)
    }

    private func fullPath(_ path: String) -> String { root.appending(path: path).path(percentEncoded: false) }

    private func confirmMissing(_ names: [String], in folder: String) throws {
        try confirmMissing(names.map { MissingChild(name: $0) }, in: folder)
    }

    private func confirmMissing(_ children: [MissingChild], in folder: String, progress: () -> Void = {}) throws {
        try DirectoryListing.confirmMissing(children, locationRoot: rootFD,
                                            relativePath: XCTUnwrap(RelativePath(folder)), expected: identity,
                                            progress: progress)
    }

    /// Returns the errno, and checks that the error names no path component.
    private func listErrno(_ path: String) -> Int32? {
        do {
            _ = try list(path)
            return nil
        } catch {
            let error = error as NSError
            let text = "\(error) \(error.localizedDescription)"
            for component in path.split(separator: "/") { XCTAssertFalse(text.contains(component), path) }
            return error.domain == NSPOSIXErrorDomain ? Int32(error.code) : nil
        }
    }

    private func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: false)
    }

    private func create(_ path: String, size: Int = 0) {
        XCTAssertEqual(createErrno(path, size: size), 0, path)
    }

    /// Creates the file with the exact UTF-8 bytes of `path`, which URL APIs might not keep.
    private func createErrno(_ path: String, size: Int = 0) -> Int32 { createErrnoBytes(Array(path.utf8), size: size) }

    private func createErrnoBytes(_ path: [UInt8], size: Int = 0) -> Int32 {
        let full = Array(root.path(percentEncoded: false).utf8) + [UInt8(ascii: "/")] + path + [0]
        let fd = full.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) { open($0.baseAddress!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        }
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        return ftruncate(fd, off_t(size)) == 0 ? 0 : errno
    }

    private func setModified(_ path: String, _ time: timespec) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), time]
        XCTAssertEqual(utimensat(AT_FDCWD, fullPath(path), &times, AT_SYMLINK_NOFOLLOW), 0)
    }

    private func fileInfo(_ path: String) -> stat {
        var info = stat()
        XCTAssertEqual(fstatat(rootFD, path, &info, AT_SYMLINK_NOFOLLOW), 0, path)
        return info
    }

    private func nanoseconds(_ time: timespec) -> Int64 {
        ContentFingerprint.nanoseconds(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec))
    }

    private func openDescriptors() -> Int {
        (0..<getdtablesize()).filter { fcntl($0, F_GETFD) != -1 }.count
    }

    /// One getattrlistbulk entry, laid out as the kernel packs this listing's attributes.
    private struct PackedEntry {
        var name: [UInt8]
        var type: UInt32
        var error: UInt32 = 0
        var size: Int64 = 0
        var returned = attribute_set_t(
            commonattr: ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE
                | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID),
            volattr: 0, dirattr: 0, fileattr: attrgroup_t(ATTR_FILE_DATALENGTH), forkattr: 0)
        var nameOffsetAdjustment: Int32 = 0
        var lengthAdjustment = 0
        var terminated = true

        var bytes: [UInt8] {
            var fixed: [UInt8] = []
            func append<Value>(_ value: Value) { withUnsafeBytes(of: value) { fixed.append(contentsOf: $0) } }
            append(UInt32(0))
            append(returned)
            append(error)
            let nameField = fixed.count
            append(attrreference_t(attr_dataoffset: 0, attr_length: 0))
            append(type)
            append(timespec(tv_sec: 1_700_000_000, tv_nsec: 7))
            append(timespec(tv_sec: 1_700_000_001, tv_nsec: 9))
            append(UInt64(77))
            if type != VDIR.rawValue { append(size) }
            let reference = attrreference_t(attr_dataoffset: Int32(fixed.count - nameField) + nameOffsetAdjustment,
                                            attr_length: UInt32(name.count + 1))
            withUnsafeBytes(of: reference) { fixed.replaceSubrange(nameField..<(nameField + 8), with: $0) }
            var result = fixed + name + [terminated ? 0 : 0x78]
            while result.count % 8 != 0 { result.append(0) }
            let length = UInt32(result.count + lengthAdjustment)
            withUnsafeBytes(of: length) { result.replaceSubrange(0..<4, with: $0) }
            return result
        }
    }

    private func pack(_ entries: [PackedEntry], _ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        try entries.flatMap(\.bytes).withUnsafeBytes(body)
    }
}
