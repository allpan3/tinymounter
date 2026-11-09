import Foundation

/// The IDs of one share's sessions that ended with a lost connection. The server keeps such a
/// session's open files until it notices the loss; a new session that names it as its
/// PreviousSessionId makes the server end it at once. Each new session names one, oldest first.
public struct PreviousSessions: Sendable {
    /// Each new session takes one, so more only build up while the server stays unreachable.
    public static let limit = 16
    private var ids: [UInt64] = []

    public init() {}

    /// A session that this process opened lost its connection and will never send again.
    public mutating func dropped(_ id: UInt64) {
        guard id != 0, !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.limit { ids.removeFirst() }
    }

    /// The ID for the next session to send, removed until `unsent(_:)` returns it.
    public mutating func take() -> UInt64? { ids.isEmpty ? nil : ids.removeFirst() }

    /// The session that took `id` didn't sign in, so the server may not have ended it.
    public mutating func unsent(_ id: UInt64) {
        guard !ids.contains(id) else { return }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast() }
    }
}
