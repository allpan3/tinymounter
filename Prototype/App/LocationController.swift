import Darwin
import FileProvider
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Domain steps, launch reconciliation, recovery signals and relisting (plan §3 and §7).
@MainActor
final class LocationController {
    let store: SettingsStore
    /// Set when launch reconciliation can't run; nothing is added or removed then.
    private(set) var problem: String?
    /// Until launch reconciliation ends, a new catalog could look like one without a record.
    private(set) var isReady = false
    /// Pause Downloads, for every location. Each launch starts with it off (plan §7).
    private(set) var paused = false
    /// The latest Pause Downloads change.
    private var pauseChange: Task<Bool, Never>?
    var onChange: (() -> Void)?
    private let reader = SourceReaderHost()
    private var shares: [UUID: ShareAccess] = [:]
    private var sources: [String: LocationSource] = [:]
    private var domains: [String: NSFileProviderDomain] = [:]
    /// Grants with a relisting running; true if a recovery asked for another one.
    private var relisting: [UUID: Bool] = [:]
    private var diagnosticsSignal: (any DispatchSourceSignal)?
    nonisolated private static let catalogLog = Logger(subsystem: "dev.tinymounter.prototype", category: "catalog")
    nonisolated private static let listingLog = Logger(subsystem: "dev.tinymounter.prototype", category: "listing")
    nonisolated private static let shareLog = Logger(subsystem: "dev.tinymounter.prototype", category: "share")
    nonisolated private static let readerLog = Logger(subsystem: "dev.tinymounter.prototype", category: "source-reader")

    init(store: SettingsStore) {
        self.store = store
        reader.source = { [weak self] in self?.sources[$0] }
        reader.onConnected = { [weak self] domainID in
            Task { await self?.signalResolved(domainID, [.serverUnreachable]) }
        }
    }

    var onReaderStatus: ((String) -> Void)? {
        get { reader.onStatus }
        set { reader.onStatus = newValue }
    }

    /// Plan §7 app launch: the staging sweep before any reader connects, then the domain steps.
    func launch() async {
        sweepStaging()
        guard case .ready(let settings) = store.state else {
            problem = "tinymounter cannot read its settings file. tinymounter does not change the locations."
            Self.catalogLog.error("launch_reconciliation stopped reason=settings")
            onChange?()
            return
        }
        let registered: [NSFileProviderDomain]
        let catalogs: Set<String>
        do {
            registered = try await NSFileProviderManager.domains()
            catalogs = try SharedContainer.catalogDomainIDs()
        } catch {
            problem = "tinymounter cannot read the locations of this Mac (\(logFields(error)))."
            Self.catalogLog.error("launch_reconciliation stopped \(logFields(error), privacy: .public)")
            onChange?()
            return
        }
        let byID = Dictionary(registered.map { ($0.identifier.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = LaunchReconciliation.plan(records: .success(settings.locations), catalogs: catalogs,
                                             domains: Set(byID.keys))
        for id in plan.unknownDomains {
            Self.catalogLog.info("launch_reconciliation unknown_domain=\(id, privacy: .public) kept=1")
        }
        var failed = 0
        for sequence in plan.sequences {
            for step in sequence {
                do {
                    try await run(step, registered: byID)
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
        for share in shares.values { share.connect() }
        logDiagnostics(reason: "launch")
        installDiagnosticsSignal()
        isReady = true
        onChange?()
    }

    /// The access for a saved grant, made on first use.
    func share(forGrantID id: UUID) -> ShareAccess? {
        if let share = shares[id] { return share }
        return store.settings?.servers.first { $0.id == id }.map(share(for:))
    }

    /// Saves a grant. A grant for a share that has one replaces its bookmark and keeps its ID.
    func saveGrant(_ grant: ServerGrant) throws -> UUID {
        var saved = grant.id
        try store.update { settings in
            if let index = settings.servers.firstIndex(where: { $0.mountFrom == grant.mountFrom }) {
                settings.servers[index].bookmark = grant.bookmark
                saved = settings.servers[index].id
            } else {
                settings.servers.append(grant)
            }
        }
        shares[saved]?.replaceBookmark(grant.bookmark)
        return saved
    }

    /// Plan §7: create the catalog, list the root into it, save the record, then add the domain.
    func add(name: String, folder: RelativePath, grantID: UUID) async throws {
        guard isReady, let settings = store.settings, let grant = settings.servers.first(where: { $0.id == grantID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let record = LocationRecord(name: LocationRecord.uniqueName(name, among: settings.locations.map(\.name)),
                                    serverID: grantID, folder: folder)
        let url = try SharedContainer.catalogURL(domainID: record.domainID)
        try FileManager.default.createDirectory(at: SharedContainer.catalogsDirectory(), withIntermediateDirectories: true)
        let source = makeSource(record, folder: folder, grant: grant,
                                catalog: try Catalog.create(at: url, domainID: record.domainID, rootName: record.name))
        do {
            let receipt = try await source.list(Catalog.rootItemID, requestID: UUID())
            try store.update { $0.locations.append(record) }
            Self.catalogLog.info("""
                location_added domain=\(record.domainID, privacy: .public) entries=\(receipt.entries) \
                skipped=\(receipt.skipped)
                """)
        } catch {
            source.close()
            domains[record.domainID] = nil
            // A catalog left here has no record, so the next launch deletes it.
            do { try Catalog.delete(at: url) } catch {
                Self.catalogLog.error("location_add_cleanup ok=0 \(logFields(error), privacy: .public)")
            }
            throw error
        }
        sources[record.domainID] = source
        if paused { Self.pause(source, true) }
        onChange?()
        try await NSFileProviderManager.add(domain(for: record))
        await refreshDomains()
    }

    /// Plan §7: mark the record, remove the domain, delete the catalog, delete the record.
    func remove(_ recordID: UUID) async throws {
        guard isReady, let record = store.settings?.locations.first(where: { $0.id == recordID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        try store.update { settings in
            guard let index = settings.locations.firstIndex(where: { $0.id == recordID }) else { return }
            settings.locations[index].removing = true
        }
        onChange?()
        if let registered = try await NSFileProviderManager.domains()
            .first(where: { $0.identifier.rawValue == record.domainID }) {
            // Downloaded copies are only NAS files again; a later location downloads them anew.
            _ = try await NSFileProviderManager.remove(registered, mode: .removeAll)
        }
        sources.removeValue(forKey: record.domainID)?.close()
        domains[record.domainID] = nil
        try Catalog.delete(at: SharedContainer.catalogURL(domainID: record.domainID))
        try store.update { $0.locations.removeAll { $0.id == recordID } }
        Self.catalogLog.info("""
            location_removed domain=\(record.domainID, privacy: .public)
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

    /// Plan §7 diagnostics: counts only, at launch and on SIGUSR1.
    func logDiagnostics(reason: String) {
        var open = 0, unavailable = 0, items = 0, tombstones = 0, listed = 0, kept = 0, paused = 0
        for source in sources.values {
            do {
                let counts = try source.counts()
                open += 1
                items += counts.live
                tombstones += counts.tombstones
                listed += counts.listedFolders
                kept += counts.kept
                if try source.isPaused() { paused += 1 }
            } catch {
                unavailable += 1
            }
        }
        let files = (try? SharedContainer.catalogDomainIDs().count) ?? -1
        let stageFiles = Self.stageFileCount(), descriptors = Self.descriptorCount(), rss = Self.residentBytes()
        let sessions = shares.values.count { $0.hasSession }
        Self.catalogLog.info("""
            diagnostics reason=\(reason, privacy: .public) catalog_files=\(files) catalogs_open=\(open) \
            catalogs_unavailable=\(unavailable) items=\(items) tombstones=\(tombstones) listed_folders=\(listed) \
            stage_files=\(stageFiles) descriptors=\(descriptors) rss_bytes=\(rss) shares=\(self.shares.count) \
            sessions=\(sessions) kept=\(kept) catalogs_paused=\(paused)
            """)
    }

    private func run(_ step: LaunchReconciliation.Step, registered: [String: NSFileProviderDomain]) async throws {
        switch step {
        case .removeDomain(let id):
            guard let domain = registered[id] else { return }
            _ = try await NSFileProviderManager.remove(domain, mode: .removeAll)
        case .deleteCatalog(let id):
            try Catalog.delete(at: SharedContainer.catalogURL(domainID: id))
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
                guard let grant = settings.servers.first(where: { $0.id == record.serverID }),
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
    }

    private func makeSource(_ record: LocationRecord, folder: RelativePath, grant: ServerGrant,
                            catalog: Catalog) -> LocationSource {
        let domain = domain(for: record)
        domains[record.domainID] = domain
        let domainID = record.domainID
        return LocationSource(domainID: domainID, folder: folder, catalog: catalog, access: share(for: grant)) {
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { error in
                guard let error else { return }
                Self.listingLog.error("signal domain=\(domainID, privacy: .public) \(logFields(error), privacy: .public)")
            }
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
        shares[grant.id] = share
        return share
    }

    /// Only domains with an open catalog get a reader; the others fail without one.
    private func refreshDomains() async {
        do {
            reader.update(try await NSFileProviderManager.domains().filter { sources[$0.identifier.rawValue] != nil })
        } catch {
            Self.readerLog.error("domains_unavailable \(logFields(error), privacy: .public)")
        }
    }

    /// Plan §3 flow 4: the system retries what failed, then flow 5 lists materialized folders again.
    private func recovered(_ grantID: UUID, _ failures: [SourceFailure]) async {
        let affected = sources.values.filter { $0.access.grantID == grantID }.map(\.domainID)
        Self.shareLog.info("""
            share=\(grantID.uuidString, privacy: .public) recovery domains=\(affected.count) \
            resolved=\(failures.map { "\($0)" }.joined(separator: ","), privacy: .public)
            """)
        for domainID in affected { await signalResolved(domainID, failures) }
        relist(grantID)
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
            folders = try await MaterializedFolders.read(manager)
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
            MainActor.assumeIsolated { self?.logDiagnostics(reason: "signal") }
        }
        source.activate()
        diagnosticsSignal = source
    }

    private static func stageFileCount() -> Int {
        guard let directory = try? SharedContainer.stagingDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return -1
        }
        return names.count(where: Staging.isStageFileName)
    }

    private static func descriptorCount() -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        return used > 0 ? Int(used) / stride : -1
    }

    private static func residentBytes() -> UInt64 {
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

/// The folders of a domain's materialized set: the items that the system keeps on this Mac.
enum MaterializedFolders {
    static func read(_ manager: NSFileProviderManager) async throws -> [String] {
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        let observer = MaterializedObserver()
        // The header asks for an empty first page: the sort constants don't apply here.
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        while let current = page {
            page = try await observer.next(enumerator, from: current)
        }
        return observer.folders
    }
}

/// The system calls it on its own queue, one page at a time.
private final class MaterializedObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []
    private var waiting: CheckedContinuation<NSFileProviderPage?, Error>?

    var folders: [String] { lock.withLock { found } }

    func next(_ enumerator: NSFileProviderEnumerator, from page: NSFileProviderPage) async throws -> NSFileProviderPage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        // The system materializes its own Trash folder, which is not in the catalog.
        let folders = updatedItems
            .filter { $0.contentType?.conforms(to: .folder) == true && $0.itemIdentifier != .trashContainer }
            .map(\.itemIdentifier.rawValue)
        lock.withLock { found += folders }
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
