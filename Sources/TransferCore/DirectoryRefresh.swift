import Foundation

public struct DirectoryRefresh: Sendable {
    public static let interval = Duration.seconds(60)
    public static let hintDelay = Duration.milliseconds(500)
    public static let minimumInterval = Duration.seconds(2)
    private struct Entry: Sendable {
        var due: Duration
        var last: Duration?
        var failures = 0
        var running = false
        var changed = false
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func replaceFolders(_ folders: Set<String>, now: Duration) {
        entries = entries.filter { folders.contains($0.key) }
        for id in folders where entries[id] == nil { entries[id] = Entry(due: now) }
    }

    public mutating func changed(_ id: String, now: Duration) {
        guard var entry = entries[id] else { return }
        if entry.running {
            entry.changed = true
        } else if entry.failures == 0 {
            let earliest = max(now + Self.hintDelay, entry.last.map { $0 + Self.minimumInterval } ?? now)
            entry.due = min(entry.due, earliest)
        }
        entries[id] = entry
    }

    public mutating func next(now: Duration) -> String? {
        let due = entries.filter { !$0.value.running && $0.value.due <= now }
        guard let first = due.min(by: {
            $0.value.due == $1.value.due ? $0.key < $1.key : $0.value.due < $1.value.due
        }) else { return nil }
        entries[first.key]?.running = true
        return first.key
    }

    public mutating func finished(_ id: String, succeeded: Bool, now: Duration) {
        guard var entry = entries[id], entry.running else { return }
        entry.running = false
        entry.last = now
        if succeeded {
            entry.failures = 0
            entry.due = now + (entry.changed ? Self.minimumInterval : Self.interval)
        } else {
            entry.failures = min(entry.failures + 1, 4)
            entry.due = now + .seconds(15 * (1 << entry.failures))
        }
        entry.changed = false
        entries[id] = entry
    }

    public mutating func refreshAll(now: Duration) {
        for id in entries.keys { changed(id, now: now) }
    }
}
