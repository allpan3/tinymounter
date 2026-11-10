import Foundation
import OSLog

/// Each share's `PreviousSessions` in `Application Support/tinymounter/PreviousSessions.json`,
/// app-private, so the next run also names the sessions that a quit or restart left on the server.
/// The file changes only when a session drops, a sign-in ends one, a share goes, or the app ends.
final class PreviousSessionStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var shares: [UUID: PreviousSessions]
    private var ending = false
    // Saves in the order of the changes, off the threads that made them.
    private let writer = DispatchQueue(label: "dev.tinymounter.prototype.previous-sessions", qos: .utility)
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    init(url: URL = URL.applicationSupportDirectory.appending(path: "tinymounter/" + PreviousSessionsFile.fileName)) {
        self.url = url
        do {
            shares = try PreviousSessionsFile.load(from: url)
        } catch {
            Self.logger.error("previous_sessions_load \(logFields(error), privacy: .public)")
            shares = [:]
        }
    }

    func take(_ shareID: UUID) -> UInt64? { lock.withLock { shares[shareID, default: PreviousSessions()].take() } }

    func unsent(_ shareID: UUID, _ id: UInt64) { lock.withLock { shares[shareID]?.unsent(id) } }

    func signedIn(_ shareID: UUID, session: UInt64, previous: UInt64?) {
        lock.withLock {
            shares[shareID, default: PreviousSessions()].signedIn(session, previous: previous)
            if previous != nil { saveSoon() }
        }
    }

    func ended(_ shareID: UUID, session: UInt64, dropped: Bool) {
        lock.withLock {
            if dropped {
                shares[shareID, default: PreviousSessions()].dropped(session)
                saveSoon()
            } else {
                shares[shareID]?.closed(session)
            }
        }
    }

    /// The shares in the settings; the others are forgotten, with their sessions.
    func keep(_ shareIDs: Set<UUID>) {
        lock.withLock {
            let stale = shares.keys.filter { !shareIDs.contains($0) }
            guard !stale.isEmpty else { return }
            for id in stale { shares[id] = nil }
            saveSoon()
        }
    }

    /// Quit, logout, restart and shutdown: the sessions still open count as dropped, because a
    /// network loss now can leave them and their open files on the server. Force Quit and crashes
    /// skip this, so only their dropped sessions are named.
    func end() {
        let snapshot = lock.withLock {
            ending = true
            return shares
        }
        writer.sync { save(snapshot, ending: true) }
    }

    /// Called with the lock held, so the writer saves the snapshots in order.
    private func saveSoon() {
        guard !ending else { return }
        let snapshot = shares
        writer.async { [self] in save(snapshot, ending: false) }
    }

    private func save(_ snapshot: [UUID: PreviousSessions], ending: Bool) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PreviousSessionsFile.save(snapshot, ending: ending, to: url)
        } catch {
            Self.logger.error("previous_sessions_save \(logFields(error), privacy: .public)")
        }
    }
}
