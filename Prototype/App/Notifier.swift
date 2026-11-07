import Foundation
import OSLog
import UserNotifications

/// Plan §7 notifications: one per share per outage, never at launch and never with a file name.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notifications"
    /// Shares with a notification in this outage; a connection ends the outage.
    private var notified: Set<UUID> = []
    nonisolated private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "share")

    private var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    override init() {
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

    /// Posts when a share that has locations goes from connected to not connected or unresponsive.
    func shareChanged(_ grant: ServerGrant, from before: ShareHealth.State, to state: ShareHealth.State,
                      hasLocations: Bool) {
        switch (before, state) {
        case (_, .connected):
            notified.remove(grant.id)
        case _ where !hasLocations:
            break
        case (.connected, .notConnected):
            post(grant, title: UIText.shareDisconnected(grant.share), body: UIText.connectInLocation)
        case (.connected, .unresponsive):
            post(grant, title: UIText.cannotConnectTitle(grant.host), body: UIText.onSameNetwork(grant.host))
        default:
            break
        }
    }

    /// The user disconnects the share, so its outage gets no notification.
    func userDisconnected(_ grantID: UUID) { notified.insert(grantID) }

    /// The share is still mounted.
    func disconnectFailed(_ grantID: UUID) { notified.remove(grantID) }

    /// A download that the user started failed because the share is not connected or does not respond.
    func downloadFailed(_ grant: ServerGrant, _ failure: SourceFailure) {
        post(grant, title: UIText.downloadFailedTitle,
             body: failure == .notConnected ? UIText.connectInLocation : UIText.onSameNetwork(grant.host))
    }

    private func post(_ grant: ServerGrant, title: String, body: String) {
        guard isEnabled, notified.insert(grant.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "share-\(grant.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Self.log.info("""
                notification share=\(grant.id.uuidString, privacy: .public) posted=\(error == nil)
                """)
        }
    }
}
