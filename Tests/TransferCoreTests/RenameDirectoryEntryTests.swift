import Foundation
import XCTest
@testable import TransferCore

final class RenameDirectoryEntryTests: XCTestCase {
    private func entry(_ name: String, id: UInt64 = 7, attributes: UInt32 = 0, next: Bool = false) -> [UInt8] {
        let encoded = Array(name.data(using: .utf16LittleEndian)!)
        let size = (80 + encoded.count + 7) & ~7
        var bytes = [UInt8](repeating: 0, count: size)
        func set(_ offset: Int, _ count: Int, _ value: UInt64) {
            for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        set(0, 4, next ? UInt64(size) : 0)
        set(8, 8, (11_644_473_600_000_000 + 123_456) * 10)
        set(56, 4, UInt64(attributes))
        set(60, 4, UInt64(encoded.count))
        set(72, 8, id)
        bytes.replaceSubrange(80..<(80 + encoded.count), with: encoded)
        return bytes
    }

    func testKindsKeepUnsupportedEntriesInCompleteListings() throws {
        let attributes: [UInt32] = [0x20, 0x10, 0x400, 0x410, 0x40]
        let bytes = attributes.enumerated().flatMap {
            entry("child-\($0.offset)", attributes: $0.element, next: $0.offset != attributes.count - 1)
        }
        let parsed = try RenameDirectoryEntry.parse(bytes)
        XCTAssertEqual(parsed.map(\.attributes), attributes)
        XCTAssertEqual(parsed.map(\.kind), [.file, .folder, nil, nil, nil])
        XCTAssertEqual(parsed.map(\.name), (0..<attributes.count).map { "child-\($0)" })
    }

    func testStoredSpellingAndIdentitySurviveDirectoryParsing() throws {
        let names = [".", "..", "CASE.txt", "e\u{301}.txt", "\u{1F4C4}.txt"]
        let bytes = names.enumerated().flatMap { entry($0.element, next: $0.offset != names.count - 1) }
        let parsed = try RenameDirectoryEntry.parse(bytes)
        XCTAssertEqual(parsed.map { Array($0.name.utf8) }, names.dropFirst(2).map { Array($0.utf8) })
        XCTAssertTrue(parsed.allSatisfy { $0.identity.fileID == 7 && $0.identity.birthMicroseconds == 123_456 })
    }

    func testTruncatedOffsetsInvalidNamesAndUnprovenIdentityFailClosed() throws {
        let valid = entry("file.txt")
        for length in 0..<(80 + "file.txt".utf16.count * 2) {
            XCTAssertThrowsError(try RenameDirectoryEntry.parse(Array(valid.prefix(length))))
        }
        var overlap = valid
        overlap[0] = 8
        XCTAssertThrowsError(try RenameDirectoryEntry.parse(overlap))
        var oddLength = valid
        oddLength[60] = 3
        XCTAssertThrowsError(try RenameDirectoryEntry.parse(oddLength))
        var invalidUTF16 = valid
        invalidUTF16[80] = 0
        invalidUTF16[81] = 0xDC
        XCTAssertThrowsError(try RenameDirectoryEntry.parse(invalidUTF16))
        XCTAssertThrowsError(try RenameDirectoryEntry.parse(entry("file.txt", id: 0)))
        var noBirth = valid
        noBirth.replaceSubrange(8..<16, with: [UInt8](repeating: 0, count: 8))
        XCTAssertThrowsError(try RenameDirectoryEntry.parse(noBirth))
    }
}
