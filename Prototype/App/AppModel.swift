import AppKit
import FileProvider
import Observation
import OSLog
import ServiceManagement

/// The state of the Settings window and the menu bar item (plan §8).
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
        var grantID: UUID?
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
        var grantID: UUID
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
        case starting, removing, catalogUnavailable, turnedOff, needsGrant, notConnected, unresponsive, folderMissing
        case connected(downloading: Double?)

        var isProblem: Bool {
            switch self {
            case .catalogUnavailable, .turnedOff, .needsGrant, .notConnected, .unresponsive, .folderMissing: true
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
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let notifier = Notifier()
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
    private(set) var shares: [ServerGrant] = []
    private(set) var connectionBusy = false
    private(set) var states: [UUID: LocationState] = [:]
    private(set) var shareStates: [UUID: ShareHealth.State] = [:]
    private(set) var keepRows: [UUID: [KeepRow]] = [:]
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
        controller = LocationController(store: store)
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onShareState = { [weak self] grantID, before, state in self?.shareChanged(grantID, before, state) }
        controller.onUserFetchFailed = { [weak self] grantID, failure in self?.downloadFailed(grantID, failure) }
        controller.onKeepsRestored = { [weak self] record, ids in self?.keepsRestored(record, ids) }
        controller.onLocationChange = { [weak self] domainID in self?.locationChanged(domainID) }
        controller.onMaterializedChange = { [weak self] in self?.materializedRevision += 1 }
        controller.onPreserved = { [weak self] url in self?.showPreserved(url) }
        controller.onConfirmDeletion = { [weak self] selection, progress in
            await self?.confirmPermanentDeletion(selection, progress: progress) ?? false
        }
        refresh()
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

    func grant(_ id: UUID?) -> ServerGrant? { shares.first { $0.id == id } }

    var selectedRecord: LocationRecord? {
        guard case .location(let id) = selection else { return nil }
        return record(id)
    }

    // MARK: State and text

    func state(_ record: LocationRecord) -> LocationState { states[record.id] ?? .starting }

    func statusText(_ record: LocationRecord) -> String {
        let host = grant(record.grantID)?.host ?? ""
        return switch state(record) {
        case .starting: UIText.notConnected
        case .removing: UIText.removalNotComplete
        case .catalogUnavailable: UIText.catalogUnavailable
        case .turnedOff: UIText.turnedOff
        case .needsGrant: UIText.selectShareAgainShort
        case .notConnected: UIText.connectInLocation
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
        case .catalogUnavailable, .turnedOff, .needsGrant, .folderMissing: UIText.problem
        }
    }

    func symbol(_ record: LocationRecord) -> String {
        switch state(record) {
        case .connected(.some): "arrow.down.circle"
        case .connected(nil): "checkmark.circle"
        case .starting, .notConnected, .unresponsive: "bolt.horizontal.circle"
        case .removing: "trash.circle"
        case .catalogUnavailable, .turnedOff, .needsGrant, .folderMissing: "exclamationmark.triangle"
        }
    }

    var menuImageName: String {
        let all = records.map(state)
        if all.contains(where: \.isProblem)
            || serverVolumes.contains(where: { shareStates[$0.grantID] != .connected }) { return "MenuBarProblem" }
        if all.contains(where: { if case .connected(.some) = $0 { true } else { false } }) { return "MenuBarDownloading" }
        return "MenuBarDrive"
    }

    func shareStatus(_ grant: ServerGrant) -> String {
        switch shareStates[grant.id] ?? .notConnected {
        case .connected: UIText.connected
        case .notConnected: UIText.notConnected
        case .unresponsive: UIText.notResponding
        case .needsGrant: UIText.selectShareAgainShort
        }
    }

    func sourceText(_ record: LocationRecord) -> String {
        let grant = grant(record.grantID)
        return UIText.source(host: grant?.host ?? "", share: grant?.share ?? "", folder: record.folder)
    }

    var isDownloading: Bool { !controller.downloading.isEmpty }

    // MARK: Source fields

    func grantID(_ id: UUID) -> UUID? {
        if let draft = draft(id) { return draft.grantID }
        return edits[id]?.grantID ?? record(id)?.grantID ?? serverVolume(id)?.grantID
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
        draft(id)?.serverID ?? grant(grantID(id))?.serverID
    }

    func setServer(_ id: UUID, _ serverID: UUID) {
        let available = shares.first { $0.serverID == serverID }
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].serverID = serverID
            drafts[index].grantID = available?.id
            followFolder(index)
        } else if let available {
            setGrant(id, available.id)
        } else {
            guard !connectionBusy else { return }
            connectionBusy = true
            Task {
                defer { connectionBusy = false }
                if let grantID = await acquireShare(serverID) { setGrant(id, grantID) }
            }
        }
    }

    func setGrant(_ id: UUID, _ grantID: UUID) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].serverID = grant(grantID)?.serverID
            guard drafts[index].grantID != grantID else { return }
            drafts[index].grantID = grantID
            followFolder(index)
        } else if let record = record(id) {
            setEdit(record, SourceEdit(grantID: grantID, folder: folderText(id)))
        }
    }

    func setFolder(_ id: UUID, _ text: String) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
            // A field that takes focus writes its text again; only a change makes the name follow.
            guard drafts[index].folder != text else { return }
            drafts[index].folder = text
            followFolder(index)
        } else if let record = record(id) {
            setEdit(record, SourceEdit(grantID: grantID(id) ?? record.grantID, folder: text))
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

    /// Plan §8: the subfolders of the typed folder; the view calls it 150 ms after the last change.
    func suggestFolders(_ id: UUID) async {
        guard let grantID = grantID(id) else { return update(\.folderSuggestions, []) }
        let suggestions = await controller.folderSuggestions(grantID: grantID, typed: folderText(id))
        if !Task.isCancelled { update(\.folderSuggestions, suggestions) }
    }

    func endFolderCompletion() {
        update(\.folderSuggestions, [])
        controller.endFolderCompletion()
    }

    private func setEdit(_ record: LocationRecord, _ edit: SourceEdit) {
        let folder = LocationRecord.normalizedFolder(edit.folder)?.string
        edits[record.id] = edit.grantID == record.grantID && folder == record.folder ? nil : edit
    }

    private func followFolder(_ index: Int) {
        guard !drafts[index].nameEdited else { return }
        drafts[index].name = defaultName(grantID: drafts[index].grantID, folder: drafts[index].folder)
    }

    /// The last folder name, or the share's name for the full share.
    private func defaultName(grantID: UUID?, folder: String) -> String {
        if let folder = LocationRecord.normalizedFolder(folder), let last = folder.components.last { return last }
        return grant(grantID)?.share ?? ""
    }

    /// The saved paths that Add would take, below the draft's folder.
    func savedKeeps(_ draft: Draft) -> [String] {
        guard let grant = grant(draft.grantID), let folder = LocationRecord.normalizedFolder(draft.folder),
              let settings = store.settings else { return [] }
        return settings.savedKeeps(host: grant.host, share: grant.share, inside: folder)
            .map { ($0.below(folder)?.string ?? $0.path) + ($0.kind == .folder ? "/" : "") }
    }

    // MARK: Sidebar actions

    func newLocation() {
        let server = servers.first
        let grant = shares.first { $0.serverID == server?.id }
        let draft = Draft(serverID: server?.id, grantID: grant?.id, folder: "", name: grant?.share ?? "", original: nil)
        drafts.append(draft)
        select(draft.id)
    }

    /// Design §4.2: a copy below the original, without its Keep Downloaded requests.
    func duplicate(_ recordID: UUID) {
        guard let record = record(recordID) else { return }
        let taken = records.map(\.name) + drafts.map(\.name)
        let draft = Draft(serverID: grant(record.grantID)?.serverID, grantID: record.grantID, folder: record.folder,
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
        guard let grantID = draft.grantID else { return }
        do { try store.settings?.requireMode(draft.mode, for: grantID) }
        catch { return show(error, grantID: grantID) }
        if draft.mode == .serverVolume { return addServerVolume(draft) }
        guard let folder = LocationRecord.normalizedFolder(draft.folder) else { return show(UIText.wrongFolderPath) }
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? defaultName(grantID: grantID, folder: draft.folder) : typed
        guard RelativePath.isValidComponent(name) else { return show(UIText.wrongName) }
        busy.insert(draftID)
        Task {
            defer { busy.remove(draftID) }
            do {
                if controller.mountPath(grantID) == nil {
                    guard let grant = grant(grantID), await connectShare(grant) else { return }
                }
                var bookmark: Data?
                if !draft.readOnly {
                    guard let granted = try await writeGrant(grantID: grantID) else { return }
                    bookmark = granted
                }
                // The record keeps the draft's ID, and its selection, from the moment it is saved.
                _ = try await controller.add(id: draftID, name: name, folder: folder, grantID: grantID,
                                             after: draft.original, writeBookmark: bookmark)
                notifier.requestPermission()
                await controller.restorePendingKeeps(draftID)
            } catch {
                show(error, grantID: grantID)
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
                show(error, grantID: record.grantID)
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
                var bookmark: Data?
                if !record.readOnly {
                    guard let granted = try await writeGrant(grantID: edit.grantID) else { return }
                    bookmark = granted
                }
                _ = try await controller.apply(recordID, grantID: edit.grantID, folder: folder,
                                               writeBookmark: bookmark)
                edits[recordID] = nil
                await controller.restorePendingKeeps(recordID)
            } catch {
                // A failure after the record changed leaves the domain for the next launch to add.
                if let changed = self.record(recordID), changed.grantID == edit.grantID, changed.folder == folder.string {
                    edits[recordID] = nil
                }
                show(error, grantID: edit.grantID)
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
                show(error, grantID: nil)
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
                show(error, grantID: record.grantID)
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
            do {
                var bookmark = record.writeBookmark
                if !readOnly {
                    guard let granted = try await writeGrant(grantID: record.grantID) else { return }
                    bookmark = granted
                }
                try await controller.setWriteMode(id, readOnly: readOnly, bookmark: bookmark)
            } catch { show(error, grantID: record.grantID) }
        }
    }

    private func writeGrant(grantID: UUID) async throws -> Data? {
        guard let grant = grant(grantID) else { throw UploadError.readOnly }
        if let bookmark = store.settings?.writeBookmark(for: grantID) { return bookmark }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = UIText.writeGrantMessage
        panel.prompt = UIText.confirmWriteSetup
        panel.directoryURL = URL(filePath: controller.mountPath(grantID) ?? "/Volumes", directoryHint: .isDirectory)
        guard await run(panel), let url = panel.url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let mount = try ShareAccess.connectedShares().first(where: {
            $0.path == ShareAccess.filePath(url)
        }), mount.identity.mountFrom == grant.mountFrom else { throw UploadError.readOnly }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        try controller.saveWriteGrant(bookmark, grantID: grantID)
        return bookmark
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
            catch { show(error, grantID: record.grantID) }
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

    func volumeName(_ volume: ServerVolumeRecord) -> String { grant(volume.grantID)?.share ?? UIText.serverVolume }

    func volumeStatus(_ volume: ServerVolumeRecord) -> String {
        grant(volume.grantID).map(shareStatus) ?? UIText.notConnected
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
        guard busy.isEmpty, let grant = grant(draft.grantID) else { return }
        busy.insert(draft.id)
        Task {
            defer { busy.remove(draft.id) }
            guard await connectShare(grant, native: true) else { return }
            do { try controller.addServerVolume(id: draft.id, grantID: grant.id) }
            catch { show(error, grantID: grant.id) }
        }
    }

    private func showServerVolume(_ volume: ServerVolumeRecord) {
        guard !connectionBusy, let grant = grant(volume.grantID) else { return }
        Task {
            guard await connectShare(grant) else { return }
            guard let path = controller.mountPath(grant.id),
                  NSWorkspace.shared.open(URL(filePath: path, directoryHint: .isDirectory)) else {
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
            } catch { show(error, grantID: volume.grantID) }
        }
    }

    // MARK: Keep Downloaded

    func keepKey(_ record: LocationRecord) -> KeepKey {
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

    func reloadKeeps(_ recordID: UUID) async {
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
        await controller.offlineStates(record) { states in
            guard self.keepGeneration[recordID] == generation, !Task.isCancelled,
                  let current = self.record(recordID), self.keepKey(current) == key else { return }
            self.keepRows[recordID] = self.keepRows[recordID]?.map { row in
                var row = row
                if case .item(let id) = row.target { row.availability = states[id] ?? .requested }
                return row
            }
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
                show(error, grantID: record.grantID)
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

    /// Plan §8: evicts the downloaded files that are not kept, after a confirmation.
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
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            guard let text = await askAddress() else { return }
            guard let address = ServerAddress(typed: text) else { return show(UIText.wrongAddress) }
            do {
                let serverID = try controller.saveServer(address)
                setServer(locationID, serverID)
                if address.share != nil || grant(grantID(locationID))?.serverID != serverID,
                   let grantID = await acquireShare(serverID, address: address) {
                    setGrant(locationID, grantID)
                }
            } catch { show(error, grantID: nil) }
        }
    }

    func addShare(for locationID: UUID) {
        guard !connectionBusy, let serverID = serverID(locationID) else { return }
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            if let grantID = await acquireShare(serverID) { setGrant(locationID, grantID) }
        }
    }

    private func acquireShare(_ serverID: UUID, address: ServerAddress? = nil) async -> UUID? {
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        do {
            let before = try ShareAccess.connectedShares()
            let compatible = before.filter { mount in
                server.account.map { $0.caseInsensitiveCompare(mount.address.account) == .orderedSame } ?? true
            }
            if !compatible.isEmpty {
                switch await chooseConnectedShare(compatible, server: server) {
                case .existing(let mount): return await selectShare(serverID: serverID, at: mount.path)
                case .cancel: return nil
                case .connect: break
                }
            }
            let (status, paths) = await ShareAccess.mount(address?.url ?? server.address)
            guard status == 0 || status == EEXIST else {
                if let message = Self.mountMessage(status, host: server.host) { show(message) }
                return nil
            }
            let mounted = try ShareAccess.connectedShares()
            let path = paths.first ?? address.flatMap { ShareAccess.mountPath(of: $0) }
            let grantID: UUID?
            if let path {
                grantID = await selectShare(serverID: serverID, at: path)
            } else {
                show(UIText.cannotDo("status=\(status)"))
                grantID = nil
            }
            let kept = grant(grantID)?.mountFrom
            let previous = Set(before.map(\.identity))
            let requestedPaths = Set(paths)
            for mount in mounted where requestedPaths.contains(mount.path)
                && !previous.contains(mount.identity) && mount.identity.mountFrom != kept {
                do { try await ShareAccess.unmount(mount, reason: "not_selected") }
                catch { show(UIText.cannotDisconnect(mount.address.share)) }
            }
            return grantID
        } catch {
            show(error, grantID: nil)
            return nil
        }
    }

    func connect(_ grant: ServerGrant) {
        Task { _ = await connectShare(grant) }
    }

    private func connectShare(_ grant: ServerGrant, native: Bool? = nil) async -> Bool {
        guard !connectionBusy else { return false }
        guard let url = URL(string: "smb:" + grant.mountFrom) else {
            show(UIText.addressRejected)
            return false
        }
        connectionBusy = true
        defer { connectionBusy = false }
        let visible = native ?? serverVolumes.contains { $0.grantID == grant.id }
        if visible {
            do {
                let mounts = try ShareAccess.connectedShares().filter { $0.identity.mountFrom == grant.mountFrom }
                if mounts.contains(where: { !$0.isHidden }) {
                    controller.shareMounted(grant.id)
                    return true
                }
                for mount in mounts where mount.isHidden {
                    try await ShareAccess.unmount(mount, reason: "server_volume_visibility")
                }
            } catch {
                controller.shareMounted(grant.id)
                show(UIText.cannotDisconnect(grant.share))
                return false
            }
        }
        let (status, _) = await ShareAccess.mount(url, browsable: visible)
        guard status == 0 || status == EEXIST else {
            if let message = Self.mountMessage(status, host: grant.host) { show(message) }
            return false
        }
        guard let mounted = try? ShareAccess.connectedShares(),
              mounted.contains(where: { $0.identity.mountFrom == grant.mountFrom && (!visible || !$0.isHidden) }) else {
            show(visible ? UIText.nativeMountUnavailable : UIText.selectShareAgain)
            return false
        }
        controller.shareMounted(grant.id)
        return true
    }

    func disconnect(_ grant: ServerGrant) {
        guard !connectionBusy else { return }
        connectionBusy = true
        notifier.userDisconnected(grant.id)
        Task {
            defer { connectionBusy = false }
            do { try await controller.disconnect(grant.id) }
            catch {
                notifier.disconnectFailed(grant.id)
                show(UIText.cannotDisconnect(grant.share))
            }
        }
    }

    func selectAgain(_ grant: ServerGrant) {
        guard !connectionBusy else { return }
        let serverID = grant.serverID
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            _ = await selectShare(serverID: serverID, again: grant)
        }
    }

    private func selectShare(serverID: UUID, again existing: ServerGrant? = nil, at path: String? = nil) async -> UUID? {
        let panel = NSOpenPanel()
        let directory = path ?? existing.flatMap { controller.mountPath($0.id) } ?? "/Volumes"
        panel.directoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = UIText.selectShareMessage
        guard await run(panel), let url = panel.url else { return nil }
        do {
            let grant = try await ShareAccess.makeGrant(for: url, serverID: serverID)
            if let existing, existing.mountFrom != grant.mountFrom {
                show(UIText.otherShare)
                return nil
            }
            if let server = servers.first(where: { $0.id == serverID }), !server.accepts(account: grant.account) {
                show(UIText.otherAccount)
                return nil
            }
            return try controller.saveGrant(grant)
        } catch {
            show(error, grantID: nil)
            return nil
        }
    }

    func forgetShare(_ grant: ServerGrant) {
        guard !connectionBusy else { return }
        guard !isGrantUsed(grant.id) else { return show(UIText.shareInUse) }
        let alert = NSAlert()
        alert.messageText = UIText.forgetShareTitle(grant.share)
        alert.informativeText = UIText.forgetShareMessage
        alert.addButton(withTitle: UIText.forget)
        alert.addButton(withTitle: UIText.cancel)
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            guard await present(alert) == .alertFirstButtonReturn else { return }
            do {
                try await controller.removeShare(grant.id)
                let serverGone = !servers.contains { $0.id == grant.serverID }
                for index in drafts.indices where drafts[index].grantID == grant.id
                    || (serverGone && drafts[index].serverID == grant.serverID) {
                    drafts[index].grantID = nil
                    if serverGone { drafts[index].serverID = nil }
                }
                edits = edits.filter { $0.value.grantID != grant.id }
            } catch SettingsError.shareInUse {
                show(UIText.shareInUse)
            } catch {
                show(UIText.cannotDisconnect(grant.share))
            }
        }
    }

    /// A saved server without shares, from an Add Server… that did not finish.
    func forgetServer(_ id: UUID) {
        guard !connectionBusy, !isServerUsed(id) else { return }
        connectionBusy = true
        Task {
            defer { connectionBusy = false }
            do {
                try await controller.removeServer(id)
                for index in drafts.indices where drafts[index].serverID == id {
                    drafts[index].serverID = nil
                    drafts[index].grantID = nil
                }
            } catch {
                show(UIText.cannotRemoveServer)
            }
        }
    }

    /// The names of the locations that use a share, for Servers.
    func locationNames(using grantID: UUID) -> [String] {
        records.filter { $0.grantID == grantID }.map(\.name)
            + serverVolumes.filter { $0.grantID == grantID }.map(volumeName)
    }

    func isServerUsed(_ id: UUID) -> Bool {
        let grants = Set(shares.filter { $0.serverID == id }.map(\.id))
        return records.contains { grants.contains($0.grantID) }
            || serverVolumes.contains { grants.contains($0.grantID) }
    }

    func isGrantUsed(_ id: UUID) -> Bool {
        records.contains { $0.grantID == id } || serverVolumes.contains { $0.grantID == id }
    }

    private enum ShareChoice {
        case existing(ShareAccess.ConnectedShare), connect, cancel
    }

    private func chooseConnectedShare(_ mounts: [ShareAccess.ConnectedShare], server: ServerRecord) async -> ShareChoice {
        let alert = NSAlert()
        alert.messageText = UIText.chooseShareTitle(server.host)
        alert.informativeText = UIText.chooseShareDescription
        alert.addButton(withTitle: UIText.useShare)
        alert.addButton(withTitle: UIText.connectAnotherShare)
        alert.addButton(withTitle: UIText.cancel)
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        for mount in mounts { choices.addItem(withTitle: UIText.mountedShare(mount.address)) }
        if let index = mounts.firstIndex(where: { $0.address.host.caseInsensitiveCompare(server.host) == .orderedSame }) {
            choices.selectItem(at: index)
        }
        alert.accessoryView = choices
        switch await present(alert) {
        case .alertFirstButtonReturn:
            let mount = mounts[choices.indexOfSelectedItem]
            let known = Set(shares.filter { $0.serverID == server.id }.map { $0.host.lowercased() } + [server.host.lowercased()])
            if !known.contains(mount.address.host.lowercased()) {
                let confirmation = NSAlert()
                confirmation.messageText = UIText.useOtherAddressTitle
                confirmation.informativeText = UIText.useOtherAddress(mount.address, server: server.host)
                confirmation.addButton(withTitle: UIText.useShare)
                confirmation.addButton(withTitle: UIText.cancel)
                guard await present(confirmation) == .alertFirstButtonReturn else { return .cancel }
            }
            return .existing(mount)
        case .alertSecondButtonReturn: return .connect
        default: return .cancel
        }
    }

    /// Select… for Folder: a folder in the share. It connects the share first if necessary.
    func selectFolder(_ id: UUID) {
        guard !connectionBusy, let grantID = grantID(id), let grant = grant(grantID) else { return }
        Task {
            if controller.mountPath(grantID) == nil {
                guard await connectShare(grant) else { return }
            }
            guard let mount = controller.mountPath(grantID) else { return show(UIText.cannotShow) }
            let panel = NSOpenPanel()
            let current = LocationRecord.normalizedFolder(folderText(id)) ?? .root
            panel.directoryURL = URL(filePath: current.isRoot ? mount : mount + "/" + current.string,
                                     directoryHint: .isDirectory)
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = false
            panel.message = UIText.selectFolderMessage
            guard await run(panel), let url = panel.url else { return }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed == mount {
                setFolder(id, "")
            } else if trimmed.hasPrefix(mount + "/") {
                setFolder(id, String(trimmed.dropFirst(mount.count + 1)))
            } else {
                show(UIText.folderNotOnShare)
            }
        }
    }

    // MARK: General and menu bar

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Self.log.error("open_at_login on=\(on) \(logFields(error), privacy: .public)")
            show(error, grantID: nil)
        }
        refreshLoginStatus()
    }

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
            sessions=\(counts.sessions)
            """
    }

    // MARK: Updates from the controller

    private func refresh() {
        let settings = store.settings
        update(\.records, settings?.locations ?? [])
        update(\.serverVolumes, settings?.serverVolumes ?? [])
        update(\.servers, settings?.servers ?? [])
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
        update(\.states, Dictionary(uniqueKeysWithValues: records.map { ($0.id, computeState($0)) }))
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
        switch controller.shareState(record.grantID) {
        case .needsGrant: return .needsGrant
        case .notConnected: return .notConnected
        case .unresponsive: return .unresponsive
        case .connected: break
        }
        return rootMissing ? .folderMissing : .connected(downloading: controller.downloading[record.domainID])
    }

    private func shareChanged(_ grantID: UUID, _ before: ShareHealth.State, _ state: ShareHealth.State) {
        guard let grant = grant(grantID) else { return }
        notifier.shareChanged(grant, from: before, to: state, hasLocations: isGrantUsed(grantID))
    }

    private func downloadFailed(_ grantID: UUID, _ failure: SourceFailure) {
        guard let grant = grant(grantID) else { return }
        notifier.downloadFailed(grant, failure)
    }

    // MARK: Alerts

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        Task { _ = await present(alert) }
    }

    private func show(_ error: Error, grantID: UUID?) {
        Self.log.error("action failed \(logFields(error), privacy: .public)")
        show(Self.message(for: error, host: grant(grantID)?.host))
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

    private func askAddress() async -> String? {
        let alert = NSAlert()
        alert.messageText = UIText.addServerTitle
        alert.informativeText = UIText.addServerDescription
        alert.addButton(withTitle: UIText.add)
        alert.addButton(withTitle: UIText.cancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = UIText.addressPlaceholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Nil when the user clicked Cancel in macOS's dialog.
    private static func mountMessage(_ status: Int32, host: String) -> String? {
        switch status {
        case Int32(userCanceledErr): nil
        case EAUTH, EACCES, EPERM: UIText.passwordNotAccepted(host)
        case _ where RemountPolicy.isNetworkFailure(status): UIText.cannotConnect(host)
        default: UIText.cannotDo("status=\(status)")
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
        if let refusal = error as? ShareGrantError {
            return switch refusal {
            case .notVolumeRoot: UIText.notVolumeRoot
            case .notSMBShare: UIText.notSMBShare
            case .addressRejected: UIText.addressRejected
            }
        }
        return switch error as? SourceFailure {
        case .notConnected?: UIText.connectInLocation
        case .notAuthenticated?: UIText.selectShareAgain
        case .serverUnreachable?: host.map(UIText.cannotConnect) ?? UIText.cannotDo(logFields(error))
        case .missing?: UIText.folderNotOnShare
        case .tooManyEntries?: UIText.tooManyItems
        default: UIText.cannotDo(logFields(error))
        }
    }
}
