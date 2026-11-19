import Darwin
import Foundation
import OSLog

public final class DownloadSpace: @unchecked Sendable {
    public static let defaultReserveGB = 20
    public static let bytesPerGB: Int64 = 1_000_000_000

    public static func reserveBytes(gigabytes: Int) -> Int64? {
        guard gigabytes > 0 else { return nil }
        let (bytes, overflow) = Int64(gigabytes).multipliedReportingOverflow(by: bytesPerGB)
        return overflow ? nil : bytes
    }

    public static let recoveryBytes: Int64 = 64 << 20
    private struct Entry {
        let length: Int64
        var completed: Int64 = 0
        var checked: Int64 = 0
        var remaining: Int128 { Int128(length) * 2 + 65536 - Int128(completed) }
    }

    private let lock = NSLock()
    private let capacity: @Sendable () throws -> Int64
    private let reserve: @Sendable () -> Int64
    private let checkStride: Int64
    private var entries: [UUID: Entry] = [:]
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "storage")

    public init(reserve: @escaping @Sendable () -> Int64 = { Int64(defaultReserveGB) * bytesPerGB },
                checkStride: Int64 = 16 << 20,
                capacity: @escaping @Sendable () throws -> Int64) {
        precondition(checkStride > 0)
        self.reserve = reserve
        self.checkStride = checkStride
        self.capacity = capacity
    }

    public static func available(at directory: URL) throws -> Int64 {
        var directory = directory
        directory.removeAllCachedResourceValues()
        guard let bytes = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity else { throw CocoaError(.fileReadUnknown) }
        return max(0, Int64(bytes))
    }

    public static func isFull(_ error: Error) -> Bool {
        let domain: String, code: Int
        if let failure = error as? SourceFailure, case let .unknown(value, number) = failure {
            domain = value
            code = number
        } else {
            let error = error as NSError
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying !== error, isFull(underlying) { return true }
            domain = error.domain
            code = error.code
        }
        return domain == NSCocoaErrorDomain && code == CocoaError.fileWriteOutOfSpace.rawValue
            || domain == NSPOSIXErrorDomain && [Int(ENOSPC), Int(EDQUOT)].contains(code)
    }

    public func begin(_ id: UUID, bytes: Int64) throws {
        try lock.withLock {
            guard bytes >= 0, entries[id] == nil else { throw CocoaError(.fileReadCorruptFile) }
            guard try fits(Entry(length: bytes).remaining) else { throw CocoaError(.fileWriteOutOfSpace) }
            entries[id] = Entry(length: bytes)
        }
    }

    public func check(_ id: UUID, completedBytes: Int64) throws {
        try lock.withLock {
            guard var entry = entries[id] else { throw TransferError.cancelled }
            entry.completed = max(entry.completed, min(entry.length, max(0, completedBytes)))
            entries[id] = entry
            // Queueing and a final short block can cross the reserve between stride checks.
            guard completedBytes == 0 || entry.completed == entry.length
                || entry.completed - entry.checked >= checkStride else { return }
            entry.checked = entry.completed
            entries[id] = entry
            guard try fits(0) else { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    public func end(_ id: UUID) { lock.withLock { _ = entries.removeValue(forKey: id) } }

    public func canRetry(bytes: Int64) throws -> Bool {
        try lock.withLock {
            guard bytes >= 0 else { return false }
            return try fits(Entry(length: bytes).remaining + Int128(Self.recoveryBytes), recovery: true)
        }
    }

    private func fits(_ additional: Int128, recovery: Bool = false) throws -> Bool {
        let pending = entries.values.reduce(Int128(0)) { $0 + $1.remaining }
        let available = try capacity()
        let reserve = reserve()
        precondition(reserve >= 0)
        let fits = Int128(available) >= Int128(reserve) + pending + additional
        if recovery || !fits {
            Self.logger.info("local_space available_bytes=\(available) reserve_bytes=\(reserve) pending_bytes=\(Int64(clamping: pending)) requested_bytes=\(Int64(clamping: additional)) recovery=\(recovery) fits=\(fits)")
        }
        return fits
    }
}

public enum DownloadRecovery {
    public typealias Requests = [String: [String: SourceReadRequest]]
    public static let fileName = "BlockedDownloads.json"

    public static func load(from url: URL) throws -> Requests {
        do {
            let requests = try JSONDecoder().decode(Requests.self, from: Data(contentsOf: url))
            try validate(requests)
            return requests
        } catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    public static func save(_ requests: Requests, to url: URL) throws {
        try validate(requests)
        try JSONEncoder().encode(requests.filter { !$0.value.isEmpty }).write(to: url, options: .atomic)
    }

    private static func validate(_ requests: Requests) throws {
        for (domain, items) in requests {
            guard UUID(uuidString: domain)?.uuidString == domain else { throw CocoaError(.fileReadCorruptFile) }
            for (id, request) in items {
                let range = request.range
                guard id == request.item, ReaderMessage.isItemID(id), range.offset >= 0, range.length >= 0,
                      range.offset <= Int64.max - range.length else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}
