import CryptoKit
import Foundation
import XCTest
@testable import TransferCore

final class VerifiedReadTests: XCTestCase {
    private typealias Reader = (Int64, UnsafeMutableRawBufferPointer) throws -> Int
    private enum ReadFailure: Error, Equatable { case disconnected }

    func testWholeDigestAndBlockBoundariesWithShortReads() throws {
        let bytes = contents(VerifiedRead.blockSize * 2 + 37)
        let ordinary = reader(bytes)
        let limits = [7, 4093, 113, 65_537]
        var calls = 0, expectedOffset: Int64 = 0
        let captured = try VerifiedRead.capture(size: Int64(bytes.count)) { offset, buffer in
            XCTAssertEqual(offset, expectedOffset)
            XCTAssertLessThanOrEqual(buffer.count, VerifiedRead.blockSize)
            let count = min(buffer.count, limits[calls % limits.count])
            calls += 1
            let returned = try ordinary(offset, UnsafeMutableRawBufferPointer(rebasing: buffer[..<count]))
            expectedOffset += Int64(returned)
            return returned
        }
        let proof = try XCTUnwrap(captured.proof)
        XCTAssertEqual(expectedOffset, Int64(bytes.count))
        XCTAssertEqual(captured.digest, digest(bytes))
        XCTAssertEqual(proof.digest, captured.digest)
        XCTAssertEqual(proof.size, Int64(bytes.count))
        let range = try ByteRange(offset: 19, length: Int64(bytes.count - 30), fileSize: proof.size)
        XCTAssertEqual(try proof.verify(range: range, read: reader(bytes, maximum: 4001)),
                       digest(bytes.subdata(in: 19..<(bytes.count - 11))))
    }

    func testUnalignedRangesAndTailReadOnlyIntersectingBlocks() throws {
        let block = VerifiedRead.blockSize
        let bytes = contents(block * 3 + 31)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: reader(bytes)).proof)
        let ranges = [(block - 3, 9), (block + 7, 13), (block, block), (block * 3 + 2, 29)]
        for (offset, length) in ranges {
            let range = try ByteRange(offset: Int64(offset), length: Int64(length), fileSize: proof.size)
            var reads: [Int64] = []
            let ordinary = reader(bytes)
            let actual = try proof.verify(range: range) { offset, buffer in
                reads.append(offset)
                return try ordinary(offset, buffer)
            }
            let first = offset / block, last = (offset + length - 1) / block
            XCTAssertEqual(reads, (first...last).map { Int64($0 * block) })
            XCTAssertEqual(actual, digest(bytes.subdata(in: offset..<(offset + length))))
        }
    }

    func testChangedRequestedByteAndNeighborInSameBlockAreRejected() throws {
        let bytes = contents(VerifiedRead.blockSize + 20)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: reader(bytes)).proof)
        let range = try ByteRange(offset: 100, length: 10, fileSize: proof.size)
        for index in [100, 2, VerifiedRead.blockSize - 1] {
            var changed = bytes
            changed[index] ^= 1
            XCTAssertThrowsError(try proof.verify(range: range, read: reader(changed))) {
                XCTAssertEqual($0 as? TransferError, .checksumMismatch)
            }
        }
    }

    func testChangeOutsideCoveredBlocksIsRejectedWhenLaterRead() throws {
        let block = VerifiedRead.blockSize
        let bytes = contents(block * 2 + 20)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: reader(bytes)).proof)
        var changed = bytes
        changed[block * 2 + 1] ^= 1
        let first = try ByteRange(offset: 17, length: 19, fileSize: proof.size)
        XCTAssertEqual(try proof.verify(range: first, read: reader(changed)), digest(bytes.subdata(in: 17..<36)))
        let later = try ByteRange(offset: Int64(block * 2), length: 20, fileSize: proof.size)
        XCTAssertThrowsError(try proof.verify(range: later, read: reader(changed))) {
            XCTAssertEqual($0 as? TransferError, .checksumMismatch)
        }
    }

    func testEmptyFileAndEmptyRangesDoNotRead() throws {
        let noReads: Reader = { _, _ in XCTFail("Empty range performed a read"); return 0 }
        let captured = try VerifiedRead.capture(size: 0, read: noReads)
        let empty = try XCTUnwrap(captured.proof)
        let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(captured.digest, emptyDigest)
        XCTAssertEqual(try empty.verify(range: ByteRange(offset: 0, length: 0, fileSize: 0), read: noReads),
                       emptyDigest)
        let bytes = Data("abc".utf8)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: 3, read: reader(bytes)).proof)
        XCTAssertEqual(proof.digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for offset: Int64 in [0, 1, 3] {
            XCTAssertEqual(try proof.verify(range: ByteRange(offset: offset, length: 0, fileSize: 3),
                                            read: noReads), emptyDigest)
        }
    }

    func testInvalidSizeAndRangesFailBeforeReading() throws {
        let noReads: Reader = { _, _ in XCTFail("Invalid bounds performed a read"); return 0 }
        XCTAssertThrowsError(try VerifiedRead.capture(size: -1, read: noReads)) {
            XCTAssertEqual($0 as? TransferError, .invalidRange)
        }
        XCTAssertThrowsError(try VerifiedRead.capture(size: .max) { _, _ in throw ReadFailure.disconnected }) {
            XCTAssertEqual($0 as? ReadFailure, .disconnected)
        }
        let proof = try XCTUnwrap(VerifiedRead.capture(size: 3, read: reader(Data("abc".utf8))).proof)
        let invalid = [
            "{\"offset\":-1,\"length\":1}",
            "{\"offset\":0,\"length\":-1}",
            "{\"offset\":4,\"length\":0}",
            "{\"offset\":3,\"length\":1}",
            "{\"offset\":9223372036854775807,\"length\":9223372036854775807}"
        ]
        for json in invalid {
            let range = try JSONDecoder().decode(ByteRange.self, from: Data(json.utf8))
            XCTAssertThrowsError(try proof.verify(range: range, read: noReads)) {
                XCTAssertEqual($0 as? TransferError, .invalidRange)
            }
        }
    }

    func testMalformedReadCountsAndPrematureEOFAreRejected() throws {
        let bytes = Data("abc".utf8)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: 3, read: reader(bytes)).proof)
        let range = try ByteRange(offset: 0, length: 3, fileSize: 3)
        for result in [0, -1, 4] {
            let bad: Reader = { _, _ in result }
            XCTAssertThrowsError(try VerifiedRead.capture(size: 3, read: bad)) {
                XCTAssertEqual($0 as? TransferError, .sourceChanged)
            }
            XCTAssertThrowsError(try proof.verify(range: range, read: bad)) {
                XCTAssertEqual($0 as? TransferError, .sourceChanged)
            }
        }
        let short = reader(Data("ab".utf8))
        XCTAssertThrowsError(try VerifiedRead.capture(size: 3, read: short)) {
            XCTAssertEqual($0 as? TransferError, .sourceChanged)
        }
        XCTAssertThrowsError(try proof.verify(range: range, read: short)) {
            XCTAssertEqual($0 as? TransferError, .sourceChanged)
        }
        let oversizedAfterShortRead: Reader = { offset, buffer in
            if offset == 0 {
                buffer[0] = bytes[0]
                return 1
            }
            return buffer.count + 1
        }
        XCTAssertThrowsError(try VerifiedRead.capture(size: 3, read: oversizedAfterShortRead)) {
            XCTAssertEqual($0 as? TransferError, .sourceChanged)
        }
        XCTAssertThrowsError(try proof.verify(range: range, read: oversizedAfterShortRead)) {
            XCTAssertEqual($0 as? TransferError, .sourceChanged)
        }
    }

    func testCancellationAndReadFailurePropagateAfterPartialProgress() throws {
        let bytes = contents(VerifiedRead.blockSize + 20)
        let ordinary = reader(bytes)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: ordinary).proof)
        let range = try ByteRange(offset: 0, length: proof.size, fileSize: proof.size)
        let failures: [Error] = [TransferError.cancelled, ReadFailure.disconnected]
        for error in failures {
            let fail: Reader = { offset, buffer in
                if offset > 0 { throw error }
                return try ordinary(offset, buffer)
            }
            for operation in [
                { _ = try VerifiedRead.capture(size: Int64(bytes.count), read: fail) },
                { _ = try proof.verify(range: range, read: fail) }
            ] {
                XCTAssertThrowsError(try operation()) {
                    if let expected = error as? TransferError {
                        XCTAssertEqual($0 as? TransferError, expected)
                    } else {
                        XCTAssertEqual($0 as? ReadFailure, .disconnected)
                    }
                }
            }
        }
    }

    func testProofBudgetAndDisabledCollectionStillHashAllContents() throws {
        let block = VerifiedRead.blockSize
        let bytes = contents(block + 1)
        let exact = bytes.prefix(block)
        let collected = try VerifiedRead.capture(size: Int64(block), maximumBytes: 32,
                                                  read: reader(Data(exact)))
        XCTAssertNotNil(collected.proof)
        XCTAssertEqual(collected.digest, digest(Data(exact)))
        let capped = try VerifiedRead.capture(size: Int64(bytes.count), maximumBytes: 32, read: reader(bytes))
        XCTAssertNil(capped.proof)
        XCTAssertEqual(capped.digest, digest(bytes))
        let disabled = try VerifiedRead.capture(size: Int64(bytes.count), collect: false, read: reader(bytes))
        XCTAssertNil(disabled.proof)
        XCTAssertEqual(disabled.digest, digest(bytes))
        let noRoom = try VerifiedRead.capture(size: 1, maximumBytes: 31, read: reader(Data([7])))
        XCTAssertNil(noRoom.proof)
        XCTAssertEqual(noRoom.digest, digest(Data([7])))
    }

    func testPersistedProofRequiresExactReceiptAndPathAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = contents(VerifiedRead.blockSize + 31)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: reader(bytes)).proof)
        let path = try XCTUnwrap(RelativePath("folder/file"))
        let version = try EditFileVersion(identity: EditFileIdentity(fileID: 17, birthMicroseconds: 23),
            size: proof.size, digest: proof.digest, modifiedMicroseconds: 31, changedMicroseconds: 37,
            attributes: 32, security: Data([1, 2, 3]))
        let receipt = try EditBaseReceipt(item: UUID().uuidString, version: version)
        try VerifiedReadCache(directory: directory).store(proof, receipt: receipt, path: path)
        let reopened = VerifiedReadCache(directory: directory)
        let restored = try XCTUnwrap(reopened.load(receipt: receipt, path: path))
        let range = try ByteRange(offset: 19, length: proof.size - 23, fileSize: proof.size)
        XCTAssertEqual(try restored.verify(range: range, read: reader(bytes)),
                       digest(bytes.subdata(in: 19..<(bytes.count - 4))))
        XCTAssertNil(reopened.load(receipt: receipt, path: RelativePath("other/file")!))
        XCTAssertNil(reopened.load(receipt: try EditBaseReceipt(item: receipt.item, version: version), path: path))
        XCTAssertNil(reopened.load(receipt: try EditBaseReceipt(id: receipt.id, item: UUID().uuidString,
                                                           version: version), path: path))
        for field in 0..<8 {
            let changed = try EditFileVersion(
                identity: EditFileIdentity(fileID: field == 0 ? 18 : 17, birthMicroseconds: field == 1 ? 24 : 23),
                size: field == 2 ? proof.size + 1 : proof.size,
                digest: field == 3 ? String(repeating: "0", count: 64) : proof.digest,
                modifiedMicroseconds: field == 4 ? 32 : 31, changedMicroseconds: field == 5 ? 38 : 37,
                attributes: field == 6 ? 33 : 32, security: field == 7 ? Data([4]) : Data([1, 2, 3]))
            XCTAssertNil(reopened.load(receipt: try EditBaseReceipt(id: receipt.id, item: receipt.item,
                                                               version: changed), path: path))
        }
    }

    func testProofCacheIsBoundedAndMalformedEvidenceFallsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("original".utf8)
        let proof = try XCTUnwrap(VerifiedRead.capture(size: Int64(bytes.count), read: reader(bytes)).proof)
        let version = try EditFileVersion(identity: EditFileIdentity(fileID: 1, birthMicroseconds: 2),
            size: proof.size, digest: proof.digest, modifiedMicroseconds: 3, changedMicroseconds: 4,
            attributes: 32, security: Data([1]))
        let receipt = try EditBaseReceipt(item: UUID().uuidString, version: version)
        let path = RelativePath("file")!, cache = VerifiedReadCache(directory: directory)
        XCTAssertNil(cache.load(receipt: receipt, path: path))
        try cache.store(proof, receipt: receipt, path: path)
        let second = try EditBaseReceipt(item: UUID().uuidString, version: version)
        try cache.store(proof, receipt: second, path: path)
        XCTAssertNil(cache.load(receipt: receipt, path: path))
        XCTAssertNotNil(cache.load(receipt: second, path: path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        let url = directory.appendingPathComponent("Proof.json")
        for bad in [Data(), Data("{".utf8), Data(repeating: 0, count: 4 * 1_048_576 + 1)] {
            try bad.write(to: url)
            XCTAssertNil(cache.load(receipt: second, path: path))
        }
        let wrong = try XCTUnwrap(VerifiedRead.capture(size: 8, read: reader(Data("modified".utf8))).proof)
        XCTAssertThrowsError(try cache.store(wrong, receipt: receipt, path: path)) {
            XCTAssertEqual($0 as? TransferError, .checksumMismatch)
        }
    }

    func testDecodedProofRejectsImpossibleSizesAndBlockTables() throws {
        let proof = try XCTUnwrap(VerifiedRead.capture(size: 3, read: reader(Data("abc".utf8))).proof)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as? [String: Any])
        let mutations: [(String, Any)] = [
            ("size", -1), ("size", Int64.max), ("size", VerifiedRead.blockSize + 1),
            ("digest", "invalid"), ("blocks", Data(count: 31).base64EncodedString()),
            ("blocks", Data(count: VerifiedRead.maxBytes + 32).base64EncodedString())
        ]
        for (key, value) in mutations {
            var changed = original
            changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(VerifiedRead.self,
                from: JSONSerialization.data(withJSONObject: changed)))
        }
    }

    private func contents(_ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8)) })
    }

    private func reader(_ bytes: Data, maximum: Int = .max) -> Reader {
        { offset, buffer in
            let start = Int(offset)
            let count = min(buffer.count, maximum, bytes.count - start)
            if count > 0 {
                bytes.withUnsafeBytes { source in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[start..<(start + count)]))
                }
            }
            return count
        }
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

final class VerifiedReadTransferTests: XCTestCase {
    private enum Failure: Error, Equatable { case staleVersion, storage }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data(repeating: 83, count: VerifiedRead.blockSize * 2 + 17)
        let progress = Progress()
        var source: URL { directory.appendingPathComponent("source") }
        var staging: URL { directory.appendingPathComponent("staging") }
        var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

        init() throws {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try bytes.write(to: source)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func transfer(checkSpace: ((Int64) throws -> Void)? = nil) throws -> VerifiedReadTransfer {
            try VerifiedReadTransfer(source: ReadOnlyFile(url: source),
                range: ByteRange(offset: 0, length: Int64(bytes.count), fileSize: Int64(bytes.count)),
                stagingDirectory: staging, progress: progress, checkSpace: checkSpace)
        }

        func stagedCount() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: staging.path).count }
    }

    func testNativeTransferAndVerificationOverlapBeforeHandoff() throws {
        let fixture = try Fixture(), entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var first = true
        let transfer = try fixture.transfer { _ in
            if first {
                first = false
                entered.signal()
                guard released.wait(timeout: .now() + 5) == .success else { throw Failure.storage }
            }
        }
        let output = try transfer.run(verify: {
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            released.signal()
            return fixture.digest
        })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output.stagingURL)), fixture.bytes)
        XCTAssertEqual(output.metrics.bytes, Int64(fixture.bytes.count))
    }

    func testStaleVersionCancelsAndJoinsNativeWorkerBeforeReturning() throws {
        let fixture = try Fixture(), entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var first = true
        let transfer = try fixture.transfer { _ in
            if first {
                first = false
                entered.signal()
                guard released.wait(timeout: .now() + 5) == .success else { throw Failure.storage }
            }
        }
        XCTAssertThrowsError(try transfer.run(verify: {
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            released.signal()
            throw Failure.staleVersion
        })) { XCTAssertEqual($0 as? Failure, .staleVersion) }
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testNativeFailureCancelsVerificationAndPreservesFailure() throws {
        let fixture = try Fixture(), cancelled = DispatchSemaphore(value: 0)
        let transfer = try fixture.transfer { _ in throw Failure.storage }
        let observer = transfer.verificationProgress.observe(\.isCancelled) { value, _ in
            if value.isCancelled { cancelled.signal() }
        }
        defer { observer.invalidate() }
        XCTAssertThrowsError(try transfer.run(verify: {
            XCTAssertEqual(cancelled.wait(timeout: .now() + 5), .success)
            throw TransferError.cancelled
        })) { XCTAssertEqual($0 as? Failure, .storage) }
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testWrongNativeBytesNeverReachHandoff() throws {
        let fixture = try Fixture()
        let transfer = try fixture.transfer()
        XCTAssertThrowsError(try transfer.run(verify: { String(repeating: "0", count: 64) })) {
            XCTAssertEqual($0 as? TransferError, .checksumMismatch)
        }
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testReplacementBetweenVerificationAndReadRejectsChangedIdentity() throws {
        let fixture = try Fixture(), entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var first = true
        let transfer = try fixture.transfer { _ in
            if first {
                first = false
                entered.signal()
                guard released.wait(timeout: .now() + 5) == .success else { throw Failure.storage }
            }
        }
        XCTAssertThrowsError(try transfer.run(verify: {
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            defer { released.signal() }
            try FileManager.default.moveItem(at: fixture.source,
                                            to: fixture.directory.appendingPathComponent("held"))
            try Data(repeating: 99, count: fixture.bytes.count).write(to: fixture.source)
            return fixture.digest
        })) { XCTAssertEqual($0 as? TransferError, .sourceChanged) }
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testCancellationBeforeStartAndDuringVerificationCleansStaging() throws {
        for beforeStart in [true, false] {
            let fixture = try Fixture(), transfer = try fixture.transfer()
            if beforeStart { fixture.progress.cancel() }
            XCTAssertThrowsError(try transfer.run(verify: {
                XCTAssertFalse(beforeStart)
                fixture.progress.cancel()
                XCTAssertTrue(transfer.verificationProgress.isCancelled)
                throw TransferError.cancelled
            })) { XCTAssertEqual($0 as? TransferError, .cancelled) }
            XCTAssertEqual(try fixture.stagedCount(), 0)
        }
    }

    func testCancellationDuringChecksumRemovesCompletedStage() throws {
        let fixture = try Fixture(), transfer = try fixture.transfer()
        XCTAssertThrowsError(try transfer.run(verify: { fixture.digest }, willChecksum: { _ in
            fixture.progress.cancel()
        })) { XCTAssertEqual($0 as? TransferError, .cancelled) }
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testCompletedTransferCannotReuseItsHandleForAnotherRequest() throws {
        let fixture = try Fixture(), transfer = try fixture.transfer()
        _ = try transfer.run(verify: { fixture.digest })
        XCTAssertThrowsError(try transfer.run(verify: { XCTFail("Reused verification"); return fixture.digest })) {
            XCTAssertEqual($0 as? TransferError, .invalidRange)
        }
        XCTAssertEqual(try fixture.stagedCount(), 1)
    }

    func testIndependentConcurrentRequestsKeepTheirOwnResultsAndCancellation() throws {
        let first = try Fixture(), second = try Fixture()
        let one = try first.transfer(), two = try second.transfer()
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let done = expectation(description: "first request joined")
        DispatchQueue.global().async {
            do {
                _ = try one.run(verify: {
                    entered.signal()
                    XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
                    throw TransferError.cancelled
                })
                XCTFail("Cancelled request succeeded")
            } catch { XCTAssertEqual(error as? TransferError, .cancelled) }
            done.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        first.progress.cancel()
        let output = try two.run(verify: { second.digest })
        released.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try first.stagedCount(), 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output.stagingURL)), second.bytes)
    }
}
