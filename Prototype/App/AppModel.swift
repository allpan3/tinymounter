import AppKit
import FileProvider
import Observation
import OSLog
import ServiceManagement

/// The state of the Settings window and the menu bar item (docs/ui-design.md).
@MainActor
@Observable
final class AppModel {
    enum Pane: Hashable {
        /// A record or a draft, by its ID.
        case location(UUID)
        case general, storage, servers, about
    }

    /// A location before Add. Finder does not show it.
    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var serverID: UUID?
        var shareID: UUID?
        var folder: String
        var name: String
        var readOnly = false
        var mode: LocationMode = .fileProvider
        /// The name follows the folder until the user types one.
        var nameEdited = false
        /// The location that it copies, or nil for New Location.
        var original: UUID?
    }

    /// A source change that waits for Apply.
    struct SourceEdit: Equatable {
        var shareID: UUID
        var folder: String
    }

    struct KeepRow: Identifiable, Equatable {
        enum Target: Equatable {
            case item(String)
            /// A saved path from the share root that the location hasn't found.
            case saved(KeepPath)
        }

        let target: Target
        /// Below the location folder.
        let path: String
        let kind: CatalogRow.Kind
        let notOnServer: Bool
        var availability: OfflineState = .requested

        var id: String {
            switch target {
            case .item(let id): "item:" + id
            case .saved(let path): "saved:\(path.kind.rawValue):" + path.path
            }
        }
    }

    /// What reloads a location's Keep Downloaded rows.
    struct KeepKey: Hashable {
        let domainID: String
        let unavailable: Bool
        let pending: [KeepPath]
        let missing: Set<KeepPath>
        let revision: Int
        let materialized: Int
        let downloading: Bool
    }

    enum LocationState: Equatable {
        case starting, removing, catalogUnavailable, turnedOff, needsSignIn, notConnected, unresponsive
        case folderMissing
        case connected(downloading: Double?)

        var isProblem: Bool {
            switch self {
            case .catalogUnavailable, .turnedOff, .needsSignIn, .notConnected, .unresponsive,
                 .folderMissing: true
            case .starting, .removing, .connected: false
            }
        }
    }

    enum Entry: Identifiable {
        case record(LocationRecord)
        case serverVolume(ServerVolumeRecord, String)
        case draft(Draft)

        var id: UUID {
            switch self {
            case .record(let record): record.id
            case .serverVolume(let volume, _): volume.id
            case .draft(let draft): draft.id
            }
        }

        var name: String {
            switch self {
            case .record(let record): record.name
            case .serverVolume(_, let name): name
            case .draft(let draft): draft.name
            }
        }
    }

    let controller: LocationController
    @ObservationIgnored let activity: ActivityLog
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let credentials = KeychainCredentialStore()
    @ObservationIgnored private let client: any RemoteClient = SMBClient()
    var selection: Pane?
    var searchText = ""
    var drafts: [Draft] = []
    var edits: [UUID: SourceEdit] = [:]
    /// Name text that the user is typing, by record.
    var names: [UUID: String] = [:]
    /// The entry whose Folder field takes focus next.
    var focusFolder: UUID?
    /// Folder completion for the entry whose Folder field has focus.
    private(set) var folderSuggestions: [String] = []
    private(set) var records: [LocationRecord] = []
    private(set) var serverVolumes: [ServerVolumeRecord] = []
    private(set) var servers: [ServerRecord] = []
    private(set) var shares: [ShareRecord] = []
    /// The shares with a Server Volume that macOS has mounted.
    private(set) var mountedVolumes: Set<UUID> = []
    /// Servers without a saved password; they show Sign In Again….
    private(set) var passwordMissing: Set<UUID> = []
    /// Servers that refused the saved password since it was last saved.
    private(set) var refusedServers: Set<UUID> = []
    @ObservationIgnored private var passwordCheck = 0
    var signIn: SignInRequest?
    var folderBrowser: FolderBrowserRequest?
    private(set) var connectionBusy = false
    private(set) var states: [UUID: LocationState] = [:]
    private(set) var shareStates: [UUID: ConnectionState] = [:]
    private(set) var keepRows: [UUID: [KeepRow]] = [:]
    @ObservationIgnored private var keepReloads: [UUID: (key: KeepKey, task: Task<Void, Never>)] = [:]
    /// Kept items verified available offline in this run; nil until a record's first verified check.
    @ObservationIgnored private var keptOffline: [UUID: Set<String>] = [:]
    /// Uploads, by domain and item, with an Upload failed event since their last success.
    @ObservationIgnored private var failedUploads: Set<String> = []
    /// For the menu bar panel; the reader host updates it at most twice a second.
    private(set) var transfers: [ActiveTransfer] = []
    private(set) var notOnServer: [UUID: Set<KeepPath>] = [:]
    private(set) var keepRevision: [UUID: Int] = [:]
    @ObservationIgnored private var keepGeneration: [UUID: Int] = [:]
    /// Each location's downloaded files, by record; absent until read, or if they can't be read.
    private(set) var storage: [UUID: StorageUsage] = [:]
    /// The space that the home volume has for downloads.
    private(set) var availableBytes: Int64?
    @ObservationIgnored private var storageGeneration = 0
    /// Counts changes of the system's downloaded files; Storage reads again at each.
    private(set) var materializedRevision = 0
    /// Records and drafts with an action that runs.
    private(set) var busy: Set<UUID> = []
    private(set) var paused = false
    private(set) var isReady = false
    private(set) var problem: String?
    /// The settings are unreadable, so General offers Start Fresh.
    private(set) var canStartFresh = false
    private(set) var loginStatus = SMAppService.mainApp.status
    /// The Settings window, for sheets; its view sets it.
    @ObservationIgnored weak var window: NSWindow? {
        didSet { deletionConfirmation?.show(in: window) }
    }
    @ObservationIgnored private var deletionConfirmation: PermanentDeletionConfirmation?
    /// Opens the Settings window; the window and the menu bar item set it when they show.
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored private static let log = Logger(subsystem: "dev.tinymounter.prototype", category: "catalog")

    init() {
        store = SettingsStore()
        let activity = ActivityLog()
        self.activity = activity
        notifier = Notifier(activity: activity)
        controller = LocationController(store: store)
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onShareState = { [weak self] shareID, before, state in self?.shareChanged(shareID, before, state) }
        controller.onActivity = { [weak self] domainID, activity in self?.readerActivity(domainID, activity) }
        controller.onTransfers = { [weak self] in self?.update(\.transfers, $0) }
        controller.onLowSpace = { [weak self] domainID, name in self?.lowSpace(domainID, name) }
        controller.onVolumeSignInRefused = { [weak self] shareID in self?.volumeSignInRefused(shareID) }
        controller.onKeepsRestored = { [weak self] record, ids in self?.keepsRestored(record, ids) }
        controller.onLocationChange = { [weak self] domainID in self?.locationChanged(domainID) }
        controller.onMaterializedChange = { [weak self] in self?.materializedRevision += 1 }
        controller.onPreserved = { [weak self] url in self?.showPreserved(url) }
        controller.onConfirmDeletion = { [weak self] selection, progress in
            await self?.confirmPermanentDeletion(selection, progress: progress) ?? false
        }
        refresh()
        watchKeeps()
        if let first = entries.first { selection = .location(first.id) } else { newLocation() }
        Task { await controller.launch() }
    }

    var hasLocations: Bool { !records.isEmpty || !serverVolumes.isEmpty }

    /// Records and drafts in order: each draft below the location that it copies.
    var entries: [Entry] {
        var list: [Entry] = []
        for record in records {
            list.append(.record(record))
            list += drafts.filter { $0.original == record.id }.map(Entry.draft)
        }
        list += serverVolumes.map { .serverVolume($0, volumeName($0)) }
        list += drafts.filter { draft in !records.contains { $0.id == draft.original } }.map(Entry.draft)
        let search = searchText.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? list : list.filter { $0.name.localizedStandardContains(search) }
    }

    func record(_ id: UUID) -> LocationRecord? { records.first { $0.id == id } }

    func draft(_ id: UUID) -> Draft? { drafts.first { $0.id == id } }

    func share(_ id: UUID?) -> ShareRecord? { shares.first { $0.id == id } }

    /// The share's server sign-in and name.
    func address(_ id: UUID?) -> ShareAddress? {
        guard let share = share(id), let server = servers.first(where: { $0.id == share.serverID }) else { return nil }
        return ShareAddress(server.login, share: share.name)
    }

    var selectedRecord: LocationRecord? {
        guard case .location(let id) = selection else { return nil }
        return record(id)
    }

    // MARK: State and text

    func state(_ record: LocationRecord) -> LocationState { states[record.id] ?? .starting }

    func statusText(_ record: LocationRecord) -> String {
        let host = address(record.shareID)?.host ?? ""
        return switch state(record) {
        case .starting: UIText.notConnected
        case .removing: UIText.removalNotComplete
        case .catalogUnavailable: UIText.catalogUnavailable
        case .turnedOff: UIText.turnedOff
        case .needsSignIn: UIText.signInAgainShort
        case .notConnected: UIText.clickConnect
        case .unresponsive: UIText.cannotConnect(host)
        case .folderMissing: UIText.folderNotOnShare
        case .connected(let fraction?): UIText.joined(UIText.connected, UIText.downloaded(fraction))
        case .connected(nil): UIText.connected
        }
    }

    /// A short state for the menu bar and VoiceOver.
    func shortStatus(_ record: LocationRecord) -> String {
        switch state(record) {
        case .connected(let fraction?): UIText.downloaded(fraction)
        case .connected(nil): UIText.connected
        case .starting, .notConnected, .unresponsive: UIText.notConnected
        case .removing: UIText.removalNotComplete
        case .catalogUnavailable, .turnedOff, .needsSignIn, .folderMissing: UIText.problem
        }
    }

    func symbol(_ record: LocationRecord) -> String {
        switch state(record) {
        case .connected(.some): "arrow.down.circle"
        case .connected(nil): "checkmark.circle"
        case .starting, .notConnected, .unresponsive: "bolt.horizontal.circle"
        case .removing: "trash.circle"
        case .catalogUnavailable, .turnedOff, .needsSignIn, .folderMissing: "exclamationmark.triangle"
        }
    }

    var menuImageName: String {
        let all = records.map(state)
        if all.contains(where: \.isProblem)
            || serverVolumes.contains(where: { !mountedVolumes.contains($0.shareID) }) { return "MenuBarProblem" }
        if all.contains(where: { if case .connected(.some) = $0 { true } else { false } }) { return "MenuBarDownloading" }
        return "MenuBarDrive"
    }

    /// A Server Volume's share is mounted or not; a location's share has its connection state.
    func shareStatus(_ share: ShareRecord) -> String {
        if serverVolumes.contains(where: { $0.shareID == share.id }) {
            return mountedVolumes.contains(share.id) ? UIText.mounted : UIText.notMounted
        }
        return switch shareStates[share.id] ?? .notConnected {
        case .connected: UIText.connected
        case .notConnected: UIText.notConnected
        case .unresponsive: UIText.notResponding
        case .needsSignIn: UIText.signInAgainShort
        }
    }

    func sourceText(_ record: LocationRecord) -> String {
        UIText.source(host: address(record.shareID)?.host ?? "", share: share(record.shareID)?.name ?? "",
                      folder: record.folder)
    }

    var isDownloading: Bool { !controller.downloading.isEmpty }

    // MARK: Source fields

    func shareID(_ id: UUID) -> UUID? {
        if let draft = draft(id) { return draft.shareID }
        return edits[id]?.shareID ?? record(id)?.shareID ?? serverVolume(id)?.shareID
    }

    func folderText(_ id: UUID) -> String {
        if let draft = draft(id) { return draft.folder }
        return edits[id]?.folder ?? record(id)?.folder ?? ""
    }

    func nameText(_ id: UUID) -> String {
        if let draft = draft(id) { return draft.name }
        return names[id] ?? record(id)?.name ?? ""
    }

    func serverID(_ id: UUID) -> UUID? {
        draft(id)?.serverID ?? share(shareID(id))?.serverID
    }

    func setServer(_ id: UUID, _ serverID: UUID) {
        let available = shares.first { $0.serverID == serverID }
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].serverID = serverID
            drafts[index].shareID = available?.id
            followFolder(index)
        } else if let available {
            setShare(id, available.id)
        } else {
            guard !connectionBusy else { return }
            connectionBusy = true
            Task {
                defer { connectionBusy = false }
                if let shareID = await acquireShare(serverID) { setShare(id, shareID) }
            }
        }
    }

    func setShare(_ id: UUID, _ shareID: UUID) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].serverID = share(shareID)?.serverID
            guard drafts[index].shareID != shareID else { return }
            drafts[index].shareID = shareID
            followFolder(index)
        } else if let record = record(id) {
            setEdit(record, SourceEdit(shareID: shareID, folder: folderText(id)))
        }
    }

    func setFolder(_ id: UUID, _ text: String) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            // A field that takes focus writes its text again; only a change makes the name follow.
            guard drafts[index].folder != text else { return }
            drafts[index].folder = text
            followFolder(index)
        } else if let record = record(id) {
            setEdit(record, SourceEdit(shareID: shareID(id) ?? record.shareID, folder: text))
        }
    }

    func setName(_ id: UUID, _ text: String) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].name = text
            drafts[index].nameEdited = !text.isEmpty
            if text.isEmpty { followFolder(index) }
        } else {
            names[id] = text
        }
    }

    func hasEdit(_ id: UUID) -> Bool { edits[id] != nil }

    /// The subfolders of the typed folder; the view calls it 150 ms after the last change.
    func suggestFolders(_ id: UUID) async {
        guard let shareID = shareID(id) else { return update(\.folderSuggestions, []) }
        let suggestions = await controller.folderSuggestions(shareID: shareID, typed: folderText(id))
        if !Task.isCancelled { update(\.folderSuggestions, suggestions) }
    }

    func endFolderCompletion() {
        update(\.folderSuggestions, [])
        controller.endFolderCompletion()
    }

    private func setEdit(_ record: LocationRecord, _ edit: SourceEdit) {
        let folder = LocationRecord.normalizedFolder(edit.folder)?.string
        edits[record.id] = edit.shareID == record.shareID && folder == record.folder ? nil : edit
    }

    private func followFolder(_ index: Int) {
        guard !drafts[index].nameEdited else { return }
        drafts[index].name = defaultName(shareID: drafts[index].shareID, folder: drafts[index].folder)
    }

    /// The last folder name, or the share's name for the full share.
    private func defaultName(shareID: UUID?, folder: String) -> String {
        if let folder = LocationRecord.normalizedFolder(folder), let last = folder.components.last { return last }
        return share(shareID)?.name ?? ""
    }

    /// The saved paths that Add would take, below the draft's folder.
    func savedKeeps(_ draft: Draft) -> [String] {
        guard let address = address(draft.shareID), let folder = LocationRecord.normalizedFolder(draft.folder),
              let settings = store.settings else { return [] }
        return settings.savedKeeps(host: address.host, share: address.share, inside: folder)
            .map { ($0.below(folder)?.string ?? $0.path) + ($0.kind == .folder ? "/" : "") }
    }

    // MARK: Sidebar actions

    func newLocation() {
        let server = servers.first
        let share = shares.first { $0.serverID == server?.id }
        let draft = Draft(serverID: server?.id, shareID: share?.id, folder: "", name: share?.name ?? "", original: nil)
        drafts.append(draft)
        select(draft.id)
    }

    /// Design §4.2: a copy below the original, without its Keep Downloaded requests.
    func duplicate(_ recordID: UUID) {
        guard let record = record(recordID) else { return }
        let taken = records.map(\.name) + drafts.map(\.name)
        let draft = Draft(serverID: share(record.shareID)?.serverID, shareID: record.shareID, folder: record.folder,
                          name: LocationRecord.copyName(record.name, among: taken), readOnly: record.readOnly,
                          original: record.id)
        drafts.insert(draft, at: 0)
        select(draft.id)
    }

    func cancel(_ draftID: UUID) {
        guard !connectionBusy, let draft = draft(draftID), !busy.contains(draftID) else { return }
        drafts.removeAll { $0.id == draftID }
        guard selection == .location(draftID) else { return }
        if let original = draft.original, record(original) != nil {
            selection = .location(original)
        } else {
            selection = entries.first.map { .location($0.id) } ?? .general
        }
    }

    /// The sidebar's `−`: Cancel for a draft, Remove Location… for a record.
    func removeSelected() {
        guard case .location(let id) = selection else { return }
        if draft(id) != nil { cancel(id) } else { confirmRemove(id) }
    }

    private func select(_ id: UUID) {
        selection = .location(id)
        focusFolder = id
    }

    // MARK: Location actions

    func add(_ draftID: UUID) {
        guard !connectionBusy, let draft = draft(draftID), !busy.contains(draftID) else { return }
        guard let shareID = draft.shareID else { return }
        do { try store.settings?.requireMode(draft.mode, for: shareID) }
        catch { return show(error, shareID: shareID) }
        if draft.mode == .serverVolume { return addServerVolume(draft) }
        guard let folder = LocationRecord.normalizedFolder(draft.folder) else { return show(UIText.wrongFolderPath) }
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? defaultName(shareID: shareID, folder: draft.folder) : typed
        guard RelativePath.isValidComponent(name) else { return show(UIText.wrongName) }
        busy.insert(draftID)
        Task {
            defer { busy.remove(draftID) }
            do {
                // The record keeps the draft's ID, and its selection, from the moment it is saved.
                _ = try await controller.add(id: draftID, name: name, folder: folder, shareID: shareID,
                                             after: draft.original, readOnly: draft.readOnly)
                notifier.requestPermission()
                await controller.restorePendingKeeps(draftID)
            } catch {
                show(error, shareID: shareID)
            }
        }
    }

    /// Return or focus loss in Name: a unique name, at once.
    func commitName(_ recordID: UUID) {
        guard let typed = names[recordID], let record = record(recordID) else { return }
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != record.name else {
            names[recordID] = nil
            return
        }
        guard RelativePath.isValidComponent(name) else { return show(UIText.wrongName) }
        Task {
            do {
                _ = try await controller.rename(recordID, to: name)
                names[recordID] = nil
            } catch {
                names[recordID] = nil
                show(error, shareID: record.shareID)
            }
        }
    }

    func revert(_ recordID: UUID) {
        if !busy.contains(recordID) { edits[recordID] = nil }
    }

    func confirmApply(_ recordID: UUID) {
        guard let record = record(recordID), let edit = edits[recordID], !busy.contains(recordID) else { return }
        guard let folder = LocationRecord.normalizedFolder(edit.folder) else { return show(UIText.wrongFolderPath) }
        let alert = NSAlert()
        alert.messageText = UIText.applyTitle(record.name)
        alert.informativeText = UIText.applyBar
        alert.addButton(withTitle: UIText.apply)
        alert.addButton(withTitle: UIText.cancel)
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            busy.insert(recordID)
            defer { busy.remove(recordID) }
            do {
                _ = try await controller.apply(recordID, shareID: edit.shareID, folder: folder)
                edits[recordID] = nil
                await controller.restorePendingKeeps(recordID)
            } catch {
                // A failure after the record changed leaves the domain for the next launch to add.
                if let changed = self.record(recordID), changed.shareID == edit.shareID, changed.folder == folder.string {
                    edits[recordID] = nil
                }
                show(error, shareID: edit.shareID)
            }
        }
    }

    func confirmStartFresh() {
        guard canStartFresh else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UIText.startFreshTitle
        alert.informativeText = UIText.startFreshMessage
        alert.addButton(withTitle: UIText.startFresh).hasDestructiveAction = true
        alert.addButton(withTitle: UIText.cancel)
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            do {
                let preserved = try await controller.startFresh()
                if !preserved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(preserved) }
            } catch {
                show(error, shareID: nil)
            }
        }
    }

    func confirmRemove(_ recordID: UUID) {
        if let volume = serverVolume(recordID) { return confirmRemoveServerVolume(volume) }
        guard let record = record(recordID), !busy.contains(recordID) else { return }
        Task {
            // Unreadable records leave the decision to the removal, which checks them again.
            let items = (try? await controller.removalItems(record)) ?? RemovalItems()
            guard items.blocking.isEmpty else {
                let blocked = NSAlert()
                blocked.messageText = UIText.removeBlockedTitle(record.name)
                blocked.informativeText = UIText.removeBlockedMessage(items.blocking)
                _ = await present(blocked)
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = UIText.removeTitle(record.name)
            alert.informativeText = items.stoppable.isEmpty ? UIText.removeMessage
                : UIText.removeMessage + "\n\n" + UIText.removeStops(items.stoppable)
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = UIText.saveKeepList
            alert.suppressionButton?.state = .on
            alert.addButton(withTitle: UIText.removeLocation).hasDestructiveAction = true
            alert.addButton(withTitle: UIText.cancel)
            guard await present(alert) == .alertFirstButtonReturn else { return }
            let save = alert.suppressionButton?.state == .on
            busy.insert(recordID)
            defer { busy.remove(recordID) }
            do {
                try await controller.remove(recordID, saveKeeps: save, stopping: items.stoppable)
                for index in drafts.indices where drafts[index].original == recordID { drafts[index].original = nil }
                edits[recordID] = nil
                names[recordID] = nil
                if selection == .location(recordID) {
                    selection = entries.first.map { .location($0.id) } ?? .general
                }
            } catch {
                show(error, shareID: record.shareID)
            }
        }
    }

    /// macOS can return a folder with nothing in it; an unreadable folder is shown.
    private func showPreserved(_ url: URL) {
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path), contents.isEmpty { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setReadOnly(_ id: UUID, _ readOnly: Bool) {
        guard !busy.contains(id) else { return }
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].readOnly = readOnly
            return
        }
        guard let record = record(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do { try await controller.setWriteMode(id, readOnly: readOnly) }
            catch { show(error, shareID: record.shareID) }
        }
    }

    func savedChangeBytes(_ record: LocationRecord) async throws -> Int64 { try await controller.savedChangeBytes(record) }

    func retryPending(_ record: LocationRecord) { controller.retryPending(record) }

    func pendingCreates(_ record: LocationRecord) async throws -> [PendingCreate] {
        try await controller.pendingCreates(record)
    }

    func systemPendingChanges(_ record: LocationRecord) async throws -> SystemPendingChanges {
        try await controller.systemPendingChanges(record)
    }

    func showPendingInFinder(_ item: SystemPendingChange, record: LocationRecord) {
        guard let manager = controller.manager(for: record) else { return show(UIText.cannotShow) }
        Task {
            do {
                let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(item.id))
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { show(UIText.cannotShow) }
        }
    }

    func deletionRecords(_ record: LocationRecord) async throws -> [DeletionStatus] {
        try await controller.deletionRecords(record)
    }

    func retryDeletion(_ deletion: DeletionStatus, record: LocationRecord) async {
        do { try await controller.retryDeletion(record, id: deletion.id) }
        catch { show(UIText.deletionFailure(DeletionFailure.classify(error))) }
    }

    func confirmStopDeletion(_ deletion: DeletionStatus, record: LocationRecord) async {
        let alert = NSAlert()
        alert.messageText = UIText.stopDeletingTitle(deletion.path)
        alert.informativeText = UIText.stopDeletingMessage
        alert.addButton(withTitle: UIText.stopDeleting)
        alert.addButton(withTitle: UIText.cancel)
        guard await present(alert) == .alertFirstButtonReturn else { return }
        do { try await controller.stopDeletion(record, id: deletion.id) }
        catch { show(UIText.deletionFailure(DeletionFailure.classify(error))) }
    }

    func confirmDismissDeletion(_ deletion: DeletionStatus, record: LocationRecord) async {
        let alert = NSAlert()
        alert.messageText = UIText.dismissDeletionTitle
        alert.informativeText = UIText.dismissDeletionMessage
        alert.addButton(withTitle: UIText.dismissEditNotice)
        alert.addButton(withTitle: UIText.cancel)
        guard await present(alert) == .alertFirstButtonReturn else { return }
        do { try await controller.dismissDeletion(record, id: deletion.id) }
        catch { show(UIText.deletionFailure(DeletionFailure.classify(error))) }
    }

    func confirmStop(_ item: PendingCreate, record: LocationRecord) {
        let alert = NSAlert()
        alert.messageText = UIText.stopUploadingTitle(item.path)
        alert.informativeText = UIText.stopUploadingMessage(item.kind)
        alert.addButton(withTitle: UIText.stopUploading)
        alert.addButton(withTitle: UIText.cancel)
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            do { try await controller.stopCreate(record, template: item.id) }
            catch UploadError.unresolved { show(UIText.stopRefused) }
            catch { show(error, shareID: record.shareID) }
        }
    }

    func renameRecords(_ record: LocationRecord) async throws -> [RenameIntent] {
        try await controller.renameRecords(record)
    }

    func pendingUploads(_ record: LocationRecord) async throws -> Int { try await controller.pendingUploads(record) }

    func showInFinder(_ recordID: UUID) {
        if let volume = serverVolume(recordID) { return showServerVolume(volume) }
        guard let record = record(recordID), let manager = controller.manager(for: record) else {
            return show(UIText.cannotShow)
        }
        Task {
            do {
                let url = try await manager.getUserVisibleURL(for: .rootContainer)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if !NSWorkspace.shared.open(url) { show(UIText.cannotShow) }
            } catch {
                show(UIText.cannotShow)
            }
        }
    }

    func serverVolume(_ id: UUID) -> ServerVolumeRecord? { serverVolumes.first { $0.id == id } }

    func volumeName(_ volume: ServerVolumeRecord) -> String { share(volume.shareID)?.name ?? UIText.serverVolume }

    func volumeStatus(_ volume: ServerVolumeRecord) -> String {
        mountedVolumes.contains(volume.shareID) ? UIText.mounted : UIText.notMounted
    }

    func setMode(_ id: UUID, _ mode: LocationMode) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].mode = mode
        if mode == .serverVolume {
            drafts[index].folder = ""
            followFolder(index)
        }
    }

    private func addServerVolume(_ draft: Draft) {
        guard busy.isEmpty, let shareID = draft.shareID else { return }
        busy.insert(draft.id)
        Task {
            defer { busy.remove(draft.id) }
            guard await mountVolume(shareID) else { return }
            do { try controller.addServerVolume(id: draft.id, shareID: shareID) }
            catch { show(error, shareID: shareID) }
        }
    }

    private func showServerVolume(_ volume: ServerVolumeRecord) {
        guard !connectionBusy else { return }
        Task {
            if controller.volumePath(volume.shareID) == nil {
                guard await mountVolume(volume.shareID) else { return }
            }
            // The sandbox can't open the mount point; Finder opens the mounted share for its URL.
            guard let url = controller.volumeURL(volume.shareID), NSWorkspace.shared.open(url) else {
                return show(UIText.cannotShow)
            }
        }
    }

    private func confirmRemoveServerVolume(_ volume: ServerVolumeRecord) {
        guard !connectionBusy, !busy.contains(volume.id) else { return }
        let alert = NSAlert()
        alert.messageText = UIText.removeLocationMenu
        alert.informativeText = UIText.removeServerVolumeHint
        alert.addButton(withTitle: UIText.removeLocation).hasDestructiveAction = true
        alert.addButton(withTitle: UIText.cancel)
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            busy.insert(volume.id)
            connectionBusy = true
            defer { busy.remove(volume.id); connectionBusy = false }
            do {
                try await controller.removeServerVolume(volume.id)
                selection = entries.first.map { .location($0.id) } ?? .general
            } catch { show(error, shareID: volume.shareID) }
        }
    }

    // MARK: Keep Downloaded

    private func keepKey(_ record: LocationRecord) -> KeepKey {
        KeepKey(domainID: record.domainID,
                unavailable: !isReady || record.removing || states[record.id] == .turnedOff
                    || states[record.id] == .catalogUnavailable,
                pending: record.pendingKeeps, missing: notOnServer[record.id] ?? [],
                revision: keepRevision[record.id] ?? 0, materialized: materializedRevision,
                downloading: downloadInProgress(record))
    }

    private func downloadInProgress(_ record: LocationRecord) -> Bool {
        if case .connected(let progress) = states[record.id] { return progress != nil }
        return false
    }

    private func reloadKeeps(_ recordID: UUID) async {
        guard let record = record(recordID) else { return }
        let key = keepKey(record)
        let generation = (keepGeneration[recordID] ?? 0) + 1
        keepGeneration[recordID] = generation
        if key.unavailable {
            keepRows[recordID] = keepRows[recordID]?.map { row in
                var row = row
                row.availability = .requested
                return row
            }
        }
        let kept = await controller.keptPaths(record)
        guard keepGeneration[recordID] == generation, !Task.isCancelled,
              let current = self.record(recordID), keepKey(current) == key else { return }
        let folder = RelativePath(record.folder) ?? .root
        let missing = notOnServer[recordID] ?? []
        let previous = Dictionary(uniqueKeysWithValues: (keepRows[recordID] ?? []).map { ($0.id, $0.availability) })
        keepRows[recordID] = kept.map {
            KeepRow(target: .item($0.id), path: $0.path.string, kind: $0.kind, notOnServer: false,
                    availability: previous["item:" + $0.id] ?? .requested)
        }
            + record.pendingKeeps.map { path in
                KeepRow(target: .saved(path), path: path.below(folder)?.string ?? path.path,
                        kind: path.kind, notOnServer: missing.contains(path))
            }
        let verified = await controller.offlineStates(record) { states in
            guard self.keepGeneration[recordID] == generation, !Task.isCancelled,
                  let current = self.record(recordID), self.keepKey(current) == key else { return }
            self.keepRows[recordID] = self.keepRows[recordID]?.map { row in
                var row = row
                if case .item(let id) = row.target { row.availability = states[id] ?? .requested }
                return row
            }
        }
        if verified, !key.unavailable, keepGeneration[recordID] == generation, !Task.isCancelled {
            reportKeptOffline(record)
        }
    }

    /// Every location's Keep Downloaded rows stay current, so a finished keep shows in the panel.
    private func watchKeeps() {
        let keys = withObservationTracking {
            Dictionary(uniqueKeysWithValues: records.map { ($0.id, keepKey($0)) })
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchKeeps() }
        }
        for (id, reload) in keepReloads where keys[id] == nil {
            reload.task.cancel()
            keepReloads[id] = nil
            keptOffline[id] = nil
        }
        for (id, key) in keys where keepReloads[id]?.key != key {
            keepReloads[id]?.task.cancel()
            keepReloads[id] = (key, Task { await reloadKeeps(id) })
        }
    }

    /// The first verified check after launch is the baseline: a kept item reports when it becomes
    /// available offline after that, or again after an update or a lack of space.
    private func reportKeptOffline(_ record: LocationRecord) {
        let rows = (keepRows[record.id] ?? []).filter { if case .item = $0.target { true } else { false } }
        let offline = Set(rows.filter { $0.availability == .availableOffline }.map(\.id))
        let known = keptOffline[record.id]
        let unavailable = Set(rows.filter { [.updateInProgress, .notSufficientSpace].contains($0.availability) }.map(\.id))
        keptOffline[record.id] = (known ?? []).union(offline).intersection(rows.map(\.id)).subtracting(unavailable)
        guard let known else { return }
        for row in rows where offline.contains(row.id) && !known.contains(row.id) {
            let name = (row.path as NSString).lastPathComponent
            notifier.report(ActivityEvent(kind: .keptDownloaded, domain: record.domainID, name: name),
                            title: UIText.keptTitle(name))
        }
    }

    func keepStatus(_ row: KeepRow) -> String {
        guard !row.notOnServer else { return UIText.notOnServer }
        switch row.availability {
        case .requested: return UIText.requested
        case .updateInProgress: return UIText.updateInProgress
        case .availableOffline: return UIText.availableOffline
        case .notSufficientSpace: return UIText.notSufficientSpace
        }
    }

    /// `−` on a request.
    func removeKeep(_ row: KeepRow, in recordID: UUID) {
        guard let record = record(recordID) else { return }
        Task {
            do {
                switch row.target {
                case .item(let id): try await controller.unkeep(id, in: record)
                case .saved(let path): try controller.discardPendingKeep(path, in: recordID)
                }
            } catch {
                show(error, shareID: record.shareID)
            }
        }
    }

    private func keepsRestored(_ record: LocationRecord, _ ids: [String]) {
        Task {
            let waiting = await controller.filesInFoldersNotMaterialized(ids, in: record)
            guard !waiting.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = UIText.downloadTitle(waiting.count)
            alert.informativeText = UIText.downloadMessage(record.name)
            alert.addButton(withTitle: UIText.downloadNow)
            alert.addButton(withTitle: UIText.notNow)
            let download = await present(alert) == .alertFirstButtonReturn
            Self.log.info("""
                restore_prompt domain=\(record.domainID, privacy: .public) files=\(waiting.count) download=\(download)
                """)
            if download { await controller.requestFolders(above: waiting, in: record) }
        }
    }

    private func locationChanged(_ domainID: String) {
        guard let record = records.first(where: { $0.domainID == domainID }) else { return }
        keepRevision[record.id, default: 0] += 1
    }

    // MARK: Storage

    func storageText(_ record: LocationRecord) -> String {
        storage[record.id].map { UIText.downloadedSize($0.bytes) } ?? UIText.notAvailable
    }

    var totalStorageText: String {
        let total = UIText.downloadedSize(records.compactMap { storage[$0.id]?.bytes }.reduce(0, +))
        return availableBytes.map { UIText.joined(total, UIText.availableSize($0)) } ?? total
    }

    /// Reads every location's materialized files; a later read replaces an earlier one.
    func refreshStorage() async {
        storageGeneration += 1
        let generation = storageGeneration
        var read: [UUID: StorageUsage] = [:]
        for record in records where !record.removing {
            read[record.id] = await controller.storage(record)
        }
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard generation == storageGeneration else { return }
        update(\.storage, read)
        update(\.availableBytes, values?.volumeAvailableCapacityForImportantUsage)
    }

    func canRemoveDownloads(_ recordID: UUID) -> Bool {
        !(storage[recordID]?.removable.isEmpty ?? true) && !busy.contains(recordID)
    }

    /// Evicts the downloaded files that are not kept, after a confirmation.
    func confirmRemoveDownloads(_ recordID: UUID) {
        guard let record = record(recordID), canRemoveDownloads(recordID) else { return }
        Task {
            // The count must be current: a file can be kept or evicted after the pane read it.
            guard let usage = await controller.storage(record) else { return show(UIText.cannotRemoveDownloads) }
            storage[recordID] = usage
            guard !usage.removable.isEmpty else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = UIText.removeDownloadsTitle(record.name)
            alert.informativeText = UIText.removeDownloadsMessage(files: usage.removable.count,
                                                                  bytes: usage.removableBytes)
            alert.addButton(withTitle: UIText.removeDownloads).hasDestructiveAction = true
            alert.addButton(withTitle: UIText.cancel)
            guard await present(alert) == .alertFirstButtonReturn else { return }
            busy.insert(recordID)
            let result = await controller.removeDownloads(record)
            busy.remove(recordID)
            await refreshStorage()
            if let result {
                if result.stayed > 0 { show(UIText.downloadsStayed(result.stayed)) }
            } else {
                show(UIText.cannotRemoveDownloads)
            }
        }
    }

    // MARK: Servers

    func addServer(for locationID: UUID) {
        guard !connectionBusy else { return }
        signIn = SignInRequest(purpose: .add(locationID: locationID))
    }

    func signInAgain(serverID: UUID) {
        guard !connectionBusy, let server = servers.first(where: { $0.id == serverID }) else { return }
        signIn = SignInRequest(purpose: .again(server))
    }

    /// No password is saved, or the server refused it for a location or a Server Volume.
    func needsSignIn(_ serverID: UUID) -> Bool {
        passwordMissing.contains(serverID) || refusedServers.contains(serverID)
            || shares.contains { $0.serverID == serverID && shareStates[$0.id] == .needsSignIn }
    }

    /// Sign In: the server checks the password first, so a refusal saves nothing.
    func completeSignIn(_ request: SignInRequest, server text: String, name: String, password: Data) async -> String? {
        guard !connectionBusy else { return UIText.cannotDo("busy") }
        var login: ServerAccount
        var share: String?
        if let fixed = request.fixed {
            login = fixed
        } else {
            guard let address = ServerAddress(typed: text) else { return UIText.wrongAddress }
            let typed = name.trimmingCharacters(in: .whitespaces)
            guard let account = typed.isEmpty ? address.account : typed, !account.isEmpty else { return UIText.typeName }
            login = ServerAccount(remoteProtocol: .smb, host: address.host, account: account)
            if let saved = store.settings?.servers.first(where: { $0.login.matches(login) }) { login = saved.login }
            share = address.share
        }
        connectionBusy = true
        defer { connectionBusy = false }
        let names: [String]
        do {
            names = try await listShares(login, password)
        } catch SourceFailure.notAuthenticated {
            return UIText.signInRefused
        } catch {
            Self.log.error("sign_in \(logFields(error), privacy: .public)")
            return Self.message(for: error, host: login.host)
        }
        let credentials = credentials
        let isNew = store.settings?.servers.contains { $0.login == login } != true
        do {
            try await Task.detached { try credentials.savePassword(password, for: login) }.value
        } catch {
            Self.log.error("save_password \(logFields(error), privacy: .public)")
            return UIText.cannotSavePassword
        }
        let serverID: UUID
        do {
            serverID = try saveServer(login)
        } catch {
            if isNew { try? await Task.detached { try credentials.deletePassword(for: login) }.value }
            Self.log.error("save_server \(logFields(error), privacy: .public)")
            return Self.message(for: error, host: login.host)
        }
        passwordMissing.remove(serverID)
        signIn = nil
        notifier.signedIn(serverID)
        controller.credentialsChanged(serverID)
        guard case .add(let locationID) = request.purpose else { return nil }
        setServer(locationID, serverID)
        if share != nil || self.share(shareID(locationID))?.serverID != serverID,
           let shareID = await chooseShare(serverID, names: names, typed: share) {
            setShare(locationID, shareID)
        }
        return nil
    }

    /// Signs in with the password and returns the share names, off the main actor.
    private func listShares(_ login: ServerAccount, _ password: Data) async throws -> [String] {
        let client = client
        return try await Task.detached { try client.shareNames(on: login, password: password) }.value
    }

    private func saveServer(_ login: ServerAccount) throws -> UUID {
        if let saved = store.settings?.servers.first(where: { $0.login.matches(login) }) { return saved.id }
        let server = ServerRecord(login: login)
        try store.update { $0.servers.append(server) }
        refresh()
        return server.id
    }

    /// Reads only the items' attributes, so it never shows a Keychain prompt.
    private func checkPasswords() {
        passwordCheck += 1
        let check = passwordCheck
        let logins = servers.map { ($0.id, $0.login) }
        let credentials = credentials
        Task {
            let missing = await Task.detached {
                Set(logins.filter { (try? credentials.hasPassword(for: $0.1)) == false }.map(\.0))
            }.value
            if check == passwordCheck { update(\.passwordMissing, missing) }
        }
    }

    /// False if the item remains; the caller then keeps the server.
    private func deletePassword(_ login: ServerAccount) async -> Bool {
        let credentials = credentials
        do {
            try await Task.detached { try credentials.deletePassword(for: login) }.value
            return true
        } catch {
            Self.log.error("delete_password \(logFields(error), privacy: .public)")
            show(UIText.cannotDeletePassword)
            return false
        }
    }

    func addShare(for locationID: UUID) {
        guard !connectionBusy, let serverID = serverID(locationID) else { return }
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            if let shareID = await acquireShare(serverID) { setShare(locationID, shareID) }
        }
    }

    /// Add Share…: the server's share names with the saved password; nothing is mounted.
    private func acquireShare(_ serverID: UUID) async -> UUID? {
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        let credentials = credentials
        let login = server.login
        do {
            guard let password = try await Task.detached(operation: { try credentials.password(for: login) }).value else {
                passwordMissing.insert(serverID)
                show(UIText.signInAgainMessage(login.host))
                return nil
            }
            let names = try await listShares(login, password)
            return await chooseShare(serverID, names: names, typed: nil)
        } catch SourceFailure.notAuthenticated {
            show(UIText.signInAgainMessage(login.host))
            return nil
        } catch {
            show(error, shareID: nil, host: login.host)
            return nil
        }
    }

    /// A share named in the typed address is saved at once; otherwise the user picks one.
    private func chooseShare(_ serverID: UUID, names: [String], typed: String?) async -> UUID? {
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        guard !names.isEmpty else {
            show(UIText.noSharesOnServer(server.login.host))
            return nil
        }
        var name = typed.flatMap { typed in names.first { $0.caseInsensitiveCompare(typed) == .orderedSame } }
        if name == nil {
            let alert = NSAlert()
            alert.messageText = UIText.chooseShareTitle(server.login.host)
            alert.addButton(withTitle: UIText.addShareButton)
            alert.addButton(withTitle: UIText.cancel)
            let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            choices.addItems(withTitles: sorted)
            alert.accessoryView = choices
            guard await present(alert) == .alertFirstButtonReturn else { return nil }
            name = sorted[choices.indexOfSelectedItem]
        }
        guard let name else { return nil }
        do { return try controller.saveShare(serverID: serverID, name: name) }
        catch {
            show(error, shareID: nil)
            return nil
        }
    }

    /// Connect in a location starts a connection attempt; for a Server Volume it mounts the share.
    func connect(_ share: ShareRecord) {
        if serverVolumes.contains(where: { $0.shareID == share.id }) {
            Task { _ = await mountVolume(share.id) }
        } else {
            controller.connect(share.id)
        }
    }

    private func mountVolume(_ shareID: UUID) async -> Bool {
        guard !connectionBusy, let share = share(shareID), let address = address(shareID) else { return false }
        connectionBusy = true
        let failure = await controller.mountVolume(shareID)
        connectionBusy = false
        switch failure {
        case nil: return true
        case .notAuthenticated?: showSignInAgain(share.serverID, host: address.host)
        case let failure?: show(Self.mountMessage(failure, host: address.host, share: share.name))
        }
        return false
    }

    /// The same sign-in serves the server's locations, so Sign In Again… opens from here too.
    private func showSignInAgain(_ serverID: UUID, host: String) {
        let alert = NSAlert()
        alert.messageText = UIText.signInAgainMessage(host)
        alert.addButton(withTitle: UIText.signInAgain)
        alert.addButton(withTitle: UIText.cancel)
        Task {
            if await present(alert) == .alertFirstButtonReturn { signInAgain(serverID: serverID) }
        }
    }

    /// Disconnect for a Server Volume: an eject, so macOS does not mount it again.
    func disconnect(_ share: ShareRecord) {
        guard !connectionBusy else { return }
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            do { try await controller.unmountVolume(share.id) }
            catch { show(UIText.cannotDisconnect(share.name)) }
        }
    }

    func forgetShare(_ record: ShareRecord) {
        guard !connectionBusy else { return }
        guard !isShareUsed(record.id) else { return show(UIText.shareInUse) }
        let alert = NSAlert()
        alert.messageText = UIText.forgetShareTitle(record.name)
        alert.informativeText = UIText.forgetShareMessage
        alert.addButton(withTitle: UIText.forget)
        alert.addButton(withTitle: UIText.cancel)
        let lastLogin = shares.contains { $0.serverID == record.serverID && $0.id != record.id }
            ? nil : servers.first { $0.id == record.serverID }?.login
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            guard await present(alert) == .alertFirstButtonReturn else { return }
            // The server goes with its last share, so its password goes first.
            if let lastLogin, !(await deletePassword(lastLogin)) { return }
            do {
                try await controller.removeShare(record.id)
                let serverGone = !servers.contains { $0.id == record.serverID }
                for index in drafts.indices where drafts[index].shareID == record.id
                    || (serverGone && drafts[index].serverID == record.serverID) {
                    drafts[index].shareID = nil
                    if serverGone { drafts[index].serverID = nil }
                }
                edits = edits.filter { $0.value.shareID != record.id }
            } catch SettingsError.shareInUse {
                show(UIText.shareInUse)
            } catch {
                show(UIText.cannotForgetShare)
            }
        }
    }

    /// An unused server, with its shares and its password.
    func forgetServer(_ id: UUID) {
        guard !connectionBusy, !isServerUsed(id), let server = servers.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = UIText.forgetServerTitle(UIText.serverAddress(server))
        alert.informativeText = UIText.forgetServerMessage
        alert.addButton(withTitle: UIText.forget)
        alert.addButton(withTitle: UIText.cancel)
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            guard await present(alert) == .alertFirstButtonReturn else { return }
            // A failed eject keeps the server, which then offers Sign In Again….
            guard await deletePassword(server.login) else { return }
            do {
                try await controller.removeServer(id)
                for index in drafts.indices where drafts[index].serverID == id {
                    drafts[index].serverID = nil
                    drafts[index].shareID = nil
                }
            } catch {
                show(UIText.cannotRemoveServer)
            }
        }
    }

    /// The names of the locations that use a share, for Servers.
    func locationNames(using shareID: UUID) -> [String] {
        records.filter { $0.shareID == shareID }.map(\.name)
            + serverVolumes.filter { $0.shareID == shareID }.map(volumeName)
    }

    func isServerUsed(_ id: UUID) -> Bool {
        let ids = Set(shares.filter { $0.serverID == id }.map(\.id))
        return records.contains { ids.contains($0.shareID) } || serverVolumes.contains { ids.contains($0.shareID) }
    }

    func isShareUsed(_ id: UUID) -> Bool {
        records.contains { $0.shareID == id } || serverVolumes.contains { $0.shareID == id }
    }

    /// Select… for Folder: the in-app folder browser, which lists the share's folders.
    func selectFolder(_ id: UUID) {
        guard !connectionBusy, let shareID = shareID(id), let share = share(shareID) else { return }
        let controller = controller, host = address(shareID)?.host
        folderBrowser = FolderBrowserRequest(
            entryID: id, share: share.name, start: LocationRecord.normalizedFolder(folderText(id)) ?? .root
        ) { path in
            do { return try await controller.folderNames(shareID: shareID, in: path) }
            catch { throw FolderBrowserError(message: Self.message(for: error, host: host)) }
        }
    }

    func chooseFolder(_ request: FolderBrowserRequest, _ folder: RelativePath) {
        folderBrowser = nil
        setFolder(request.entryID, folder.string)
    }

    // MARK: General and menu bar

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Self.log.error("open_at_login on=\(on) \(logFields(error), privacy: .public)")
            show(error, shareID: nil)
        }
        refreshLoginStatus()
    }

    func record(domain: String) -> LocationRecord? { records.first { $0.domainID == domain } }

    /// The state line of a location in the menu bar panel.
    func panelStatus(_ record: LocationRecord) -> String {
        switch state(record) {
        case .connected(nil): paused ? UIText.paused : UIText.connected
        case .connected(let fraction?): UIText.downloaded(fraction)
        case .needsSignIn: UIText.cannotSignInTo(address(record.shareID)?.host ?? "")
        case .unresponsive: UIText.offline
        case .starting, .notConnected: UIText.notConnected
        case .removing, .catalogUnavailable, .turnedOff, .folderMissing: statusText(record)
        }
    }

    /// A waiting upload's host, for "Waiting for home-nas".
    func host(domain: String) -> String? { record(domain: domain).flatMap { address($0.shareID)?.host } }

    /// The changes that wait in all locations; a location that can't be read counts none.
    func pendingCount() async -> Int {
        var total = 0
        for record in records where !record.removing {
            let uploads = (try? await controller.pendingUploads(record)) ?? 0
            let system = (try? await controller.systemPendingChanges(record))?.items.count ?? 0
            total += max(uploads, system)
        }
        return total
    }

    func retryAllPending() { records.filter { !$0.removing }.forEach(controller.retryPending) }

    func retryPending(domain: String) { record(domain: domain).map(controller.retryPending) }

    func togglePause() {
        let pause = !paused
        Task {
            if !(await controller.setPaused(pause)) { show(pause ? UIText.pauseFailed : UIText.resumeFailed) }
        }
    }

    func diagnosticsText() async -> String {
        let counts = await controller.diagnostics()
        return """
            catalog_files=\(counts.catalogFiles)
            catalogs_open=\(counts.catalogsOpen)
            catalogs_unavailable=\(counts.catalogsUnavailable)
            catalogs_paused=\(counts.catalogsPaused)
            items=\(counts.items)
            tombstones=\(counts.tombstones)
            listed_folders=\(counts.listedFolders)
            kept=\(counts.kept)
            stage_files=\(counts.stageFiles)
            descriptors=\(counts.descriptors)
            rss_bytes=\(counts.residentBytes)
            shares=\(counts.shares)
            connected=\(counts.connected)
            """
    }

    // MARK: Updates from the controller

    private func refresh() {
        let settings = store.settings
        update(\.records, settings?.locations ?? [])
        update(\.serverVolumes, settings?.serverVolumes ?? [])
        let savedServers = servers
        update(\.servers, settings?.servers ?? [])
        if servers != savedServers { checkPasswords() }
        update(\.shares, settings?.shares ?? [])
        update(\.paused, controller.paused)
        update(\.isReady, controller.isReady)
        let problem: String? = switch controller.problem {
        case .settingsUnreadable?: UIText.settingsUnreadable
        case .domainsUnreadable?: UIText.domainsUnreadable
        case .providerTranslocated?: UIText.providerTranslocated
        case nil: settings == nil ? UIText.settingsUnreadable : nil
        }
        update(\.problem, problem)
        update(\.canStartFresh, controller.problem == .settingsUnreadable)
        update(\.notOnServer, controller.notOnServer)
        update(\.shareStates, Dictionary(uniqueKeysWithValues: shares.map { ($0.id, controller.shareState($0.id)) }))
        update(\.mountedVolumes, controller.mountedVolumes)
        update(\.refusedServers, controller.refusedServers)
        update(\.states, Dictionary(uniqueKeysWithValues: records.map { ($0.id, computeState($0)) }))
        // A removed location's events go with it, and with them its file names.
        if settings != nil { activity.keep(domains: Set(records.map(\.domainID))) }
        let ids = Set(records.map(\.id) + serverVolumes.map(\.id))
        if edits.keys.contains(where: { !ids.contains($0) }) { edits = edits.filter { ids.contains($0.key) } }
        if drafts.contains(where: { ids.contains($0.id) }) { drafts.removeAll { ids.contains($0.id) } }
    }

    /// Observation notifies on every set, and progress changes many times each second.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func computeState(_ record: LocationRecord) -> LocationState {
        if record.removing { return .removing }
        guard controller.isReady else { return .starting }
        guard let rootMissing = controller.isRootMissing(record) else { return .catalogUnavailable }
        if controller.turnedOff.contains(record.domainID) { return .turnedOff }
        switch controller.shareState(record.shareID) {
        case .needsSignIn: return .needsSignIn
        case .notConnected: return .notConnected
        case .unresponsive: return .unresponsive
        case .connected: break
        }
        return rootMissing ? .folderMissing : .connected(downloading: controller.downloading[record.domainID])
    }

    private func shareChanged(_ shareID: UUID, _ before: ConnectionState, _ state: ConnectionState) {
        guard let share = share(shareID), let address = address(shareID) else { return }
        notifier.shareChanged(share, host: address.host, from: before, to: state, hasLocations: isShareUsed(shareID))
    }

    private func volumeSignInRefused(_ shareID: UUID) {
        guard let share = share(shareID), let address = address(shareID) else { return }
        notifier.signInRefused(share, host: address.host)
    }

    private func readerActivity(_ domainID: String, _ activity: ReaderActivity) {
        let key = domainID + "/" + activity.item
        let name = activity.name
        switch activity.outcome {
        case .uploaded:
            failedUploads.remove(key)
            notifier.report(ActivityEvent(kind: .uploaded, domain: domainID, name: name, item: activity.item))
        case .downloaded:
            notifier.report(ActivityEvent(kind: .downloaded, domain: domainID, name: name))
        case .uploadFailed(let reason):
            // macOS sends a failed upload again, so it reports once until it succeeds. The history
            // covers a relaunch; the set covers a failure that the panel doesn't list.
            guard failedUploads.insert(key).inserted,
                  !self.activity.history.uploadFailed(domain: domainID, item: activity.item) else { return }
            notifier.report(ActivityEvent(kind: .uploadFailed, domain: domainID, name: name, detail: reason,
                                          item: activity.item),
                            title: UIText.uploadFailedTitle(name), body: reason)
        case .conflict:
            failedUploads.remove(key)
            notifier.report(ActivityEvent(kind: .conflictCopy, domain: domainID, name: name, item: activity.item),
                            title: UIText.conflictTitle(name), body: UIText.conflictMessage)
        case .downloadFailed(let failure):
            guard let record = record(domain: domainID), let share = share(record.shareID),
                  let address = address(record.shareID) else { return }
            notifier.downloadFailed(share, host: address.host, domain: domainID, name: name, failure)
        case .uploadWaiting:
            break
        }
    }

    private func lowSpace(_ domainID: String, _ name: String) {
        notifier.report(ActivityEvent(kind: .lowDiskSpace, domain: domainID, name: name),
                        title: UIText.lowSpaceTitle, body: UIText.lowSpaceMessage(name))
    }

    // MARK: Alerts

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        Task { _ = await present(alert) }
    }

    private func show(_ error: Error, shareID: UUID?, host: String? = nil) {
        Self.log.error("action failed \(logFields(error), privacy: .public)")
        show(Self.message(for: error, host: host ?? address(shareID)?.host))
    }

    private func confirmPermanentDeletion(_ selection: PermanentDeletionSelection, progress: Progress) async -> Bool {
        guard deletionConfirmation == nil, !progress.isCancelled,
              window != nil || openSettings != nil else { return false }
        defer { deletionConfirmation = nil }
        return await withCheckedContinuation { continuation in
            let confirmation = PermanentDeletionConfirmation(selection, progress: progress) {
                continuation.resume(returning: $0)
            }
            deletionConfirmation = confirmation
            if window == nil { openSettings?() }
            confirmation.show(in: window)
        }
    }

    /// A sheet on the Settings window if it shows, otherwise a window of its own.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        NSApp.activate()
        return alert.runModal()
    }

    /// A Server Volume that did not mount. A refused password goes to Sign In Again… instead.
    private static func mountMessage(_ failure: SourceFailure, host: String, share: String) -> String {
        switch failure {
        case .missing: UIText.shareNotOnServer(share, host: host)
        case .noPermission: UIText.noShareAccess(share, host: host)
        case .serverUnreachable, .notConnected: UIText.cannotConnect(host)
        case .localNetworkDenied: UIText.localNetworkDenied
        case .unknown(_, let code): UIText.cannotMount(share, code: code)
        default: UIText.cannotDo(logFields(failure))
        }
    }

    private func run(_ panel: NSSavePanel) async -> Bool {
        if let window, window.isVisible { return await panel.beginSheetModal(for: window) == .OK }
        NSApp.activate()
        return panel.runModal() == .OK
    }

    private static func message(for error: Error, host: String?) -> String {
        if error as? SettingsError == .shareModeConflict { return UIText.shareModeConflict }
        if (error as NSError).domain == NSCocoaErrorDomain,
           (error as NSError).code == NSFileManagerUnmountBusyError { return UIText.volumeBusy }
        if let error = error as? UploadError {
            return error == .pendingWrites ? UIText.pendingUploadHint : UIText.uploadAccessError
        }
        return switch error as? SourceFailure {
        case .notConnected?: UIText.connectInLocation
        case .notAuthenticated?: host.map(UIText.signInAgainMessage) ?? UIText.signInAgainShort
        case .serverUnreachable?: host.map(UIText.cannotConnect) ?? UIText.cannotDo(logFields(error))
        case .localNetworkDenied?: UIText.localNetworkDenied
        case .missing?: UIText.folderNotOnShare
        case .tooManyEntries?: UIText.tooManyItems
        default: UIText.cannotDo(logFields(error))
        }
    }
}
