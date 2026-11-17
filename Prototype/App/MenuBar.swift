import AppKit
import SwiftUI

enum MenuBarSettings {
    static let showKey = "showMenuBar"
}

/// Design §5: locations, transfers, recent activity and the actions, in a window-style panel.
struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// The panel is key while it shows, so the pending count is read only then.
    @Environment(\.appearsActive) private var appearsActive
    @State private var pending = 0
    @State private var detailsHeight: CGFloat = 0
    @State private var actionsHeight: CGFloat = 0
    @State private var availableHeight: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                details
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(detailsHeight, max(0, availableHeight - actionsHeight - 12)))
            actions
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
        }
        .padding(.vertical, 6)
        .frame(width: PanelLayout.width)
        .onAppear(perform: updateAvailableHeight)
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { updateAvailableHeight() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            updateAvailableHeight()
        }
        .task(id: appearsActive) {
            while appearsActive, !Task.isCancelled {
                pending = await model.pendingCount()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, PanelLayout.inset)
                    .padding(.vertical, 4)
            }
            PanelHeader(UIText.locations)
            if !model.hasLocations { PanelNote(UIText.noLocations) }
            ForEach(model.records, id: \.id) { record in
                LocationRow(model: model, record: record, signInAgain: signInAgain)
            }
            ForEach(model.serverVolumes) { volume in
                VolumeRow(model: model, volume: volume, signInAgain: signInAgain)
            }
            if !model.transfers.isEmpty {
                PanelDivider()
                PanelHeader(UIText.transfers)
                ForEach(model.transfers) { TransferRow(model: model, transfer: $0) }
            }
            PanelDivider()
            PanelHeader(UIText.recentActivity)
            ActivityList(model: model)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelDivider()
            PanelButton(model.paused ? UIText.resumeDownloads : UIText.pauseDownloads, action: model.togglePause)
                .disabled(!model.isReady)
            PanelButton(UIText.retryPending, trailing: pending > 0 ? "\(pending)" : nil, action: model.retryAllPending)
                .disabled(pending == 0)
            PanelDivider()
            PanelButton(UIText.settingsMenu, trailing: UIText.settingsShortcut, action: openSettings)
                .keyboardShortcut(",")
            PanelButton(UIText.quit, trailing: UIText.quitShortcut) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func updateAvailableHeight() {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        availableHeight = max(0, screen.visibleFrame.height - 16)
    }

    /// Like a menu, the panel closes when an action opens another window.
    private func openSettings() {
        dismiss()
        openWindow(id: SettingsWindow.id)
        NSApp.activate()
    }

    /// The sign-in sheet opens on the Settings window, so the window opens first.
    private func signInAgain(_ serverID: UUID, location: UUID) {
        model.selection = .location(location)
        openSettings()
        model.signInAgain(serverID: serverID)
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

/// The newest events first; past a few rows the list scrolls.
private struct ActivityList: View {
    var model: AppModel
    private static let visibleRows = 6

    var body: some View {
        let events = model.activity.history.events
        if events.isEmpty {
            PanelNote(UIText.noActivity)
        } else {
            TimelineView(.everyMinute) { context in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { ActivityRow(model: model, event: $0, now: context.date) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: PanelLayout.activityRowHeight * CGFloat(min(events.count, Self.visibleRows)))
            }
        }
    }
}
