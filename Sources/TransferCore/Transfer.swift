import CryptoKit
import Darwin
import Foundation

func posixError(_ operation: String, code: Int32 = errno) -> NSError {
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
        NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"
    ])
}

public struct FileSnapshot: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixError("fstat") }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw TransferError.notRegularFile
        }
        device = UInt64(UInt32(bitPattern: value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }

    /// A metadata fingerprint for immutable fixtures, not a server revision guarantee.
    public var versionData: Data {
        Data("\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)".utf8)
    }

    public var fingerprint: ContentFingerprint {
        ContentFingerprint(
            size: size,
            mtimeNs: ContentFingerprint.nanoseconds(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds),
            ctimeNs: ContentFingerprint.nanoseconds(seconds: changedSeconds, nanoseconds: changedNanoseconds))
    }
}

/// The fields of a published content version: unlike `FileSnapshot`, no device or inode.
public struct ContentFingerprint: Hashable, Sendable {
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64

    public init(size: Int64, mtimeNs: Int64, ctimeNs: Int64) {
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
    }

    public init(smbSize: Int64, modifiedMicroseconds: UInt64, changedMicroseconds: UInt64) throws {
        guard smbSize >= 0, modifiedMicroseconds <= UInt64(Int64.max / 1_000),
              changedMicroseconds <= UInt64(Int64.max / 1_000) else { throw TransferError.sourceChanged }
        self.init(size: smbSize, mtimeNs: Int64(modifiedMicroseconds) * 1_000,
                  ctimeNs: Int64(changedMicroseconds) * 1_000)
    }

    /// A save time to set on the server, to the nearest microsecond since 1970. libsmb2 reads and
    /// writes SMB times as microseconds, so this value comes back unchanged in every version.
    /// Nil before 1970 or after the year 5000, where the server keeps its own time.
    public static func smbMicroseconds(_ date: Date) -> UInt64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds > 0, seconds < 95_617_584_000 else { return nil }
        // The fraction alone scales without the rounding error that seconds * 1e6 adds.
        let whole = seconds.rounded(.down)
        return UInt64(whole) * 1_000_000 + UInt64(((seconds - whole) * 1_000_000).rounded())
    }

    /// At most 65 UTF-8 bytes, within File Provider's 128-byte version limit.
    public var contentVersion: String { "f1:\(size):\(mtimeNs):\(ctimeNs)" }

    /// Nanoseconds since 1970, clamped to Int64.
    public static func nanoseconds(seconds: Int64, nanoseconds: Int64) -> Int64 {
        // APFS's earliest time is Int64.min nanoseconds, yet its seconds * 10^9 overflows Int64.
        Int64(clamping: Int128(seconds) * 1_000_000_000 + Int128(nanoseconds))
    }
}

public struct FileSystemInfo: Codable, Sendable {
    public let type: String
    public let isLocal: Bool

    public init(fd: Int32) throws {
        var value = statfs()
        guard fstatfs(fd, &value) == 0 else { throw posixError("fstatfs") }
        type = withUnsafePointer(to: &value.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        isLocal = value.f_flags & UInt32(MNT_LOCAL) != 0
    }
}

public final class ReadOnlyFile {
    public let descriptor: Int32
    public let snapshot: FileSnapshot
    public let filesystem: FileSystemInfo
    public let ignoresMaterializationChangeTime: Bool

    public convenience init(url: URL, noCache: Bool = false, allowMaterialization: Bool = false) throws {
        // O_NONBLOCK prevents an accidental FIFO from blocking before the regular-file check.
        let fd = url.withUnsafeFileSystemRepresentation {
            Darwin.open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { throw posixError("open source read-only") }
        try self.init(descriptor: fd, noCache: noCache, allowMaterialization: allowMaterialization)
    }

    /// Takes ownership of `fd` and closes it if a check fails.
    private init(descriptor fd: Int32, noCache: Bool, allowMaterialization: Bool) throws {
        do {
            snapshot = try FileSnapshot(fd: fd)
            filesystem = try FileSystemInfo(fd: fd)
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { throw posixError("fstat flags") }
            ignoresMaterializationChangeTime = allowMaterialization && filesystem.isLocal
                && metadata.st_flags & UInt32(SF_DATALESS) != 0
            if noCache, fcntl(fd, F_NOCACHE, 1) == -1 { throw posixError("F_NOCACHE") }
        } catch { Darwin.close(fd); throw error }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    /// The open file as it is now, which can differ from `snapshot`.
    public func currentSnapshot() throws -> FileSnapshot { try FileSnapshot(fd: descriptor) }

    public func validateUnchanged() throws {
        let current = try currentSnapshot()
        // Hydrating a local dataless file changes ctime without changing its content version.
        if ignoresMaterializationChangeTime {
            guard current.device == snapshot.device, current.inode == snapshot.inode,
                  current.size == snapshot.size, current.modifiedSeconds == snapshot.modifiedSeconds,
                  current.modifiedNanoseconds == snapshot.modifiedNanoseconds else {
                throw TransferError.sourceChanged
            }
        } else if current != snapshot { throw TransferError.sourceChanged }
    }

    public func checksum(range: ByteRange, progress: Progress? = nil) throws -> String {
        _ = try ByteRange(offset: range.offset, length: range.length, fileSize: snapshot.size)
        let capacity = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 4096)
        defer { buffer.deallocate() }
        var hash = SHA256()
        var offset = range.offset
        while offset < range.end {
            if progress?.isCancelled == true { throw TransferError.cancelled }
            let n = pread(descriptor, buffer, min(capacity, Int(range.end - offset)), offset)
            if n < 0 { if errno == EINTR { continue }; throw posixError("checksum read") }
            guard n > 0 else { throw TransferError.sourceChanged }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            offset += Int64(n)
            progress?.completedUnitCount += Int64(n)
        }
        if progress?.isCancelled == true { throw TransferError.cancelled }
        try validateUnchanged()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct TransferMetrics: Codable, Sendable {
    public let bytes: Int64
    public let readCalls: Int
    public let firstReadSeconds: Double?
    public let transferSeconds: Double
    public let steadyStateMBps: Double?
    public let syncSeconds: Double
    public let processCPUSeconds: Double
    public let processLifetimePeakRSSBytes: Int64
    public var megabytesPerSecond: Double? {
        transferSeconds > 0 && bytes > 0 ? Double(bytes) / transferSeconds / 1_000_000 : nil
    }
}

public struct TransferOutput {
    /// Caller owns this file until handing it to File Provider. Remove it after a standalone benchmark.
    public let stagingURL: URL?
    public let metrics: TransferMetrics
}

public enum Transfer {
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000_000
    }

    public static func run(source: ReadOnlyFile, range: ByteRange, blockSize: Int = 1024 * 1024,
                           stagingDirectory: URL? = nil, syncStaging: Bool = false,
                           progress: Progress = Progress(),
                           checkSpace: ((Int64) throws -> Void)? = nil) throws -> TransferOutput {
        try run(size: source.snapshot.size, range: range, blockSize: blockSize,
                stagingDirectory: stagingDirectory, syncStaging: syncStaging, progress: progress,
                checkSpace: checkSpace, validate: source.validateUnchanged) { offset, buffer in
            var count: Int
            repeat { count = pread(source.descriptor, buffer.baseAddress!, buffer.count, offset) }
            while count < 0 && errno == EINTR
            guard count >= 0 else { throw posixError("pread") }
            return count
        }
    }

    public static func run(size: Int64, range: ByteRange, blockSize: Int = 1024 * 1024,
                           stagingDirectory: URL? = nil, syncStaging: Bool = false,
                           progress: Progress = Progress(), checkSpace: ((Int64) throws -> Void)? = nil,
                           validate: () throws -> Void,
                           read: (Int64, UnsafeMutableRawBufferPointer) throws -> Int) throws -> TransferOutput {
        _ = try ByteRange(offset: range.offset, length: range.length, fileSize: size)
        guard (4096...16 * 1024 * 1024).contains(blockSize) else { throw TransferError.invalidBlockSize }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        try validate()
        try checkSpace?(0)
        let begin = DispatchTime.now().uptimeNanoseconds
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        var outputFD: Int32 = -1
        var outputURL: URL?
        var keepOutput = false
        defer {
            if outputFD >= 0 { Darwin.close(outputFD) }
            if !keepOutput, let url = outputURL { try? FileManager.default.removeItem(at: url) }
        }
        if let directory = stagingDirectory {
            let directoryFD = directory.withUnsafeFileSystemRepresentation {
                Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            guard directoryFD >= 0 else { throw posixError("open staging directory") }
            defer { Darwin.close(directoryFD) }
            guard try FileSystemInfo(fd: directoryFD).isLocal else { throw TransferError.stagingMustBeLocal }
            // Atomic exclusive creation; never truncate an existing file, even on name collision.
            let name = Staging.stageFileName(UUID())
            outputFD = name.withCString { openat(directoryFD, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
            guard outputFD >= 0 else { throw posixError("create staging file") }
            outputURL = directory.appendingPathComponent(name)
            // File Provider requires data at the original file offsets. Earlier bytes can be sparse.
            guard ftruncate(outputFD, range.end) == 0 else { throw posixError("size staging file") }
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 4096)
        defer { buffer.deallocate() }
        progress.totalUnitCount = range.length
        progress.completedUnitCount = 0
        var offset = range.offset
        var calls = 0
        var firstReadTime: UInt64?
        var firstChunkDone: UInt64?
        var firstChunkBytes: Int64 = 0
        while offset < range.end {
            guard !progress.isCancelled else { throw TransferError.cancelled }
            try checkSpace?(offset - range.offset)
            let capacity = min(blockSize, Int(range.end - offset))
            let n = try read(offset, UnsafeMutableRawBufferPointer(start: buffer, count: capacity))
            guard n > 0, n <= capacity else { throw TransferError.sourceChanged }
            calls += 1
            if firstReadTime == nil { firstReadTime = DispatchTime.now().uptimeNanoseconds }
            if outputFD >= 0 {
                var written = 0
                while written < n {
                    guard !progress.isCancelled else { throw TransferError.cancelled }
                    let result = pwrite(outputFD, buffer.advanced(by: written), n - written, offset + Int64(written))
                    if result < 0 { if errno == EINTR { continue }; throw posixError("pwrite") }
                    guard result > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                    written += result
                }
            }
            offset += Int64(n)
            progress.completedUnitCount = offset - range.offset
            if firstChunkDone == nil {
                firstChunkDone = DispatchTime.now().uptimeNanoseconds
                firstChunkBytes = Int64(n)
            }
        }
        let payloadEnd = DispatchTime.now().uptimeNanoseconds
        var syncSeconds = 0.0
        if syncStaging, outputFD >= 0 {
            let start = DispatchTime.now().uptimeNanoseconds
            guard fsync(outputFD) == 0 else { throw posixError("fsync") }
            syncSeconds = seconds(start, DispatchTime.now().uptimeNanoseconds)
        }
        guard !progress.isCancelled else { throw TransferError.cancelled }
        try validate()
        if outputFD >= 0 {
            let fd = outputFD
            outputFD = -1 // close must not be retried: the descriptor may have been reused.
            guard Darwin.close(fd) == 0 else { throw posixError("close staging") }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        getrusage(RUSAGE_SELF, &after)
        func cpu(_ r: rusage) -> Double {
            Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
        }
        let steady: Double?
        if let first = firstChunkDone, payloadEnd > first, range.length > firstChunkBytes {
            steady = Double(range.length - firstChunkBytes) / seconds(first, payloadEnd) / 1_000_000
        } else { steady = nil }
        let metrics = TransferMetrics(bytes: range.length, readCalls: calls,
            firstReadSeconds: firstReadTime.map { seconds(begin, $0) },
            transferSeconds: seconds(begin, end), steadyStateMBps: steady,
            syncSeconds: syncSeconds, processCPUSeconds: cpu(after) - cpu(before),
            processLifetimePeakRSSBytes: Int64(after.ru_maxrss))
        keepOutput = true
        return TransferOutput(stagingURL: outputURL, metrics: metrics)
    }
}
