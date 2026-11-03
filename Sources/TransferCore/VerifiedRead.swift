import CryptoKit
import Darwin
import Foundation

public struct VerifiedRead: Codable, Sendable {
    public static let blockSize = 1_048_576
    public static let maxBytes = 2_097_152

    public let size: Int64
    public let digest: String
    private let blocks: Data

    private init(size: Int64, digest: String, blocks: Data) {
        self.size = size
        self.digest = digest
        self.blocks = blocks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let size = try values.decode(Int64.self, forKey: .size)
        let digest = try values.decode(String.self, forKey: .digest)
        let blocks = try values.decode(Data.self, forKey: .blocks)
        guard size >= 0, EditFileVersion.validDigest(digest), blocks.count <= Self.maxBytes,
              size / Int64(Self.blockSize) + (size % Int64(Self.blockSize) == 0 ? 0 : 1)
                == Int64(blocks.count / SHA256.Digest.byteCount),
              blocks.count % SHA256.Digest.byteCount == 0 else { throw TransferError.invalidRange }
        self.init(size: size, digest: digest, blocks: blocks)
    }

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

public struct VerifiedReadCache: Sendable {
    private struct Entry: Codable {
        let receipt: EditBaseReceipt
        let path: String
        let proof: VerifiedRead
    }

    private static let encodedLimit = 4 * 1_048_576
    private let directory: URL
    private var url: URL { directory.appendingPathComponent("Proof.json") }

    public init(directory: URL) { self.directory = directory }

    public func load(receipt: EditBaseReceipt, path: RelativePath) -> VerifiedRead? {
        do {
            let file = try ReadOnlyFile(url: url)
            guard file.filesystem.isLocal, file.snapshot.size <= Self.encodedLimit else { return nil }
            var bytes = Data(count: Int(file.snapshot.size))
            try bytes.withUnsafeMutableBytes { buffer in
                var done = 0
                while done < buffer.count {
                    let count = pread(file.descriptor, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(done))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw TransferError.sourceChanged }
                    done += count
                }
            }
            try file.validateUnchanged()
            let entry = try JSONDecoder().decode(Entry.self, from: bytes)
            guard entry.receipt == receipt, entry.path.utf8.elementsEqual(path.string.utf8),
                  entry.proof.size == receipt.version.size, entry.proof.digest == receipt.version.digest else { return nil }
            return entry.proof
        } catch { return nil }
    }

    public func store(_ proof: VerifiedRead, receipt: EditBaseReceipt, path: RelativePath) throws {
        guard proof.size == receipt.version.size, proof.digest == receipt.version.digest else {
            throw TransferError.checksumMismatch
        }
        let bytes = try JSONEncoder().encode(Entry(receipt: receipt, path: path.string, proof: proof))
        guard bytes.count <= Self.encodedLimit else { throw TransferError.invalidRange }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try bytes.write(to: url, options: .atomic)
    }

    public func remove() throws { try FileManager.default.removeItem(at: directory) }
}

/// Joins the native worker before its caller can release server protection or publish staging.
public final class VerifiedReadTransfer: @unchecked Sendable {
    private let source: ReadOnlyFile
    private let range: ByteRange
    private let stagingDirectory: URL
    private let checkSpace: ((Int64) throws -> Void)?
    private let progress: Progress
    public let verificationProgress: Progress
    private let nativeProgress = Progress()
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var result: Result<TransferOutput, Error>?
    private var started = false
    private var nativeCompleted: Int64 = 0
    private var verificationCompleted: Int64 = 0

    public init(source: ReadOnlyFile, range: ByteRange, stagingDirectory: URL, progress: Progress,
                verificationProgress: Progress = Progress(),
                checkSpace: ((Int64) throws -> Void)? = nil) {
        self.source = source
        self.range = range
        self.stagingDirectory = stagingDirectory
        self.progress = progress
        self.verificationProgress = verificationProgress
        self.checkSpace = checkSpace
    }

    public func run(verify: () throws -> String, willChecksum: (TransferMetrics) -> Void = { _ in })
        throws -> TransferOutput {
        guard verificationProgress !== progress else { throw TransferError.invalidRange }
        let admitted = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard admitted else {
            throw TransferError.invalidRange
        }
        let cancellation = progress.observe(\.isCancelled, options: [.initial]) { [self] value, _ in
            if value.isCancelled { nativeProgress.cancel(); verificationProgress.cancel() }
        }
        let nativeObservation = nativeProgress.observe(\.completedUnitCount, options: [.initial, .new]) { [self] _, change in
            if let completed = change.newValue { reportProgress(completed, native: true) }
        }
        let verificationObservation = verificationProgress.observe(\.completedUnitCount, options: [.initial, .new]) { [self] _, change in
            if let completed = change.newValue { reportProgress(completed, native: false) }
        }
        defer { cancellation.invalidate(); nativeObservation.invalidate(); verificationObservation.invalidate() }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = Result {
                try Transfer.run(source: source, range: range, stagingDirectory: stagingDirectory,
                                 progress: nativeProgress, checkSpace: checkSpace)
            }
            lock.withLock { result = outcome }
            if case .failure = outcome { verificationProgress.cancel() }
            finished.leave()
        }
        let verification = Result { try verify() }
        if case .failure = verification { nativeProgress.cancel() }
        finished.wait()
        nativeObservation.invalidate()
        verificationObservation.invalidate()
        let outcome = lock.withLock { result! }
        do {
            guard !progress.isCancelled else { throw TransferError.cancelled }
            let output = try outcome.get()
            let expected = try verification.get()
            willChecksum(output.metrics)
            guard let url = output.stagingURL else { throw TransferError.checksumMismatch }
            let staged = try ReadOnlyFile(url: url)
            guard try staged.checksum(range: range, progress: progress) == expected else {
                throw TransferError.checksumMismatch
            }
            return output
        } catch {
            if case .success(let output) = outcome, let url = output.stagingURL {
                try? FileManager.default.removeItem(at: url)
            }
            // A verification failure cancels native I/O; retain the cause rather than that cancellation.
            // A version change wins over any native error, so the caller refreshes the item.
            if !progress.isCancelled, case .failure(let reason) = verification {
                switch outcome {
                case .success: throw reason
                case .failure(let nativeError) where nativeError as? TransferError == .cancelled: throw reason
                case .failure where reason as? SourceFailure == .versionChanged: throw reason
                default: break
                }
            }
            throw error
        }
    }

    private func reportProgress(_ completed: Int64, native: Bool) {
        let total = lock.withLock {
            if native { nativeCompleted = max(nativeCompleted, completed) }
            else { verificationCompleted = max(verificationCompleted, completed) }
            return nativeCompleted + verificationCompleted
        }
        progress.completedUnitCount = total
    }
}
