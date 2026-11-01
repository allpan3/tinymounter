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
