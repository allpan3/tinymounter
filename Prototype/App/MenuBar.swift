import AppKit
import SwiftUI

enum MenuBarSettings {
    static let showKey = "showMenuBar"
}

/// Design §5: one line per location, Pause Downloads, Settings… and Quit tinymounter.
/// A menu-style menu can't show a progress bar, so a download shows as "42% downloaded".
struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let problem = model.problem { Text(problem) }
        if !model.hasLocations { Text(UIText.noLocations) }
        ForEach(model.records, id: \.id) { record in
            Text(UIText.joined(record.name, model.shortStatus(record)))
        }
        ForEach(model.serverVolumes) { volume in
            Button(UIText.joined(model.volumeName(volume), model.volumeStatus(volume))) {
                model.showInFinder(volume.id)
            }
        }
        Divider()
        Button(model.paused ? UIText.resumeDownloads : UIText.pauseDownloads, action: model.togglePause)
            .disabled(!model.isReady)
        Divider()
        Button(UIText.settingsMenu) {
            openWindow(id: SettingsWindow.id)
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button(UIText.quit) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(model.menuImageName)
            .renderingMode(.template)
            .accessibilityLabel(UIText.appName)
            .onAppear { model.openSettings = { openWindow(id: SettingsWindow.id) } }
    }
}
