import Foundation

/// One entry in the menu bar panel's recent activity.
public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case uploaded, downloaded, keptDownloaded
        case uploadFailed, downloadFailed, conflictCopy, lowDiskSpace, signInNeeded
        case connectionLost, connectionRestored
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// The location's File Provider domain; nil for an event of a whole server.
    public let domain: String?
    /// A file or folder name, or the server's host name for sign-in and connection events.
    public let name: String
    /// A short reason for a failure, as UI text.
    public let detail: String?
    /// The File Provider item of an upload, which relates its failure to a later success.
    public let item: String?

    public init(kind: Kind, domain: String?, name: String, detail: String? = nil, item: String? = nil,
                date: Date = .now, id: UUID = UUID()) {
        self.id = id
        self.date = date
        self.kind = kind
        self.domain = domain
        self.name = name
        self.detail = detail
        self.item = item
    }

    /// The setting that routes this event; nil for finished uploads and downloads, which only
    /// the panel lists.
    public var notification: NotificationKind? {
        switch kind {
        case .uploaded, .downloaded: nil
        case .keptDownloaded: .keepDownloaded
        case .uploadFailed: .uploadFailed
        case .downloadFailed: .downloadFailed
        case .conflictCopy: .conflictCopy
        case .lowDiskSpace: .lowDiskSpace
        case .signInNeeded: .signInNeeded
        case .connectionLost, .connectionRestored: .connection
        }
    }
}

/// A row of Settings › General › Notifications.
public enum NotificationKind: String, CaseIterable, Sendable {
    case signInNeeded, uploadFailed, downloadFailed, conflictCopy, lowDiskSpace, connection, keepDownloaded

    /// Problems that need the user's action also post a macOS notification.
    public var needsAction: Bool { ![.connection, .keepDownloaded].contains(self) }

    public var notifyKey: String { "notification.\(rawValue).notify" }
    public var panelKey: String { "notification.\(rawValue).panel" }

    public func route(in defaults: UserDefaults) -> NotificationRoute {
        NotificationRoute(notify: defaults.object(forKey: notifyKey) as? Bool ?? needsAction,
                          panel: defaults.object(forKey: panelKey) as? Bool ?? true)
    }
}

public struct NotificationRoute: Equatable, Sendable {
    public var notify: Bool
    public var panel: Bool

    public init(notify: Bool, panel: Bool) {
        self.notify = notify
        self.panel = panel
    }
}

/// The panel's recent activity, newest first, kept across a relaunch.
public struct ActivityHistory: Equatable, Sendable {
    public static let limit = 100
    public static let fileName = "Activity.json"

    public private(set) var events: [ActivityEvent]

    public init(events: [ActivityEvent] = []) {
        self.events = Array(events.sorted { $0.date > $1.date }.prefix(Self.limit))
    }

    public mutating func add(_ event: ActivityEvent) {
        events.insert(event, at: events.firstIndex { $0.date <= event.date } ?? events.endIndex)
        if events.count > Self.limit { events.removeLast(events.count - Self.limit) }
    }

    /// True when the item's newest upload outcome is a failure. macOS sends a failed upload
    /// again, also after a relaunch, and the failure is listed once until the upload succeeds.
    public func uploadFailed(domain: String, item: String) -> Bool {
        events.first {
            $0.domain == domain && $0.item == item && [.uploaded, .uploadFailed, .conflictCopy].contains($0.kind)
        }?.kind == .uploadFailed
    }

    /// A removed location takes its names with it.
    public mutating func removeEvents(domain: String) {
        events.removeAll { $0.domain == domain }
    }

    /// A missing file is an empty history; an unreadable one throws.
    public static func load(from url: URL) throws -> ActivityHistory {
        do {
            return ActivityHistory(events: try JSONDecoder().decode([ActivityEvent].self, from: Data(contentsOf: url)))
        } catch CocoaError.fileReadNoSuchFile { return ActivityHistory() }
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}
