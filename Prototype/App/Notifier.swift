import Foundation
import OSLog
import UserNotifications

/// Sends each event to the panel, a notification, both or neither, as Settings › General says.
/// Notifications hold file names. Connection and sign-in events come once per outage, not at launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let activity: ActivityLog
    /// Shares that lost their connection in this outage; a connection ends the outage.
    private var lost: Set<UUID> = []
    /// Servers that refused the saved password since it was saved or a share connected.
    private var refused: Set<UUID> = []
    /// Shares with a failed download in this outage.
    private var failedDownloads: Set<UUID> = []
    nonisolated private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    init(activity: ActivityLog) {
        self.activity = activity
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Without this, macOS shows no notification while tinymounter is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// When the user adds a location; the system asks only once.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Self.log.info("notification_permission granted=\(granted) error=\(error != nil)")
        }
    }

    /// A share that has locations stops answering, connects again, or its server refuses the
    /// saved password. A lost network is no event: the share connects again by itself.
    func shareChanged(_ share: ShareRecord, host: String, from before: ConnectionState, to state: ConnectionState,
                      hasLocations: Bool) {
        switch (before, state) {
        case (_, .connected):
            refused.remove(share.serverID)
            failedDownloads.remove(share.id)
            guard lost.remove(share.id) != nil else { return }
            report(ActivityEvent(kind: .connectionRestored, domain: nil, name: host),
                   title: UIText.connectedAgainTitle(host), body: "", id: "share-\(share.id.uuidString)")
        case _ where !hasLocations:
            break
        case (.connected, .unresponsive):
            guard lost.insert(share.id).inserted else { return }
            report(ActivityEvent(kind: .connectionLost, domain: nil, name: host),
                   title: UIText.cannotConnectTitle(host), body: UIText.onSameNetwork(host),
                   id: "share-\(share.id.uuidString)")
        case (_, .needsSignIn):
            signInRefused(share, host: host)
        default:
            break
        }
    }

    /// Once per server, also when a Server Volume did not mount again for this reason.
    func signInRefused(_ share: ShareRecord, host: String) {
        guard refused.insert(share.serverID).inserted else { return }
        report(ActivityEvent(kind: .signInNeeded, domain: nil, name: host),
               title: UIText.cannotSignInTitle(host), body: UIText.signInAgainInSettings,
               id: "server-\(share.serverID.uuidString)")
    }

    /// Sign In Again… saved a new password: the next refusal is an event again.
    func signedIn(_ serverID: UUID) { refused.remove(serverID) }

    /// A download that the user started failed because the share is not connected or does not respond.
    func downloadFailed(_ share: ShareRecord, host: String, domain: String, name: String, _ failure: SourceFailure) {
        guard failedDownloads.insert(share.id).inserted else { return }
        let body = switch failure {
        case .notConnected: UIText.connectInLocation
        case .localNetworkDenied: UIText.localNetworkDenied
        default: UIText.onSameNetwork(host)
        }
        report(ActivityEvent(kind: .downloadFailed, domain: domain, name: name, detail: body),
               title: UIText.downloadFailedTitle(name), body: body)
    }

    /// `id` replaces an earlier notification with the same ID; finished transfers only go to the panel.
    func report(_ event: ActivityEvent, title: String = "", body: String = "", id: String? = nil) {
        let route = event.notification?.route(in: .standard) ?? NotificationRoute(notify: false, panel: true)
        if route.panel { activity.add(event) }
        guard route.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id ?? event.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Self.log.info("""
                notification kind=\(event.kind.rawValue, privacy: .public) \
                event=\(event.id.uuidString, privacy: .public) posted=\(error == nil)
                """)
        }
    }
}
