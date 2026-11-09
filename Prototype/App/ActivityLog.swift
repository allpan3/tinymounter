import Foundation
import Observation
import OSLog

/// The panel's recent activity in `Application Support/tinymounter/Activity.json`, app-private.
/// It holds file names, so it stays out of logs and Export Diagnostics.
@MainActor
@Observable
final class ActivityLog {
    private(set) var history: ActivityHistory
    @ObservationIgnored private let url: URL
    @ObservationIgnored private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "activity")

    init(url: URL = URL.applicationSupportDirectory.appending(path: "tinymounter/" + ActivityHistory.fileName)) {
        self.url = url
        do {
            history = try ActivityHistory.load(from: url)
        } catch {
            Self.log.error("activity_load \(logFields(error), privacy: .public)")
            history = ActivityHistory()
        }
    }

    func add(_ event: ActivityEvent) {
        history.add(event)
        save()
    }

    /// The events of locations that are gone, with their names.
    func keep(domains: Set<String>) {
        let stale = Set(history.events.compactMap(\.domain)).subtracting(domains)
        guard !stale.isEmpty else { return }
        for domain in stale { history.removeEvents(domain: domain) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try history.save(to: url)
        } catch {
            Self.log.error("activity_save \(logFields(error), privacy: .public)")
        }
    }
}
