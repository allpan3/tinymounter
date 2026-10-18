import Foundation

/// `Application Support/tinymounter/Settings.json` in the app container.
@MainActor
final class SettingsStore {
    enum State {
        case ready(AppSettings)
        /// Launch reconciliation stops and saves are refused, so the file is never replaced.
        case unreadable(any Error)
    }

    let url: URL
    private(set) var state: State
    /// Called after each saved update.
    var onUpdate: (() -> Void)?

    init(url: URL = URL.applicationSupportDirectory.appending(path: "tinymounter/Settings.json")) {
        self.url = url
        state = Self.read(url)
    }

    var settings: AppSettings? {
        guard case .ready(let settings) = state else { return nil }
        return settings
    }

    func reload() { state = Self.read(url) }

    /// Saves before memory changes, so `state` never holds settings that the file lacks.
    func update(_ change: (inout AppSettings) throws -> Void) throws {
        switch state {
        case .unreadable(let error): throw error
        case .ready(var settings):
            try change(&settings)
            try settings.save(to: url)
            state = .ready(settings)
            onUpdate?()
        }
    }

    private static func read(_ url: URL) -> State {
        do { return .ready(try AppSettings.load(from: url)) } catch { return .unreadable(error) }
    }
}
