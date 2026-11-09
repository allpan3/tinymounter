import Foundation
import XCTest
@testable import TransferCore

final class ReaderMessageTests: XCTestCase {
    private let item = UUID().uuidString

    func testDeletionMessagesBindVersionAndRecursiveIntentWithoutPaths() throws {
        for recursive in [true, false] {
            let request = try DeleteItemRequest(item: item, contentVersion: "v1", metadataVersion: "7",
                                                eventVersion: Data([1]), recursive: recursive)
            let data = try ReaderMessage.encode(request)
            XCTAssertEqual(try ReaderMessage.decode(DeleteItemRequest.self, from: data), request)
            XCTAssertLessThan(data.count, ReaderMessage.maxBytes)
            let receipt = DeleteItemReceipt(id: request.id, item: request.item)
            XCTAssertEqual(try ReaderMessage.decode(DeleteItemReceipt.self, from: ReaderMessage.encode(receipt)), receipt)
        }
    }

    func testDeletionMessagesRejectRootsPathsAndInvalidVersionsAtDecode() throws {
        let request = try DeleteItemRequest(item: item, contentVersion: "v1", metadataVersion: "7",
                                            eventVersion: Data([1]), recursive: true)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderMessage.encode(request)) as? [String: Any])
        let invalid: [(String, Any)] = [("item", Catalog.rootItemID), ("item", "folder/file"),
            ("item", item.lowercased()), ("contentVersion", ""), ("contentVersion", String(repeating: "x", count: 129)),
            ("metadataVersion", "-1"), ("metadataVersion", "unknown"), ("metadataVersion", String(repeating: "1", count: 21)),
            ("eventVersion", ""), ("eventVersion", Data(repeating: 1, count: 4097).base64EncodedString()),
            ("recursive", "yes")]
        for (key, value) in invalid {
            var changed = original
            changed[key] = value
            XCTAssertThrowsError(try ReaderMessage.decode(DeleteItemRequest.self,
                from: JSONSerialization.data(withJSONObject: changed)), key)
        }
        for key in ["recursive", "eventVersion"] {
            var missing = original
            missing[key] = nil
            XCTAssertThrowsError(try ReaderMessage.decode(DeleteItemRequest.self,
                from: JSONSerialization.data(withJSONObject: missing)), key)
        }
    }

    func testDeletionEventArchiveFitsWithinTheBoundedEnvelope() throws {
        let event = Data(repeating: 0xff, count: 4096)
        let request = try DeleteItemRequest(item: item, contentVersion: String(repeating: "v", count: 128),
            metadataVersion: String(Int64.max), eventVersion: event, recursive: true)
        let data = try ReaderMessage.encode(request)
        XCTAssertLessThanOrEqual(data.count, ReaderMessage.maxBytes)
        XCTAssertEqual(try ReaderMessage.decode(DeleteItemRequest.self, from: data), request)
        XCTAssertThrowsError(try ReaderMessage.decode(DeleteItemRequest.self,
            from: padded(data, to: ReaderMessage.maxBytes + 1)))
        for invalid in [Data(), Data(repeating: 1, count: 4097)] {
            XCTAssertThrowsError(try DeleteItemRequest(item: item, contentVersion: "v1", metadataVersion: "7",
                eventVersion: invalid, recursive: true))
        }
    }

    func testEditMessagesKeepBaseAndConflictPolicyAndRejectUnsafePaths() throws {
        let request = try EditRequest(item: UUID().uuidString, parent: Catalog.rootItemID, name: "note.txt",
                                      baseVersion: "r1:" + UUID().uuidString, staging: UUID(), failOnConflict: true)
        let decoded = try ReaderMessage.decode(EditRequest.self, from: ReaderMessage.encode(request))
        XCTAssertEqual(decoded.baseVersion, request.baseVersion)
        XCTAssertEqual(decoded.staging, request.staging)
        XCTAssertTrue(decoded.failOnConflict)
        XCTAssertNil(decoded.modified)
        for name in ["../note.txt", "file:stream", "live.sqlite", "disk.vmdk"] {
            XCTAssertThrowsError(try EditRequest(item: UUID().uuidString, parent: Catalog.rootItemID, name: name,
                                                baseVersion: "legacy", staging: UUID(), failOnConflict: false))
        }
    }

    func testUploadMessagesCarryTheSaveTimeExactly() throws {
        let saved = Date(timeIntervalSince1970: 1_762_600_000.987_654_3)
        let edit = try EditRequest(item: UUID().uuidString, parent: Catalog.rootItemID, name: "note.txt",
                                   baseVersion: "v", staging: UUID(), failOnConflict: false, modified: saved)
        XCTAssertEqual(try ReaderMessage.decode(EditRequest.self, from: ReaderMessage.encode(edit)).modified, saved)
        let create = try CreateRequest(template: "t", parent: Catalog.rootItemID, name: "new.txt", kind: .file,
                                       staging: UUID(), modified: saved)
        XCTAssertEqual(try ReaderMessage.decode(CreateRequest.self, from: ReaderMessage.encode(create)).modified, saved)
    }

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
        let read = try SourceReadRequest(id: UUID(), item: item, version: version, range: range, background: true)
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
            XCTAssertThrowsError(try SourceReadRequest(id: UUID(), item: invalid, version: "f1:1:2:3", range: range, background: false),
                                 invalid)
            let list = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "folder": invalid])
            XCTAssertThrowsError(try ReaderMessage.decode(ListRequest.self, from: list), invalid) {
                XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
            }
            var read = try XCTUnwrap(JSONSerialization.jsonObject(with: ReaderMessage.encode(
                SourceReadRequest(id: UUID(), item: item, version: "f1:1:2:3", range: range, background: false))) as? [String: Any])
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
        XCTAssertThrowsError(try SourceReadRequest(id: UUID(), item: item, version: longVersion, range: range, background: false))
        XCTAssertThrowsError(try ListReceipt(generation: 1, entries: -1, changed: 0, skipped: 0))
        let negative = Data(#"{"generation":-1,"entries":0,"changed":0,"skipped":0}"#.utf8)
        XCTAssertThrowsError(try ReaderMessage.decode(ListReceipt.self, from: negative))
        XCTAssertThrowsError(try ReaderMessage.decode(ListReceipt.self, from: Data("{}".utf8)))
    }

    func testKeepRequestsStayWithinTheBoundAndSplitAnAction() throws {
        let ids = (0..<KeepRequest.maxItemsPerAction).map { _ in UUID().uuidString }
        let largest = try KeepRequest(items: Array(ids.prefix(KeepRequest.maxItems)), keep: false)
        let data = try ReaderMessage.encode(largest)
        XCTAssertLessThanOrEqual(data.count, ReaderMessage.maxBytes)
        XCTAssertEqual(try ReaderMessage.decode(KeepRequest.self, from: data), largest)
        let receipt = try KeepReceipt(changed: KeepRequest.maxItems)
        XCTAssertEqual(try ReaderMessage.decode(KeepReceipt.self, from: ReaderMessage.encode(receipt)), receipt)

        let batches = try KeepRequest.batches(Array(ids.prefix(250)), keep: true)
        XCTAssertEqual(batches.map(\.items.count), [100, 100, 50])
        XCTAssertEqual(batches.flatMap(\.items), Array(ids.prefix(250)))
        XCTAssertTrue(batches.allSatisfy(\.keep))
        XCTAssertEqual(Set(batches.map(\.id)).count, 3)
        XCTAssertEqual(try KeepRequest.batches(ids, keep: false).count, 10)
        XCTAssertEqual(try KeepRequest.batches([], keep: true), [])
        XCTAssertThrowsError(try KeepRequest.batches(ids + [item], keep: true)) {
            XCTAssertEqual($0 as? CocoaError, CocoaError(.featureUnsupported))
        }
    }

    func testInvalidKeepRequestsAreRejected() throws {
        XCTAssertThrowsError(try KeepRequest(items: [], keep: true))
        let over = (0...KeepRequest.maxItems).map { _ in UUID().uuidString }
        XCTAssertThrowsError(try KeepRequest(items: over, keep: true))
        let overData = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "items": over, "keep": true])
        XCTAssertLessThanOrEqual(overData.count, ReaderMessage.maxBytes, "the count check, not the size, rejects it")
        XCTAssertThrowsError(try ReaderMessage.decode(KeepRequest.self, from: overData))
        for invalid in ["", "fixture", item.lowercased(), "a/b", Catalog.rootItemID] {
            XCTAssertThrowsError(try KeepRequest(items: [item, invalid], keep: true), invalid)
            XCTAssertThrowsError(try KeepRequest.batches([item, invalid], keep: true), invalid)
            let json = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "items": [item, invalid],
                                                                   "keep": true])
            XCTAssertThrowsError(try ReaderMessage.decode(KeepRequest.self, from: json), invalid) {
                XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadCorruptFile))
            }
        }
        let noValue = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "items": [item]])
        XCTAssertThrowsError(try ReaderMessage.decode(KeepRequest.self, from: noValue))
        XCTAssertThrowsError(try KeepReceipt(changed: -1))
        XCTAssertThrowsError(try ReaderMessage.decode(KeepReceipt.self, from: Data(#"{"changed":-1}"#.utf8)))
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
