import Foundation
import OSLog
import UserNotifications

/// Plan §7 notifications: one per share per outage, never at launch and never with a file name.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "notifications"
    /// Shares and servers with a notification in this outage; a connection ends the outage.
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

    /// Posts when a share that has locations stops answering, and once per server that refuses the
    /// saved password. A lost network needs no notification: the share connects again by itself.
    func shareChanged(_ share: ShareRecord, host: String, from before: ConnectionState, to state: ConnectionState,
                      hasLocations: Bool) {
        switch (before, state) {
        case (_, .connected):
            notified.remove(share.id)
            notified.remove(share.serverID)
        case _ where !hasLocations:
            break
        case (.connected, .unresponsive):
            post(share.id, title: UIText.cannotConnectTitle(host), body: UIText.onSameNetwork(host))
        case (_, .needsSignIn):
            post(share.serverID, title: UIText.cannotSignInTitle(host), body: UIText.signInAgainInSettings)
        default:
            break
        }
    }

    /// A download that the user started failed because the share is not connected or does not respond.
    func downloadFailed(_ share: ShareRecord, host: String, _ failure: SourceFailure) {
        post(share.id, title: UIText.downloadFailedTitle,
             body: failure == .notConnected ? UIText.connectInLocation : UIText.onSameNetwork(host))
    }

    /// `id` is a share's, or a server's for sign-in; it has one notification per outage.
    private func post(_ id: UUID, title: String, body: String) {
        guard isEnabled, notified.insert(id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "share-\(id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Self.log.info("""
                notification share=\(id.uuidString, privacy: .public) posted=\(error == nil)
                """)
        }
    }
}
