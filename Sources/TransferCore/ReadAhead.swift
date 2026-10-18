import Foundation

/// Plans bounded sequential read-ahead from observed demand misses only.
///
/// Speculation begins when a demand miss continues the current run and never passes the limit set
/// by that miss, so speculative completions cannot extend themselves. The window grows with the
/// bytes the run has already consumed, from one chunk up to `window`, so a short read cannot
/// trigger a large download. A non-sequential miss starts a new generation; older requests become
/// stale. Ranges already handed to the system are not requested or returned again, until a later
/// miss in them shows that macOS removed them.
public struct ReadAheadPlanner: Sendable {
    /// Merged delivered ranges kept per item; a strided reader leaves one per miss.
    static let deliveredCapacity = 64
    /// A miss in bytes delivered this long ago, with no newer bytes, means macOS evicted them.
    public static let deliveredLifetime: Duration = .seconds(10)

    public enum Kind: Equatable, Sendable {
        case demand(sequential: Bool)
        case speculative(current: Bool)
    }

    public let fileSize: Int64
    public let chunk: Int64
    public let window: Int64
    public let maxInFlight: Int
    private var runStart: Int64 = 0
    private var demandEnd: Int64 = -1
    private var next: Int64 = 0
    private var limit: Int64 = 0
    private var generation = 0
    private var pending: [Int64: (length: Int64, generation: Int)] = [:]
    private var satisfied: [Int64: Int64] = [:]
    private var running: Set<Int64> = []
    private var delivered: [ByteRange] = [] // sorted, disjoint
    private var newestBytes: ContinuousClock.Instant?

    public init(fileSize: Int64, chunk: Int64, window: Int64, maxInFlight: Int) {
        precondition(fileSize >= 0 && chunk > 0 && window >= 0 && maxInFlight >= 0)
        self.fileSize = fileSize
        self.chunk = chunk
        self.window = window
        self.maxInFlight = maxInFlight
    }

    /// A reader's own miss can start at a planned offset; only a fetch covering the plan is ours.
    public mutating func classify(offset: Int64, length: Int64, now: ContinuousClock.Instant = .now) -> Kind {
        if let request = pending[offset], length >= request.length {
            pending.removeValue(forKey: offset)
            if request.generation == generation { running.insert(offset) }
            return .speculative(current: request.generation == generation)
        }
        if let covered = satisfied[offset], length >= covered {
            satisfied.removeValue(forKey: offset)
            return .speculative(current: false)
        }
        if let newestBytes, now - newestBytes >= Self.deliveredLifetime,
           delivered.contains(where: { $0.offset <= offset && offset < $0.end }) {
            restart()
        }
        // Players such as IINA re-read up to a chunk before the previous end; that's still sequential.
        let sequential = demandEnd >= 0 && offset >= demandEnd - chunk && offset <= next
        if !sequential {
            runStart = offset
            generation += 1
            running.removeAll()
            limit = next
        }
        return .demand(sequential: sequential)
    }

    /// Where a range that must cover up to `end` should stop extending: the next delivered byte.
    public func deliveredStart(after end: Int64) -> Int64? {
        delivered.first { $0.end > end }.map { max($0.offset, end) }
    }

    /// Returns the ranges to request after a demand range has been handed to the system.
    public mutating func demandCompleted(_ range: ByteRange, sequential: Bool,
                                         now: ContinuousClock.Instant = .now) -> [ByteRange] {
        record(range, at: now)
        demandEnd = range.end
        if !sequential { runStart = range.offset }
        next = sequential ? max(next, range.end) : range.end
        // An overtaken request may never arrive; waiting for it would stop read-ahead.
        var overtaken = false
        for (offset, request) in pending where offset >= range.offset && offset < range.end {
            pending.removeValue(forKey: offset)
            satisfied[offset] = request.length
            overtaken = overtaken || offset + request.length > range.end
        }
        if overtaken && running.isEmpty { next = range.end }
        let grown = min(window, max(chunk, range.end - runStart))
        limit = sequential ? min(fileSize, range.end + grown) : range.end
        return plan()
    }

    /// Returns further ranges, still bounded by the limit set at the last sequential demand miss.
    public mutating func speculativeFinished(_ range: ByteRange, now: ContinuousClock.Instant = .now) -> [ByteRange] {
        guard running.remove(range.offset) != nil else { return [] }
        record(range, at: now)
        return plan()
    }

    // A full handoff ends speculation without suppressing reads after a later eviction.
    public mutating func fullCompleted() { restart() }

    private mutating func restart() {
        for (offset, request) in pending { satisfied[offset] = request.length }
        pending.removeAll()
        running.removeAll()
        delivered.removeAll()
        newestBytes = nil
        generation += 1
        runStart = 0
        demandEnd = -1
        next = 0
        limit = 0
    }

    /// Ends the current run after a failed speculative fetch instead of retrying blindly.
    public mutating func speculativeFailed(offset: Int64) {
        if running.remove(offset) != nil { limit = next }
    }

    /// Call when the system refuses to schedule a requested range.
    public mutating func requestFailed(_ range: ByteRange) {
        if pending[range.offset]?.generation == generation { pending.removeValue(forKey: range.offset) }
    }

    private mutating func plan() -> [ByteRange] {
        var ranges: [ByteRange] = []
        var inFlight = running.count + pending.values.filter { $0.generation == generation }.count
        while inFlight < maxInFlight, next < limit {
            if let covering = delivered.first(where: { $0.offset <= next && next < $0.end }) {
                next = covering.end
                continue
            }
            let stop = min(limit, deliveredStart(after: next) ?? limit)
            guard let range = try? ByteRange(offset: next, length: min(chunk, stop - next), fileSize: fileSize) else {
                break
            }
            pending[range.offset] = (range.length, generation)
            inFlight += 1
            next = range.end
            ranges.append(range)
        }
        return ranges
    }

    private mutating func record(_ range: ByteRange, at now: ContinuousClock.Instant) {
        guard range.length > 0 else { return }
        if !delivered.contains(where: { $0.offset <= range.offset && range.end <= $0.end }) { newestBytes = now }
        var merged = range
        let fileSize = fileSize
        delivered.removeAll { other in
            guard other.offset <= merged.end, merged.offset <= other.end else { return false }
            let start = min(other.offset, merged.offset), end = max(other.end, merged.end)
            merged = (try? ByteRange(offset: start, length: end - start, fileSize: fileSize)) ?? merged
            return true
        }
        delivered.insert(merged, at: delivered.firstIndex { $0.offset > merged.offset } ?? delivered.endIndex)
        // Playback moves forward, so the lowest range is the least likely to be read again.
        if delivered.count > Self.deliveredCapacity { delivered.removeFirst() }
    }
}

/// A planner per item and version, so a seek in one file leaves another file's requests current.
public struct ReadAheadRegistry: Sendable {
    public static let defaultCapacity = 8

    private struct Entry: Sendable {
        let item: String
        let version: String
        var planner: ReadAheadPlanner
    }

    public let chunk: Int64
    public let window: Int64
    public let maxInFlight: Int
    public let capacity: Int
    private var entries: [Entry] = [] // least recently used first

    public init(chunk: Int64, window: Int64, maxInFlight: Int, capacity: Int = defaultCapacity) {
        precondition(capacity > 0)
        self.chunk = chunk
        self.window = window
        self.maxInFlight = maxInFlight
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    /// The only call that starts a planner; the others do nothing for an item or version not held.
    public mutating func classify(item: String, version: String, fileSize: Int64,
                                  offset: Int64, length: Int64) -> ReadAheadPlanner.Kind {
        if use(item: item, version: version) == nil {
            entries.removeAll { $0.item == item }
            if entries.count == capacity { entries.removeFirst() }
            entries.append(Entry(item: item, version: version, planner: ReadAheadPlanner(
                fileSize: fileSize, chunk: chunk, window: window, maxInFlight: maxInFlight)))
        }
        return entries[entries.count - 1].planner.classify(offset: offset, length: length)
    }

    public mutating func demandCompleted(item: String, version: String, range: ByteRange,
                                         sequential: Bool) -> [ByteRange] {
        guard let index = use(item: item, version: version) else { return [] }
        return entries[index].planner.demandCompleted(range, sequential: sequential)
    }

    public mutating func speculativeFinished(item: String, version: String, range: ByteRange) -> [ByteRange] {
        guard let index = use(item: item, version: version) else { return [] }
        return entries[index].planner.speculativeFinished(range)
    }

    public mutating func fullCompleted(item: String, version: String) {
        guard let index = use(item: item, version: version) else { return }
        entries[index].planner.fullCompleted()
    }

    /// Never extends into delivered bytes: a read meeting that rewrite made fileproviderd download
    /// the whole file. Not a use, so it doesn't reorder the registry.
    public func extent(item: String, version: String, covering required: ByteRange, alignment: Int64,
                       fileSize: Int64, preferredLength: Int64) throws -> ByteRange {
        var preferred = preferredLength
        if alignment > 0, let stop = entries.first(where: { $0.item == item && $0.version == version })?
            .planner.deliveredStart(after: required.end) {
            preferred = min(preferred, max(stop - (required.offset - required.offset % alignment), 1))
        }
        return try ByteRange.aligned(minimum: required, alignment: alignment, fileSize: fileSize,
                                     preferredLength: preferred)
    }

    public mutating func speculativeFailed(item: String, version: String, offset: Int64) {
        guard let index = use(item: item, version: version) else { return }
        entries[index].planner.speculativeFailed(offset: offset)
    }

    public mutating func requestFailed(item: String, version: String, range: ByteRange) {
        guard let index = use(item: item, version: version) else { return }
        entries[index].planner.requestFailed(range)
    }

    private mutating func use(item: String, version: String) -> Int? {
        guard let index = entries.firstIndex(where: { $0.item == item && $0.version == version }) else {
            return nil
        }
        entries.append(entries.remove(at: index))
        return entries.count - 1
    }
}
