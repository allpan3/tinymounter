import AppKit
import ServiceManagement
import SwiftUI

/// Design §4: a sidebar with the locations and the settings panes.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
        } detail: {
            switch model.selection {
            case .location(let id)?: LocationPane(model: model, id: id).id(id)
            case .general?: GeneralPane(model: model)
            case .storage?: StoragePane(model: model)
            case .servers?: ServersPane(model: model)
            case .about?: AboutPane(model: model)
            case nil: Color.clear
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .background(WindowReader { model.window = $0 })
        .onAppear { model.openSettings = { openWindow(id: SettingsWindow.id) } }
    }
}

enum SettingsWindow {
    static let id = "settings"
}

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section(UIText.locations) {
                ForEach(model.entries) { entry in
                    row(entry)
                        .tag(AppModel.Pane.location(entry.id))
                        .contextMenu { menu(entry) }
                }
            }
            Section(UIText.settings) {
                Label(UIText.general, systemImage: "gearshape").tag(AppModel.Pane.general)
                Label(UIText.storage, systemImage: "internaldrive").tag(AppModel.Pane.storage)
                Label(UIText.servers, systemImage: "server.rack").tag(AppModel.Pane.servers)
                Label(UIText.about, systemImage: "info.circle").tag(AppModel.Pane.about)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: UIText.search)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: model.newLocation) { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help(UIText.newLocation)
                    .accessibilityLabel(UIText.newLocation)
                Button(action: model.removeSelected) { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .help(UIText.removeLocationMenu)
                    .accessibilityLabel(UIText.removeLocationMenu)
                    .disabled(!canRemoveSelected)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    private var canRemoveSelected: Bool {
        guard case .location(let id)? = model.selection else { return false }
        return !model.busy.contains(id)
    }

    @ViewBuilder
    private func row(_ entry: AppModel.Entry) -> some View {
        switch entry {
        case .record(let record):
            Label(record.name, systemImage: model.symbol(record))
                .accessibilityLabel("\(record.name), \(model.shortStatus(record))")
        case .draft(let draft):
            HStack {
                Label(draft.name, systemImage: "circle.dashed")
                Spacer()
                Text(UIText.notAdded).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func menu(_ entry: AppModel.Entry) -> some View {
        let isDraft = if case .draft = entry { true } else { false }
        Button(UIText.showInFinder) { model.showInFinder(entry.id) }.disabled(isDraft)
        Button(UIText.duplicate) { model.duplicate(entry.id) }.disabled(isDraft)
        Divider()
        Button(isDraft ? UIText.cancel : UIText.removeLocationMenu) {
            if isDraft { model.cancel(entry.id) } else { model.confirmRemove(entry.id) }
        }
    }
}

/// Design §4.1: all settings of one location in one form.
private struct LocationPane: View {
    enum Field: Hashable { case folder, name }

    @Bindable var model: AppModel
    let id: UUID
    @FocusState private var focus: Field?

    var body: some View {
        Group {
            if let record = model.record(id) {
                form(record: record, draft: nil)
                    .task(id: model.keepKey(record)) { await model.reloadKeeps(record.id) }
            } else if let draft = model.draft(id) {
                form(record: nil, draft: draft)
            }
        }
        .onAppear(perform: takeFocus)
        .onChange(of: model.focusFolder) { takeFocus() }
        .onChange(of: focus) { old, _ in
            if old == .name, model.record(id) != nil { model.commitName(id) }
            if old == .folder { model.endFolderCompletion() }
        }
    }

    private func takeFocus() {
        guard model.focusFolder == id else { return }
        model.focusFolder = nil
        // The field exists only after this update.
        DispatchQueue.main.async { focus = .folder }
    }

    private func form(record: LocationRecord?, draft: AppModel.Draft?) -> some View {
        Form {
            if let problem = model.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if let record { header(record) }
            sourceSection
            connectionSection
            if let record {
                keepSection(record)
                Section {
                    Button(UIText.removeLocationMenu, role: .destructive) { model.confirmRemove(record.id) }
                        .disabled(model.busy.contains(record.id))
                } footer: {
                    Text(UIText.removeLocationDescription).foregroundStyle(.secondary)
                }
            } else if let draft {
                draftKeepSection(draft)
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy.contains(id) || !model.isReady || model.connectionBusy)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(record: record) }
    }

    private func header(_ record: LocationRecord) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.title2.bold())
                    Text(model.sourceText(record)).foregroundStyle(.secondary)
                    Label(model.statusText(record), systemImage: model.symbol(record))
                        .foregroundStyle(model.state(record).isProblem ? .red : .secondary)
                }
                Spacer()
                Button(UIText.showInFinder) { model.showInFinder(record.id) }.disabled(record.removing)
            }
        }
    }

    private var sourceSection: some View {
        Section(UIText.source) {
            Picker(UIText.server, selection: serverBinding) {
                if model.serverID(id) == nil { Text(UIText.noServer).tag(String?.none) }
                ForEach(model.servers) { Text(UIText.serverAddress($0)).tag(Optional($0.id.uuidString)) }
                Divider()
                Text(UIText.addServer).tag(Optional(Self.addServerTag))
            }
            Picker(UIText.share, selection: shareBinding) {
                if model.grantID(id) == nil { Text(UIText.noShare).tag(String?.none) }
                ForEach(sharesOnServer, id: \.id) {
                    Text(UIText.accountAndShare($0.account, $0.share)).tag(Optional($0.id.uuidString))
                }
                Divider()
                Text(UIText.addShare).tag(Optional(Self.addShareTag))
            }
            .disabled(model.serverID(id) == nil)
            LabeledContent(UIText.folder) {
                HStack {
                    TextField(UIText.folder, text: binding(model.folderText, model.setFolder),
                              prompt: Text(UIText.fullShare))
                        .labelsHidden()
                        .focused($focus, equals: .folder)
                        .onSubmit(submit)
                        .textInputSuggestions {
                            ForEach(model.folderSuggestions, id: \.self) { Text($0).textInputCompletion($0) }
                        }
                        .task(id: focus == .folder ? model.folderText(id) : nil) {
                            guard focus == .folder else { return }
                            try? await Task.sleep(for: Self.completionDelay)
                            if !Task.isCancelled { await model.suggestFolders(id) }
                        }
                    Button(UIText.select) { model.selectFolder(id) }.disabled(model.grantID(id) == nil)
                }
            }
            TextField(UIText.name, text: binding(model.nameText, model.setName))
                .focused($focus, equals: .name)
                .onSubmit(submit)
        }
    }

    private var connectionSection: some View {
        Section(UIText.connectionMode) {
            Picker(UIText.connectionMode, selection: .constant(0)) {
                mode(UIText.fileProvider, UIText.fileProviderDescription).tag(0)
                mode(UIText.serverVolume, UIText.serverVolumeDescription).tag(1).disabled(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private func mode(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func keepSection(_ record: LocationRecord) -> some View {
        Section {
            let rows = model.keepRows[record.id] ?? []
            ForEach(rows) { row in
                HStack {
                    Text(row.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(row.notOnServer ? UIText.notOnServer : UIText.requested).foregroundStyle(.secondary)
                    Button { model.removeKeep(row, in: record.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(UIText.removeItem)
                        .accessibilityLabel(UIText.removeItem)
                }
            }
        } header: {
            Text(UIText.keepDownloaded)
        } footer: {
            Text(UIText.keepHint).foregroundStyle(.secondary)
        }
    }

    private func draftKeepSection(_ draft: AppModel.Draft) -> some View {
        let saved = model.savedKeeps(draft)
        return Section {
            ForEach(saved, id: \.self) { path in
                Text(path).lineLimit(1).truncationMode(.middle)
            }
        } header: {
            Text(UIText.keepDownloaded)
        } footer: {
            Text(saved.isEmpty ? UIText.keepHint : UIText.draftKeepHint).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bottomBar(record: LocationRecord?) -> some View {
        if record == nil {
            bar(UIText.draftBar) {
                Button(UIText.cancel) { model.cancel(id) }.disabled(model.busy.contains(id))
                Button(UIText.add) { model.add(id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.grantID(id) == nil || !model.isReady || model.busy.contains(id))
            }
        } else if model.hasEdit(id) {
            bar(UIText.applyBar) {
                Button(UIText.revert) { model.revert(id) }.disabled(model.busy.contains(id))
                Button(UIText.apply) { model.confirmApply(id) }.disabled(!model.isReady || model.busy.contains(id))
            }
        }
    }

    private func bar(_ text: String, @ViewBuilder buttons: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if model.busy.contains(id) { ProgressView().controlSize(.small) }
                buttons()
            }
            .padding(12)
        }
        .background(.bar)
    }

    /// Return in a field of a draft adds it; in Name of a location it renames it.
    private func submit() {
        if model.record(id) != nil { model.commitName(id) } else { model.add(id) }
    }

    private static let addServerTag = "\u{0}add-server"
    private static let addShareTag = "\u{0}add-share"
    private static let completionDelay = Duration.milliseconds(150)

    private var sharesOnServer: [ServerGrant] {
        model.shares.filter { $0.serverID == model.serverID(id) }
    }

    private var serverBinding: Binding<String?> {
        Binding { model.serverID(id)?.uuidString } set: { key in
            if key == Self.addServerTag {
                model.addServer(for: id)
            } else if let key, let serverID = UUID(uuidString: key), serverID != model.serverID(id) {
                model.setServer(id, serverID)
            }
        }
    }

    private var shareBinding: Binding<String?> {
        Binding { model.grantID(id)?.uuidString } set: { key in
            if key == Self.addShareTag {
                model.addShare(for: id)
            } else if let key, let grantID = UUID(uuidString: key) {
                model.setGrant(id, grantID)
            }
        }
    }

    private func binding(_ get: @escaping (UUID) -> String, _ set: @escaping (UUID, String) -> Void) -> Binding<String> {
        Binding { get(id) } set: { set(id, $0) }
    }
}

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @AppStorage(MenuBarSettings.showKey) private var showMenuBar = true
    @AppStorage(Notifier.enabledKey) private var notifications = true

    var body: some View {
        Form {
            Section {
                Toggle(UIText.openAtLogin, isOn: Binding {
                    model.loginStatus == .enabled
                } set: { model.setOpenAtLogin($0) })
                if model.loginStatus == .requiresApproval {
                    Text(UIText.openAtLoginApproval).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(UIText.showInMenuBar, isOn: $showMenuBar)
            } footer: {
                Text(UIText.menuBarDescription).foregroundStyle(.secondary)
            }
            Section {
                Toggle(UIText.notifications, isOn: $notifications)
            } footer: {
                Text(UIText.notificationsDescription).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refreshLoginStatus)
    }
}

/// Plan §8: the disk space of each location's downloaded files, then the total.
private struct StoragePane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(locations, id: \.id) { record in
                    LabeledContent(record.name) {
                        HStack {
                            Text(model.storageText(record))
                            if model.busy.contains(record.id) { ProgressView().controlSize(.small) }
                            Button(UIText.removeDownloadsMenu) { model.confirmRemoveDownloads(record.id) }
                                .disabled(!model.canRemoveDownloads(record.id))
                        }
                    }
                }
            } header: {
                Text(UIText.locations)
            } footer: {
                Text(UIText.storageDescription).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(UIText.total, value: model.totalStorageText)
            }
        }
        .formStyle(.grouped)
        .task(id: StorageKey(locations: locations.map(\.id), kept: model.keepRevision,
                             materialized: model.materializedRevision)) {
            await model.refreshStorage()
        }
    }

    private var locations: [LocationRecord] { model.records.filter { !$0.removing } }

    /// Storage reads again when the locations, their kept files or the downloaded files change.
    private struct StorageKey: Hashable {
        let locations: [UUID]
        let kept: [UUID: Int]
        let materialized: Int
    }
}

private struct ServersPane: View {
    @Bindable var model: AppModel
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $selected) {
                ForEach(model.servers) { server in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(UIText.serverAddress(server)).font(.headline)
                            Spacer()
                            Button(UIText.addShare) { model.addShare(on: server.id) }
                        }
                        let grants = model.shares.filter { $0.serverID == server.id }
                        if grants.isEmpty { Text(UIText.noSelectedShares).foregroundStyle(.secondary) }
                        ForEach(grants, id: \.id) { grant in shareRow(grant) }
                    }
                    .padding(.vertical, 6)
                    .tag(server.id)
                }
                if !model.otherConnectedShares.isEmpty {
                    Section(UIText.otherConnectedShares) {
                        ForEach(model.otherConnectedShares) { mount in
                            HStack {
                                Text(UIText.mountedShare(mount.address))
                                Spacer()
                                Button(UIText.useShare) { model.useConnectedShare(mount) }
                                Button(UIText.disconnect) { model.disconnect(mount) }
                            }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .disabled(model.connectionBusy || !model.isReady)
            HStack(spacing: 0) {
                Button { model.addServer() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help(UIText.addServer)
                .accessibilityLabel(UIText.addServer)
                Button { if let selected { model.removeServer(selected) } } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .help(UIText.removeItem)
                .accessibilityLabel(UIText.removeItem)
                .disabled(selected.map(model.isServerUsed) ?? true)
                Spacer()
                if model.connectionBusy { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.borderless)
            .disabled(model.connectionBusy || !model.isReady)
            Text(UIText.serverSetupHint).font(.callout).foregroundStyle(.secondary)
            Text(UIText.disconnectHint).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func shareRow(_ grant: ServerGrant) -> some View {
        HStack {
            Text(UIText.accountAndShare(grant.account, grant.share))
            Spacer()
            Text(model.shareStatus(grant)).foregroundStyle(.secondary)
            switch model.shareStates[grant.id] ?? .notConnected {
            case .notConnected: Button(UIText.connect) { model.connect(grant) }
            case .connected, .unresponsive: Button(UIText.disconnect) { model.disconnect(grant) }
            case .needsGrant: EmptyView()
            }
            Button(UIText.selectAgain) { model.selectAgain(grant) }
        }
    }
}

private struct AboutPane: View {
    var model: AppModel
    @State private var report = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UIText.appName).font(.title2.bold())
                    Text(UIText.version).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(report).font(.body.monospaced()).textSelection(.enabled)
            } header: {
                Text(UIText.diagnostics)
            } footer: {
                HStack(alignment: .top) {
                    Text(UIText.diagnosticsDescription).foregroundStyle(.secondary)
                    Spacer()
                    Button(UIText.copy) {
                        Task {
                            report = await model.diagnosticsText()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { report = await model.diagnosticsText() }
    }
}

/// The window that holds a view, for sheets.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow?) -> Void

        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}
