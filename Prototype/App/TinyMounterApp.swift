import AppKit
import OSLog
import SwiftUI

/// Plan §8: a Dock icon, the menu bar item and the Settings window.
@main
struct TinyMounterPrototypeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = true

    var body: some Scene {
        Window(UIText.appName, id: SettingsWindow.id) {
            SettingsView(model: delegate.model)
        }
        .defaultSize(width: 780, height: 540)
        .windowResizability(.contentMinSize)
        // Without locations or a menu bar item, the window is the only way in.
        .defaultLaunchBehavior(delegate.model.hasLocations && showMenuBar ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .commands { LocationCommands(model: delegate.model) }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct LocationCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        CommandGroup(replacing: .newItem) {
            OpenSettingsButton(title: UIText.newLocation, key: "n", action: model.newLocation)
            Button(UIText.duplicate) { if let record = model.selectedRecord { model.duplicate(record.id) } }
                .keyboardShortcut("d")
                .disabled(model.selectedRecord == nil)
        }
    }
}

private struct OpenSettingsButton: View {
    var title = UIText.settingsMenu
    var key: KeyEquivalent = ","
    var action: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            action()
            openWindow(id: SettingsWindow.id)
        }
        .keyboardShortcut(key)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "app")

    /// Phase 3 plan §2: the extension restarts the app only if this run ends in a crash.
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            let url = try SharedContainer.url().appending(path: RunState.fileName)
            let previous = try RunStateRecorder.start(at: url)
            Self.logger.info("previous_run=\(previous?.state.rawValue ?? "none", privacy: .public)")
        } catch {
            Self.logger.error("run_state failed \(logFields(error), privacy: .public)")
        }
    }

    /// Quit, logout and shutdown, but not Force Quit.
    func applicationWillTerminate(_ notification: Notification) { RunStateRecorder.stop() }

    /// The reader must stay up, so closing the window keeps the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click doesn't open a closed `Window` scene by itself.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.openSettings?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isDownloading else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = UIText.quitTitle
        alert.informativeText = UIText.quitMessage
        alert.addButton(withTitle: UIText.quit)
        alert.addButton(withTitle: UIText.cancel)
        // Quit from the menu bar item leaves the app inactive, and the alert would open behind.
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
