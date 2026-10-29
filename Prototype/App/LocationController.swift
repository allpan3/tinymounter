import AppKit
import Darwin
import FileProvider
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Domain steps, launch reconciliation, recovery signals and relisting (plan §3 and §7).
@MainActor
final class LocationController {
    enum Problem: Equatable {
        /// Launch reconciliation stopped: nothing is added or removed.
        case settingsUnreadable
        case domainsUnreadable
    }

    struct Diagnostics: Equatable {
        var catalogFiles = 0, catalogsOpen = 0, catalogsUnavailable = 0, items = 0, tombstones = 0
        var listedFolders = 0, kept = 0, catalogsPaused = 0, stageFiles = 0, descriptors = 0
        var residentBytes: UInt64 = 0
        var shares = 0, sessions = 0
    }

    let store: SettingsStore
    private(set) var problem: Problem?
    /// Until launch reconciliation ends, a new catalog could look like one without a record.
    private(set) var isReady = false
    /// Pause Downloads, for every location. Each launch starts with it off (plan §7).
    private(set) var paused = false
    /// The latest Pause Downloads change.
    private var pauseChange: Task<Bool, Never>?
    var onChange: (() -> Void)?
    /// A share's state changed: the grant, the state before and the state now.
    var onShareState: ((UUID, ShareHealth.State, ShareHealth.State) -> Void)?
    /// A fetch that a user waits for failed on its share: the grant and the failure.
    var onUserFetchFailed: ((UUID, SourceFailure) -> Void)?
    /// Saved Keep Downloaded paths became kept files: the record and the item IDs.
    var onKeepsRestored: ((LocationRecord, [String]) -> Void)?
    /// A location's kept files or root state changed: its domain ID.
    var onLocationChange: ((String) -> Void)?
    /// The system's set of downloaded files changed, in any domain.
    var onMaterializedChange: (() -> Void)?
    /// Saved Keep Downloaded paths that a complete listing showed are not on the server, by record.
    private(set) var notOnServer: [UUID: Set<KeepPath>] = [:]
    private var restoring: Set<UUID> = []
    /// Each domain's download progress while the system downloads; absent at rest.
    private(set) var downloading: [String: Double] = [:]
    /// Domains that the user turned off in System Settings.
    private(set) var turnedOff: Set<String> = []
    private let reader = SourceReaderHost()
    private var shares: [UUID: ShareAccess] = [:]
    private var shareStates: [UUID: ShareHealth.State] = [:]
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
    /// Grants with a relisting running; true if a recovery asked for another one.
    private var relisting: [UUID: Bool] = [:]
    private var diagnosticsSignal: (any DispatchSourceSignal)?
    /// Folder completion's last listing, reused while the user types in the same folder.
    private var completion: (grantID: UUID, parent: RelativePath, names: [String])?
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
        reader.onConnected = { [weak self] domainID in
            Task { await self?.signalResolved(domainID, [.serverUnreachable]) }
        }
        reader.onUserFetchFailed = { [weak self] domainID, failure in
            guard let self, let grantID = sources[domainID]?.access.grantID else { return }
            onUserFetchFailed?(grantID, failure)
        }
        reader.onSpaceChange = { [weak self] domainID, request, blocked in
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
            }
        }
    }

    deinit {
        discoveryTask?.cancel()
        spaceTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// The share's state; not connected until its first session starts.
    func shareState(_ grantID: UUID) -> ShareHealth.State { shareStates[grantID] ?? .notConnected }

    /// Nil for a record without an open catalog: "catalog unavailable" (plan §7).
    func isRootMissing(_ record: LocationRecord) -> Bool? { sources[record.domainID]?.isRootMissing }

    /// Plan §7 app launch: the staging sweep before any reader connects, then the domain steps.
    func launch() async {
        do { spaceBlocked = try DownloadRecovery.load(from: SharedContainer.url().appending(path: DownloadRecovery.fileName)) }
        catch { Self.readerLog.error("space_state_load \(logFields(error), privacy: .public)") }
        sweepStaging()
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
            problem = .domainsUnreadable
            Self.catalogLog.error("launch_reconciliation stopped \(logFields(error), privacy: .public)")
            onChange?()
            return
        }
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
        for grant in store.settings?.shares ?? [] { share(for: grant).connect() }
        await logDiagnostics(reason: "launch")
        installDiagnosticsSignal()
        isReady = true
        startDiscovery()
        spaceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.retrySpaceBlockedDownloads()
            }
        }
        onChange?()
    }

    /// Saves a grant. A grant for a share that has one replaces its bookmark and keeps its ID.
    func saveGrant(_ grant: ServerGrant) throws -> UUID {
        var saved = grant.id
        try store.update { settings in
            if let index = settings.shares.firstIndex(where: { $0.mountFrom == grant.mountFrom }) {
                settings.shares[index].bookmark = grant.bookmark
                settings.shares[index].serverID = grant.serverID
                saved = settings.shares[index].id
            } else {
                settings.shares.append(grant)
            }
        }
        if let share = shares[saved] {
            share.replaceBookmark(grant.bookmark)
        } else if let saved = store.settings?.shares.first(where: { $0.id == saved }) {
            share(for: saved).connect()
        }
        onChange?()
        return saved
    }

    func saveServer(_ address: ServerAddress) throws -> UUID {
        if let existing = store.settings?.servers.first(where: { $0.matches(address) }) { return existing.id }
        let server = ServerRecord(address: address)
        try store.update { $0.servers.append(server) }
        onChange?()
        return server.id
    }

    func removeServer(_ id: UUID) async throws {
        guard let settings = store.settings else { throw SettingsError.invalidServer }
        guard !settings.serverIsUsed(id) else { throw SettingsError.serverInUse }
        let grants = settings.shares.filter { $0.serverID == id }
        for grant in grants { try await disconnect(grant.id, reason: "server_removed") }
        try store.update { try $0.removeServer(id) }
        for grant in grants {
            shares[grant.id] = nil
            shareStates[grant.id] = nil
        }
        onChange?()
    }

    func disconnect(_ id: UUID, reason: String = "disconnect") async throws {
        guard let grant = store.settings?.shares.first(where: { $0.id == id }) else { return }
        let access = share(for: grant)
        do {
            for mount in try ShareAccess.connectedShares() where mount.identity.mountFrom == grant.mountFrom {
                try await ShareAccess.unmount(mount, reason: reason)
            }
        } catch {
            access.unmountFailed()
            throw error
        }
        access.checkNow()
    }

    /// Connect mounted the share: its session starts now.
    func shareMounted(_ grantID: UUID) { shares[grantID]?.checkNow() }

    /// The share's mount path, for Select…; nil if it isn't mounted.
    func mountPath(_ grantID: UUID) -> String? {
        guard let grant = store.settings?.shares.first(where: { $0.id == grantID }) else { return nil }
        return share(for: grant).mountPath()
    }

    /// Plan §7: create the catalog, list the root into it, save the record, then add the domain.
    /// The record takes the saved Keep Downloaded paths inside its folder (plan §4). A copy goes
    /// below its original (design §4.2).
    func add(id: UUID, name: String, folder: RelativePath, grantID: UUID,
             after original: UUID? = nil, writeBookmark: Data? = nil) async throws -> LocationRecord {
        guard isReady, let settings = store.settings, let grant = settings.shares.first(where: { $0.id == grantID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var record = LocationRecord(id: id, name: LocationRecord.uniqueName(name, among: settings.locations.map(\.name)),
                                    serverID: grantID, folder: folder)
        record.writeBookmark = writeBookmark
        record.readOnly = writeBookmark == nil
        record.smbOnlyEditing = writeBookmark == nil ? nil : true
        let listedName = record.name
        let source = try await makeListedSource(record, folder: folder, grant: grant)
        do {
            try store.update { settings in
                // Another Add or a rename can take the name during the root listing.
                record.name = LocationRecord.uniqueName(name, among: settings.locations.map(\.name))
                record.pendingKeeps = settings.takeSavedKeeps(host: grant.host, share: grant.share, inside: folder)
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

    func setWriteMode(_ recordID: UUID, readOnly: Bool, bookmark: Data?, confirmed: Bool) async throws {
        guard isReady, let record = store.settings?.locations.first(where: { $0.id == recordID }),
              readOnly || (bookmark != nil && confirmed),
              !record.removing, let source = sources[record.domainID] else { throw UploadError.readOnly }
        let save: (Data?, Bool, Bool?) throws -> Void = { bookmark, readOnly, confirmation in
            try self.store.update { settings in
                guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { throw UploadError.readOnly }
                settings.locations[index].writeBookmark = bookmark
                settings.locations[index].readOnly = readOnly
                settings.locations[index].smbOnlyEditing = confirmation
            }
        }
        if !readOnly {
            try save(bookmark, false, true)
            do { try await Self.offMain { try source.configureWriteMode(bookmark, confirmed: true) } }
            catch { try save(record.writeBookmark, record.readOnly, record.smbOnlyEditing); throw error }
        } else {
            try await Self.offMain { try source.configureWriteMode(nil, confirmed: false) }
            do { try save(record.writeBookmark, true, record.smbOnlyEditing) }
            catch {
                try? await Self.offMain {
                    try source.configureWriteMode(record.activeWriteBookmark, confirmed: record.smbOnlyEditing == true)
                }
                throw error
            }
        }
        onChange?()
    }

    func editRecords(_ record: LocationRecord) async throws -> [PendingEdit] {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.editRecords() }
    }

    func exportEdit(_ record: LocationRecord, id: UUID, destination: URL) async throws {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        try await Self.offMain { try source.exportEdit(id, destination: destination) }
    }

    func retryEdits(_ record: LocationRecord) {
        sources[record.domainID]?.retryEdits()
        guard let source = sources[record.domainID] else { return }
        for candidate in sources.values where candidate.editNamespace === source.editNamespace { candidate.retryRenames() }
    }

    func renameRecords(_ record: LocationRecord) async throws -> [PendingFileRename] {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.renameRecords() }
    }

    func pendingUploads(_ record: LocationRecord) async throws -> Int {
        guard let source = sources[record.domainID] else { throw LocationError.catalogClosed }
        return try await Self.offMain { try source.pendingUploads() }
    }

    /// Plan §8 Name: a unique name in the record and the root row, then `add` again with the same ID.
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

    /// Plan §7 Apply: a new catalog with its root listed, the record with both domain IDs, the old
    /// domain removed, then the new one added. Kept paths inside the new source stay pending on the
    /// location; the others go to the old share's saved list.
    func apply(_ recordID: UUID, grantID: UUID, folder: RelativePath,
               writeBookmark: Data? = nil) async throws -> LocationRecord {
        guard isReady, let settings = store.settings,
              let record = settings.locations.first(where: { $0.id == recordID }), !record.removing,
              let grant = settings.shares.first(where: { $0.id == grantID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let previousSource = sources[record.domainID]
        if let previousSource { try await Self.offMain { try previousSource.suspendMutations() } }
        else if try LocationSource.pendingWrites(domainID: record.domainID) > 0 { throw UploadError.pendingWrites }
        defer { previousSource?.resumeMutations() }
        let oldGrant = settings.shares.first { $0.id == record.serverID }
        let kept = await keptSharePaths(record) + record.pendingKeeps
        let sameShare = oldGrant?.isSameShare(host: grant.host, share: grant.share) ?? false
        let moving = sameShare ? kept.filter { $0.below(folder) != nil } : []
        var updated = record
        updated.domainID = UUID().uuidString
        updated.retiredDomainID = record.domainID
        updated.serverID = grantID
        updated.folder = folder.string
        updated.writeBookmark = writeBookmark
        updated.readOnly = writeBookmark == nil
        updated.smbOnlyEditing = writeBookmark == nil ? nil : true
        let source = try await makeListedSource(updated, folder: folder, grant: grant)
        do {
            try store.update { settings in
                guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
                if let oldGrant {
                    settings.saveKeeps(kept.filter { !moving.contains($0) }, host: oldGrant.host, share: oldGrant.share)
                }
                var added = Set<KeepPath>()
                updated.pendingKeeps = (moving + settings.takeSavedKeeps(host: grant.host, share: grant.share, inside: folder))
                    .filter { added.insert($0).inserted }
                settings.locations[index] = updated
            }
        } catch {
            discard(source, updated.domainID)
            throw error
        }
        notOnServer[recordID] = nil
        sources.removeValue(forKey: record.domainID)?.close()
        domains[record.domainID] = nil
        sources[updated.domainID] = source
        if paused { Self.pause(source, true) }
        onChange?()
        // Remove before add, so two domains never share a display name or a disk location [H].
        try await run(.removeDomain(record.domainID), registered: registeredDomains())
        try Catalog.delete(at: SharedContainer.catalogURL(domainID: record.domainID))
        try LocationSource.outbox(domainID: record.domainID).removeIfCompleted()
        try LocationSource.editOutbox(domainID: record.domainID).removeIfCompleted()
        try LocationSource.renameOutbox().removeCompleted(owner: record.domainID)
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

    /// Plan §7: save the kept paths if asked, mark the record, remove the domain, delete the
    /// catalog, delete the record.
    func remove(_ recordID: UUID, saveKeeps: Bool) async throws {
        guard isReady, let settings = store.settings, let record = settings.locations.first(where: { $0.id == recordID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let previousSource = sources[record.domainID]
        if let previousSource { try await Self.offMain { try previousSource.suspendMutations() } }
        else if try LocationSource.pendingWrites(domainID: record.domainID) > 0 { throw UploadError.pendingWrites }
        defer { previousSource?.resumeMutations() }
        let grant = settings.shares.first { $0.id == record.serverID }
        // A location whose catalog can't be read saves only its pending paths; it must stay removable.
        let paths = saveKeeps && !record.removing ? await keptSharePaths(record) + record.pendingKeeps : []
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            if let grant { settings.saveKeeps(paths, host: grant.host, share: grant.share) }
            settings.locations[index].removing = true
        }
        notOnServer[recordID] = nil
        onChange?()
        // Downloaded copies are only NAS files again; a later location downloads them anew.
        try await run(.removeDomain(record.domainID), registered: registeredDomains())
        sources.removeValue(forKey: record.domainID)?.close()
        domains[record.domainID] = nil
        try Catalog.delete(at: SharedContainer.catalogURL(domainID: record.domainID))
        try LocationSource.outbox(domainID: record.domainID).removeIfCompleted()
        try LocationSource.editOutbox(domainID: record.domainID).removeIfCompleted()
        try LocationSource.renameOutbox().removeCompleted(owner: record.domainID)
        previousSource?.editNamespace.unregister(record.domainID)
        try store.update { $0.locations.removeAll { $0.id == recordID } }
        Self.catalogLog.info("""
            location_removed domain=\(record.domainID, privacy: .public) saved_keeps=\(paths.count)
            """)
        await refreshDomains()
        onChange?()
    }

    /// Plan §6: Keep Downloaded downloads and read-ahead stop; a file that the user opens downloads.
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

    func offlineStates(_ record: LocationRecord, update: ([String: OfflineState]) -> Void) async {
        guard let source = sources[record.domainID], let manager = manager(for: record),
              !record.removing, !turnedOff.contains(record.domainID) else {
            offlineVerification[record.domainID] = nil
            offlineGeneration[record.domainID] = nil
            update([:])
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
                offlineVerification[record.domainID] = nil
                update([:])
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
                    update([:])
                    return
                }
                var verification = offlineVerification[record.domainID] ?? OfflineVerification()
                let blocked = Set(snapshot.items.filter {
                    spaceBlocked[record.domainID]?[$0.id]?.version == $0.contentVersion
                }.map(\.id))
                let states = verification.states(snapshot: snapshot, files: observed.files,
                                                 folders: observed.folders, synchronized: synchronized,
                                                 spaceBlocked: blocked)
                offlineVerification[record.domainID] = verification
                update(states)
            }
        } catch {
            guard !Task.isCancelled, sources[record.domainID] === source,
                  offlineGeneration[record.domainID] == generation else { return }
            offlineVerification[record.domainID] = nil
            update([:])
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

    /// Plan §4: lists the parent folders of each pending path, as flow 1 does, and keeps the files
    /// it finds. A path that a complete listing of its parent lacks is not on the server; one that
    /// can't be checked yet stays for the next recovery.
    func restorePendingKeeps(_ recordID: UUID) async {
        guard let record = store.settings?.locations.first(where: { $0.id == recordID }), !record.removing,
              !record.pendingKeeps.isEmpty, let source = sources[record.domainID],
              let folder = RelativePath(record.folder), restoring.insert(recordID).inserted else { return }
        defer { restoring.remove(recordID) }
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
                   [SourceFailure.serverUnreachable, .notConnected, .notAuthenticated].contains(failure) { break }
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

    /// Plan §8 folder completion: lists the typed parent folder unless the last listing was of it.
    /// It never lists more than one folder at a time, and a cancelled request lists nothing.
    func folderSuggestions(grantID: UUID, typed: String) async -> [String] {
        guard let query = FolderCompletion(typed: typed),
              let grant = store.settings?.shares.first(where: { $0.id == grantID }) else { return [] }
        while completion?.grantID != grantID || completion?.parent != query.parent {
            if let running = completionListing {
                await running.value
                continue
            }
            guard !Task.isCancelled else { return [] }
            let share = share(for: grant)
            let listing = Task {
                let started = ContinuousClock.now
                do {
                    let names = try await share.folderNames(in: query.parent)
                    completion = (grantID, query.parent, names)
                    Self.listingLog.info("""
                        completion_list folders=\(names.count) \
                        total_ms=\(started.duration(to: .now) / .milliseconds(1), format: .fixed(precision: 1))
                        """)
                } catch {
                    // Typing on in the same folder doesn't list it again.
                    completion = (grantID, query.parent, [])
                    Self.listingLog.error("completion_list \(logFields(error), privacy: .public)")
                }
                completionListing = nil
            }
            completionListing = listing
            await listing.value
        }
        return completion.map { query.suggestions(from: $0.names) } ?? []
    }

    /// The Folder field lost focus: the next completion lists again.
    func endFolderCompletion() {
        completion = nil
    }

    /// Plan §8 Storage: the catalog sizes of the materialized files; nil if they can't be read.
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

    /// Plan §8 Remove Downloads: evicts the materialized files that are not kept. A file that an app
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

    /// Plan §7 diagnostics: counts only.
    func diagnostics() async -> Diagnostics {
        let sources = Array(sources.values)
        let shares = Array(shares.values)
        return (try? await Self.offMain { Self.diagnostics(sources, shares) }) ?? Diagnostics()
    }

    private nonisolated static func diagnostics(_ sources: [LocationSource], _ shares: [ShareAccess]) -> Diagnostics {
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
        counts.sessions = shares.count { $0.hasSession }
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
            shares=\(counts.shares) sessions=\(counts.sessions) kept=\(counts.kept) catalogs_paused=\(counts.catalogsPaused)
            """)
    }

    private func run(_ step: LaunchReconciliation.Step, registered: [String: NSFileProviderDomain]) async throws {
        switch step {
        case .removeDomain(let id):
            guard try LocationSource.pendingWrites(domainID: id) == 0 else { throw UploadError.pendingWrites }
            guard let domain = registered[id] else { return }
            _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
        case .deleteCatalog(let id):
            guard try LocationSource.pendingWrites(domainID: id) == 0 else { throw UploadError.pendingWrites }
            try Catalog.delete(at: SharedContainer.catalogURL(domainID: id))
            try LocationSource.outbox(domainID: id).removeIfCompleted()
            try LocationSource.editOutbox(domainID: id).removeIfCompleted()
            try LocationSource.renameOutbox().removeCompleted(owner: id)
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
                guard let grant = settings.shares.first(where: { $0.id == record.serverID }),
                      let folder = RelativePath(record.folder) else { throw CocoaError(.fileReadCorruptFile) }
                let catalog = try Catalog.openWriter(at: SharedContainer.catalogURL(domainID: record.domainID),
                                                     domainID: record.domainID)
                let source = makeSource(record, folder: folder, grant: grant, catalog: catalog)
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

    private func makeSource(_ record: LocationRecord, folder: RelativePath, grant: ServerGrant,
                            catalog: Catalog) -> LocationSource {
        offlineVerification[record.domainID] = nil
        offlineGeneration[record.domainID] = nil
        let domain = domain(for: record)
        domains[record.domainID] = domain
        let domainID = record.domainID
        let source = LocationSource(domainID: domainID, folder: folder, catalog: catalog, access: share(for: grant)) {
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { error in
                guard let error else { return }
                Self.listingLog.error("signal domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
            }
        }
        try? source.configureWriteMode(record.activeWriteBookmark, confirmed: record.smbOnlyEditing == true)
        source.retryEdits()
        source.onChange { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onLocationChange?(domainID)
                    self?.onChange?()
                }
            }
        }
        source.onDirectoryChange { [weak self, weak source] folders in
            Task { @MainActor in
                guard let self, let source, self.canDiscover(source) else { return }
                let now = Self.discoveryNow
                for folder in folders { self.discovery[domainID]?.changed(folder, now: now) }
            }
        }
        return source
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

    private func saveSpaceBlockedDownloads() {
        do {
            try DownloadRecovery.save(spaceBlocked, to: SharedContainer.url().appending(path: DownloadRecovery.fileName))
        } catch {
            Self.readerLog.error("space_state_save \(logFields(error), privacy: .public)")
        }
    }

    private func canDiscover(_ source: LocationSource) -> Bool {
        isReady && sources[source.domainID] === source && domains[source.domainID] != nil
            && !turnedOff.contains(source.domainID) && source.access.state == .connected
            && source.access.hasSession
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
            sources[id]?.setDiscoveryFolders([])
        }
        for source in active where Self.discoveryNow >= (discoveryMembershipDue[source.domainID] ?? .zero) {
            let id = source.domainID
            discoveryMembershipDue[id] = Self.discoveryNow + .seconds(30)
            guard let domain = domains[id], let manager = NSFileProviderManager(for: domain) else { continue }
            do {
                let materialized = try await MaterializedItems.read(manager)
                let folders = try await Self.offMain { try source.discoveryFolders(materialized: materialized.folders) }
                guard canDiscover(source), !Task.isCancelled else { continue }
                var schedule = discovery[id] ?? DirectoryRefresh()
                schedule.replaceFolders(folders, now: Self.discoveryNow)
                discovery[id] = schedule
                source.setDiscoveryFolders(folders)
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

    private func share(for grant: ServerGrant) -> ShareAccess {
        if let share = shares[grant.id] { return share }
        let grantID = grant.id
        let share = ShareAccess(grant: grant, store: store) { [weak self] failures in
            Task { @MainActor in await self?.recovered(grantID, failures) }
        }
        if let settings = store.settings {
            let related = Set(settings.shares.filter {
                EditNamespace.key($0.mountFrom) == EditNamespace.key(grant.mountFrom)
            }.map(\.id))
            for record in settings.locations where related.contains(record.serverID) {
                if let folder = RelativePath(record.folder) {
                    share.editNamespace.register(domain: record.domainID, folder: folder)
                }
            }
        }
        // Changes on two threads can be queued in reverse order, so read the state on main.
        share.onStateChange { [weak self, weak share] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let share { self?.shareChanged(grantID, share.state) } }
            }
        }
        shares[grant.id] = share
        shareStates[grant.id] = share.state
        share.setRemountWanted(store.settings?.locations.contains { $0.serverID == grantID } == true)
        return share
    }

    /// Phase 3 plan §1: the app mounts again only a share that a location uses.
    private func updateRemountWanted() {
        let used = Set(store.settings?.locations.map(\.serverID) ?? [])
        for (id, share) in shares { share.setRemountWanted(used.contains(id)) }
    }

    private func shareChanged(_ grantID: UUID, _ state: ShareHealth.State) {
        guard shares[grantID] != nil else { return }
        let before = shareStates[grantID] ?? .notConnected
        guard before != state else { return }
        shareStates[grantID] = state
        onShareState?(grantID, before, state)
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
            offlineVerification[id] = nil
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

    /// Plan §3 flow 4: the system retries what failed, then flow 5 lists materialized folders again.
    private func recovered(_ grantID: UUID, _ failures: [SourceFailure]) async {
        let affected = sources.values.filter { $0.access.grantID == grantID }.map(\.domainID)
        Self.shareLog.info("""
            share=\(grantID.uuidString, privacy: .public) recovery domains=\(affected.count) \
            resolved=\(failures.map { "\($0)" }.joined(separator: ","), privacy: .public)
            """)
        for domainID in affected {
            sources[domainID]?.retryRenames()
            await signalResolved(domainID, failures)
        }
        relist(grantID)
        for record in store.settings?.locations ?? [] where record.serverID == grantID && !record.pendingKeeps.isEmpty {
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
        do { try await manager.signalEnumerator(for: .workingSet) } catch {
            Self.listingLog.error("signal domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
        }
    }

    /// One relisting per grant at a time; a recovery during one starts another after it.
    private func relist(_ grantID: UUID) {
        guard relisting[grantID] == nil else {
            relisting[grantID] = true
            return
        }
        relisting[grantID] = false
        Task {
            repeat {
                relisting[grantID] = false
                for source in sources.values where source.access.grantID == grantID {
                    await relistMaterialized(source)
                }
            } while relisting[grantID] == true
            relisting[grantID] = nil
        }
    }

    /// D6: the system never enumerates a materialized folder again, so the app lists it again.
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
                   [SourceFailure.serverUnreachable, .notConnected, .notAuthenticated].contains(failure) { break }
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
    private func makeListedSource(_ record: LocationRecord, folder: RelativePath,
                                  grant: ServerGrant) async throws -> LocationSource {
        let url = try SharedContainer.catalogURL(domainID: record.domainID)
        try FileManager.default.createDirectory(at: SharedContainer.catalogsDirectory(), withIntermediateDirectories: true)
        let source = makeSource(record, folder: folder, grant: grant,
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
