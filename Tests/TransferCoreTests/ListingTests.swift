import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class ListingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
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

    func testUnicodeNamesShareKeysWhereAPFSDoes() throws {
        for name in ["Cafe\u{301}.txt", "R\u{e9}sum\u{e9}.pdf", "MiXeD Case.TXT", "Stra\u{df}e", "\u{1100}\u{1161}"] {
            XCTAssertEqual(createErrno(name), 0, name)
        }
        // APFS treats each variant as the existing name, so the key must be the same.
        for (existing, variant) in [("Cafe\u{301}.txt", "Caf\u{e9}.txt"), ("R\u{e9}sum\u{e9}.pdf", "Re\u{301}sume\u{301}.pdf"),
                                    ("MiXeD Case.TXT", "mixed case.txt"), ("Stra\u{df}e", "STRASSE"),
                                    ("\u{1100}\u{1161}", "\u{ac00}")] {
            XCTAssertEqual(createErrno(variant), EEXIST, variant)
            XCTAssertEqual(NameKey(existing), NameKey(variant), variant)
        }
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
}
