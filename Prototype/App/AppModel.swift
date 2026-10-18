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
        var grantID: UUID?
        var folder: String
        var name: String
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
            case saved(String)
        }

        let target: Target
        /// Below the location folder.
        let path: String
        let notOnServer: Bool

        var id: String {
            switch target {
            case .item(let id): "item:" + id
            case .saved(let path): "saved:" + path
            }
        }
    }

    /// What reloads a location's Keep Downloaded rows.
    struct KeepKey: Hashable {
        let pending: [String]
        let missing: Set<String>
        let revision: Int
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
        case draft(Draft)

        var id: UUID {
            switch self {
            case .record(let record): record.id
            case .draft(let draft): draft.id
            }
        }

        var name: String {
            switch self {
            case .record(let record): record.name
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
    private(set) var servers: [ServerGrant] = []
    private(set) var states: [UUID: LocationState] = [:]
    private(set) var shareStates: [UUID: ShareHealth.State] = [:]
    private(set) var keepRows: [UUID: [KeepRow]] = [:]
    private(set) var notOnServer: [UUID: Set<String>] = [:]
    private(set) var keepRevision: [UUID: Int] = [:]
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
    private(set) var loginStatus = SMAppService.mainApp.status
    /// The Settings window, for sheets; its view sets it.
    @ObservationIgnored weak var window: NSWindow?
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
        refresh()
        if records.isEmpty {
            newLocation()
        } else {
            selection = .location(records[0].id)
        }
        Task { await controller.launch() }
    }

    var hasLocations: Bool { !records.isEmpty }

    /// Records and drafts in order: each draft below the location that it copies.
    var entries: [Entry] {
        var list: [Entry] = []
        for record in records {
            list.append(.record(record))
            list += drafts.filter { $0.original == record.id }.map(Entry.draft)
        }
        list += drafts.filter { draft in !records.contains { $0.id == draft.original } }.map(Entry.draft)
        let search = searchText.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? list : list.filter { $0.name.localizedStandardContains(search) }
    }

    func record(_ id: UUID) -> LocationRecord? { records.first { $0.id == id } }

    func draft(_ id: UUID) -> Draft? { drafts.first { $0.id == id } }

    func grant(_ id: UUID?) -> ServerGrant? { servers.first { $0.id == id } }

    var selectedRecord: LocationRecord? {
        guard case .location(let id) = selection else { return nil }
        return record(id)
    }

    // MARK: State and text

    func state(_ record: LocationRecord) -> LocationState { states[record.id] ?? .starting }

    func statusText(_ record: LocationRecord) -> String {
        let host = grant(record.serverID)?.host ?? ""
        return switch state(record) {
        case .starting: UIText.notConnected
        case .removing: UIText.removalNotComplete
        case .catalogUnavailable: UIText.catalogUnavailable
        case .turnedOff: UIText.turnedOff
        case .needsGrant: UIText.selectShareAgain
        case .notConnected: UIText.connectInFinder
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

    /// SF Symbols has no drive with a download badge, so downloads show an arrow.
    var menuSymbol: String {
        let all = records.map(state)
        if all.contains(where: \.isProblem) { return "externaldrive.badge.exclamationmark" }
        if all.contains(where: { if case .connected(.some) = $0 { true } else { false } }) { return "arrow.down.circle" }
        return "externaldrive"
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
        let grant = grant(record.serverID)
        return UIText.source(host: grant?.host ?? "", share: grant?.share ?? "", folder: record.folder)
    }

    var isDownloading: Bool { !controller.downloading.isEmpty }

    // MARK: Source fields

    func grantID(_ id: UUID) -> UUID? {
        if let draft = draft(id) { return draft.grantID }
        return edits[id]?.grantID ?? record(id)?.serverID
    }

    func folderText(_ id: UUID) -> String {
        if let draft = draft(id) { return draft.folder }
        return edits[id]?.folder ?? record(id)?.folder ?? ""
    }

    func nameText(_ id: UUID) -> String {
        if let draft = draft(id) { return draft.name }
        return names[id] ?? record(id)?.name ?? ""
    }

    func setGrant(_ id: UUID, _ grantID: UUID) {
        if let index = drafts.firstIndex(where: { $0.id == id }) {
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
            setEdit(record, SourceEdit(grantID: grantID(id) ?? record.serverID, folder: text))
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
        edits[record.id] = edit.grantID == record.serverID && folder == record.folder ? nil : edit
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
            .map { LocationRecord.path($0, inside: folder)?.string ?? $0 }
    }

    // MARK: Sidebar actions

    func newLocation() {
        let grant = servers.first
        let draft = Draft(grantID: grant?.id, folder: "", name: grant?.share ?? "", original: nil)
        drafts.append(draft)
        select(draft.id)
    }

    /// Design §4.2: a copy below the original, without its Keep Downloaded requests.
    func duplicate(_ recordID: UUID) {
        guard let record = record(recordID) else { return }
        let taken = records.map(\.name) + drafts.map(\.name)
        let draft = Draft(grantID: record.serverID, folder: record.folder,
                          name: LocationRecord.copyName(record.name, among: taken), original: record.id)
        drafts.insert(draft, at: 0)
        select(draft.id)
    }

    func cancel(_ draftID: UUID) {
        guard let draft = draft(draftID), !busy.contains(draftID) else { return }
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
        guard let draft = draft(draftID), !busy.contains(draftID) else { return }
        guard let grantID = draft.grantID else { return }
        guard let folder = LocationRecord.normalizedFolder(draft.folder) else { return show(UIText.wrongFolderPath) }
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? defaultName(grantID: grantID, folder: draft.folder) : typed
        guard RelativePath.isValidComponent(name) else { return show(UIText.wrongName) }
        busy.insert(draftID)
        Task {
            defer { busy.remove(draftID) }
            do {
                // The record keeps the draft's ID, and its selection, from the moment it is saved.
                _ = try await controller.add(id: draftID, name: name, folder: folder, grantID: grantID,
                                             after: draft.original)
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
                show(error, grantID: record.serverID)
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
                _ = try await controller.apply(recordID, grantID: edit.grantID, folder: folder)
                edits[recordID] = nil
                await controller.restorePendingKeeps(recordID)
            } catch {
                // A failure after the record changed leaves the domain for the next launch to add.
                if let changed = self.record(recordID), changed.serverID == edit.grantID, changed.folder == folder.string {
                    edits[recordID] = nil
                }
                show(error, grantID: edit.grantID)
            }
        }
    }

    func confirmRemove(_ recordID: UUID) {
        guard let record = record(recordID), !busy.contains(recordID) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UIText.removeTitle(record.name)
        alert.informativeText = UIText.removeMessage
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = UIText.saveKeepList
        alert.suppressionButton?.state = .on
        alert.addButton(withTitle: UIText.removeLocation).hasDestructiveAction = true
        alert.addButton(withTitle: UIText.cancel)
        Task {
            guard await present(alert) == .alertFirstButtonReturn else { return }
            let save = alert.suppressionButton?.state == .on
            busy.insert(recordID)
            defer { busy.remove(recordID) }
            do {
                try await controller.remove(recordID, saveKeeps: save)
                for index in drafts.indices where drafts[index].original == recordID { drafts[index].original = nil }
                edits[recordID] = nil
                names[recordID] = nil
                if selection == .location(recordID) {
                    selection = entries.first.map { .location($0.id) } ?? .general
                }
            } catch {
                show(error, grantID: record.serverID)
            }
        }
    }

    func showInFinder(_ recordID: UUID) {
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

    // MARK: Keep Downloaded

    func keepKey(_ record: LocationRecord) -> KeepKey {
        KeepKey(pending: record.pendingKeeps, missing: notOnServer[record.id] ?? [], revision: keepRevision[record.id] ?? 0)
    }

    func reloadKeeps(_ recordID: UUID) async {
        guard let record = record(recordID) else { return }
        let kept = await controller.keptPaths(record)
        let folder = RelativePath(record.folder) ?? .root
        let missing = notOnServer[recordID] ?? []
        keepRows[recordID] = kept.map { KeepRow(target: .item($0.id), path: $0.path.string, notOnServer: false) }
            + record.pendingKeeps.map { path in
                KeepRow(target: .saved(path), path: LocationRecord.path(path, inside: folder)?.string ?? path,
                        notOnServer: missing.contains(path))
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
                show(error, grantID: record.serverID)
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

    /// Add Share… or Select Again…. Returns the saved grant's ID.
    @discardableResult
    func selectShare(again existing: ServerGrant? = nil) async -> UUID? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // The share is read-only to tinymounter, and the panel could make a folder on it.
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = UIText.selectShareMessage
        guard await run(panel), let url = panel.url else { return nil }
        do {
            let grant = try await ShareAccess.makeGrant(for: url)
            if let existing, existing.mountFrom != grant.mountFrom {
                show(UIText.otherShare)
                return nil
            }
            return try controller.saveGrant(grant)
        } catch {
            show(error, grantID: nil)
            return nil
        }
    }

    /// From the Server picker of a location.
    func addShare(for id: UUID) {
        Task {
            guard let grantID = await selectShare() else { return }
            setGrant(id, grantID)
        }
    }

    func removeGrant(_ id: UUID) {
        do { try controller.removeGrant(id) } catch { return show(UIText.serverInUse) }
        for index in drafts.indices where drafts[index].grantID == id { drafts[index].grantID = nil }
        edits = edits.filter { $0.value.grantID != id }
    }

    func isGrantUsed(_ id: UUID) -> Bool { records.contains { $0.serverID == id } }

    /// Select… for Folder: a folder in the mounted share.
    func selectFolder(_ id: UUID) {
        guard let grantID = grantID(id), let mount = controller.mountPath(grantID) else {
            return show(UIText.shareNotMounted)
        }
        let panel = NSOpenPanel()
        let current = LocationRecord.normalizedFolder(folderText(id)) ?? .root
        panel.directoryURL = URL(filePath: current.isRoot ? mount : mount + "/" + current.string, directoryHint: .isDirectory)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.message = UIText.selectFolderMessage
        Task {
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
        update(\.servers, settings?.servers ?? [])
        update(\.paused, controller.paused)
        update(\.isReady, controller.isReady)
        let problem: String? = switch controller.problem {
        case .settingsUnreadable?: UIText.settingsUnreadable
        case .domainsUnreadable?: UIText.domainsUnreadable
        case nil: settings == nil ? UIText.settingsUnreadable : nil
        }
        update(\.problem, problem)
        update(\.notOnServer, controller.notOnServer)
        update(\.shareStates, Dictionary(uniqueKeysWithValues: servers.map { ($0.id, controller.shareState($0.id)) }))
        update(\.states, Dictionary(uniqueKeysWithValues: records.map { ($0.id, computeState($0)) }))
        let ids = Set(records.map(\.id))
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
        switch controller.shareState(record.serverID) {
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

    /// A sheet on the Settings window if it shows, otherwise a window of its own.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        NSApp.activate()
        return alert.runModal()
    }

    private func run(_ panel: NSOpenPanel) async -> Bool {
        if let window, window.isVisible { return await panel.beginSheetModal(for: window) == .OK }
        NSApp.activate()
        return panel.runModal() == .OK
    }

    private static func message(for error: Error, host: String?) -> String {
        if let refusal = error as? ShareGrantError {
            return switch refusal {
            case .notVolumeRoot: UIText.notVolumeRoot
            case .notSMBShare: UIText.notSMBShare
            case .addressRejected: UIText.addressRejected
            }
        }
        return switch error as? SourceFailure {
        case .notConnected?: UIText.connectInFinder
        case .notAuthenticated?: UIText.selectShareAgain
        case .serverUnreachable?: host.map(UIText.cannotConnect) ?? UIText.cannotDo(logFields(error))
        case .missing?: UIText.folderNotOnShare
        case .tooManyEntries?: UIText.tooManyItems
        default: UIText.cannotDo(logFields(error))
        }
    }
}
