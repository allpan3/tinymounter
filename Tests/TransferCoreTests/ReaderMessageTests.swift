import Foundation
import XCTest
@testable import TransferCore

final class ReaderMessageTests: XCTestCase {
    private let item = UUID().uuidString

    func testItemIDsAreTheRootConstantOrUpperCaseUUIDs() {
        XCTAssertTrue(ReaderMessage.isItemID(Catalog.rootItemID))
        XCTAssertTrue(ReaderMessage.isItemID(item))
        for invalid in ["", "fixture", item.lowercased(), "{\(item)}", " \(item)", item + "\n", "..", "Movies",
                        Catalog.rootItemID.lowercased(), Catalog.rootItemID + "/",
                        "NSFileProviderWorkingSetContainerItemIdentifier"] {
            XCTAssertFalse(ReaderMessage.isItemID(invalid), invalid)
        }
    }

    func testMessagesRoundTrip() throws {
        for folder in [Catalog.rootItemID, item] {
            let request = try ListRequest(folder: folder)
            XCTAssertEqual(try ReaderMessage.decode(ListRequest.self, from: ReaderMessage.encode(request)), request)
        }
        let receipt = try ListReceipt(generation: 7, entries: 169, changed: 3, skipped: 2)
        XCTAssertEqual(try ReaderMessage.decode(ListReceipt.self, from: ReaderMessage.encode(receipt)), receipt)

        let range = try ByteRange(offset: 16 << 20, length: 16 << 20, fileSize: 1 << 40)
        let version = ContentFingerprint(size: .max, mtimeNs: .min, ctimeNs: .min).contentVersion
        let read = try SourceReadRequest(id: UUID(), item: item, version: version, range: range)
        let data = try ReaderMessage.encode(read)
        XCTAssertEqual(try ReaderMessage.decode(SourceReadRequest.self, from: data), read)
        XCTAssertLessThan(data.count, 512)

        let started = SourceReadStarted(id: read.id)
        let startedData = try ReaderMessage.encode(started)
        XCTAssertEqual(try ReaderMessage.decode(SourceReadStarted.self, from: startedData), started)
        XCTAssertEqual(try ReaderMessage.decode(SourceReadStarted.self, from: startedData).id.uuidString,
                       read.id.uuidString, "the extension finds the fetch by this string")
    }

    func testInvalidIDsAreRejectedWhenMadeAndWhenDecoded() throws {
        let range = try ByteRange(offset: 0, length: 1, fileSize: 1)
        for invalid in ["", "fixture", item.lowercased(), "a/b"] {
            XCTAssertThrowsError(try ListRequest(folder: invalid), invalid)
            XCTAssertThrowsError(try SourceReadRequest(id: UUID(), item: invalid, version: "f1:1:2:3", range: range),
                                 invalid)
            let list = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "folder": invalid])
            XCTAssertThrowsError(try ReaderMessage.decode(ListRequest.self, from: list), invalid) {
                XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
            }
            var read = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderMessage.encode(
                SourceReadRequest(id: UUID(), item: item, version: "f1:1:2:3", range: range))) as? [String: Any])
            read["item"] = invalid
            XCTAssertThrowsError(try ReaderMessage.decode(SourceReadRequest.self,
                                                          from: JSONSerialization.data(withJSONObject: read)), invalid)
        }
        for invalid in ["", "fixture", "a/b", Catalog.rootItemID] {
            let started = try JSONSerialization.data(withJSONObject: ["id": invalid])
            XCTAssertThrowsError(try ReaderMessage.decode(SourceReadStarted.self, from: started), invalid) {
                XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
            }
        }
        XCTAssertThrowsError(try ReaderMessage.decode(SourceReadStarted.self, from: Data("{}".utf8)))
        let longVersion = String(repeating: "9", count: SourceReadRequest.maxVersionBytes + 1)
        XCTAssertThrowsError(try SourceReadRequest(id: UUID(), item: item, version: longVersion, range: range))
        XCTAssertThrowsError(try ListReceipt(generation: 1, entries: -1, changed: 0, skipped: 0))
        let negative = Data(#"{"generation":-1,"entries":0,"changed":0,"skipped":0}"#.utf8)
        XCTAssertThrowsError(try ReaderMessage.decode(ListReceipt.self, from: negative))
        XCTAssertThrowsError(try ReaderMessage.decode(ListReceipt.self, from: Data("{}".utf8)))
    }

    func testMessagesOverTheBoundAreRejected() throws {
        let list = try ReaderMessage.encode(ListRequest(folder: item))
        let largest = padded(list, to: ReaderMessage.maxBytes)
        XCTAssertEqual(largest.count, ReaderMessage.maxBytes)
        XCTAssertEqual(try ReaderMessage.decode(ListRequest.self, from: largest).folder, item)
        let over = padded(list, to: ReaderMessage.maxBytes + 1)
        XCTAssertThrowsError(try ReaderMessage.decode(ListRequest.self, from: over)) {
            XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
        }

        let metrics = TransferMetrics(bytes: 1, readCalls: 1, firstReadSeconds: nil, transferSeconds: 0.5,
                                      steadyStateMBps: nil, syncSeconds: 0, processCPUSeconds: 0.1,
                                      processLifetimePeakRSSBytes: 1 << 20)
        let receipt = try ReaderMessage.encode(SourceReadReceipt(stagingName: "tinymounter-\(item).stage",
                                                                 metrics: metrics))
        let largestReceipt = padded(receipt, to: ReaderMessage.maxBytes)
        XCTAssertEqual(try ReaderMessage.decode(SourceReadReceipt.self, from: largestReceipt).metrics.bytes, 1)
        XCTAssertThrowsError(try ReaderMessage.decode(SourceReadReceipt.self,
                                                      from: padded(receipt, to: ReaderMessage.maxBytes + 1)))
        let started = try ReaderMessage.encode(SourceReadStarted(id: UUID()))
        XCTAssertNoThrow(try ReaderMessage.decode(SourceReadStarted.self, from: padded(started, to: ReaderMessage.maxBytes)))
        XCTAssertThrowsError(try ReaderMessage.decode(SourceReadStarted.self,
                                                      from: padded(started, to: ReaderMessage.maxBytes + 1)))
        XCTAssertThrowsError(try ReaderMessage.encode(["pad": String(repeating: "x", count: ReaderMessage.maxBytes)])) {
            XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
        }
    }

    /// Decoders ignore unknown keys, so a padding key makes a valid message of any size.
    private func padded(_ message: Data, to size: Int) -> Data {
        let key = Data(#"{"pad":""#.utf8), end = Data(#"","#.utf8)
        let fill = size - key.count - end.count - (message.count - 1)
        return key + Data(repeating: UInt8(ascii: "x"), count: fill) + end + message.dropFirst()
    }
}
