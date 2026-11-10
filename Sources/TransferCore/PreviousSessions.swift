import Foundation

/// The IDs of one share's sessions that ended with a lost connection. The server keeps such a
/// session's open files until it notices the loss; a new session that names it as its
/// PreviousSessionId makes the server end it at once. Each new session names one, oldest first.
public struct PreviousSessions: Equatable, Sendable {
    /// Each new session takes one, so more only build up while the server stays unreachable.
    public static let limit = 16
    private var ids: [UInt64] = []
    /// Taken by a sign-in that hasn't finished, so the server may not have ended them yet.
    private var sending: [UInt64] = []
    /// This process's sessions that are still open, which a lost network can leave on the server.
    private var open: Set<UInt64> = []

    /// `saved` are an earlier run's `saved(ending:)`, oldest first.
    public init(saved: [UInt64] = []) {
        for id in saved { dropped(id) }
    }

    /// A session that this process opened lost its connection and will never send again.
    public mutating func dropped(_ id: UInt64) {
        open.remove(id)
        guard id != 0, !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.limit { ids.removeFirst() }
    }

    /// The ID for the next session to send, removed until `unsent(_:)` returns it.
    public mutating func take() -> UInt64? {
        guard !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        sending.append(id)
        return id
    }

    /// `session` signed in, and the server ended `previous`, the ID it took.
    public mutating func signedIn(_ session: UInt64, previous: UInt64?) {
        if let previous { sending.removeAll { $0 == previous } }
        if session != 0 { open.insert(session) }
    }

    /// The session that took `id` didn't sign in, so the server may not have ended it.
    public mutating func unsent(_ id: UInt64) {
        sending.removeAll { $0 == id }
        guard !ids.contains(id) else { return }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast() }
    }

    /// A session ended without losing its connection, so the server ended it too.
    public mutating func closed(_ id: UInt64) { open.remove(id) }

    /// The IDs for the next run to name, oldest first. A session of an earlier run is never used
    /// again, so when this run is `ending`, its open sessions count as dropped too.
    public func saved(ending: Bool) -> [UInt64] {
        PreviousSessions(saved: sending + ids + (ending ? open.sorted() : [])).ids
    }
}

/// Each share's `PreviousSessions.saved(ending:)`, kept across a relaunch, by share ID.
public enum PreviousSessionsFile {
    public static let fileName = "PreviousSessions.json"

    /// A missing file is no saved session; an unreadable one throws.
    public static func load(from url: URL) throws -> [UUID: PreviousSessions] {
        let saved: [String: [UInt64]]
        do {
            saved = try JSONDecoder().decode([String: [UInt64]].self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile { return [:] }
        return try Dictionary(uniqueKeysWithValues: saved.map { key, ids in
            guard let shareID = UUID(uuidString: key) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (shareID, PreviousSessions(saved: ids))
        })
    }

    /// Shares without a session to name are left out.
    public static func save(_ shares: [UUID: PreviousSessions], ending: Bool, to url: URL) throws {
        let saved = shares.reduce(into: [String: [UInt64]]()) { saved, share in
            let ids = share.value.saved(ending: ending)
            if !ids.isEmpty { saved[share.key.uuidString] = ids }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(saved).write(to: url, options: .atomic)
    }
}
