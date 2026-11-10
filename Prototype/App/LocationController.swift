import AppKit
import Darwin
import FileProvider
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Domain steps, launch reconciliation, recovery signals and relisting (docs/architecture.md §3).
@MainActor
final class LocationController {
    enum Problem: Equatable {
        /// Launch reconciliation stopped: nothing is added or removed.
        case settingsUnreadable
        case domainsUnreadable
        case providerTranslocated
    }

    struct Diagnostics: Equatable {
        var catalogFiles = 0, catalogsOpen = 0, catalogsUnavailable = 0, items = 0, tombstones = 0
        var listedFolders = 0, kept = 0, catalogsPaused = 0, stageFiles = 0, descriptors = 0
        var residentBytes: UInt64 = 0
        var shares = 0, connected = 0
    }

    let store: SettingsStore
    private(set) var problem: Problem?
    /// Until launch reconciliation ends, a new catalog could look like one without a record.
    private(set) var isReady = false
    /// Pause Downloads, for every location. Each launch starts with it off.
    private(set) var paused = false
    /// The latest Pause Downloads change.
    private var pauseChange: Task<Bool, Never>?
    var onChange: (() -> Void)?
    /// A share's state changed: the share, the state before and the state now.
    var onShareState: ((UUID, ConnectionState, ConnectionState) -> Void)?
    /// A transfer ended, or a user's fetch failed on its share: the domain and the outcome.
    var onActivity: ((String, ReaderActivity) -> Void)?
    var onTransfers: (([ActiveTransfer]) -> Void)?
    /// A file's download first stopped for want of disk space: the domain and the file's name.
    var onLowSpace: ((String, String) -> Void)?
    /// A Server Volume's share did not mount again: the server refused the saved password.
    var onVolumeSignInRefused: ((UUID) -> Void)?
    /// Saved Keep Downloaded paths became kept files: the record and the item IDs.
    var onKeepsRestored: ((LocationRecord, [String]) -> Void)?
    /// A location's kept files or root state changed: its domain ID.
    var onLocationChange: ((String) -> Void)?
    /// The system's set of downloaded files changed, in any domain.
    var onMaterializedChange: (() -> Void)?
    /// A domain was removed, and macOS kept its items that had not uploaded in this folder.
    var onPreserved: ((URL) -> Void)?
    var onConfirmDeletion: ((PermanentDeletionSelection, Progress) async -> Bool)?
    /// Saved Keep Downloaded paths that a complete listing showed are not on the server, by record.
    private(set) var notOnServer: [UUID: Set<KeepPath>] = [:]
    private var restoring: Set<UUID> = []
    /// Each domain's download progress while the system downloads; absent at rest.
    private(set) var downloading: [String: Double] = [:]
    /// Domains that the user turned off in System Settings.
    private(set) var turnedOff: Set<String> = []
    private let reader = SourceReaderHost()
    private let client: any RemoteClient = SMBClient()
    private let watchLimit = SMBWatch.folderLimit
    private let credentials = KeychainCredentialStore()
    /// By share ID, for the shares that locations use.
    private var connections: [UUID: ShareConnection] = [:]
    private let previousSessions = PreviousSessionStore()
    /// By server ID: one sign-in for every share of a server.
    private var signIns: [UUID: ServerSignIn] = [:]
    private var shareStates: [UUID: ConnectionState] = [:]
    /// By share ID, for Server Volumes.
    private var volumes: [UUID: ServerVolumeMount] = [:]
    /// The shares of Server Volumes that macOS has mounted.
    private(set) var mountedVolumes: Set<UUID> = []
    private var sources: [String: LocationSource] = [:]
    private var offlineVerification: [String: OfflineVerification] = [:]
    private var offlineGeneration: [String: UUID] = [:]
    private var domains: [String: NSFileProviderDomain] = [:]
    private var progress: [String: (progress: Progress, observation: NSKeyValueObservation)] = [:]
    private var domainObserver: (any NSObjectProtocol)?
    private var localContentObservers: [any NSObjectProtocol] = []
    private var discoveryTask: Task<Void, Never>?
    private var discovery: [String: DirectoryRefresh] = [:]
    private var discoveryMembershipDue: [String: Duration] = [:]
    private var discoveryCursor: String?
    private var spaceTask: Task<Void, Never>?
    private var spaceBlocked: [String: [String: SourceReadRequest]] = [:]
    private var wakeObserver: NotificationCenter.ObservationToken?
    /// Shares with a relisting running; true if a recovery asked for another one.
    private var relisting: [UUID: Bool] = [:]
    private var diagnosticsSignal: (any DispatchSourceSignal)?
    /// Folder completion's last listing, reused while the user types in the same folder.
    private var completion: (shareID: UUID, parent: RelativePath, names: [String])?
    private var completionListing: Task<Void, Never>?
    nonisolated private static let catalogLog = Logger(subsystem: "dev.tinymounter.prototype", category: "catalog")
    nonisolated private static let listingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")
    nonisolated private static let shareLog = Logger(subsystem: "dev.tinymounter.prototype", category: "share")
    nonisolated private static let readerLog = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")
    /// Remove Downloads reads the kept state again before each batch of evictions.
    private static let evictionBatch = 100

    init(store: SettingsStore) {
        self.store = store
        store.onUpdate = { [weak self] in self?.updateRemountWanted() }
        reader.source = { [weak self] in self?.sources[$0] }
        reader.confirmDeletion = { [weak self] domain, request, progress in
            guard let self else { throw UploadError.readOnly }
            try await self.confirmPermanentDeletion(domain, request: request, progress: progress)
        }
        reader.onConnected = { [weak self] domainID in
            Task { await self?.signalResolved(domainID, [.serverUnreachable]) }
        }
        reader.onActivity = { [weak self] in self?.onActivity?($0, $1) }
        reader.onTransfers = { [weak self] in self?.onTransfers?($0) }
        reader.onSpaceChange = { [weak self] domainID, request, blocked, name in
            guard let self, self.sources[domainID] != nil else { return }
            let before = self.spaceBlocked[domainID]?[request.item]
            if blocked {
                let previous = self.spaceBlocked[domainID]?[request.item]
                if previous?.version != request.version || (previous?.range.length ?? -1) < request.range.length {
                    self.spaceBlocked[domainID, default: [:]][request.item] = request
                }
            } else if let previous = self.spaceBlocked[domainID]?[request.item],
                      previous.version == request.version, previous.range.length <= request.range.length {
                self.spaceBlocked[domainID]?[request.item] = nil
            }
            if self.spaceBlocked[domainID]?[request.item] != before {
                self.saveSpaceBlockedDownloads()
                self.onLocationChange?(domainID)
                if before == nil, let name { self.onLowSpace?(domainID, name) }
            }
        }
    }

    deinit {
        discoveryTask?.cancel()
        spaceTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func confirmPermanentDeletion(_ domain: String, request: DeleteItemRequest,
                                          progress: Progress) async throws {
        guard let source = sources[domain], let confirm = onConfirmDeletion,
              !progress.isCancelled else { throw TransferError.cancelled }
        let selected = try await Self.offMain { try source.permanentDeletionSelection(request) }
        try await requireNoPendingDeletionChanges(selected)
        guard !progress.isCancelled, await confirm(selected, progress), !progress.isCancelled else {
            throw TransferError.cancelled
        }
        guard sources[domain] === source else { throw LocationError.catalogClosed }
        try await requireNoPendingDeletionChanges(selected)
        let current = try await Self.offMain { try source.permanentDeletionSelection(request) }
        guard current == selected else { throw SourceFailure.versionChanged }
    }

    private func requireNoPendingDeletionChanges(_ selection: PermanentDeletionSelection) async throws {
        for id in selection.domains {
            guard let domain = domains[id], let manager = NSFileProviderManager(for: domain) else {
                throw LocationError.catalogClosed
            }
            try await DeletionPendingObserver.requireEmpty(manager)
        }
    }

    /// The share's state; not connected until its first session starts.
    func shareState(_ shareID: UUID) -> ConnectionState { shareStates[shareID] ?? .notConnected }

    /// Servers that refused the saved password, or have none, for a location or a Server Volume.
    var refusedServers: Set<UUID> { Set(signIns.filter { $0.value.isRefused }.keys) }

    /// Nil for a record without an open catalog: "catalog unavailable" (docs/architecture.md §7).
    func isRootMissing(_ record: LocationRecord) -> Bool? { sources[record.domainID]?.isRootMissing }

    /// App launch: the staging sweep before any reader connects, then the domain steps.
    func launch() async {
        do { spaceBlocked = try DownloadRecovery.load(from: SharedContainer.url().appending(path: DownloadRecovery.fileName)) }
        catch { Self.readerLog.error("space_state_load \(logFields(error), privacy: .public)") }
        sweepStaging()
        do {
            offlineVerification = try VerifiedVersions.load(from: Self.verifiedVersionsURL)
                .mapValues { OfflineVerification(versions: $0) }
        } catch {
            Self.catalogLog.error("verified_versions_load \(logFields(error), privacy: .public)")
            offlineVerification = [:]
        }
        guard case .ready(let settings) = store.state else {
            problem = .settingsUnreadable
            Self.catalogLog.error("launch_reconciliation stopped reason=settings")
            onChange?()
            return
        }
        let registered: [String: NSFileProviderDomain]
        let catalogs: Set<String>
        do {
            registered = try await registeredDomains()
            catalogs = try SharedContainer.catalogDomainIDs()
        } catch {
            let failure = error as NSError
            problem = failure.domain == NSFileProviderErrorDomain
                && failure.code == NSFileProviderError.providerTranslocated.rawValue
                ? .providerTranslocated : .domainsUnreadable
            Self.catalogLog.error("launch_reconciliation stopped \(logFields(error), privacy: .public)")
            onChange?()
            return
        }
        previousSessions.keep(Set(settings.shares.map(\.id)))
        let plan = LaunchReconciliation.plan(records: .success(settings.locations), catalogs: catalogs,
                                             domains: Set(registered.keys))
        for id in plan.unknownDomains {
            Self.catalogLog.info("launch_reconciliation unknown_domain=\(id, privacy: .public) kept=1")
        }
        var failed = 0
        for sequence in plan.sequences {
            for step in sequence {
                do {
                    try await run(step, registered: registered)
                    Self.catalogLog.info("launch_step \(Self.label(step), privacy: .public) ok=1")
                } catch {
                    failed += 1
                    Self.catalogLog.error("""
                        launch_step \(Self.label(step), privacy: .public) ok=0 \(logFields(error), privacy: .public)
                        """)
                    break
                }
            }
        }
        Self.catalogLog.info("""
            launch_reconciliation records=\(settings.locations.count) catalogs=\(catalogs.count) \
            domains=\(registered.count) unknown_domains=\(plan.unknownDomains.count) failed_sequences=\(failed)
            """)
        openSources()
        for id in offlineVerification.keys where sources[id] == nil { setVerification(id, nil) }
        for volume in settings.serverVolumes { self.volume(for: volume.shareID)?.checkNow() }
        await refreshDomains()
        // Posted only after a first domains() call, such as refreshDomains made.
        domainObserver = NotificationCenter.default.addObserver(forName: .fileProviderDomainDidChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshDomains() }
        }
        // A materialized item can still be pending when it first appears.
        localContentObservers = [Notification.Name.fileProviderMaterializedSetDidChange,
                                 .fileProviderPendingSetDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.onMaterializedChange?()
                    self?.discoveryMembershipDue.removeAll()
                }
            }
        }
        // Only shares with locations connect; a Server Volume is macOS's own mount.
        for id in Set(settings.locations.filter { !$0.removing }.map(\.shareID)) { connection(for: id)?.connect() }
        await logDiagnostics(reason: "launch")
        installDiagnosticsSignal()
        isReady = true
        for source in sources.values { source.retryDeletions() }
        startDiscovery()
        spaceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.retrySpaceBlockedDownloads()
            }
        }
        onChange?()
    }

    /// Add Share…: a share that is saved already keeps its ID.
    func saveShare(serverID: UUID, name: String) throws -> UUID {
        var saved = UUID()
        try store.update { settings in
            guard settings.servers.contains(where: { $0.id == serverID }) else { throw SettingsError.invalidServer }
            if let existing = settings.shares.first(where: { $0.serverID == serverID && $0.name == name }) {
                saved = existing.id
            } else {
                settings.shares.append(ShareRecord(id: saved, serverID: serverID, name: name))
            }
        }
        onChange?()
        return saved
    }

    /// Sign In Again… saved a new password: every share of the server signs in with it.
    func credentialsChanged(_ serverID: UUID) {
        signIns[serverID]?.credentialsChanged()
        let ids = Set(store.settings?.shares.filter { $0.serverID == serverID }.map(\.id) ?? [])
        for (id, connection) in connections where ids.contains(id) { connection.credentialsChanged() }
        for (id, volume) in volumes where ids.contains(id) { volume.credentialsChanged() }
        onChange?()
    }

    func removeServer(_ id: UUID) async throws {
        guard let settings = store.settings else { throw SettingsError.invalidServer }
        guard !settings.serverIsUsed(id) else { throw SettingsError.serverInUse }
        let ids = settings.shares.filter { $0.serverID == id }.map(\.id)
        try store.update { try $0.removeServer(id) }
        for share in ids { forget(share) }
        signIns[id] = nil
        onChange?()
    }

    /// Forgets an unused share. A server without other shares goes with it.
    func removeShare(_ id: UUID) async throws {
        guard let settings = store.settings else { throw SettingsError.invalidServer }
        guard !settings.shareIsUsed(id) else { throw SettingsError.shareInUse }
        let serverID = settings.shares.first { $0.id == id }?.serverID
        try store.update { try $0.removeShare(id) }
        forget(id)
        if let serverID, store.settings?.servers.contains(where: { $0.id == serverID }) != true { signIns[serverID] = nil }
        onChange?()
    }

    private func forget(_ shareID: UUID) {
        connections[shareID]?.close()
        connections[shareID] = nil
        previousSessions.keep(Set(store.settings?.shares.map(\.id) ?? []))
        shareStates[shareID] = nil
        volumes[shareID] = nil
        mountedVolumes.remove(shareID)
    }

    /// Quit, logout, restart or shutdown: the next run names the sessions that are open now.
    func terminate() { previousSessions.end() }

    /// Connect in a location: the next connection attempt starts now.
    func connect(_ shareID: UUID) { connection(for: shareID)?.connect() }

    /// Server Volume: a visible mount through macOS with the server's saved password.
    /// Nil once the share is mounted.
    func mountVolume(_ shareID: UUID) async -> SourceFailure? {
        guard let volume = volume(for: shareID) else { return .missing }
        let failure = await volume.mount()
        if failure == .notAuthenticated { onChange?() }
        return failure
    }

    /// Server Volume Disconnect: an eject, after which macOS does not mount it again.
    func unmountVolume(_ shareID: UUID, reason: String = "disconnect") async throws {
        try await volume(for: shareID)?.unmount(reason: reason)
    }

    /// Where the Server Volume's share is mounted; nil if it isn't.
    func volumePath(_ shareID: UUID) -> String? { volume(for: shareID)?.mountPath }

    /// The Server Volume's `smb://` URL, without a password.
    func volumeURL(_ shareID: UUID) -> URL? { volume(for: shareID)?.shareURL }

    func addServerVolume(id: UUID, shareID: UUID) throws {
        guard isReady else { throw LocationError.catalogClosed }
        try store.update { settings in
            try settings.requireMode(.serverVolume, for: shareID)
            settings.serverVolumes.append(ServerVolumeRecord(id: id, shareID: shareID))
        }
        updateRemountWanted()
        onChange?()
    }

    func removeServerVolume(_ id: UUID) async throws {
        guard let volume = store.settings?.serverVolumes.first(where: { $0.id == id }) else { return }
        volumes[volume.shareID]?.setRemountWanted(false)
        defer { updateRemountWanted() }
        try await unmountVolume(volume.shareID, reason: "location_removed")
        try store.update { $0.serverVolumes.removeAll { $0.id == id } }
        onChange?()
    }

    /// Create the catalog, list the root into it, save the record, then add the domain.
    /// The record takes the saved Keep Downloaded paths inside its folder. A copy goes
    /// below its original (design §4.2).
    func add(id: UUID, name: String, folder: RelativePath, shareID: UUID,
             after original: UUID? = nil, readOnly: Bool) async throws -> LocationRecord {
        guard isReady, let settings = store.settings, let address = settings.address(of: shareID) else {
            throw CocoaError(.fileReadUnknown)
        }
        try settings.requireMode(.fileProvider, for: shareID)
        var record = LocationRecord(id: id, name: LocationRecord.uniqueName(name, among: settings.locations.map(\.name)),
                                    shareID: shareID, folder: folder)
        record.readOnly = readOnly
        let listedName = record.name
        let source = try await makeListedSource(record, folder: folder)
        do {
            try store.update { settings in
                try settings.requireMode(.fileProvider, for: shareID)
                // Another Add or a rename can take the name during the root listing.
                record.name = LocationRecord.uniqueName(name, among: settings.locations.map(\.name))
                record.pendingKeeps = settings.takeSavedKeeps(host: address.host, share: address.share, inside: folder)
                if let index = settings.locations.firstIndex(where: { $0.id == original }) {
                    settings.locations.insert(record, at: index + 1)
                } else {
                    settings.locations.append(record)
                }
            }
        } catch {
            discard(source, record.domainID)
            throw error
        }
        Self.catalogLog.info("""
            location_added domain=\(record.domainID, privacy: .public) pending_keeps=\(record.pendingKeeps.count)
            """)
        if record.name != listedName { try? await Self.offMain { [name = record.name] in try source.setRootName(name) } }
        sources[record.domainID] = source
        if paused { Self.pause(source, true) }
        onChange?()
        try await NSFileProviderManager.add(domain(for: record))
        await refreshDomains()
        return record
    }

    /// Read only on: writes stop before the setting is saved. Off: the setting is saved first.
    func setWriteMode(_ recordID: UUID, readOnly: Bool) async throws {
        guard isReady, let record = store.settings?.locations.first(where: { $0.id == recordID }),
              !record.removing, let source = sources[record.domainID] else { throw UploadError.readOnly }
        let save: (Bool) throws -> Void = { readOnly in
            try self.store.update { settings in
                guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { throw UploadError.readOnly }
                settings.locations[index].readOnly = readOnly
            }
        }
        if !readOnly {
            try save(false)
            do { try await Self.offMain { try source.configureWriteMode(true) } }
            catch { try save(record.readOnly); throw error }
        } else {
            try await Self.offMain { try source.configureWriteMode(false) }
            do { try save(true) }
            catch {
                try? await Self.offMain { try source.configureWriteMode(!record.readOnly) }
                throw error
            }
        }
        onChange?()
    }

    func savedChangeBytes(_ record: LocationRecord) async throws -> Int64 {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.savedChangeBytes() }
    }

    func retryPending(_ record: LocationRecord) { retryPending(domainID: record.domainID) }

    private func retryPending(domainID: String) {
        guard let source = sources[domainID] else { return }
        let shared = sources.values.filter { $0.editNamespace === source.editNamespace }
        for candidate in shared { candidate.retryRenames() }
        Task { for candidate in shared { await resumeCreates(candidate.domainID) } }
    }

    /// macOS sends the item again after the signal and is told to keep it on this Mac.
    func stopCreate(_ record: LocationRecord, template: String) async throws {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        try await Self.offMain { try source.stopCreate(template) }
        await resumeCreates(record.domainID)
    }

    func systemPendingChanges(_ record: LocationRecord) async throws -> SystemPendingChanges {
        guard let source = sources[record.domainID], let manager = manager(for: record) else {
            throw LocationError.catalogClosed
        }
        let snapshot = try await SystemPendingObserver.read(manager)
        return try await Self.offMain {
            let hasUnresolvedRename = try !source.renameRecords().isEmpty
            return try source.withCatalog { catalog in
                let items = try snapshot.items.map { item in
                    SystemPendingChange(change: try PendingChange(item: item.id, name: item.name,
                        parent: item.parent, trashed: item.trashed,
                        organizationRefused: SourceReaderBridge.isRefusedOrganization(item.error),
                        hasUnresolvedRename: hasUnresolvedRename, catalog: catalog), error: item.error)
                }
                return SystemPendingChanges(items: items.sorted { $0.change.path < $1.change.path },
                                            incomplete: snapshot.incomplete)
            }
        }
    }

    func pendingCreates(_ record: LocationRecord) async throws -> [PendingCreate] {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.pendingCreates() }
    }

    func deletionRecords(_ record: LocationRecord) async throws -> [DeletionStatus] {
        let owners = sources
        return try await Self.offMain {
            try LocationSource.deletionOutbox().records()
                .filter { $0.needsAttention && $0.plan.views.contains { $0.domain == record.domainID } }
                .map { deletion in
                    try DeletionStatus(record: deletion, domain: record.domainID,
                                       attempt: owners[deletion.plan.owner]?.deletionAttempt(deletion.id))
                }.sorted { $0.path < $1.path }
        }
    }

    func retryDeletion(_ record: LocationRecord, id: UUID) async throws {
        let (source, deletion) = try await deletionOwner(record, id: id)
        guard deletion.isSettled || SourceReaderBridge.deletionResumeEnabled else { throw UploadError.readOnly }
        // A settled refusal must be selected again in Finder, never admitted again by Retry.
        guard !deletion.isComplete else { return }
        _ = try await withCheckedThrowingContinuation { continuation in
            source.retryDeletion(id) { continuation.resume(with: $0) }
        }
    }

    func stopDeletion(_ record: LocationRecord, id: UUID) async throws {
        let (source, _) = try await deletionOwner(record, id: id)
        try await withCheckedThrowingContinuation { continuation in
            source.stopDeletion(id) { continuation.resume(with: $0) }
        }
    }

    func dismissDeletion(_ record: LocationRecord, id: UUID) async throws {
        let (source, _) = try await deletionOwner(record, id: id)
        try await withCheckedThrowingContinuation { continuation in
            source.dismissDeletion(id) { continuation.resume(with: $0) }
        }
    }

    private func deletionOwner(_ record: LocationRecord, id: UUID) async throws -> (LocationSource, PendingDeletion) {
        let deletion = try await Self.offMain {
            try LocationSource.deletionOutbox().records().first {
                $0.id == id && $0.plan.views.contains { $0.domain == record.domainID }
            }
        }
        guard let deletion, let source = sources[deletion.plan.owner] else { throw LocationError.catalogClosed }
        return (source, deletion)
    }

    /// macOS stops sending an item that failed with `cannotSynchronize` until this signal.
    private func resumeCreates(_ domainID: String) async {
        guard let domain = domains[domainID], let manager = NSFileProviderManager(for: domain) else { return }
        do { try await manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize)) } catch {
            Self.shareLog.error("resume_creates domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
        }
    }

    func renameRecords(_ record: LocationRecord) async throws -> [RenameIntent] {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.renameRecords() }
    }

    func pendingUploads(_ record: LocationRecord) async throws -> Int {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.pendingUploads() }
    }

    /// Name: a unique name in the record and the root row, then `add` again with the same ID.
    func rename(_ recordID: UUID, to name: String) async throws -> String {
        guard isReady, let settings = store.settings,
              var record = settings.locations.first(where: { $0.id == recordID }), !record.removing else {
            throw CocoaError(.fileReadUnknown)
        }
        let unique = LocationRecord.uniqueName(name, among: settings.locations.filter { $0.id != recordID }.map(\.name))
        guard unique != record.name else { return unique }
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            settings.locations[index].name = unique
        }
        record.name = unique
        domains[record.domainID] = domain(for: record)
        onChange?()
        if let source = sources[record.domainID] { try await Self.offMain { try source.setRootName(unique) } }
        try await NSFileProviderManager.add(domain(for: record))
        Self.catalogLog.info("location_renamed domain=\(record.domainID, privacy: .public)")
        await refreshDomains()
        return unique
    }

    /// Apply: a new catalog with its root listed, the record with both domain IDs, the old
    /// domain removed, then the new one added. Kept paths inside the new source stay pending on the
    /// location; the others go to the old share's saved list.
    func apply(_ recordID: UUID, shareID: UUID, folder: RelativePath) async throws -> LocationRecord {
        guard isReady, let settings = store.settings,
              let record = settings.locations.first(where: { $0.id == recordID }), !record.removing,
              let address = settings.address(of: shareID) else {
            throw CocoaError(.fileReadUnknown)
        }
        try settings.requireMode(.fileProvider, for: shareID)
        let previousSource = sources[record.domainID]
        if let previousSource { try await Self.offMain { try previousSource.suspendMutations() } }
        else if try LocationSource.pendingWrites(domainID: record.domainID) > 0 { throw UploadError.pendingWrites }
        defer { previousSource?.resumeMutations() }
        let oldAddress = settings.address(of: record.shareID)
        let kept = await keptSharePaths(record) + record.pendingKeeps
        let sameShare = oldAddress?.isSameShare(host: address.host, share: address.share) ?? false
        let moving = sameShare ? kept.filter { $0.below(folder) != nil } : []
        var updated = record
        updated.domainID = UUID().uuidString
        updated.retiredDomainID = record.domainID
        updated.shareID = shareID
        updated.folder = folder.string
        let source = try await makeListedSource(updated, folder: folder)
        do {
            try store.update { settings in
                try settings.requireMode(.fileProvider, for: shareID)
                guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
                if let oldAddress {
                    settings.saveKeeps(kept.filter { !moving.contains($0) }, host: oldAddress.host, share: oldAddress.share)
                }
                var added = Set<KeepPath>()
                updated.pendingKeeps = (moving + settings.takeSavedKeeps(host: address.host, share: address.share, inside: folder))
                    .filter { added.insert($0).inserted }
                settings.locations[index] = updated
            }
        } catch {
            discard(source, updated.domainID)
            throw error
        }
        notOnServer[recordID] = nil
        sources.removeValue(forKey: record.domainID)?.close()
        setVerification(record.domainID, nil)
        domains[record.domainID] = nil
        sources[updated.domainID] = source
        if paused { Self.pause(source, true) }
        onChange?()
        // Remove before add, so two domains never share a display name or a disk location [H].
        try await run(.removeDomain(record.domainID), registered: registeredDomains())
        try Catalog.delete(at: SharedContainer.catalogURL(domainID: record.domainID))
        try LocationSource.outbox(domainID: record.domainID).removeIfCompleted()
        try LocationSource.renameOutbox().removeCompletedIntents(removedDomain: record.domainID)
        try LocationSource.deletionOutbox().removeSettled(domain: record.domainID)
        previousSource?.editNamespace.unregister(record.domainID)
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            settings.locations[index].retiredDomainID = nil
        }
        updated.retiredDomainID = nil
        try await NSFileProviderManager.add(domain(for: updated))
        Self.catalogLog.info("""
            location_applied domain=\(updated.domainID, privacy: .public) retired=\(record.domainID, privacy: .public) \
            pending_keeps=\(updated.pendingKeeps.count)
            """)
        await refreshDomains()
        onChange?()
        return updated
    }

    func removalItems(_ record: LocationRecord) async throws -> RemovalItems {
        try await Self.offMain { try LocationSource.removalItems(domainID: record.domainID) }
    }

    /// Save the kept paths if asked, mark the record, remove the domain, delete the
    /// catalog, delete the record. `stopping` is what the user confirmed would stop.
    func remove(_ recordID: UUID, saveKeeps: Bool, stopping: [String] = []) async throws {
        guard isReady, let settings = store.settings, let record = settings.locations.first(where: { $0.id == recordID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let previousSource = sources[record.domainID]
        if let previousSource { try await Self.offMain { try previousSource.suspendForRemoval(stopping: stopping) } }
        else {
            let items = try LocationSource.removalItems(domainID: record.domainID)
            guard items.blocking.isEmpty, items.stoppable == stopping else { throw UploadError.pendingWrites }
        }
        defer { previousSource?.resumeMutations() }
        let address = settings.address(of: record.shareID)
        // A location whose catalog can't be read saves only its pending paths; it must stay removable.
        let paths = saveKeeps && !record.removing ? await keptSharePaths(record) + record.pendingKeeps : []
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            if let address { settings.saveKeeps(paths, host: address.host, share: address.share) }
            settings.locations[index].removing = true
        }
        notOnServer[recordID] = nil
        onChange?()
        // Downloaded copies are only NAS files again; a later location downloads them anew.
        try await run(.removeDomain(record.domainID), registered: registeredDomains())
        sources.removeValue(forKey: record.domainID)?.close()
        setVerification(record.domainID, nil)
        domains[record.domainID] = nil
        try Catalog.delete(at: SharedContainer.catalogURL(domainID: record.domainID))
        try LocationSource.outbox(domainID: record.domainID).removeForLocationRemoval()
        try LocationSource.renameOutbox().removeCompletedIntents(removedDomain: record.domainID)
        try LocationSource.deletionOutbox().removeSettled(domain: record.domainID)
        previousSource?.editNamespace.unregister(record.domainID)
        try store.update { $0.locations.removeAll { $0.id == recordID } }
        Self.catalogLog.info("""
            location_removed domain=\(record.domainID, privacy: .public) saved_keeps=\(paths.count)
            """)
        await refreshDomains()
        onChange?()
    }

    /// Pause: Keep Downloaded downloads and read-ahead stop; a file that the user opens downloads.
    /// Returns false if a catalog kept its earlier state.
    func setPaused(_ paused: Bool) async -> Bool {
        // Each change waits for the one before it, so the last request is the state that stays.
        let previous = pauseChange
        let change = Task {
            _ = await previous?.value
            self.paused = paused
            let all = Array(sources.values)
            // Catalog writes can wait for a listing's commit, so they run off the main actor.
            let failed = await Task.detached { all.count { !Self.pause($0, paused) } }.value
            // Only after every commit: a fetch that the extension checks later sees `paused`.
            if paused { reader.pauseDownloads() }
            // A catalog that stays paused needs Resume.
            if failed > 0 { self.paused = true }
            onChange?()
            return failed == 0
        }
        pauseChange = change
        return await change.value
    }

    @discardableResult
    nonisolated private static func pause(_ source: LocationSource, _ paused: Bool) -> Bool {
        do {
            let changed = try source.setPaused(paused)
            catalogLog.info("""
                paused=\(paused) domain=\(source.domainID, privacy: .public) kept_changed=\(changed)
                """)
            return true
        } catch {
            catalogLog.error("""
                paused=\(paused) domain=\(source.domainID, privacy: .public) failed \(logFields(error), privacy: .public)
                """)
            return false
        }
    }

    func manager(for record: LocationRecord) -> NSFileProviderManager? {
        NSFileProviderManager(for: domains[record.domainID] ?? domain(for: record))
    }

    /// Explicit requests, with their paths below the location folder.
    func keptPaths(_ record: LocationRecord) async -> [(id: String, path: RelativePath, kind: CatalogRow.Kind)] {
        guard let source = sources[record.domainID] else { return [] }
        do { return try await Self.offMain { try source.keptPaths() } } catch {
            Self.catalogLog.error("kept_paths domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)")
            return []
        }
    }

    /// `update` gets each check's states, and true when they are verified: the synchronized check,
    /// or a local check that trusted every local copy.
    func offlineStates(_ record: LocationRecord, update: ([String: OfflineState], Bool) -> Void) async {
        guard let source = sources[record.domainID], let manager = manager(for: record),
              !record.removing, !turnedOff.contains(record.domainID) else {
            setVerification(record.domainID, nil)
            offlineGeneration[record.domainID] = nil
            update([:], false)
            return
        }
        let generation = UUID()
        offlineGeneration[record.domainID] = generation
        do {
            let snapshot = try await Self.offMain { try source.keepSnapshot() }
            guard !Task.isCancelled, sources[record.domainID] === source,
                  offlineGeneration[record.domainID] == generation,
                  !turnedOff.contains(record.domainID) else { return }
            guard !snapshot.requests.isEmpty else {
                setVerification(record.domainID, nil)
                update([:], false)
                return
            }
            for synchronized in [false, true] {
                if synchronized {
                    do {
                        try await manager.signalEnumerator(for: .workingSet)
                        try await manager.waitForStabilization()
                    } catch {
                        // A blocked download cannot invalidate other versions already checked locally.
                        if DownloadSpace.isFull(error), spaceBlocked[record.domainID]?.isEmpty == false { return }
                        throw error
                    }
                }
                let observed = try await localOfflineStates(snapshot, manager: manager)
                let current = try await Self.offMain { try source.keepSnapshot() }
                guard !Task.isCancelled, sources[record.domainID] === source,
                      offlineGeneration[record.domainID] == generation,
                      !turnedOff.contains(record.domainID) else { return }
                guard current == snapshot else {
                    update([:], false)
                    return
                }
                var verification = offlineVerification[record.domainID] ?? OfflineVerification()
                let blocked = Set(snapshot.items.filter {
                    spaceBlocked[record.domainID]?[$0.id]?.version == $0.contentVersion
                }.map(\.id))
                let states = verification.states(snapshot: snapshot, files: observed.files,
                                                 folders: observed.folders, synchronized: synchronized,
                                                 spaceBlocked: blocked)
                setVerification(record.domainID, verification)
                update(states, synchronized || verification.trustedAll)
            }
        } catch {
            guard !Task.isCancelled, sources[record.domainID] === source,
                  offlineGeneration[record.domainID] == generation else { return }
            setVerification(record.domainID, nil)
            update([:], false)
            Self.catalogLog.error("offline_state domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)")
        }
    }

    private func localOfflineStates(_ snapshot: FolderKeepSnapshot, manager: NSFileProviderManager) async throws
        -> (files: [String: OfflineState], folders: Set<String>) {
        let materialized = try await MaterializedItems.read(manager)
        let files = Set(materialized.files)
        var result: [String: OfflineState] = [:]
        for row in snapshot.items where row.kind == .file && files.contains(row.id) {
            try Task.checkCancellation()
            do {
                let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(row.id))
                result[row.id] = try await Self.offMain {
                    var url = url
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    url.removeAllCachedResourceValues()
                    let values = try url.resourceValues(forKeys: [
                        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
                        .isUbiquitousItemKey, .fileSizeKey, .contentModificationDateKey
                    ])
                    return OfflineState(status: values.ubiquitousItemDownloadingStatus,
                                        downloading: values.ubiquitousItemIsDownloading,
                                        ubiquitous: values.isUbiquitousItem, size: values.fileSize,
                                        modified: values.contentModificationDate, expectedSize: row.size,
                                        expectedModified: row.modificationDate)
                }
            } catch {
                result[row.id] = .requested
            }
        }
        return (result, Set(materialized.folders))
    }

    /// `−` cancels an explicit request; inherited retention can still apply.
    func unkeep(_ itemID: String, in record: LocationRecord) async throws {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        _ = try await Self.offMain { try source.keep([itemID], value: false) }
    }

    /// `−` on a saved path that the location hasn't found.
    func discardPendingKeep(_ path: KeepPath, in recordID: UUID) throws {
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            settings.locations[index].pendingKeeps.removeAll { $0 == path }
        }
        notOnServer[recordID]?.remove(path)
        onChange?()
    }

    /// Lists the parent folders of each pending path, as flow 1 does, and keeps the files
    /// it finds. A path that a complete listing of its parent lacks is not on the server; one that
    /// can't be checked yet stays for the next recovery.
    func restorePendingKeeps(_ recordID: UUID) async {
        guard let record = store.settings?.locations.first(where: { $0.id == recordID }), !record.removing,
              !record.pendingKeeps.isEmpty, let source = sources[record.domainID],
              let folder = RelativePath(record.folder), restoring.insert(recordID).inserted else { return }
        defer {
            restoring.remove(recordID)
            for participant in sources.values where participant.editNamespace === source.editNamespace {
                participant.retryDeletions()
                participant.retryRenames()
            }
        }
        var listed: Set<String> = []
        var found: [(path: KeepPath, id: String)] = []
        var missing: Set<KeepPath> = []
        var waiting = 0
        for path in record.pendingKeeps {
            guard let below = path.below(folder) else {
                missing.insert(path)
                continue
            }
            do {
                if let id = try await resolveItem(below, kind: path.kind, in: source, listed: &listed) {
                    found.append((path, id))
                } else {
                    missing.insert(path)
                }
            } catch {
                waiting += 1
                // Every path would fail the same way; the next recovery tries them again.
                if let failure = error as? SourceFailure,
                   [SourceFailure.serverUnreachable, .notConnected, .localNetworkDenied, .notAuthenticated].contains(failure) { break }
            }
        }
        var kept: [String] = []
        if !found.isEmpty {
            do {
                let ids = found.map(\.id)
                _ = try await Self.offMain { try source.keep(ids, value: true) }
                let done = Set(found.map(\.path))
                try store.update { settings in
                    guard let index = settings.locations.firstIndex(where: { $0.domainID == record.domainID }) else { return }
                    settings.locations[index].pendingKeeps.removeAll(where: done.contains)
                }
                kept = ids
            } catch {
                Self.catalogLog.error("""
                    restore_keeps domain=\(record.domainID, privacy: .public) failed \(logFields(error), privacy: .public)
                    """)
            }
        }
        guard store.settings?.locations.contains(where: { $0.domainID == record.domainID }) == true else { return }
        notOnServer[recordID] = missing.isEmpty ? nil : missing
        Self.catalogLog.info("""
            restore_keeps domain=\(record.domainID, privacy: .public) pending=\(record.pendingKeeps.count) \
            kept=\(kept.count) not_on_server=\(missing.count) waiting=\(waiting) listed=\(listed.count)
            """)
        onChange?()
        if !kept.isEmpty { onKeepsRestored?(record, kept) }
    }

    /// The kept files below a folder that the system hasn't materialized; they download only when
    /// the user opens that folder (M6).
    func filesInFoldersNotMaterialized(_ ids: [String], in record: LocationRecord) async -> [String] {
        guard !ids.isEmpty, let source = sources[record.domainID], let manager = manager(for: record) else { return [] }
        do {
            let materialized = Set(try await MaterializedItems.read(manager).folders)
            return try await Self.offMain {
                let snapshot = try source.keepSnapshot()
                let files = Set(snapshot.requests.filter { $0.kind == .file }.map(\.id))
                let keptFolders = Set(snapshot.items.filter { $0.kind == .folder }.map(\.id))
                return try ids.filter { id in
                    guard files.contains(id) else { return false }
                    let parents = try source.parentChain(of: id)
                    return parents.allSatisfy { !keptFolders.contains($0) }
                        && parents.contains { !materialized.contains($0) }
                }
            }
        } catch {
            Self.listingLog.error("materialized domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)")
            return ids
        }
    }

    /// Asks the system to enumerate each folder above these files, the root first, so that it
    /// downloads the kept files in them. A request on a folder materializes only its children [H].
    func requestFolders(above ids: [String], in record: LocationRecord) async {
        guard let source = sources[record.domainID], let manager = manager(for: record) else { return }
        var requested = 0, failed = 0
        do {
            let materialized = Set(try await MaterializedItems.read(manager).folders)
            let folders = try await Self.offMain {
                var folders: [String] = []
                var seen: Set<String> = []
                for id in ids {
                    for folder in try source.parentChain(of: id)
                    where !materialized.contains(folder) && seen.insert(folder).inserted {
                        folders.append(folder)
                    }
                }
                return folders
            }
            for folder in folders {
                do {
                    try await manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(folder))
                    requested += 1
                } catch {
                    failed += 1
                    Self.listingLog.error("""
                        request_folder domain=\(record.domainID, privacy: .public) folder=\(folder, privacy: .public) \
                        \(logFields(error), privacy: .public)
                        """)
                }
            }
        } catch {
            Self.listingLog.error("request_folders domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)")
        }
        Self.listingLog.info("""
            request_folders domain=\(record.domainID, privacy: .public) files=\(ids.count) requested=\(requested) \
            failed=\(failed)
            """)
    }

    /// Folder completion: lists the typed parent folder unless the last listing was of it.
    /// It never lists more than one folder at a time, and a cancelled request lists nothing.
    func folderSuggestions(shareID: UUID, typed: String) async -> [String] {
        guard let query = FolderCompletion(typed: typed), let connection = connection(for: shareID) else { return [] }
        while completion?.shareID != shareID || completion?.parent != query.parent {
            if let running = completionListing {
                await running.value
                continue
            }
            guard !Task.isCancelled else { return [] }
            let listing = Task {
                let started = ContinuousClock.now
                do {
                    let names = try await connection.folderNames(in: query.parent)
                    completion = (shareID, query.parent, names)
                    Self.listingLog.info("""
                        completion_list folders=\(names.count) \
                        total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
                        """)
                } catch {
                    // Typing on in the same folder doesn't list it again.
                    completion = (shareID, query.parent, [])
                    Self.listingLog.error("completion_list \(logFields(error), privacy: .public)")
                }
                completionListing = nil
            }
            completionListing = listing
            await listing.value
        }
        return completion.map { query.suggestions(from: $0.names) } ?? []
    }

    /// Select…'s folder browser: every subfolder name of `path`, or the listing's failure.
    func folderNames(shareID: UUID, in path: RelativePath) async throws -> [String] {
        guard let connection = connection(for: shareID) else { throw SettingsError.invalidServer }
        return try await connection.folderNames(in: path)
    }

    /// The Folder field lost focus: the next completion lists again.
    func endFolderCompletion() {
        completion = nil
    }

    /// Storage: the catalog sizes of the materialized files; nil if they can't be read.
    func storage(_ record: LocationRecord) async -> StorageUsage? {
        guard let source = sources[record.domainID], let manager = manager(for: record) else { return nil }
        do {
            let files = try await MaterializedItems.read(manager).files
            return try await Self.offMain { try source.storage(materialized: files) }
        } catch {
            Self.catalogLog.error("storage domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)")
            return nil
        }
    }

    /// Remove Downloads: evicts the materialized files that are not kept. A file that an app
    /// has open stays. Returns the files removed and the files that stayed; nil if none were read.
    func removeDownloads(_ record: LocationRecord) async -> (removed: Int, stayed: Int)? {
        guard let source = sources[record.domainID], let manager = manager(for: record) else { return nil }
        let started = ContinuousClock.now
        var files = 0, removed = 0, stayed = 0, firstError: Error?
        do {
            let materialized = try await MaterializedItems.read(manager).files
            files = materialized.count
            for start in stride(from: 0, to: materialized.count, by: Self.evictionBatch) {
                let batch = Array(materialized[start..<min(start + Self.evictionBatch, materialized.count)])
                // Read just before each batch, so a file kept since the pane showed stays.
                for id in try await Self.offMain({ try source.storage(materialized: batch).removable }) {
                    do {
                        try await manager.evictItem(identifier: NSFileProviderItemIdentifier(id))
                        removed += 1
                    } catch {
                        stayed += 1
                        if firstError == nil { firstError = error }
                    }
                }
            }
        } catch {
            Self.catalogLog.error("""
                remove_downloads domain=\(record.domainID, privacy: .public) removed=\(removed) \
                \(logFields(error), privacy: .public)
                """)
            return nil
        }
        Self.catalogLog.info("""
            remove_downloads domain=\(record.domainID, privacy: .public) files=\(files) removed=\(removed) \
            stayed=\(stayed) \(firstError.map { "first_error " + logFields($0) } ?? "", privacy: .public) \
            total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
            """)
        return (removed, stayed)
    }

    /// Diagnostics: counts only.
    func diagnostics() async -> Diagnostics {
        let sources = Array(sources.values)
        let shares = Array(connections.values)
        return (try? await Self.offMain { Self.diagnostics(sources, shares) }) ?? Diagnostics()
    }

    private nonisolated static func diagnostics(_ sources: [LocationSource], _ shares: [ShareConnection]) -> Diagnostics {
        var counts = Diagnostics()
        for source in sources {
            do {
                let catalog = try source.counts()
                counts.catalogsOpen += 1
                counts.items += catalog.live
                counts.tombstones += catalog.tombstones
                counts.listedFolders += catalog.listedFolders
                counts.kept += catalog.kept
                if try source.isPaused() { counts.catalogsPaused += 1 }
            } catch {
                counts.catalogsUnavailable += 1
            }
        }
        counts.catalogFiles = (try? SharedContainer.catalogDomainIDs().count) ?? -1
        counts.stageFiles = stageFileCount()
        counts.descriptors = descriptorCount()
        counts.residentBytes = residentBytes()
        counts.shares = shares.count
        counts.connected = shares.count { $0.state == .connected }
        return counts
    }

    /// At launch and on SIGUSR1.
    func logDiagnostics(reason: String) async {
        let counts = await diagnostics()
        Self.catalogLog.info("""
            diagnostics reason=\(reason, privacy: .public) catalog_files=\(counts.catalogFiles) \
            catalogs_open=\(counts.catalogsOpen) catalogs_unavailable=\(counts.catalogsUnavailable) \
            items=\(counts.items) tombstones=\(counts.tombstones) listed_folders=\(counts.listedFolders) \
            stage_files=\(counts.stageFiles) descriptors=\(counts.descriptors) rss_bytes=\(counts.residentBytes) \
            shares=\(counts.shares) connected=\(counts.connected) kept=\(counts.kept) catalogs_paused=\(counts.catalogsPaused)
            """)
    }

    private func run(_ step: LaunchReconciliation.Step, registered: [String: NSFileProviderDomain]) async throws {
        switch step {
        case .removeDomain(let id):
            guard try LocationSource.removalItems(domainID: id).blocking.isEmpty else { throw UploadError.pendingWrites }
            guard let domain = registered[id] else { return }
            // Items that never reached the server, also ones that the user stopped, stay on this Mac.
            let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
            // macOS returns a location even when it kept nothing, and then creates no folder there.
            let kept = preserved.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            Self.catalogLog.info("domain_removed domain=\(id, privacy: .public) preserved=\(kept ? 1 : 0)")
            if kept, let preserved { onPreserved?(preserved) }
        case .deleteCatalog(let id):
            guard try LocationSource.removalItems(domainID: id).blocking.isEmpty else { throw UploadError.pendingWrites }
            try Catalog.delete(at: SharedContainer.catalogURL(domainID: id))
            try LocationSource.outbox(domainID: id).removeForLocationRemoval()
            try LocationSource.renameOutbox().removeCompletedIntents(removedDomain: id)
            try LocationSource.deletionOutbox().removeSettled(domain: id)
        case .deleteRecord(let id):
            try store.update { $0.locations.removeAll { $0.id == id } }
        case .clearRetiredDomain(let id):
            try store.update { settings in
                guard let index = settings.locations.firstIndex(where: { $0.id == id }) else { return }
                settings.locations[index].retiredDomainID = nil
            }
        case .addDomain(let id):
            guard let record = store.settings?.locations.first(where: { $0.id == id }) else {
                throw CocoaError(.fileReadUnknown)
            }
            try await NSFileProviderManager.add(domain(for: record))
        }
    }

    private static func label(_ step: LaunchReconciliation.Step) -> String {
        switch step {
        case .removeDomain(let id): "step=remove_domain domain=\(id)"
        case .deleteCatalog(let id): "step=delete_catalog domain=\(id)"
        case .deleteRecord(let id): "step=delete_record record=\(id.uuidString)"
        case .clearRetiredDomain(let id): "step=clear_retired_domain record=\(id.uuidString)"
        case .addDomain(let id): "step=add_domain record=\(id.uuidString)"
        }
    }

    private func openSources() {
        guard let settings = store.settings else { return }
        for record in settings.locations where !record.removing && sources[record.domainID] == nil {
            do {
                guard let folder = RelativePath(record.folder) else { throw CocoaError(.fileReadCorruptFile) }
                let catalog = try Catalog.openWriter(at: SharedContainer.catalogURL(domainID: record.domainID),
                                                     domainID: record.domainID)
                let source = try makeSource(record, folder: folder, catalog: catalog)
                sources[record.domainID] = source
                // Pause Downloads ends with the app process that set it. If it stays, offer Resume.
                if !Self.pause(source, false) { paused = true }
            } catch {
                Self.catalogLog.error("""
                    catalog_unavailable domain=\(record.domainID, privacy: .public) \(logFields(error), privacy: .public)
                    """)
            }
        }
        for source in sources.values { source.retryRenames() }
    }

    private func makeSource(_ record: LocationRecord, folder: RelativePath, catalog: Catalog) throws -> LocationSource {
        guard let address = store.settings?.address(of: record.shareID),
              let connection = connection(for: record.shareID) else { throw CocoaError(.fileReadCorruptFile) }
        if let version = try catalog.providerDomainVersion() {
            _ = try ProviderDomainVersion.decode(version)
        } else {
            try catalog.setProviderDomainVersion(ProviderDomainVersion.encode(NSFileProviderDomainVersion()))
        }
        offlineGeneration[record.domainID] = nil
        let domain = domain(for: record)
        domains[record.domainID] = domain
        let domainID = record.domainID
        let shareID = record.shareID
        let source = LocationSource(domainID: domainID, folder: folder, catalog: catalog, connection: connection,
                                    renameSettings: { [weak self] rename in
            guard let self else { throw LocationError.catalogClosed }
            try await self.commitRenameSettings(rename, host: address.host, share: address.share)
        }, renameRecovered: { [weak self] in
            Task { await self?.resumeCreates(domainID) }
        }, deletionSettings: { [weak self] deletion, paths in
            guard let self else { throw LocationError.catalogClosed }
            try await self.commitDeletionSettings(deletion, paths: paths, owner: domainID, shareID: shareID)
        }, deletionRecovered: { [weak self] in
            Task { await self?.resumeCreates(domainID) }
        }, retryPending: { [weak self] in
            Task { @MainActor in self?.retryPending(domainID: domainID) }
        }) { folders in
            for item in Set(folders.map { NSFileProviderItemIdentifier($0) } + [.workingSet]) {
                NSFileProviderManager(for: domain)?.signalEnumerator(for: item) { error in
                    guard let error else { return }
                    Self.listingLog.error("signal domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
                }
            }
        }
        try? source.configureWriteMode(!record.readOnly)
        source.onChange { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onLocationChange?(domainID)
                    self?.onChange?()
                }
            }
        }
        return source
    }

    private func commitDeletionSettings(_ record: PendingDeletion, paths: [KeepPath],
                                        owner: String, shareID: UUID) throws {
        guard record.plan.owner == owner, record.isSettled,
              paths == record.confirmedDeletedKeepPaths else { throw UploadError.unresolved }
        let current = try LocationSource.deletionOutbox().reload(record)
        guard current == record else { throw UploadError.pendingWrites }
        try store.update { settings in
            for view in current.plan.views {
                guard let location = settings.locations.first(where: { $0.domainID == view.domain }),
                      !location.removing, location.retiredDomainID == nil,
                      location.folder.utf8.elementsEqual(view.folder.utf8),
                      let source = sources[view.domain],
                      source.folder.string.utf8.elementsEqual(view.folder.utf8),
                      source.connection.shareID == location.shareID,
                      let endpoint = settings.address(of: location.shareID), current.plan.endpoint.matches(endpoint),
                      view.domain != owner || location.shareID == shareID else { throw UploadError.unresolved }
                // An older restore must finish before these paths are removed from Settings.
                guard !restoring.contains(location.id) else { throw UploadError.pendingWrites }
            }
            try settings.removeKeptItems(paths, host: current.plan.endpoint.host, share: current.plan.endpoint.share)
        }
        for view in current.plan.views {
            if let location = store.settings?.locations.first(where: { $0.domainID == view.domain }) {
                notOnServer[location.id] = nil
            }
            onLocationChange?(view.domain)
        }
        onChange?()
    }

    private func commitRenameSettings(_ rename: RenameIntent, host: String, share: String) throws {
        guard let current = try LocationSource.renameOutbox().intents().first(where: { $0.id == rename.id }) else {
            throw UploadError.unresolved
        }
        switch current {
        case .file(let record):
            guard record.state == .verified || record.state == .completed else { throw UploadError.unresolved }
            if record.state == .completed { return }
            try store.update { settings in
                try settings.moveKeptFile(from: record.source, to: record.destination, host: host, share: share)
            }
        case .folder(let record):
            guard [.verified, .recovering, .completed].contains(record.state) else { throw UploadError.unresolved }
            if record.state == .completed { return }
            // Idempotent: a retry after a crash finds no saved path left below the source.
            try store.update { settings in
                if record.rootRetired {
                    let domains = Set(record.views.map(\.domain))
                    guard !settings.locations.contains(where: {
                        domains.contains($0.domainID) && restoring.contains($0.id)
                    }) else { throw UploadError.pendingWrites }
                    try settings.removeKeptFolder(at: record.source, host: host, share: share)
                    try settings.removeKeptFolder(at: record.destination, host: host, share: share)
                } else {
                    try settings.moveKeptFolder(from: record.source, to: record.destination, host: host, share: share)
                }
            }
        }
        for domain in current.domains {
            if let record = store.settings?.locations.first(where: { $0.domainID == domain }) {
                notOnServer[record.id] = nil
            }
            onLocationChange?(domain)
        }
        onChange?()
    }

    private static var discoveryNow: Duration { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }

    private func retrySpaceBlockedDownloads() async {
        guard isReady, !paused else { return }
        let before = spaceBlocked
        for id in spaceBlocked.keys where sources[id] == nil { spaceBlocked[id] = nil }
        if before != spaceBlocked { saveSpaceBlockedDownloads() }
        for (domainID, requests) in spaceBlocked {
            guard let source = sources[domainID], canDiscover(source),
                  let domain = domains[domainID], let manager = NSFileProviderManager(for: domain) else { continue }
            for (item, request) in requests where !Task.isCancelled && !paused {
                do {
                    guard let row = try await Self.offMain({ try source.spaceRecoveryItem(item) }),
                          !row.deleted, row.keep, row.contentVersion == request.version else {
                        spaceBlocked[domainID]?[item] = nil
                        saveSpaceBlockedDownloads()
                        onLocationChange?(domainID)
                        continue
                    }
                    let space = reader.downloadSpace
                    guard try await Self.offMain({ try space.canRetry(bytes: row.size) }),
                          !paused, canDiscover(source),
                          spaceBlocked[domainID]?[item]?.id == request.id else { continue }
                    try await manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(item))
                    Self.readerLog.info("space_retry domain=\(domainID, privacy: .public) item=\(item, privacy: .public)")
                } catch {
                    Self.readerLog.error("space_retry domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
                }
            }
        }
    }

    private static var verifiedVersionsURL: URL {
        URL.applicationSupportDirectory.appending(path: "tinymounter/" + VerifiedVersions.fileName)
    }

    /// Saves the versions only when they change, so each check does not rewrite the file.
    private func setVerification(_ domainID: String, _ verification: OfflineVerification?) {
        let before = offlineVerification[domainID]?.versions ?? [:]
        offlineVerification[domainID] = verification
        guard (verification?.versions ?? [:]) != before else { return }
        do {
            let url = Self.verifiedVersionsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VerifiedVersions.save(offlineVerification.mapValues(\.versions), to: url)
        } catch {
            Self.catalogLog.error("verified_versions_save \(logFields(error), privacy: .public)")
        }
    }

    private func saveSpaceBlockedDownloads() {
        do {
            try DownloadRecovery.save(spaceBlocked, to: SharedContainer.url().appending(path: DownloadRecovery.fileName))
        } catch {
            Self.readerLog.error("space_state_save \(logFields(error), privacy: .public)")
        }
    }

    private func canDiscover(_ source: LocationSource) -> Bool {
        isReady && sources[source.domainID] === source && domains[source.domainID] != nil
            && !turnedOff.contains(source.domainID) && source.connection.state == .connected
            && store.settings?.locations.contains { $0.domainID == source.domainID && !$0.removing } == true
    }

    private func startDiscovery() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(of: NSWorkspace.self,
            for: .didWake) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.discoveryMembershipDue.removeAll()
                    for id in self.discovery.keys { self.discovery[id]?.refreshAll(now: Self.discoveryNow) }
                }
            }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.discoverChanges()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func discoverChanges() async {
        let active = sources.values.filter(canDiscover).sorted { $0.domainID < $1.domainID }
        let ids = Set(active.map(\.domainID))
        for id in discovery.keys where !ids.contains(id) {
            discovery[id] = nil
            discoveryMembershipDue[id] = nil
            sources[id]?.connection.changeWatch.removeLocation(id)
        }
        for source in active where Self.discoveryNow >= (discoveryMembershipDue[source.domainID] ?? .zero) {
            let id = source.domainID
            discoveryMembershipDue[id] = Self.discoveryNow + .seconds(30)
            guard let domain = domains[id], let manager = NSFileProviderManager(for: domain) else { continue }
            do {
                let materialized = try await MaterializedItems.read(manager)
                let (folders, watched) = try await Self.offMain {
                    let folders = try source.discoveryFolders(materialized: materialized.folders)
                    return (folders, try source.watchedFolders(folders))
                }
                guard canDiscover(source), !Task.isCancelled else { continue }
                var schedule = discovery[id] ?? DirectoryRefresh()
                schedule.replaceFolders(folders, now: Self.discoveryNow)
                discovery[id] = schedule
                source.connection.changeWatch.setFolders(watched, domainID: id, root: source.folder)
            } catch {
                Self.listingLog.error("discovery_membership domain=\(id, privacy: .public) \(logFields(error), privacy: .public)")
            }
        }
        let ordered = active.filter { $0.domainID > (discoveryCursor ?? "") }
            + active.filter { $0.domainID <= (discoveryCursor ?? "") }
        for source in ordered where canDiscover(source) && !Task.isCancelled {
            let id = source.domainID
            guard let folder = discovery[id]?.next(now: Self.discoveryNow) else { continue }
            discoveryCursor = id
            var succeeded = false
            do {
                _ = try await source.list(folder, requestID: UUID())
                succeeded = true
            } catch {
                Self.listingLog.error("discovery_list domain=\(id, privacy: .public) folder=\(folder, privacy: .public) \(logFields(error), privacy: .public)")
            }
            guard sources[id] === source else { return }
            discovery[id]?.finished(folder, succeeded: succeeded, now: Self.discoveryNow)
            return
        }
    }

    private func domain(for record: LocationRecord) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(record.domainID), displayName: record.name)
    }

    /// The share's connection; nil for a share that is not saved.
    private func connection(for shareID: UUID) -> ShareConnection? {
        if let connection = connections[shareID] { return connection }
        guard let settings = store.settings, let share = settings.shares.first(where: { $0.id == shareID }),
              let server = settings.servers.first(where: { $0.id == share.serverID }) else { return nil }
        let connection = ShareConnection(shareID: shareID, address: ShareAddress(server.login, share: share.name),
                                         client: client, signIn: signIn(for: server),
                                         previousSessions: previousSessions, watchLimit: watchLimit,
                                         refresh: { [weak self] domainID, folderIDs in
            Task { @MainActor in self?.noticed(domainID, folderIDs) }
        }) { [weak self] failures in
            Task { @MainActor in await self?.recovered(shareID, failures) }
        }
        // Locations of the same share through another account coordinate with these.
        let key = EditNamespace.key(ShareAddress(server.login, share: share.name))
        let related = Set(settings.shares.filter { other in
            settings.address(of: other.id).map { EditNamespace.key($0) == key } ?? false
        }.map(\.id))
        for record in settings.locations where related.contains(record.shareID) {
            if let folder = RelativePath(record.folder) {
                connection.editNamespace.register(domain: record.domainID, folder: folder)
            }
        }
        // Changes on two threads can be queued in reverse order, so read the state on main.
        connection.onStateChange { [weak self, weak connection] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let connection { self?.shareChanged(shareID, connection.state) } }
            }
        }
        connections[shareID] = connection
        shareStates[shareID] = connection.state
        return connection
    }

    /// A change notice: list these folders of the location soon, or every watched one for nil.
    private func noticed(_ domainID: String, _ folderIDs: [String]?) {
        guard let source = sources[domainID], canDiscover(source) else { return }
        let now = Self.discoveryNow
        if let folderIDs {
            for id in folderIDs { discovery[domainID]?.changed(id, now: now) }
        } else {
            discovery[domainID]?.refreshAll(now: now)
        }
    }

    /// One sign-in per server, shared by its locations' connections and its Server Volumes.
    private func signIn(for server: ServerRecord) -> ServerSignIn {
        if let signIn = signIns[server.id] { return signIn }
        let signIn = ServerSignIn(login: server.login, credentials: credentials)
        signIns[server.id] = signIn
        return signIn
    }

    /// The Server Volume's mount; nil for a share that is not saved.
    private func volume(for shareID: UUID) -> ServerVolumeMount? {
        if let volume = volumes[shareID] { return volume }
        guard let settings = store.settings, let share = settings.shares.first(where: { $0.id == shareID }),
              let server = settings.servers.first(where: { $0.id == share.serverID }) else { return nil }
        let volume = ServerVolumeMount(shareID: shareID, address: ShareAddress(server.login, share: share.name),
                                       client: client, signIn: signIn(for: server)) { [weak self] mounted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.volumes[shareID] != nil else { return }
                    if mounted { self.mountedVolumes.insert(shareID) } else { self.mountedVolumes.remove(shareID) }
                    self.onChange?()
                }
            }
        } onRemountRefused: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.volumes[shareID] != nil else { return }
                    self.onChange?()
                    self.onVolumeSignInRefused?(shareID)
                }
            }
        }
        volumes[shareID] = volume
        volume.setRemountWanted(store.settings?.serverVolumes.contains { $0.shareID == shareID } == true)
        return volume
    }

    /// macOS mounts again only the share of a Server Volume (docs/architecture.md §9).
    private func updateRemountWanted() {
        let wanted = Set(store.settings?.serverVolumes.map(\.shareID) ?? [])
        for (id, volume) in volumes { volume.setRemountWanted(wanted.contains(id)) }
    }

    private func shareChanged(_ shareID: UUID, _ state: ConnectionState) {
        guard connections[shareID] != nil else { return }
        let before = shareStates[shareID] ?? .notConnected
        guard before != state else { return }
        shareStates[shareID] = state
        onShareState?(shareID, before, state)
        onChange?()
    }

    /// Only domains with an open catalog get a reader; the others fail without one.
    private func refreshDomains() async {
        let current: [NSFileProviderDomain]
        do {
            current = try await NSFileProviderManager.domains().filter { sources[$0.identifier.rawValue] != nil }
        } catch {
            Self.readerLog.error("domains_unavailable \(logFields(error), privacy: .public)")
            return
        }
        reader.update(current)
        turnedOff = Set(current.filter { !$0.userEnabled }.map(\.identifier.rawValue))
        let ids = Set(current.map(\.identifier.rawValue))
        for id in offlineVerification.keys where turnedOff.contains(id) || !ids.contains(id) {
            setVerification(id, nil)
            offlineGeneration[id] = nil
        }
        for id in progress.keys where !ids.contains(id) {
            progress[id] = nil
            downloading[id] = nil
        }
        for domain in current where progress[domain.identifier.rawValue] == nil {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            let id = domain.identifier.rawValue
            let global = manager.globalProgress(for: .downloading)
            // The system updates it on the main queue [H]; a finished one has no downloads.
            let observation = global.observe(\.fractionCompleted, options: [.initial]) { [weak self] observed, _ in
                let fraction = observed.isFinished ? nil : observed.fractionCompleted
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.progress[id] != nil, self.downloading[id] != fraction else { return }
                        self.downloading[id] = fraction
                        self.onChange?()
                    }
                }
            }
            progress[id] = (global, observation)
        }
        onChange?()
    }

    /// Recovery (docs/architecture.md §3, flow 4): the system retries what failed, then flow 5
    /// lists materialized folders again.
    private func recovered(_ shareID: UUID, _ failures: [SourceFailure]) async {
        let affected = sources.values.filter { $0.connection.shareID == shareID }.map(\.domainID)
        Self.shareLog.info("""
            share=\(shareID.uuidString, privacy: .public) recovery domains=\(affected.count) \
            resolved=\(failures.map { "\($0)" }.joined(separator: ","), privacy: .public)
            """)
        for domainID in affected {
            sources[domainID]?.uploadRetry.connected()
            sources[domainID]?.retryRenames()
            sources[domainID]?.retryDeletions()
            await signalResolved(domainID, failures)
        }
        relist(shareID)
        for record in store.settings?.locations ?? [] where record.shareID == shareID && !record.pendingKeeps.isEmpty {
            await restorePendingKeeps(record.id)
        }
    }

    private func signalResolved(_ domainID: String, _ failures: [SourceFailure]) async {
        guard let domain = domains[domainID], let manager = NSFileProviderManager(for: domain) else { return }
        for failure in failures {
            do { try await manager.signalErrorResolved(SourceReaderBridge.providerError(failure)) } catch {
                Self.shareLog.error("""
                    signal_resolved domain=\(domainID, privacy: .public) failure=\("\(failure)", privacy: .public) \
                    \(logFields(error), privacy: .public)
                    """)
            }
        }
        await resumeCreates(domainID)
        do { try await manager.signalEnumerator(for: .workingSet) } catch {
            Self.listingLog.error("signal domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
        }
    }

    /// One relisting per share at a time; a recovery during one starts another after it.
    private func relist(_ shareID: UUID) {
        guard relisting[shareID] == nil else {
            relisting[shareID] = true
            return
        }
        relisting[shareID] = false
        Task {
            repeat {
                relisting[shareID] = false
                for source in sources.values where source.connection.shareID == shareID {
                    await relistMaterialized(source)
                }
            } while relisting[shareID] == true
            relisting[shareID] = nil
        }
    }

    /// The system never enumerates a materialized folder again, so the app lists it again.
    private func relistMaterialized(_ source: LocationSource) async {
        guard let domain = domains[source.domainID], let manager = NSFileProviderManager(for: domain) else { return }
        let started = ContinuousClock.now
        let folders: [String]
        do {
            folders = try await MaterializedItems.read(manager).folders
        } catch {
            Self.listingLog.error("relist domain=\(source.domainID, privacy: .public) \(logFields(error), privacy: .public)")
            return
        }
        var listed = 0, failed = 0, changed = 0
        for folder in folders {
            do {
                changed += try await source.list(folder, requestID: UUID()).changed
                listed += 1
            } catch {
                failed += 1
                // Every folder would fail the same way; the next recovery lists them again.
                if let failure = error as? SourceFailure,
                   [SourceFailure.serverUnreachable, .notConnected, .localNetworkDenied, .notAuthenticated].contains(failure) { break }
                if error is LocationError { break }
            }
        }
        Self.listingLog.info("""
            relist domain=\(source.domainID, privacy: .public) folders=\(folders.count) listed=\(listed) \
            failed=\(failed) changed=\(changed) \
            total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
            """)
    }

    /// A saved request must resolve to the same kind before it can keep an item.
    private func resolveItem(_ path: RelativePath, kind: CatalogRow.Kind, in source: LocationSource,
                             listed: inout Set<String>) async throws -> String? {
        if path.isRoot { return kind == .folder ? Catalog.rootItemID : nil }
        var parent = Catalog.rootItemID
        let names = path.components
        for (index, name) in names.enumerated() {
            if !listed.contains(parent) {
                _ = try await source.list(parent, requestID: UUID())
                listed.insert(parent)
            }
            let folder = parent
            guard let row = try await Self.offMain({ try source.liveChild(of: folder, named: name) }) else { return nil }
            let last = index == names.count - 1
            guard row.kind == (last ? kind : .folder) else { return nil }
            if last { return row.id }
            parent = row.id
        }
        return nil
    }

    private func keptSharePaths(_ record: LocationRecord) async -> [KeepPath] {
        guard let folder = RelativePath(record.folder) else { return [] }
        return await keptPaths(record).compactMap { item in
            folder.appending(item.path).map { KeepPath(path: $0.string, kind: item.kind) }
        }
    }

    /// Catalog calls can wait for a listing's commit, so they don't run on the main actor.
    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    /// A new catalog with its root listed, for Add and Apply. On failure nothing is left.
    private func makeListedSource(_ record: LocationRecord, folder: RelativePath) async throws -> LocationSource {
        let url = try SharedContainer.catalogURL(domainID: record.domainID)
        setVerification(record.domainID, nil)
        try FileManager.default.createDirectory(at: SharedContainer.catalogsDirectory(), withIntermediateDirectories: true)
        let source = try makeSource(record, folder: folder,
                                catalog: try Catalog.create(at: url, domainID: record.domainID, rootName: record.name))
        do {
            let receipt = try await source.list(Catalog.rootItemID, requestID: UUID())
            Self.catalogLog.info("""
                root_listed domain=\(record.domainID, privacy: .public) entries=\(receipt.entries) \
                skipped=\(receipt.skipped)
                """)
            return source
        } catch {
            discard(source, record.domainID)
            throw error
        }
    }

    private func discard(_ source: LocationSource, _ domainID: String) {
        source.close()
        source.editNamespace.unregister(domainID)
        domains[domainID] = nil
        // A catalog left here has no record, so the next launch deletes it.
        do { try Catalog.delete(at: SharedContainer.catalogURL(domainID: domainID)) } catch {
            Self.catalogLog.error("location_add_cleanup ok=0 \(logFields(error), privacy: .public)")
        }
    }

    /// Unreadable settings are from an earlier build, which nothing migrates: delete the saved
    /// passwords, remove every domain and set the earlier data aside, then launch as a new
    /// installation. Returns where macOS kept the changes that had not uploaded.
    func startFresh() async throws -> [URL] {
        guard problem == .settingsUnreadable else { return [] }
        // First, so that a failure changes nothing: the earlier passwords belong to earlier servers.
        try credentials.deleteAll()
        var preserved: [URL] = []
        for domain in try await NSFileProviderManager.domains() {
            if let url = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) {
                preserved.append(url)
            }
        }
        let group = try SharedContainer.url()
        for url in [URL.applicationSupportDirectory.appending(path: "tinymounter", directoryHint: .isDirectory),
                    group.appending(path: "Catalogs", directoryHint: .isDirectory),
                    group.appending(path: "UploadInbox", directoryHint: .isDirectory)] {
            try Self.setAside(url)
        }
        Self.catalogLog.info("start_fresh domains_preserved=\(preserved.count)")
        store.reload()
        problem = nil
        await launch()
        onChange?()
        return preserved
    }

    /// Kept in the container under a dated name; no build reads it again.
    private static func setAside(_ url: URL) throws {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted))
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appending(path: "\(url.lastPathComponent)-earlier-\(stamp)"))
        } catch CocoaError.fileNoSuchFile {}
    }

    private func registeredDomains() async throws -> [String: NSFileProviderDomain] {
        Dictionary(try await NSFileProviderManager.domains().map { ($0.identifier.rawValue, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func sweepStaging() {
        do {
            let removed = try Staging.removeLeftoverStageFiles(in: SharedContainer.stagingDirectory(), createdBefore: Date())
            Self.readerLog.info("staging_removed=\(removed)")
        } catch {
            Self.readerLog.error("staging_sweep failed \(logFields(error), privacy: .public)")
        }
    }

    private func installDiagnosticsSignal() {
        guard diagnosticsSignal == nil else { return }
        // Without this the default action ends the app; the dispatch source still gets the signal.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.logDiagnostics(reason: "signal") }
        }
        source.activate()
        diagnosticsSignal = source
    }

    private nonisolated static func stageFileCount() -> Int {
        guard let directory = try? SharedContainer.stagingDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return -1
        }
        return names.count(where: Staging.isStageFileName)
    }

    private nonisolated static func descriptorCount() -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        return used > 0 ? Int(used) / stride : -1
    }

    private nonisolated static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// A domain's materialized set: the items that the system keeps on this Mac.
struct MaterializedItems {
    var folders: [String] = []
    var files: [String] = []

    static func read(_ manager: NSFileProviderManager) async throws -> MaterializedItems {
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        let observer = MaterializedObserver()
        // The header asks for an empty first page: the sort constants don't apply here.
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        while let current = page {
            page = try await observer.next(enumerator, from: current)
        }
        return observer.items
    }
}

/// The system calls it on its own queue, one page at a time.
private final class MaterializedObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var found = MaterializedItems()
    private var waiting: CheckedContinuation<NSFileProviderPage?, Error>?

    var items: MaterializedItems { lock.withLock { found } }

    func next(_ enumerator: NSFileProviderEnumerator, from page: NSFileProviderPage) async throws -> NSFileProviderPage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        // The system materializes its own Trash folder, which is not in the catalog.
        let items = updatedItems.filter { $0.itemIdentifier != .trashContainer }
        let folders = items.filter { $0.contentType?.conforms(to: .folder) == true }.map(\.itemIdentifier.rawValue)
        let files = items.filter { $0.contentType?.conforms(to: .folder) != true }.map(\.itemIdentifier.rawValue)
        lock.withLock {
            found.folders += folders
            found.files += files
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { take()?.resume(returning: nextPage) }

    func finishEnumeratingWithError(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<NSFileProviderPage?, Error>? {
        lock.withLock {
            defer { waiting = nil }
            return waiting
        }
    }
}

private final class DeletionPendingObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<NSFileProviderPage?, Error>?
    private var hasItems = false

    static func requireEmpty(_ manager: NSFileProviderManager) async throws {
        let enumerator = manager.enumeratorForPendingItems()
        defer { enumerator.invalidate() }
        let observer = DeletionPendingObserver()
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        var pages = 0
        while let current = page {
            guard pages < 1024 else { throw UploadError.pendingWrites }
            pages += 1
            page = try await observer.next(enumerator, page: current)
            guard !observer.lock.withLock({ observer.hasItems }), !enumerator.isMaximumSizeReached else {
                throw UploadError.pendingWrites
            }
        }
        guard enumerator.domainVersion != nil else { throw UploadError.pendingWrites }
    }

    private func next(_ enumerator: NSFileProviderEnumerator, page: NSFileProviderPage) async throws
        -> NSFileProviderPage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ items: [NSFileProviderItem]) {
        if !items.isEmpty { lock.withLock { hasItems = true } }
    }

    func finishEnumerating(upTo page: NSFileProviderPage?) { take()?.resume(returning: page) }
    func finishEnumeratingWithError(_ error: Error) { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<NSFileProviderPage?, Error>? {
        lock.withLock { defer { waiting = nil }; return waiting }
    }
}
