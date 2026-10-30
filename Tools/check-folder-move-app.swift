import AppKit
import CryptoKit
import Darwin
import Foundation

// Compile into the app module in place of TinyMounterApp.swift; keep its signing and sandbox.
@main
enum M22AppHelper {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--m22-app",
                  ["exercise", "resume"].contains(args[2]),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  let location = UUID(uuidString: args[4]) else { throw ProbeFailure.check("arguments") }
            let probe = try Probe(phase: args[2], run: run, location: location)
            try await Task.detached { try probe.run() }.value
            exit(0)
        } catch {
            // Errors can contain private paths, so only an explicit probe label reaches stdout.
            let label = (error as? ProbeFailure)?.label ?? "unexpected-error-see-private-report"
            print("M22 app probe failed: \(label)")
            exit(1)
        }
    }
}

private enum ProbeFailure: Error {
    case check(String)
    case settingsCheckpoint
    var label: String {
        switch self {
        case .check(let label): return label
        case .settingsCheckpoint: return "injected-after-settings-save"
        }
    }
}

private func require(_ value: Bool, _ label: String) throws {
    guard value else { throw ProbeFailure.check(label) }
}

private final class Reply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?
    func finish(_ value: Result<Value, Error>) {
        lock.withLock { result = value }
        done.signal()
    }
    func get(seconds: Int = 180) throws -> Value {
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success else {
            throw ProbeFailure.check("callback-timeout")
        }
        return try lock.withLock { try result!.get() }
    }
    var finished: Bool { lock.withLock { result != nil } }
}

private final class ReadGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private var held = false
    func check(_ bytes: Int64) throws {
        guard !held else { return }
        held = true
        entered.signal()
        guard release.wait(timeout: .now() + .seconds(45)) == .success else {
            throw ProbeFailure.check("read-gate-timeout")
        }
    }
}

private struct SavedRow: Codable, Equatable {
    let id: String
    let path: String
    let version: String
    let keep: Bool
    let requested: Bool
    init(_ row: CatalogRow, path: String) {
        id = row.id; self.path = path; version = row.contentVersion
        keep = row.keep; requested = row.keepRequested
    }
}

private struct ProbeState: Codable {
    let run: UUID
    let owner: String
    let overlap: String
    var rootBirth: Int64 = 0
    var request: FileRenameRequest?
    var rows: [String: [SavedRow]] = [:]
    var auxiliaryDomains: [String] = []
}

private final class Probe: @unchecked Sendable {
    let phase: String
    let runID: UUID
    let root: RelativePath
    let directory: URL
    let store: SettingsStore
    let access: ShareAccess
    let bookmark: Data
    let originalSettingsURL: URL
    let originalSettings: Data
    private let reportLock = NSLock()
    private var events: [[String: String]] = []
    private var sources: [LocationSource] = []
    private var state: ProbeState
    private static let mount = "/Volumes/tinymounter-m19-edit-test"
    private static let host = "127.0.0.1"
    private static let share = "tinymounter-m19-edit-test"
    private static let account = "_tinymounter_m19"

    @MainActor
    init(phase: String, run: UUID, location: UUID) throws {
        self.phase = phase; runID = run
        root = RelativePath("probe-m22-app-" + run.uuidString)!
        directory = URL.applicationSupportDirectory.appending(path: "tinymounter/M22App/" + run.uuidString)
        originalSettingsURL = URL.applicationSupportDirectory.appending(path: "tinymounter/Settings.json")
        originalSettings = try Data(contentsOf: originalSettingsURL)
        // Decode directly: loading older Settings must not migrate the user's file during a probe.
        let current = try JSONDecoder().decode(AppSettings.self, from: originalSettings)
        guard let record = current.locations.first(where: { $0.id == location }),
              !record.removing, record.smbOnlyEditing == true, let write = record.activeWriteBookmark,
              let grant = current.shares.first(where: { $0.id == record.serverID }),
              let endpoint = ShareAddress(grant.mountFrom), endpoint.host == Self.host,
              endpoint.share == Self.share, endpoint.account == Self.account,
              grant.host == Self.host, grant.share == Self.share, grant.account == Self.account,
              let server = current.servers.first(where: { $0.id == grant.serverID }) else {
            throw ProbeFailure.check("explicit-fixture-write-grant-required")
        }
        bookmark = write
        var stale = false
        let scoped = try URL(resolvingBookmarkData: write,
            options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        try require(!stale && ShareAccess.filePath(scoped) == Self.mount, "write-bookmark-is-share-root")
        let privateSettings = directory.appending(path: "Settings.json")
        if phase == "exercise" {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            guard mkdir(directory.path, 0o700) == 0 else { throw ProbeFailure.check("new-run-directory-required") }
            state = ProbeState(run: run, owner: UUID().uuidString, overlap: UUID().uuidString)
            var locations: [LocationRecord] = []
            for (domain, folder) in [(state.owner, root), (state.overlap, root.appending("overlap")!)] {
                var synthetic = LocationRecord(name: "M22 app probe", serverID: grant.id,
                                               folder: folder, domainID: domain)
                synthetic.pendingKeeps = Self.oldKeeps(root)
                locations.append(synthetic)
            }
            try AppSettings(servers: [server], shares: [grant], locations: locations,
                savedKeeps: [SavedKeepList(host: Self.host, share: Self.share, paths: Self.oldKeeps(root))])
                .save(to: privateSettings)
        } else {
            state = try JSONDecoder().decode(ProbeState.self,
                from: Data(contentsOf: directory.appending(path: "state.json")))
            try require(state.run == run, "resume-run-identity")
        }
        store = SettingsStore(url: privateSettings)
        try require(store.settings != nil, "private-settings-readable")
        try Data((ISO8601DateFormatter().string(from: .now) + "\n").utf8)
            .write(to: directory.appending(path: phase + "-started.txt"), options: .withoutOverwriting)
        access = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
    }

    private static func oldKeeps(_ root: RelativePath) -> [KeepPath] {
        [KeepPath(path: root.string + "/overlap/Tree", kind: .folder),
         KeepPath(path: root.string + "/overlap/Tree/Nested/leaf.txt", kind: .file),
         KeepPath(path: root.string + "/neighbor.txt", kind: .file)]
    }

    func run() throws {
        do {
            try require(access.mountPath() == Self.mount, "existing-loopback-mount-required")
            try access.withSession { session, _ in
                try require(session.identity.typeName == "smbfs", "native-smb-session")
                guard let endpoint = ShareAddress(session.identity.mountFrom) else {
                    throw ProbeFailure.check("mount-address")
                }
                try require(endpoint.host == Self.host && endpoint.share == Self.share
                    && endpoint.account == Self.account, "mount-identity")
                let fd = try session.openFolder(root)
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw ProbeFailure.check("root-stat") }
                let birth = Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000
                    + Int64(info.st_birthtimespec.tv_nsec)
                try require(birth > 0 && (phase == "exercise" || birth == state.rootBirth), "root-birth-identity")
                state.rootBirth = birth
                let marker = try ReadOnlyFile(directoryFD: fd, relativePath: RelativePath("marker.txt")!,
                                              expected: session.identity)
                try require(marker.snapshot.size == Int64("tinymounter-m22-app:\(runID.uuidString)\n".utf8.count),
                            "fixture-marker-size")
                try require(try marker.checksum(range: ByteRange(offset: 0, length: marker.snapshot.size,
                    fileSize: marker.snapshot.size)) == Self.digest(Data("tinymounter-m22-app:\(runID.uuidString)\n".utf8)),
                    "fixture-marker")
            }
            try saveState()
            try note("setup", "validated", details: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cache": "uncontrolled", "entry": "app-module-LocationSource-API"])
            if phase == "exercise" { try exercise() } else { try resume() }
            try require(Data(contentsOf: originalSettingsURL) == originalSettings, "user-settings-unchanged")
            try note("phase", "passed")
        } catch {
            let ns = error as NSError
            try? note("phase", "failed", details: ["errorDomain": ns.domain, "errorCode": String(ns.code),
                "probe": (error as? ProbeFailure)?.label ?? "unexpected"])
            throw error
        }
        for source in sources { source.close(); access.editNamespace.unregister(source.domainID) }
    }

    private func makeSource(domain: String, folder: RelativePath, fresh: Bool) throws -> LocationSource {
        let url = directory.appending(path: domain + ".sqlite")
        if fresh {
            try require(!FileManager.default.fileExists(atPath: URL.applicationSupportDirectory
                .appending(path: "tinymounter/Uploads/" + domain).path), "fresh-upload-domain")
            try require(!FileManager.default.fileExists(atPath: URL.applicationSupportDirectory
                .appending(path: "tinymounter/Edits/" + domain).path), "fresh-edit-domain")
            try require(!LocationSource.renameOutbox().intents().contains { $0.domains.contains(domain) },
                        "fresh-rename-domain")
        }
        let catalog = try fresh ? Catalog.create(at: url, domainID: domain, rootName: "M22 app probe")
            : Catalog.openWriter(at: url, domainID: domain)
        let source = LocationSource(domainID: domain, folder: folder, catalog: catalog, access: access,
            renameSettings: { [self] intent in try await commitSettings(intent) }, signal: { _ in })
        try source.configureWriteMode(bookmark, confirmed: true)
        sources.append(source)
        return source
    }

    @MainActor
    private func commitSettings(_ intent: RenameIntent) throws {
        guard case .folder(let record) = intent,
              let current = try LocationSource.renameOutbox().intents().first(where: { $0.id == record.id }),
              case .folder(let durable) = current,
              [.verified, .recovering].contains(durable.state),
              EditNamespace.contains(root, RelativePath(durable.source)!),
              EditNamespace.contains(root, RelativePath(durable.destination)!) else {
            throw ProbeFailure.check("settings-intent-boundary")
        }
        try store.update { settings in
            try settings.moveKeptFolder(from: durable.source, to: durable.destination,
                                        host: Self.host, share: Self.share)
        }
        if phase == "exercise", durable.source == root.string + "/overlap/Tree" {
            try note("settings-checkpoint", "saved-before-injected-failure")
            throw ProbeFailure.settingsCheckpoint
        }
    }

    private func list(_ source: LocationSource, _ id: String) throws {
        let reply = Reply<ListReceipt>()
        source.list(id, requestID: UUID(), bounded: false) { reply.finish($0) }
        let result = try reply.get()
        try require(result.skipped == 0, "listing-has-no-skipped-entries")
    }

    private func row(_ source: LocationSource, _ path: String) throws -> CatalogRow {
        try source.withCatalog { catalog in
            var id = Catalog.rootItemID
            for name in RelativePath(path)!.components {
                guard let child = try catalog.liveChild(parent: id, nameKey: NameKey(name)),
                      child.name == name else { throw ProbeFailure.check("expected-catalog-path") }
                id = child.id
            }
            guard let row = try catalog.item(id: id) else { throw ProbeFailure.check("expected-catalog-row") }
            return row
        }
    }

    private func listPath(_ source: LocationSource, _ path: String) throws {
        try list(source, row(source, path).id)
    }

    private func request(_ source: LocationSource, _ from: String, _ parent: String,
                         name: String = "Moved") throws -> FileRenameRequest {
        let item = try row(source, from), target = try row(source, parent)
        return try FileRenameRequest(item: item.id, parent: target.id, name: name,
                                     contentVersion: item.contentVersion, metadataVersion: item.metadataVersion)
    }

    private func beginMove(_ source: LocationSource, _ request: FileRenameRequest) -> Reply<CreateReceipt> {
        let reply = Reply<CreateReceipt>()
        source.moveFolder(request, progress: Progress(), started: {}) { reply.finish($0) }
        return reply
    }

    private func refuse(_ source: LocationSource, _ request: FileRenameRequest, _ expected: UploadError,
                        _ label: String) throws {
        let before = Set(try LocationSource.renameOutbox().intents().map(\.id))
        do {
            _ = try beginMove(source, request).get()
            throw ProbeFailure.check(label + "-unexpected-success")
        } catch let error as UploadError { try require(error == expected, label + "-error") }
        try require(Set(LocationSource.renameOutbox().intents().map(\.id)) == before, label + "-no-intent")
        try note(label, "refused-before-intent")
    }

    private func readRequest(_ row: CatalogRow, base: Bool = false) throws -> SourceReadRequest {
        try SourceReadRequest(id: UUID(), item: row.id, version: row.contentVersion,
            range: ByteRange(offset: 0, length: row.size, fileSize: row.size), background: false,
            establishEditBase: base)
    }

    private func transfer(_ source: LocationSource, _ row: CatalogRow, base: Bool = false,
                          gate: ReadGate? = nil) throws -> TransferOutput {
        let staging = directory.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return try source.transfer(readRequest(row, base: base), progress: Progress(), stagingDirectory: staging,
                                   checkSpace: gate.map { gate in { try gate.check($0) } })
    }

    private func checkTransfer(_ output: TransferOutput, expected: Data) throws {
        guard let url = output.stagingURL else { throw ProbeFailure.check("missing-staged-read") }
        try require(Data(contentsOf: url) == expected, "full-read-contents")
    }

    private func exercise() throws {
        let owner = try makeSource(domain: state.owner, folder: root, fresh: true)
        let overlap = try makeSource(domain: state.overlap, folder: root.appending("overlap")!, fresh: true)
        try list(owner, Catalog.rootItemID)
        for name in ["drain", "timeout", "overlap"] {
            try listPath(owner, name)
            try listPath(owner, name + "/Tree")
            try listPath(owner, name + "/Dest")
        }
        try listPath(owner, "overlap/Tree/Nested")
        try list(overlap, Catalog.rootItemID)
        try listPath(overlap, "Tree"); try listPath(overlap, "Tree/Nested"); try listPath(overlap, "Dest")

        try refuse(owner, request(owner, "overlap", ""), .readOnly, "configured-root")
        let nestedDomain = UUID().uuidString
        access.editNamespace.register(domain: nestedDomain, folder: root.appending(RelativePath("overlap/Tree/Nested")!)!)
        do {
            defer { access.editNamespace.unregister(nestedDomain) }
            try refuse(owner, request(owner, "overlap/Tree", "overlap/Dest"), .readOnly, "contains-configured-root")
        }
        try refuse(owner, request(owner, "overlap/Tree", "overlap/Tree/Nested"), .invalidRequest, "into-descendant")
        try refuse(owner, request(owner, "overlap/Tree", "drain/Dest"), .readOnly, "cross-overlap-boundary")
        try drain(owner, branch: "timeout", timeout: true)
        try drain(owner, branch: "drain", timeout: false)
        try exclusions()

        for (source, prefix) in [(owner, "overlap/"), (overlap, "")] {
            _ = try source.keep([row(source, prefix + "Tree").id,
                                 row(source, prefix + "Tree/Nested/leaf.txt").id], value: true)
            for name in ["unchanged.txt", "changed.txt", "retired.txt"] {
                let path = prefix + "Tree/" + name
                try checkTransfer(transfer(source, row(source, path), base: true),
                                  expected: Data(("original-" + name + "\n").utf8))
            }
            let saved = try ["Tree", "Tree/unchanged.txt", "Tree/changed.txt",
                "Tree/retired.txt", "Tree/Nested", "Tree/Nested/leaf.txt"].map {
                    SavedRow(try row(source, prefix + $0), path: prefix + $0)
                }
            try require(saved.allSatisfy(\.keep) && saved.filter(\.requested).count == 2,
                        "independent-and-inherited-keeps-established")
            try require(saved.filter { $0.version.hasPrefix("e1:") }.count == 3, "historical-bases-established")
            state.rows[source.domainID] = saved
        }
        state.request = try request(owner, "overlap/Tree", "overlap/Dest")
        try saveState()
        do {
            _ = try beginMove(owner, state.request!).get()
            throw ProbeFailure.check("checkpoint-injection-not-reached")
        } catch ProbeFailure.settingsCheckpoint { }
        let pending = try moveRecord()
        try require(pending.state == .verified && pending.finishedDomains.isEmpty
            && pending.views.count == 2, "durable-unfinished-settings-checkpoint")
        try verifyViews(owner, overlap, recovering: false)
        try verifySettings()
        try write(pending, "checkpoint-intent.json")
        try note("checkpoint", "ready-for-between", details: ["run": runID.uuidString,
            "interruption": "injected-error-after-settings-save-clean-process-exit",
            "views": "2", "state": pending.state.rawValue])
    }

    private func drain(_ source: LocationSource, branch: String, timeout: Bool) throws {
        let tree = try row(source, branch + "/Tree"), file = try row(source, branch + "/Tree/read.txt")
        let full = root.appending(RelativePath(branch + "/Tree")!)!
        try access.withSession { session, _ in
            try session.watch(domainID: source.domainID, folderID: tree.id, path: full, changed: {})
        }
        let gate = ReadGate(), read = Reply<TransferOutput>()
        DispatchQueue.global().async { read.finish(Result { try self.transfer(source, file, gate: gate) }) }
        defer { gate.release.signal() }
        try require(gate.entered.wait(timeout: .now() + .seconds(20)) == .success, "real-native-read-open")
        let move = try request(source, branch + "/Tree", branch + "/Dest")
        let before = Set(try LocationSource.renameOutbox().intents().map(\.id))
        let reply = beginMove(source, move)
        let deadline = Date.now.addingTimeInterval(15)
        while !access.editNamespace.isReserved(full) && !reply.finished && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try require(access.editNamespace.isReserved(full), "move-reserves-before-drain")
        try require(Set(LocationSource.renameOutbox().intents().map(\.id)) == before, "drain-before-intent")
        do {
            _ = try transfer(source, file)
            throw ProbeFailure.check("reserved-read-started")
        } catch UploadError.pendingWrites { }
        if timeout {
            do {
                _ = try reply.get(seconds: 20)
                throw ProbeFailure.check("read-timeout-moved")
            } catch UploadError.pendingWrites { }
            try require(Set(LocationSource.renameOutbox().intents().map(\.id)) == before, "timeout-no-intent")
            try require(!access.editNamespace.isReserved(full), "timeout-releases-reservation")
            _ = try row(source, branch + "/Tree")
            try require(try source.liveChild(of: row(source, branch + "/Dest").id, named: "Moved") == nil,
                        "timeout-destination-absent")
            gate.release.signal()
        } else {
            try require(!reply.finished, "move-waits-for-active-read")
            gate.release.signal()
            try require(try reply.get().item == tree.id, "drained-move-retains-root-id")
        }
        try checkTransfer(read.get(), expected: Data(String(repeating: "read\n", count: 524_288).utf8))
        try note(timeout ? "active-read-timeout" : "active-read-and-watch-drain", "passed",
                       details: ["read": "LocationSource.transfer-native-descriptor-held-at-checkSpace",
                                 "watch": "ShareSession.watch-installed-before-move"])
    }

    private func exclusions() throws {
        for kind in ["upload", "save", "retained"] {
            let domain = UUID().uuidString
            state.auxiliaryDomains.append(domain)
            try saveState()
            let source = try makeSource(domain: domain, folder: root.appending("blocked-" + kind)!, fresh: true)
            defer { source.close(); access.editNamespace.unregister(domain) }
            try list(source, Catalog.rootItemID); try listPath(source, "Tree"); try listPath(source, "Dest")
            let tree = try row(source, "Tree"), child = try row(source, "Tree/child.txt")
            let contents = directory.appending(path: domain + "-pending.txt")
            try Data("pending-local-copy\n".utf8).write(to: contents, options: .withoutOverwriting)
            if kind == "upload" {
                let upload = try CreateRequest(template: UUID().uuidString, parent: tree.id, name: "new.txt",
                                               kind: .file, staging: nil)
                _ = try LocationSource.outbox(domainID: domain).prepare(upload, path: RelativePath("Tree/new.txt")!,
                    contents: contents, progress: Progress())
            } else {
                let outbox = try LocationSource.editOutbox(domainID: domain)
                var old = try outbox.prepare(item: child.id, parent: tree.id, path: RelativePath("Tree/child.txt")!,
                    baseVersion: child.contentVersion, failOnConflict: true, contents: contents, progress: Progress())
                if kind == "retained" {
                    // Inject only a local checkpoint: no remote artifact was created by this fixture.
                    old.state = .creatingStage
                    try outbox.save(old)
                    let newer = directory.appending(path: domain + "-newer.txt")
                    try Data("newer-local-copy\n".utf8).write(to: newer, options: .withoutOverwriting)
                    _ = try outbox.prepare(item: child.id, parent: tree.id, path: RelativePath("Tree/child.txt")!,
                        baseVersion: child.contentVersion, failOnConflict: true, contents: newer, progress: Progress())
                    try outbox.retainSuperseded(&old)
                    try outbox.validateContents(old)
                }
            }
            try refuse(source, request(source, "Tree", "Dest"), .pendingWrites, "pending-" + kind)
            if kind != "upload" {
                for edit in try LocationSource.editOutbox(domainID: domain).records() {
                    try LocationSource.editOutbox(domainID: domain).validateContents(edit)
                }
            }
        }
    }

    private func resume() throws {
        let owner = try makeSource(domain: state.owner, folder: root, fresh: false)
        let overlap = try makeSource(domain: state.overlap, folder: root.appending("overlap")!, fresh: false)
        try require(try moveRecord().state == .verified, "resume-original-checkpoint")
        guard let request = state.request else { throw ProbeFailure.check("resume-request") }
        try require(try beginMove(owner, request).get().item == request.item, "app-retry-completed")
        let completed = try moveRecord()
        try require(completed.state == .completed && completed.finishedDomains.count == 2
            && completed.recovery != nil, "fresh-recovery-in-both-views")
        try verifyViews(owner, overlap, recovering: true)
        try verifySettings()
        for (source, prefix) in [(owner, "overlap/"), (overlap, "")] {
            let oldParent = prefix.isEmpty ? "" : "overlap"
            for path in [oldParent, prefix + "Dest", prefix + "Dest/Moved", prefix + "Dest/Moved/Nested"] {
                try listPath(source, path)
            }
            try require(try source.liveChild(of: row(source, oldParent).id, named: "Tree") == nil,
                        "old-parent-departure-after-relisting")
        }
        try verifyViews(owner, overlap, recovering: true)
        _ = try beginMove(owner, request).get()
        try require(try moveRecord() == completed, "completed-replay-no-new-checkpoint")
        try verifyViews(owner, overlap, recovering: true)
        try staleVersions(owner)
        try write(completed, "completed-intent.json")
        try note("recovery", "passed", details: ["run": runID.uuidString,
            "boundary": "fresh-app-process-after-injected-settings-failure",
            "staleSaveCoverage": "retired-item-edit-refused; changed-read-refused; preserved-base-retained",
            "unverified": "Finder,downloads,actual-crash,partial-one-view-commit,ambiguous-names,changed-and-preserved-save-publication"])
    }

    private func verifyViews(_ owner: LocationSource, _ overlap: LocationSource, recovering: Bool) throws {
        for source in [owner, overlap] {
            for saved in state.rows[source.domainID]! {
                guard let current = try source.withCatalog({ try $0.item(id: saved.id) }) else {
                    throw ProbeFailure.check("descendant-id-lost")
                }
                if recovering && saved.path.hasSuffix("/retired.txt") {
                    try require(current.deleted, "missing-binding-retired")
                    continue
                }
                try require(!current.deleted && current.keep == saved.keep
                    && current.keepRequested == saved.requested, "keeps-and-identities-preserved")
                let expected = saved.path.replacingOccurrences(of: "Tree", with: "Dest/Moved")
                try require(try source.withCatalog { try $0.relativePath(of: current.id)?.string } == expected,
                            "descendant-path-updated")
                let changed = recovering && saved.path.hasSuffix("/changed.txt")
                try require(changed ? current.contentVersion != saved.version : current.contentVersion == saved.version,
                            "descendant-content-version")
                if current.kind == .file && current.contentVersion.hasPrefix("e1:") {
                    try require(try LocationSource.editOutbox(domainID: source.domainID)
                        .base(item: current.id, contentVersion: current.contentVersion) != nil, "receipt-before-catalog-version")
                }
            }
        }
    }

    private func verifySettings() throws {
        let settings = try JSONDecoder().decode(AppSettings.self,
            from: Data(contentsOf: directory.appending(path: "Settings.json")))
        let expected = Self.oldKeeps(root).map {
            KeepPath(path: $0.path.replacingOccurrences(of: "/overlap/Tree", with: "/overlap/Dest/Moved"), kind: $0.kind)
        }
        try require(settings.locations.count == 2 && settings.locations.allSatisfy { $0.pendingKeeps == expected },
                    "pending-keeps-saved")
        try require(settings.savedKeeps.count == 1 && settings.savedKeeps[0].paths == expected, "saved-keeps-reloaded")
    }

    private func staleVersions(_ source: LocationSource) throws {
        let old = state.rows[source.domainID]!
        let changed = old.first { $0.path.hasSuffix("/changed.txt") }!
        let retired = old.first { $0.path.hasSuffix("/retired.txt") }!
        let preserved = old.first { $0.path.hasSuffix("/unchanged.txt") }!
        let row = try self.row(source, "overlap/Dest/Moved/changed.txt")
        let request = try SourceReadRequest(id: UUID(), item: changed.id, version: changed.version,
            range: ByteRange(offset: 0, length: row.size, fileSize: row.size), background: false)
        do {
            _ = try source.transfer(request, progress: Progress(), stagingDirectory: directory.appending(path: "staging"))
            throw ProbeFailure.check("stale-read-accepted")
        } catch SourceFailure.versionChanged { }
        let current = try self.row(source, "overlap/Dest/Moved/unchanged.txt")
        try require(current.contentVersion == preserved.version, "preserved-base-version")
        try require(try LocationSource.editOutbox(domainID: source.domainID)
            .base(item: current.id, contentVersion: preserved.version) != nil, "preserved-save-base")
        let retiredRow = try source.withCatalog { try $0.item(id: retired.id)! }
        let contents = directory.appending(path: "retired-save.txt")
        try Data("must-not-publish\n".utf8).write(to: contents, options: .withoutOverwriting)
        let edit = try EditRequest(item: retired.id, parent: retiredRow.parentID!, name: retiredRow.name,
            baseVersion: retired.version, staging: UUID(), failOnConflict: true)
        let before = try LocationSource.editOutbox(domainID: source.domainID).records()
        let reply = Reply<EditReceipt>()
        source.edit(edit, contents: contents, progress: Progress(), started: {}, checkSpace: { _ in }) { reply.finish($0) }
        do {
            _ = try reply.get()
            throw ProbeFailure.check("retired-edit-accepted")
        } catch UploadError.readOnly { }
        try require(try LocationSource.editOutbox(domainID: source.domainID).records() == before,
                    "retired-edit-created-no-pending-copy")
    }

    private func moveRecord() throws -> PendingFolderMove {
        guard let request = state.request,
              let record = try LocationSource.renameOutbox().replayFolder(owner: state.owner, request: request) else {
            throw ProbeFailure.check("missing-durable-intent")
        }
        return record
    }

    private func saveState() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: directory.appending(path: "state.json"), options: .atomic)
    }

    private func write(_ value: some Encodable, _ name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appending(path: name), options: .withoutOverwriting)
    }

    private func note(_ label: String, _ outcome: String, details: [String: String] = [:]) throws {
        try reportLock.withLock {
            var event = details
            event["case"] = label; event["outcome"] = outcome
            event["date"] = ISO8601DateFormatter().string(from: .now)
            event["run"] = runID.uuidString; event["phase"] = phase
            events.append(event)
            let data = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appending(path: phase + "-report.json"), options: .atomic)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
