import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class PathTests: XCTestCase {
    func testRelativePathRejectsInvalidComponentsAndLengths() {
        for invalid in [".", "..", "a//b", "/abs", "a/", "a/./b", "a/../b", "a\0b", String(repeating: "x", count: 256),
                        String(repeating: "\u{20ac}", count: 86)] {
            XCTAssertNil(RelativePath(invalid), invalid)
        }
        XCTAssertNotNil(RelativePath(String(repeating: "x", count: 255)))
        XCTAssertNotNil(RelativePath(String(repeating: "\u{20ac}", count: 85)))
        let component = String(repeating: "x", count: 255)
        let longest = Array(repeating: component, count: 4).joined(separator: "/")
        XCTAssertEqual(longest.utf8.count, 1023)
        XCTAssertNotNil(RelativePath(longest))
        XCTAssertNil(RelativePath(longest + "y"))
        XCTAssertNil(RelativePath(longest)?.appending("y"))
    }

    func testRootAndAppending() throws {
        let root = try XCTUnwrap(RelativePath(""))
        XCTAssertEqual(root, .root)
        XCTAssertTrue(root.isRoot)

        let path = try XCTUnwrap(root.appending("Movies")?.appending("Caf\u{e9} 2024")?.appending("clip.mkv"))
        XCTAssertEqual(path.string, "Movies/Caf\u{e9} 2024/clip.mkv")
        XCTAssertFalse(path.isRoot)
        XCTAssertEqual(RelativePath(path.string), path)
        for invalid in ["", ".", "..", "a/b", "a\0"] { XCTAssertNil(root.appending(invalid), invalid) }

        // A combining mark after "/" makes one Character with it; the split must still see "/".
        let marked = try XCTUnwrap(RelativePath("a/\u{301}b"))
        XCTAssertEqual(RelativePath("a")?.appending("\u{301}b"), marked)
        XCTAssertNil(RelativePath("/\u{301}"))
        XCTAssertNotNil(RelativePath(".\u{301}"))
    }

    func testComponentsAndJoiningPaths() throws {
        XCTAssertEqual(RelativePath.root.components, [])
        XCTAssertEqual(RelativePath("a/\u{301}b/c")?.components, ["a", "\u{301}b", "c"])
        let movies = try XCTUnwrap(RelativePath("Movies"))
        let clip = try XCTUnwrap(RelativePath("2024/clip.mkv"))
        XCTAssertEqual(movies.appending(clip)?.string, "Movies/2024/clip.mkv")
        XCTAssertEqual(RelativePath.root.appending(clip), clip)
        XCTAssertEqual(movies.appending(RelativePath.root), movies)
        let component = String(repeating: "x", count: 255)
        let long = try XCTUnwrap(RelativePath([component, component].joined(separator: "/")))
        XCTAssertEqual(long.appending(long)?.string.utf8.count, RelativePath.maxBytes)
        XCTAssertNil(long.appending(long)?.appending(try XCTUnwrap(RelativePath("y"))))
    }

    func testComponentValidator() {
        XCTAssertTrue(RelativePath.isValidComponent("Report (final).pdf"))
        XCTAssertTrue(RelativePath.isValidComponent("..."))
        XCTAssertTrue(RelativePath.isValidComponent(":colon"))
        for invalid in ["", ".", "..", "a/b", "/", "a\0", String(repeating: "x", count: 256)] {
            XCTAssertFalse(RelativePath.isValidComponent(invalid), invalid)
        }
    }

    func testNameKeyFoldsCaseAndNormalizationLikeAPFS() {
        // Pairs that case-insensitive APFS treats as one name, checked in /tmp on 2026-10-12.
        for (a, b) in [("Movie.MKV", "movie.mkv"), ("Caf\u{e9}", "Cafe\u{301}"), ("Stra\u{df}e", "STRASSE"),
                       ("\u{fb01}le", "FILE"), ("\u{212a}", "k"), ("\u{3c2}", "\u{3a3}"), ("\u{ac00}", "\u{1100}\u{1161}"),
                       ("\u{1e9b}\u{323}", "\u{1e69}"), ("\u{1fb7}", "\u{391}\u{342}\u{345}"),
                       ("\u{1fc7}", "\u{397}\u{342}\u{345}"), ("\u{1ff7}", "\u{3a9}\u{342}\u{345}"),
                       ("\u{16d68}", "\u{16d67}\u{16d67}"), ("\u{16d69}", "\u{16d63}\u{16d67}"),
                       ("\u{16d6a}", "\u{16d69}\u{16d67}")] {
            XCTAssertEqual(NameKey(a), NameKey(b), "\(a) \(b)")
            XCTAssertEqual(Array(NameKey(a).value.utf8), Array(NameKey(b).value.utf8), "\(a) \(b)")
        }
        // APFS keeps these apart, so the key does too.
        XCTAssertNotEqual(NameKey("\u{131}"), NameKey("i"))
        XCTAssertNotEqual(NameKey("\u{130}"), NameKey("i"))
        XCTAssertNotEqual(NameKey("a b"), NameKey("ab"))
    }

    func testSMBNameIgnoresNormalizationButNotCase() {
        XCTAssertEqual(SMBName.key("Cafe\u{301}/Re\u{301}sume\u{301}.txt"), Data("Caf\u{e9}/R\u{e9}sum\u{e9}.txt".utf8))
        XCTAssertEqual(SMBName.key("\u{ac00}"), SMBName.key("\u{1100}\u{1161}"))
        XCTAssertTrue(SMBName.same("Cafe\u{301}", "Caf\u{e9}"))
        XCTAssertTrue(SMBName.same("plain", "plain"))
        XCTAssertFalse(SMBName.same("Caf\u{e9}", "CAF\u{c9}"))
        XCTAssertFalse(SMBName.same("Movie.MKV", "movie.mkv"))
        // Compatibility forms are other names on the wire, unlike under NameKey.
        XCTAssertFalse(SMBName.same("\u{fb01}le", "file"))
        // The macOS client sends these singletons unchanged; NFC would name other files.
        XCTAssertEqual(SMBName.key("e\u{301}\u{2126}\u{f900}\u{2f800}e\u{301}"),
                       Data("\u{e9}\u{2126}\u{f900}\u{2f800}\u{e9}".utf8))
        XCTAssertFalse(SMBName.same("\u{f900}", "\u{8c48}"))
        XCTAssertFalse(SMBName.same("ohm-\u{2126}", "ohm-\u{3a9}"))
    }

    func testStoredSMBNamesMatchOnlyTheRequestedWireSpelling() {
        XCTAssertTrue(SMBName.matchesStored("Café", requested: "Cafe\u{301}"))
        XCTAssertTrue(SMBName.matchesStored("Café", requested: "Café"))
        XCTAssertFalse(SMBName.matchesStored("Cafe\u{301}", requested: "Café"))
        XCTAssertFalse(SMBName.matchesStored("Cafe\u{301}", requested: "Cafe\u{301}"))
        XCTAssertFalse(SMBName.matchesStored("CAFÉ", requested: "Café"))
        XCTAssertTrue(SMBName.matchesStored("ohm-\u{2126}", requested: "ohm-\u{2126}"))
        XCTAssertFalse(SMBName.matchesStored("ohm-\u{3a9}", requested: "ohm-\u{2126}"))
    }

    func testDirectoryRelativeOpenReadsNestedFileAndRejectsOtherKinds() throws {
        try withTree { root, rootFD, bytes in
            let identity = try MountIdentity(descriptor: rootFD)
            let path = try XCTUnwrap(RelativePath("a/b/file.bin"))
            let file = try ReadOnlyFile(directoryFD: rootFD, relativePath: path, expected: identity, noCache: true)
            XCTAssertEqual(file.snapshot.size, Int64(bytes.count))
            for (offset, length) in [(0, 17), (4093, 9), (bytes.count - 5, 5)] {
                var read = [UInt8](repeating: 0, count: length)
                XCTAssertEqual(pread(file.descriptor, &read, length, off_t(offset)), length)
                XCTAssertEqual(Data(read), bytes[offset..<(offset + length)])
            }
            XCTAssertEqual(fcntl(file.descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)

            for kind in ["a", "a/fifo"] {
                let relative = try XCTUnwrap(RelativePath(kind))
                XCTAssertThrowsError(try ReadOnlyFile(directoryFD: rootFD, relativePath: relative, expected: identity)) {
                    XCTAssertEqual($0 as? TransferError, .notRegularFile, kind)
                }
            }
            let expected = [("", ENOENT), ("missing", ENOENT), ("linked/b/file.bin", ELOOP), ("a/b/link.bin", ELOOP)]
            for (path, code) in expected {
                let relative = try XCTUnwrap(RelativePath(path))
                XCTAssertEqual(openErrno(path) {
                    try ReadOnlyFile(directoryFD: rootFD, relativePath: relative, expected: identity)
                }, code, path)
            }
            // RelativePath can't express an escape, so these reach openat through the raw path.
            let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString)")
            try Data("outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let resolved = outside.resolvingSymlinksInPath().path(percentEncoded: false)
            for escape in ["../" + outside.lastPathComponent, resolved, outside.path(percentEncoded: false)] {
                XCTAssertEqual(openErrno(escape) { try ReadOnlyFile(directoryFD: rootFD, path: escape, noCache: false) },
                               ENOTCAPABLE, escape)
            }
        }
    }

    /// Returns the errno, and checks that the error names neither the path nor its last component.
    private func openErrno(_ path: String, _ body: () throws -> ReadOnlyFile) -> Int32? {
        do {
            _ = try body()
            return nil
        } catch {
            let error = error as NSError
            let text = "\(error) \(error.localizedDescription)"
            if let name = path.split(separator: "/").last { XCTAssertFalse(text.contains(name), path) }
            return error.domain == NSPOSIXErrorDomain ? Int32(error.code) : nil
        }
    }

    private func withTree(_ body: (URL, Int32, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<10_007).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 7)) })
        try bytes.write(to: root.appending(path: "a/b/file.bin"))
        func path(_ relative: String) -> String { root.appending(path: relative).path(percentEncoded: false) }
        try FileManager.default.createSymbolicLink(atPath: path("linked"), withDestinationPath: "a")
        try FileManager.default.createSymbolicLink(atPath: path("a/b/link.bin"), withDestinationPath: "file.bin")
        XCTAssertEqual(mkfifo(path("a/fifo"), 0o600), 0)
        let rootFD = open(root.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
        defer { close(rootFD) }
        try body(root, rootFD, bytes)
    }
}
