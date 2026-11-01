import CryptoKit
import Foundation

public struct VerifiedRead: Sendable {
    public static let blockSize = 1_048_576
    public static let maxBytes = 2_097_152

    public let size: Int64
    public let digest: String
    private let blocks: Data

    public static func capture(size: Int64, collect: Bool = true,
                               read: (Int64, UnsafeMutableRawBufferPointer) throws -> Int)
        throws -> (digest: String, proof: VerifiedRead?) {
        try capture(size: size, collect: collect, maximumBytes: maxBytes, read: read)
    }

    static func capture(size: Int64, collect: Bool = true, maximumBytes: Int,
                        read: (Int64, UnsafeMutableRawBufferPointer) throws -> Int)
        throws -> (digest: String, proof: VerifiedRead?) {
        guard size >= 0, maximumBytes >= 0 else { throw TransferError.invalidRange }
        let count = size / Int64(blockSize) + (size % Int64(blockSize) == 0 ? 0 : 1)
        let collecting = collect && count <= Int64(min(maximumBytes, maxBytes) / SHA256.Digest.byteCount)
        var blocks = Data(), hash = SHA256(), offset: Int64 = 0
        if collecting { blocks.reserveCapacity(Int(count) * SHA256.Digest.byteCount) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: blockSize, alignment: 8)
        defer { buffer.deallocate() }
        while offset < size {
            let length = Int(min(Int64(blockSize), size - offset))
            try fill(buffer, length: length, offset: offset, read: read)
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<length])
            hash.update(bufferPointer: bytes)
            if collecting { blocks.append(contentsOf: checksum(bytes)) }
            offset += Int64(length)
        }
        let digest = hex(hash.finalize())
        return (digest, collecting ? VerifiedRead(size: size, digest: digest, blocks: blocks) : nil)
    }

    public func verify(range: ByteRange, read: (Int64, UnsafeMutableRawBufferPointer) throws -> Int)
        throws -> String {
        _ = try ByteRange(offset: range.offset, length: range.length, fileSize: size)
        var hash = SHA256()
        if range.length == 0 { return Self.hex(hash.finalize()) }
        let first = range.offset / Int64(Self.blockSize)
        let last = (range.end - 1) / Int64(Self.blockSize)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.blockSize, alignment: 8)
        defer { buffer.deallocate() }
        for block in first...last {
            let offset = block * Int64(Self.blockSize)
            let length = Int(min(Int64(Self.blockSize), size - offset))
            try Self.fill(buffer, length: length, offset: offset, read: read)
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[..<length])
            let start = Int(block) * SHA256.Digest.byteCount
            guard blocks[start..<(start + SHA256.Digest.byteCount)].elementsEqual(Self.checksum(bytes)) else {
                throw TransferError.checksumMismatch
            }
            let lower = Int(max(range.offset, offset) - offset)
            let upper = Int(min(range.end, offset + Int64(length)) - offset)
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[lower..<upper]))
        }
        return Self.hex(hash.finalize())
    }

    private static func fill(_ buffer: UnsafeMutableRawBufferPointer, length: Int, offset: Int64,
                             read: (Int64, UnsafeMutableRawBufferPointer) throws -> Int) throws {
        var done = 0
        while done < length {
            let destination = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<length])
            let count = try read(offset + Int64(done), destination)
            guard count > 0, count <= destination.count else { throw TransferError.sourceChanged }
            done += count
        }
    }

    private static func checksum(_ bytes: UnsafeRawBufferPointer) -> SHA256.Digest {
        var hash = SHA256()
        hash.update(bufferPointer: bytes)
        return hash.finalize()
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
