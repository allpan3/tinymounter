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
        .background(WindowReader { window in
            // Otherwise Settings… in the menu bar item leaves the window on another desktop.
            window?.collectionBehavior.insert(.moveToActiveSpace)
            model.window = window
        })
        .onAppear { model.openSettings = { openWindow(id: SettingsWindow.id) } }
        .sheet(item: $model.signIn) { request in
            SignInSheet(request: request) { server, name, password in
                await model.completeSignIn(request, server: server, name: name, password: password)
            } cancel: { model.signIn = nil }
        }
        .sheet(item: $model.folderBrowser) { request in
            FolderBrowser(request: request) { model.chooseFolder(request, $0) } cancel: { model.folderBrowser = nil }
        }
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
            locationLabel(record.name, id: record.id, mode: .fileProvider)
                .accessibilityValue(model.shortStatus(record))
        case .serverVolume(let volume, let name):
            locationLabel(name, id: volume.id, mode: .serverVolume)
                .accessibilityValue(model.volumeStatus(volume))
        case .draft(let draft):
            HStack {
                Label(draft.name, systemImage: "circle.dashed")
                Spacer()
                Text(UIText.notAdded).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func locationLabel(_ name: String, id: UUID, mode: LocationMode) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(UIText.connectionDescription(model.remoteProtocol(id), mode: mode))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: mode == .fileProvider ? "folder" : "externaldrive.connected.to.line.below")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ entry: AppModel.Entry) -> some View {
        let isDraft = if case .draft = entry { true } else { false }
        Button(UIText.showInFinder) { model.showInFinder(entry.id) }.disabled(isDraft)
        Button(UIText.duplicate) { model.duplicate(entry.id) }.disabled(model.record(entry.id) == nil)
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
            } else if let volume = model.serverVolume(id) {
                serverVolumeForm(volume)
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
            if let draft {
                Section {
                    Picker(UIText.finderMode, selection: Binding(
                        get: { draft.mode }, set: { model.setMode(id, $0) }
                    )) {
                        Text(UIText.fileProvider).tag(LocationMode.fileProvider)
                        Text(UIText.serverVolume).tag(LocationMode.serverVolume)
                    }
                } footer: { Text(UIText.modeSwitchHint) }
            }
            sourceSection
            if draft?.mode != .serverVolume { writeSection(record: record, draft: draft) }
            if let record {
                keepSection(record)
                Section {
                    Button(UIText.removeLocationMenu, role: .destructive) { model.confirmRemove(record.id) }
                        .disabled(model.busy.contains(record.id))
                } footer: {
                    Text(UIText.removeLocationDescription).foregroundStyle(.secondary)
                }
            } else if let draft, draft.mode == .fileProvider {
                draftKeepSection(draft)
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy.contains(id) || !model.isReady || model.connectionBusy)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(record: record) }
    }

    private func serverVolumeForm(_ volume: ServerVolumeRecord) -> some View {
        Form {
            Section {
                LabeledContent(UIText.name, value: model.volumeName(volume))
                LabeledContent(UIText.networkProtocol, value: UIText.protocolName(model.remoteProtocol(id)))
                LabeledContent(UIText.finderMode, value: UIText.serverVolume)
                if let share = model.share(volume.shareID), let address = model.address(volume.shareID) {
                    LabeledContent(UIText.server, value: address.host)
                    LabeledContent(UIText.share, value: UIText.accountAndShare(address.account, share.name))
                    Text(model.volumeStatus(volume)).foregroundStyle(.secondary)
                    HStack {
                        Button(UIText.showInFinder) { model.showInFinder(volume.id) }
                        if model.mountedVolumes.contains(share.id) {
                            Button(UIText.disconnect) { model.disconnect(share) }
                        } else if model.needsSignIn(share.serverID) {
                            Button(UIText.signInAgain) { model.signInAgain(serverID: share.serverID) }
                        } else {
                            Button(UIText.connect) { model.connect(share) }
                        }
                    }
                }
            } footer: { Text(UIText.nativeVolumeHint) }
            Section {
                Button(UIText.removeLocationMenu, role: .destructive) { model.confirmRemove(volume.id) }
            } footer: { Text(UIText.modeSwitchHint) }
        }
        .formStyle(.grouped)
        .disabled(model.busy.contains(volume.id) || !model.isReady || model.connectionBusy)
    }

    private func writeSection(record: LocationRecord?, draft: AppModel.Draft?) -> some View {
        Section {
            Toggle(UIText.readOnly, isOn: Binding(
                get: { record?.readOnly ?? draft?.readOnly ?? true },
                set: { model.setReadOnly(id, $0) }
            ))
            if let record { UploadStatus(record: record, model: model) }
        } header: {
            Text(UIText.access)
        } footer: {
            Text(UIText.writeModeHint).foregroundStyle(.secondary)
        }
    }

    private func header(_ record: LocationRecord) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.title2.bold())
                    Text(model.sourceText(record)).foregroundStyle(.secondary)
                    Label(model.statusText(record), systemImage: model.symbol(record))
                        .foregroundStyle(model.state(record).isProblem ? .red : .secondary)
                    if model.state(record) == .turnedOff {
                        Text(UIText.enableFileProvider).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    if model.state(record) == .turnedOff {
                        Button(UIText.openSystemSettings) { model.openSystemSettings() }
                    } else {
                        Button(UIText.showInFinder) { model.showInFinder(record.id) }.disabled(record.removing)
                    }
                    if let share = model.share(record.shareID) { shareAction(model.state(record), share) }
                }
            }
        }
    }

    /// Connection problems are fixed in the location, not in Servers.
    @ViewBuilder
    private func shareAction(_ state: AppModel.LocationState, _ share: ShareRecord) -> some View {
        switch state {
        case .needsSignIn: Button(UIText.signInAgain) { model.signInAgain(serverID: share.serverID) }
        case .notConnected: Button(UIText.connect) { model.connect(share) }
        default: EmptyView()
        }
    }

    private var sourceSection: some View {
        Section {
            LabeledContent(UIText.networkProtocol, value: UIText.protocolName(model.remoteProtocol(id)))
            if model.record(id) != nil {
                LabeledContent(UIText.finderMode, value: UIText.fileProvider)
            }
            Picker(UIText.server, selection: serverBinding) {
                if model.serverID(id) == nil { Text(UIText.noServer).tag(String?.none) }
                ForEach(model.servers) { Text(UIText.serverAddress($0)).tag(Optional($0.id.uuidString)) }
                Divider()
                Text(UIText.addServer).tag(Optional(Self.addServerTag))
            }
            Picker(UIText.share, selection: shareBinding) {
                if model.shareID(id) == nil { Text(UIText.noShare).tag(String?.none) }
                ForEach(sharesOnServer, id: \.id) {
                    Text($0.name).tag(Optional($0.id.uuidString))
                }
                Divider()
                Text(UIText.addShare).tag(Optional(Self.addShareTag))
            }
            .disabled(model.serverID(id) == nil)
            if model.draft(id)?.mode != .serverVolume {
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
                        Button(UIText.select) { model.selectFolder(id) }.disabled(model.shareID(id) == nil)
                    }
                }
                TextField(UIText.name, text: binding(model.nameText, model.setName))
                    .focused($focus, equals: .name)
                    .onSubmit(submit)
            }
        } header: {
            Text(UIText.source)
        } footer: {
            Text(model.draft(id)?.mode == .serverVolume ? UIText.nativeVolumeHint : UIText.locationFinderHint)
                .foregroundStyle(.secondary)
        }
    }

    private func keepSection(_ record: LocationRecord) -> some View {
        Section {
            let rows = model.keepRows[record.id] ?? []
            ForEach(rows) { row in
                HStack {
                    Label(row.path.isEmpty ? record.name : row.path,
                          systemImage: row.kind == .folder ? "folder" : "doc")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(model.keepStatus(row)).foregroundStyle(.secondary)
                    Button { model.removeKeep(row, in: record.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(UIText.removeItem)
                        .accessibilityLabel(UIText.removeItem)
                }
            }
        } header: {
            Text(UIText.keepDownloaded)
        } footer: {
            Text((model.keepRows[record.id] ?? []).contains { $0.availability == .notSufficientSpace }
                 ? UIText.lowSpaceHint : UIText.keepHint).foregroundStyle(.secondary)
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
                    .disabled(model.shareID(id) == nil || !model.isReady || model.busy.contains(id))
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

    private var sharesOnServer: [ShareRecord] {
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
        Binding { model.shareID(id)?.uuidString } set: { key in
            if key == Self.addShareTag {
                model.addShare(for: id)
            } else if let key, let shareID = UUID(uuidString: key) {
                model.setShare(id, shareID)
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

    var body: some View {
        Form {
            if model.canStartFresh {
                Section {
                    Label(UIText.settingsUnreadable, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button(UIText.startFreshMenu, role: .destructive, action: model.confirmStartFresh)
                }
            }
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
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text(UIText.event)
                        Text(UIText.notification).gridColumnAlignment(.center)
                        Text(UIText.panel).gridColumnAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    ForEach(NotificationKind.allCases, id: \.self) { kind in
                        GridRow {
                            Text(UIText.notificationName(kind)).frame(maxWidth: .infinity, alignment: .leading)
                            RouteSwitch(key: kind.notifyKey, defaultValue: kind.needsAction,
                                        label: UIText.notifyLabel(kind))
                            RouteSwitch(key: kind.panelKey, defaultValue: true, label: UIText.panelLabel(kind))
                        }
                    }
                }
            } header: {
                Text(UIText.notifications)
            } footer: {
                VStack(alignment: .leading) {
                    Text(UIText.notificationsDescription)
                    if !showMenuBar { Text(UIText.menuBarOffNote) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refreshLoginStatus)
    }
}

/// One cell of the Notifications grid; the key's default is `NotificationKind.route(in:)`'s.
private struct RouteSwitch: View {
    @AppStorage private var isOn: Bool
    let label: String

    init(key: String, defaultValue: Bool, label: String) {
        _isOn = AppStorage(wrappedValue: defaultValue, key)
        self.label = label
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// Storage: the disk space of each location's downloaded files, then the total.
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
                if let preferences = SharedContainer.preferences {
                    ReserveSetting(preferences: preferences)
                }
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

private struct ReserveSetting: View {
    @AppStorage private var savedGB: Int
    @State private var text = ""

    init(preferences: UserDefaults) {
        _savedGB = AppStorage(wrappedValue: DownloadSpace.defaultReserveGB,
                              SharedContainer.reserveKey, store: preferences)
    }

    private var enteredGB: Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              DownloadSpace.reserveBytes(gigabytes: value) != nil else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent {
                TextField(UIText.reserveLabel, text: $text)
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                    .onSubmit(apply)
                Text(UIText.gigabytes)
                Button(UIText.apply, action: apply).disabled(enteredGB == nil || enteredGB == savedGB)
            } label: {
                Text(UIText.reserveLabel)
            }
            if enteredGB == nil {
                Text(UIText.reserveInvalid).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = String(savedGB) }
    }

    private func apply() {
        guard let enteredGB else { return }
        savedGB = enteredGB
        text = String(enteredGB)
    }
}

/// Saved shares, by server. Locations add shares; this pane only
/// shows them and forgets the ones that no location uses.
private struct ServersPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(UIText.serversDescription).foregroundStyle(.secondary)
                    // An eject can take several seconds.
                    if model.connectionBusy { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            if model.servers.isEmpty {
                Section { Text(UIText.noServers).foregroundStyle(.secondary) }
            }
            ForEach(model.servers) { server in
                Section(UIText.serverAddress(server)) {
                    serverRow(server)
                    let shares = model.shares.filter { $0.serverID == server.id }
                    if shares.isEmpty { Text(UIText.noShares).foregroundStyle(.secondary) }
                    ForEach(shares, id: \.id) { share in shareRow(share) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.connectionBusy || !model.isReady)
    }

    private func serverRow(_ server: ServerRecord) -> some View {
        let used = model.isServerUsed(server.id)
        return HStack {
            if model.needsSignIn(server.id) {
                Label(UIText.signInAgainShort, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Spacer()
                Button(UIText.signInAgain) { model.signInAgain(serverID: server.id) }
            } else {
                Text(UIText.passwordSaved).foregroundStyle(.secondary)
                Spacer()
            }
            Button(UIText.forget) { model.forgetServer(server.id) }
                .disabled(used)
                .help(used ? UIText.forgetServerUsedHelp : "")
        }
    }

    private func shareRow(_ share: ShareRecord) -> some View {
        let names = model.locationNames(using: share.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(share.name)
                Text(names.isEmpty ? UIText.notUsed : UIText.usedBy(names))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Text(model.shareStatus(share)).foregroundStyle(.secondary)
            Button(UIText.forget) { model.forgetShare(share) }
                .disabled(!names.isEmpty)
                .help(names.isEmpty ? "" : UIText.forgetUsedHelp)
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


private struct UploadStatus: View {
    let record: LocationRecord
    @Bindable var model: AppModel
    @State private var count: Int?
    @State private var renames: [RenameIntent] = []
    @State private var creates: [PendingCreate] = []
    @State private var recoveries: [ReimportRecovery] = []
    @State private var systemPending = SystemPendingChanges()
    @State private var systemUnavailable = false
    @State private var savedBytes: Int64 = 0
    @State private var statusUnavailable = false

    var body: some View {
        VStack(alignment: .leading) {
            if statusUnavailable || systemUnavailable {
                Label(UIText.pendingStatusUnavailable, systemImage: "exclamationmark.triangle")
            }
            if let count, count > 0 {
                Label(UIText.pendingUploads(count), systemImage: "arrow.up.circle")
                Text(UIText.pendingUploadHint).font(.callout).foregroundStyle(.secondary)
            }
            if count ?? 0 > 0 || !creates.isEmpty || !systemPending.items.isEmpty || !recoveries.isEmpty {
                Button(UIText.retryPending) { model.retryPending(record) }
            }
            if systemPending.incomplete {
                Text(UIText.systemPendingIncomplete).foregroundStyle(.secondary)
            }
            ForEach(recoveries) { item in
                VStack(alignment: .leading) {
                    Label(UIText.reimportRecovery(item.path), systemImage: "exclamationmark.triangle")
                    Text(SourceReaderBridge.reimportRecoveryDescription)
                        .font(.callout).foregroundStyle(.secondary)
                    Button(UIText.showRecoveryLocation) { model.showInFinder(record.id) }
                }
            }
            ForEach(systemPending.items) { item in
                VStack(alignment: .leading) {
                    Text(UIText.systemPending(item.change.path))
                    Text(UIText.systemPendingReason(item.error))
                        .font(.callout).foregroundStyle(.secondary)
                    if let path = item.change.originalPath {
                        Text(UIText.pendingOriginalPath(path))
                        Text(UIText.pendingOrganizationUndo).font(.callout).foregroundStyle(.secondary)
                    }
                    Button(UIText.showInFinder) { model.showPendingInFinder(item, record: record) }
                }
            }
            if savedBytes > 0 {
                Text(UIText.savedChangeBytes(savedBytes))
                Text(UIText.savedChangeSpace).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(creates) { item in
                VStack(alignment: .leading) {
                    Text(item.kind == .folder ? UIText.newFolderPending(item.path) : UIText.newFilePending(item.path))
                    Text(item.failure.map { UIText.createFailed($0.reason, at: $0.date) } ?? UIText.waitingToUpload)
                        .font(.callout).foregroundStyle(.secondary)
                    if item.stoppable {
                        Button(UIText.stopUploading) { model.confirmStop(item, record: record) }
                    }
                }
            }
            ForEach(renames, id: \.id) { rename in
                VStack(alignment: .leading) {
                    Text(UIText.renameDescription(rename))
                    Text(UIText.renameNeedsRecovery).font(.callout).foregroundStyle(.secondary)
                }
            }
            DeletionStatusList(record: record, model: model)
        }
        .task(id: record.domainID) {
            while !Task.isCancelled {
                do {
                    systemPending = try await model.systemPendingChanges(record)
                    systemUnavailable = false
                } catch { systemUnavailable = true }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: record.domainID) {
            while !Task.isCancelled {
                do {
                    count = try await model.pendingUploads(record)
                    renames = try await model.renameRecords(record)
                    creates = try await model.pendingCreates(record)
                    recoveries = try await model.reimportRecoveries(record)
                    savedBytes = try await model.savedChangeBytes(record)
                    statusUnavailable = false
                } catch {
                    statusUnavailable = true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

}

private struct DeletionStatusList: View {
    let record: LocationRecord
    @Bindable var model: AppModel
    @State private var deletions: [DeletionStatus] = []
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if unavailable {
                Label(UIText.deletionStatusUnavailable, systemImage: "exclamationmark.triangle")
            }
            if !deletions.isEmpty {
                Text(UIText.deletionEffect).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(deletions) { deletion in
                DeletionStatusRow(deletion: deletion, record: record, model: model)
                    .disabled(unavailable)
            }
        }
        .task(id: record.domainID) {
            while !Task.isCancelled {
                do {
                    deletions = try await model.deletionRecords(record)
                    unavailable = false
                } catch { unavailable = true }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct DeletionStatusRow: View {
    let deletion: DeletionStatus
    let record: LocationRecord
    @Bindable var model: AppModel
    @State private var busy = false
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(UIText.deletionPending(deletion.path))
            Text(UIText.deletionSummary(deletion.record))
            if deletion.record.hasUnconfirmed || deletion.items.contains(where: \.mayHaveBeenRequested) {
                Text(UIText.deletionUnconfirmed).foregroundStyle(.secondary)
            }
            if let attempt = deletion.attempt, let failure = attempt.failure {
                Text(UIText.deletionFailed(failure, at: attempt.date)).font(.callout).foregroundStyle(.secondary)
            } else if !deletion.record.isComplete {
                Text(deletion.record.isSettled ? UIText.deletionSettlement
                     : deletion.attempt?.active == true ? UIText.deletionActive : UIText.deletionWaiting)
                    .font(.callout).foregroundStyle(.secondary)
            } else if deletion.record.selectedOutcome != .deleted, let selected = deletion.items.last {
                Text(UIText.deletionItemStatus(selected)).font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup(UIText.deletionDetails) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(deletion.items) { item in
                            VStack(alignment: .leading) {
                                Text(item.path)
                                Text(UIText.deletionItemStatus(item)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxHeight: 240)
            }
            HStack {
                if deletion.canRetry {
                    Button(UIText.deletionRetry) { run { await model.retryDeletion(deletion, record: record) } }
                        .disabled(busy)
                }
                if !deletion.record.isSettled {
                    Button(UIText.stopDeleting) {
                        stopping = true
                        Task { @MainActor in
                            defer { stopping = false }
                            await model.confirmStopDeletion(deletion, record: record)
                        }
                    }.disabled(stopping)
                }
                if deletion.record.canDismiss {
                    Button(UIText.dismissEditNotice) { run { await model.confirmDismissDeletion(deletion, record: record) } }
                        .disabled(busy)
                }
            }
            if deletion.canRetry {
                Text(UIText.deletionRetryHint).font(.callout).foregroundStyle(.secondary)
            } else if deletion.record.isComplete, deletion.record.selectedOutcome != .deleted,
                      deletion.record.selectedOutcome != .unconfirmed {
                Text(UIText.deletionNewRequestHint).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await action()
        }
    }
}
