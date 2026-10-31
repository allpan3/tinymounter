import Darwin
import Foundation

// Replace TinyMounterApp.swift only in an isolated signed archive; the runbook is in the .py file.
@main
enum M22GapHelper {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--m22-gap", let phase = GapPhase(rawValue: args[2]),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  let location = UUID(uuidString: args[4]), location.uuidString == args[4] else {
                throw GapCheck(label: "arguments")
            }
            let probe = try GapProbe(phase: phase, run: run, location: location)
            let passed = try await Task.detached { try probe.run() }.value
            print("M22 gap phase " + (passed ? "passed: " : "incomplete: ") + phase.rawValue
                  + "; unavailable cases and untested gates are listed in its report")
            exit(passed ? 0 : 1)
        } catch {
            // Errors can carry private paths, so only a probe label reaches stdout.
            print("M22 gap phase failed: " + ((error as? GapCheck)?.label ?? "see-private-report"))
            exit(1)
        }
    }
}

/// Fresh catalogs and separate fixture cases per phase keep each process at 12 connections or fewer.
private enum GapPhase: String {
    case spelling, ancestors, retry

    var cases: [String] {
        switch self {
        case .spelling: ["case", "nfd"]
        case .ancestors: ["ancestor", "destination"]
        case .retry: ["root", "recover"]
        }
    }
}

private struct GapCheck: Error {
    let label: String
}

private enum GapInjected: Error {
    case afterSettingsSave
}

private func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw GapCheck(label: label) }
}

private enum GapErrors {
    static func failure<Value>(_ result: Result<Value, Error>) -> Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// SMBEdit's connect failure; any other error may follow a request and is never retried here.
    static func isConnectFailure(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSPOSIXErrorDomain && failure.localizedDescription.hasPrefix("connect protected save")
    }

    static func name(_ error: Error) -> String {
        if error is SourceFailure || error is UploadError || error is GapInjected { return String(describing: error) }
        if let check = error as? GapCheck { return "probe:" + check.label }
        let failure = error as NSError
        return failure.domain + ":" + String(failure.code)
    }

    static func fields(_ error: Error) -> [String: Any] {
        let failure = error as NSError
        var result: [String: Any] = ["errorDomain": failure.domain, "errorCode": failure.code, "error": name(error)]
        if let status = SMBEdit.serverStatus(error) { result["ntStatus"] = String(format: "0x%08X", status) }
        if isConnectFailure(error) { result["connectionSetup"] = true }
        return result
    }
}

private final class GapReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) {
        lock.withLock { result = value }
        done.signal()
    }

    /// Throws only on timeout; the production result comes back unchanged.
    func wait(_ label: String, seconds: Int) throws -> Result<Value, Error> {
        guard done.wait(timeout: .now() + .seconds(seconds)) == .success else {
            throw GapCheck(label: "timeout:" + label)
        }
        return lock.withLock { result! }
    }
}

/// Names each step, connection, Settings call and case, so a report says where a phase stopped.
private final class GapLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?
    private var completed: [String] = []
    private var operations: [[String: Any]] = []
    private var connections: [[String: Any]] = []
    private var settings: [[String: Any]] = []
    private var cases: [String: [String: Any]] = [:]

    var step: String? { lock.withLock { current } }

    func enter(_ next: String?) {
        lock.withLock {
            if let previous = current { completed.append(previous) }
            current = next
        }
    }

    func connection(_ label: String, attempt: Int, began: Date, error: Error?) {
        var entry: [String: Any] = ["label": label, "attempt": attempt, "seconds": GapProbe.seconds(since: began)]
        if let error { entry.merge(GapErrors.fields(error)) { $1 } }
        lock.withLock { connections.append(entry) }
    }

    func operation(_ label: String, attempt: Int, began: Date, connections expected: Int, error: Error?) {
        var entry: [String: Any] = ["label": label, "attempt": attempt, "expectedConnections": expected,
                                    "seconds": GapProbe.seconds(since: began),
                                    "result": error == nil ? "success" : "failure"]
        if let error { entry.merge(GapErrors.fields(error)) { $1 } }
        lock.withLock { operations.append(entry) }
    }

    func settingsCall(_ entry: [String: Any]) { lock.withLock { settings.append(entry) } }

    func record(_ label: String, _ values: [String: Any]) {
        lock.withLock { cases[label, default: [:]].merge(values) { $1 } }
    }

    func healthWait(_ label: String, seconds: Double) {
        lock.withLock {
            let previous = cases[label]?["healthWaitSeconds"] as? Double ?? 0
            cases[label, default: [:]]["healthWaitSeconds"] = previous + seconds
        }
    }

    func outcome(_ label: String) -> String? { lock.withLock { cases[label]?["outcome"] as? String } }

    func snapshot() -> [String: Any] {
        lock.withLock {
            ["completedSteps": completed, "operations": operations, "connections": connections,
             "settingsCalls": settings, "cases": cases]
        }
    }
}

private enum GapChange {
    case none
    case respell(String, String)
    case sourceAncestors
    case destinationReplacement
    case root(finishFirst: String)
}

private struct GapStep {
    let label: String
    let destination: String
    let change: GapChange
    let inject: Bool
}

/// The next Settings call's outside change; an unplanned call fails its move.
private final class GapPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var next: GapStep?
    private var spellings: [String: String] = [:]

    func plan(_ step: GapStep) { lock.withLock { next = step } }

    func take() -> GapStep? {
        lock.withLock {
            defer { next = nil }
            return next
        }
    }

    var isPending: Bool { lock.withLock { next != nil } }

    func setSpelling(_ label: String, _ value: String) { lock.withLock { spellings[label] = value } }

    func spelling(_ label: String) -> String { lock.withLock { spellings[label] ?? "not-reached" } }
}

private struct GapRow {
    let id: String
    let path: String
    let contentVersion: String
    let keep: Bool
    let keepRequested: Bool
}

private enum GapFiles {
    /// Created once and flushed, so no later process can replace or silently lose evidence.
    static func createExclusive(_ url: URL, _ data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create probe evidence") }
        defer { Darwin.close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("write probe evidence") }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError("open probe directory") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw posixError("sync probe directory") }
    }
}

private final class GapProbe: @unchecked Sendable {
    private static let mount = "/Volumes/tinymounter-m19-edit-test"
    private static let host = "127.0.0.1"
    private static let share = "tinymounter-m19-edit-test"
    private static let account = "_tinymounter_m19"
    // Below the parent's 600 s action timeout; the watchdog writes a report before it exits.
    private static let budget: TimeInterval = 555
    private static let nfc = "Caf\u{E9}.txt"
    private static let nfd = "Cafe\u{301}.txt"
    private static let seededKeeps = ["spelling/src/Tree/child.txt", "nfd/src/Tree/" + nfc, "root/src/Tree/a.txt"]
    private static let untested: [String] = [
        "Finder, File Provider callbacks, IPC and capability routing, including departure and arrival enumeration.",
        "Invalidation of a downloaded copy of a retired binding: the helper materializes no copy.",
        "Controller Settings, location pending keeps and keep restoration: saved keeps keep the admitted spelling.",
        "Real crashes and network loss: interruptions are an injected Settings error, a direct durable replan "
            + "and a direct one-view finish.",
        "A recovering intent left by a natural failure between replan and completion: that needs timing or a crash.",
        "Retry in a fresh process: every retry runs in the process that made the failed attempt.",
        "Respelled directory descendants: only file descendants are respelled.",
        "Spelling-only changes of the moved root or a destination ancestor; root removal or replacement.",
        "A destination ancestor that disappears without replacement, or a destination change that is never restored.",
        "Source-chain changes before durable move proof, and outside changes during completion's protected window.",
        "Overlapping views for the spelling, ancestor and recovery cases: only the root case has two views.",
        "Native client spelling of names other than one NFC file name, and NFD names present before admission.",
        "Settings callbacks longer than the mover's 60 s wait, cancellation, stop and location Add/Close.",
        "Pagination, large trees, the physical Mac and the NAS. Loopback cache state is uncontrolled.",
        "Older builds reading a folder intent left recovering.",
        "Production connection counts: expectedConnections are estimates, not measurements.",
    ]

    let phase: GapPhase
    let runID: UUID
    let root: RelativePath
    let directory: URL
    let store: SettingsStore
    let access: ShareAccess
    // For the probe's own lock checks and fixture changes, so the mover's health can't refuse them.
    let probeAccess: ShareAccess
    let bookmark: Data
    let originalSettingsURL: URL
    let originalSettings: Data
    let ledger = GapLedger()
    let plan = GapPlan()
    let started = Date()
    private var owner: LocationSource!
    private var overlap: LocationSource?
    private var endpoint: ShareAddress!

    @MainActor
    init(phase: GapPhase, run: UUID, location: UUID) throws {
        let probeRoot = RelativePath("probe-m22-gap-" + run.uuidString)!
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        let local = support.appending(path: "M22Gap/" + run.uuidString + "/" + phase.rawValue)
        let settingsURL = support.appending(path: "Settings.json")
        let original = try Data(contentsOf: settingsURL)
        // Decode directly: loading through SettingsStore could migrate the user's file.
        let current = try JSONDecoder().decode(AppSettings.self, from: original)
        guard let record = current.locations.first(where: { $0.id == location }),
              !record.removing, record.smbOnlyEditing == true, let write = record.activeWriteBookmark,
              let grant = current.shares.first(where: { $0.id == record.serverID }),
              let address = ShareAddress(grant.mountFrom), address.host == Self.host,
              address.share == Self.share, address.account == Self.account,
              grant.host == Self.host, grant.share == Self.share, grant.account == Self.account,
              let server = current.servers.first(where: { $0.id == grant.serverID }) else {
            throw GapCheck(label: "explicit-fixture-write-grant-required")
        }
        var stale = false
        let scoped = try URL(resolvingBookmarkData: write, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        try require(!stale && ShareAccess.filePath(scoped) == Self.mount, "write-bookmark-is-share-root")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A second launch of a phase stops here, leaving the first launch's evidence untouched.
        try require(mkdir(local.path, 0o700) == 0, "new-phase-directory-required")
        let privateSettings = local.appending(path: "Settings.json")
        let keeps = Self.seededKeeps.map { KeepPath(path: probeRoot.string + "/" + $0, kind: .file) }
        try AppSettings(servers: [server], shares: [grant], locations: [],
                        savedKeeps: [SavedKeepList(host: grant.host, share: grant.share, paths: keeps)])
            .save(to: privateSettings)
        try GapFiles.createExclusive(local.appending(path: "started.txt"),
                                     Data((ISO8601DateFormatter().string(from: .now) + "\n").utf8))
        self.phase = phase
        runID = run
        root = probeRoot
        directory = local
        originalSettingsURL = settingsURL
        originalSettings = original
        bookmark = write
        store = SettingsStore(url: privateSettings)
        access = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
        probeAccess = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
    }

    func run() throws -> Bool {
        startWatchdog()
        var failure: Error?
        do {
            try validateFixture()
            try openSources()
            switch phase {
            case .spelling:
                try spellingCase("case", folder: "spelling", file: "child.txt", to: "CHILD.txt")
                try spellingCase("nfd", folder: "nfd", file: Self.nfc, to: Self.nfd)
            case .ancestors:
                try sourceAncestorCase()
                try destinationCase()
            case .retry:
                try rootCase()
                try recoverCase()
            }
            ledger.enter("original-settings")
            try require(Data(contentsOf: originalSettingsURL) == originalSettings, "user-settings-unchanged")
            ledger.enter(nil)
        } catch {
            failure = error
        }
        let passed = failure == nil && phase.cases.allSatisfy { ledger.outcome($0) == "passed" }
        try writeReport(failure, passed: passed)
        if let failure { throw failure }
        for source in [owner, overlap].compactMap({ $0 }) {
            source.close()
            access.editNamespace.unregister(source.domainID)
        }
        return passed
    }

    // MARK: Cases

    /// An outside respelling after durable move proof retires only that exact binding.
    private func spellingCase(_ label: String, folder: String, file: String, to name: String) throws {
        ledger.enter(label + "-setup")
        let tree = folder + "/src/Tree", moved = folder + "/Moved"
        for path in [folder, folder + "/src", tree] { try list(owner, path) }
        guard let listed = try owner.liveChild(of: catalogRow(owner, tree).id, named: file) else {
            throw GapCheck(label: label + "-child-listed")
        }
        ledger.record(label, ["nativeAdmittedForm": Self.form(listed.name)])
        // Admission compares catalog and SMB spellings exactly; a native client rewrite ends the case.
        guard listed.name.utf8.elementsEqual(file.utf8) else {
            ledger.record(label, ["outcome": "unavailable", "reason": "native-listing-rewrote-spelling",
                                  "moved": false, "changed": false])
            return
        }
        _ = try owner.keep([listed.id], value: true)
        try establishBase(owner, tree + "/" + file, label: label + "-base")
        let child = try catalogRow(owner, tree + "/" + file)
        try require(child.id == listed.id && child.keep && child.keepRequested, label + "-independent-keep")
        let saved = try snapshot(owner, [tree, tree + "/other.txt"])
        let request = try moveRequest(owner, tree, to: folder)

        ledger.enter(label + "-move")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .respell(file, name), inject: false))
        _ = try move(label, request, connections: 3).get()
        let spelling = plan.spelling(label)
        let record = try durable(request)
        try require(record.state == .completed && record.finishedDomains == [owner.domainID], label + "-completed")
        try requirePreserved(owner, saved, from: tree, to: moved, label: label)
        let retired = try item(owner, child.id)?.deleted == true

        ledger.enter(label + "-discovery")
        try list(owner, moved)
        let found = try owner.liveChild(of: catalogRow(owner, moved).id, named: name)
        ledger.record(label, ["spelling": spelling, "retired": retired, "replanned": record.recovery != nil,
                              "moved": true, "changed": !["refused", "not-reached"].contains(spelling)])
        if spelling == "exact-target" {
            try require(record.recovery != nil && retired, label + "-exact-binding-retired")
            try requireIndependent(found, replacing: child, label: label)
            ledger.record(label, ["outcome": "passed", "discoveredForm": Self.form(found!.name)])
        } else {
            ledger.record(label, ["outcome": "unavailable", "reason": "server-spelling-" + spelling])
        }
        try replayUnchanged(label, request, record)
        try requireSavedKeep(label, try full(moved + "/" + file))
    }

    /// Changes confined to the old source chain no longer block completion after durable move proof.
    private func sourceAncestorCase() throws {
        let label = "ancestor", folder = "ancestor", tree = "ancestor/src/Old/Tree", moved = folder + "/Moved"
        ledger.enter(label + "-setup")
        for path in [folder, folder + "/src", folder + "/src/Old", tree] { try list(owner, path) }
        let saved = try snapshot(owner, [tree, tree + "/a.txt"])
        let request = try moveRequest(owner, tree, to: folder)

        ledger.enter(label + "-move")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .sourceAncestors, inject: false))
        _ = try move(label, request, connections: 3).get()
        let record = try durable(request)
        try require(record.state == .completed && record.recovery == nil
            && record.finishedDomains == [owner.domainID], label + "-completed-without-recovery")
        try requirePreserved(owner, saved, from: tree, to: moved, label: label)
        try replayUnchanged(label, request, record)
        ledger.record(label, ["outcome": "passed", "moved": true, "changed": true])
    }

    /// A replaced destination ancestor leaves the intent verified and pending until it is restored.
    private func destinationCase() throws {
        let label = "destination", folder = "destination", tree = "destination/src/Tree"
        let moved = folder + "/dst/Moved"
        ledger.enter(label + "-setup")
        for path in [folder, folder + "/src", tree, folder + "/dst"] { try list(owner, path) }
        let saved = try snapshot(owner, [tree, tree + "/a.txt"])
        let request = try moveRequest(owner, tree, to: folder + "/dst")

        ledger.enter(label + "-move")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .destinationReplacement, inject: false))
        let first = try move(label, request, connections: 3)
        _ = try requirePending(label, first, request, finished: [], roots: [(owner, request.item, moved)])

        ledger.enter(label + "-restore")
        let parent = try full(folder)
        try probeSession(label + ".restore", inSettings: false) { remote in
            _ = try renameFolder(remote, parent + "/dst", parent + "/Spare")
            _ = try renameFolder(remote, parent + "/dstAway", parent + "/dst")
        }

        ledger.enter(label + "-verified-retry")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .none, inject: false))
        _ = try move(label + ".retry", request, connections: 3).get()
        let record = try durable(request)
        try require(record.state == .completed && record.recovery == nil
            && record.finishedDomains == [owner.domainID], label + "-retry-completed")
        try requirePreserved(owner, saved, from: tree, to: moved, label: label)
        try replayUnchanged(label, request, record)
        ledger.record(label, ["outcome": "passed", "moved": true, "changed": true])
    }

    /// Proved root departure retires both views; reappearance must never revive their old bindings.
    private func rootCase() throws {
        let label = "root", folder = "root", tree = "root/src/Tree", moved = folder + "/Moved"
        guard let overlap else { throw GapCheck(label: "overlap-source") }
        ledger.enter(label + "-setup")
        for path in [folder, folder + "/src", tree, tree + "/Nested"] { try list(owner, path) }
        for path in ["src", "src/Tree", "src/Tree/Nested"] { try list(overlap, path) }
        _ = try owner.keep([catalogRow(owner, tree + "/a.txt").id], value: true)
        _ = try overlap.keep([catalogRow(overlap, "src/Tree/a.txt").id], value: true)
        let ownerSaved = try snapshot(owner, [tree, tree + "/a.txt", tree + "/Nested", tree + "/Nested/b.txt"])
        let overlapSaved = try snapshot(overlap, ["src/Tree", "src/Tree/a.txt", "src/Tree/Nested",
                                                  "src/Tree/Nested/b.txt"])
        let request = try moveRequest(owner, tree, to: folder)

        ledger.enter(label + "-move")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .root(finishFirst: owner.domainID),
                          inject: false))
        let first = try move(label, request, connections: 5)
        try require(GapErrors.failure(first) as? SourceFailure == .versionChanged, label + "-changed-version")
        let record = try durable(request)
        try require(record.state == .completed && record.rootRetired && record.views.count == 2
            && Set(record.finishedDomains) == Set([owner.domainID, overlap.domainID]), label + "-retired-both-views")
        try owner.editNamespace.perform { try owner.editNamespace.requireSettled() }
        for (source, saved) in [(owner!, ownerSaved), (overlap, overlapSaved)] {
            for row in saved { try require(try item(source, row.id)?.deleted == true, label + "-old-id-retired") }
        }
        let keeps = try onMain { store.settings?.savedKeeps.flatMap(\.paths) ?? [] }
        for keep in keeps {
            guard let path = RelativePath(keep.path) else { throw GapCheck(label: "saved-keep-path") }
            try require(!EditNamespace.contains(RelativePath(record.source)!, path)
                && !EditNamespace.contains(RelativePath(record.destination)!, path), label + "-retired-keeps-cleared")
        }

        ledger.enter(label + "-restore")
        let parent = try full(folder)
        try probeSession(label + ".restore", inSettings: false) { remote in
            _ = try renameFolder(remote, parent + "/MovedAway", parent + "/Moved")
        }

        for (source, saved, before, after) in [(owner!, ownerSaved, tree, moved),
                                              (overlap, overlapSaved, "src/Tree", "Moved")] {
            for path in [source === owner ? folder : "", after, after + "/Nested"] { try list(source, path) }
            for row in saved {
                let path = after + row.path.dropFirst(before.count)
                let discovered = try catalogRow(source, path)
                try require(discovered.id != row.id && !discovered.deleted
                    && !discovered.keep && !discovered.keepRequested
                    && !discovered.contentVersion.hasPrefix("e1:"), label + "-independent-discovery")
            }
        }
        try replayUnchanged(label, request, record)
        ledger.record(label, ["outcome": "passed", "moved": true, "changed": true,
                              "rootRetired": true, "namespaceUnblocked": true, "rediscoveredWithNewIDs": true])
    }

    /// Retry from a durable recovery plan whose catalog work never started.
    private func recoverCase() throws {
        let label = "recover", folder = "recover", tree = "recover/src/Tree", moved = folder + "/Moved"
        ledger.enter(label + "-setup")
        for path in [folder, folder + "/src", tree] { try list(owner, path) }
        let child = try catalogRow(owner, tree + "/child.txt")
        let saved = try snapshot(owner, [tree, tree + "/other.txt"])
        let request = try moveRequest(owner, tree, to: folder)

        ledger.enter(label + "-move")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .respell("child.txt", "CHILD.txt"),
                          inject: true))
        let first = try move(label, request, connections: 3)
        guard let injected = GapErrors.failure(first), injected as? GapInjected == .afterSettingsSave else {
            throw GapCheck(label: label + "-injected-settings-error")
        }
        let spelling = plan.spelling(label)
        let verified = try durable(request)
        try require(verified.state == .verified && verified.recovery == nil && verified.finishedDomains.isEmpty,
                    label + "-verified-checkpoint")
        try require(try item(owner, child.id)?.deleted == false, label + "-settled-catalog")

        // Stands in for an attempt interrupted after its durable replan, before any catalog changed.
        ledger.enter(label + "-direct-replan")
        let replanned = try probeSession(label + ".replan", inSettings: false) { remote -> PendingFolderMove in
            var record = verified
            var expected: [String: CatalogFolderMoveState] = [:]
            for view in record.views {
                try require(view.domain == owner.domainID, label + "-single-view")
                expected[view.domain] = try owner.withCatalog {
                    try $0.classifyFolderMove(view.move, proofs: view.proofs,
                                              allowed: verified.allowedCatalogStates(domain: view.domain))
                }
            }
            try FolderMoveTransaction.replan(&record, outbox: LocationSource.renameOutbox(), expected: expected,
                                             remote: remote)
            return record
        }
        try require(replanned.state == .recovering && replanned.finishedDomains.isEmpty
            && (try durable(request)) == replanned, label + "-durable-recovery-plan")
        let planned = try replanned.latestTarget(domain: owner.domainID).entries.first { $0.item == child.id }
        let exact = spelling == "exact-target"
        try require(planned?.retired == exact, label + "-plan-retirement")
        try require(try item(owner, child.id)?.deleted == false, label + "-catalog-awaits-plan")

        ledger.enter(label + "-recovering-retry")
        plan.plan(GapStep(label: label, destination: try full(moved), change: .none, inject: false))
        _ = try move(label + ".retry", request, connections: 3).get()
        let record = try durable(request)
        try require(record.state == .completed && record.recovery == replanned.recovery
            && record.finishedDomains == [owner.domainID], label + "-completed-from-plan")
        try requirePreserved(owner, saved, from: tree, to: moved, label: label)
        try require(try item(owner, child.id)?.deleted == exact, label + "-plan-applied")
        ledger.record(label, ["spelling": spelling, "moved": true,
                              "changed": !["refused", "not-reached"].contains(spelling)])
        if exact {
            try list(owner, moved)
            guard let found = try owner.liveChild(of: catalogRow(owner, moved).id, named: "CHILD.txt") else {
                throw GapCheck(label: label + "-respelled-child-discovered")
            }
            try require(found.id != child.id, label + "-new-discovery-id")
            ledger.record(label, ["outcome": "passed"])
        } else {
            ledger.record(label, ["outcome": "unavailable", "reason": "server-spelling-" + spelling])
        }
        try replayUnchanged(label, request, record)
    }

    // MARK: Settings callback

    /// Runs on the main actor while the mover waits without its namespace lock or SMB client.
    @MainActor
    private func commitSettings(_ intent: RenameIntent) throws {
        let began = Date()
        let step = plan.take()
        var entry: [String: Any] = ["case": step?.label ?? "unplanned"]
        defer {
            entry["seconds"] = Self.seconds(since: began)
            ledger.settingsCall(entry)
        }
        guard let step, case .folder(let record) = intent,
              case .folder(let durable)? = try LocationSource.renameOutbox().intents().first(where: { $0.id == record.id }),
              [.verified, .recovering].contains(durable.state),
              durable.destination.utf8.elementsEqual(step.destination.utf8),
              let source = RelativePath(durable.source), EditNamespace.contains(root, source) else {
            throw GapCheck(label: "settings-intent-boundary")
        }
        entry["state"] = durable.state.rawValue
        entry["finishedBefore"] = durable.finishedDomains.count
        try store.update {
            if durable.rootRetired {
                try $0.removeKeptFolder(at: durable.source, host: Self.host, share: Self.share)
                try $0.removeKeptFolder(at: durable.destination, host: Self.host, share: Self.share)
            } else {
                try $0.moveKeptFolder(from: durable.source, to: durable.destination, host: Self.host, share: Self.share)
            }
        }
        try probeSession("settings." + step.label, inSettings: true) { remote in
            if case .destinationReplacement = step.change {
                // This session's own parent handles would deny the rename; the retry's callback checks equality.
                entry["lockCheck"] = "skipped-session-replaces-destination-ancestor"
            } else {
                try lockCheck(remote, durable)
                entry["lockCheck"] = "passed"
            }
            entry.merge(try change(step, remote: remote, durable: durable)) { $1 }
        }
        if step.inject {
            entry["injected"] = "error-after-settings-save"
            throw GapInjected.afterSettingsSave
        }
    }

    private func lockCheck(_ remote: SMBEdit, _ durable: PendingFolderMove) throws {
        let parents = try remote.protectFolderMoveParents(source: durable.destination, destination: durable.destination)
        try require(parents == durable.destinationParents, "settings-lock-check-parents")
        if durable.rootRetired { return }
        guard let moved = try remote.inspectFolderMoveRoot(path: durable.destination), moved.identity == durable.identity,
              moved.name.utf8.elementsEqual(durable.name.utf8) else { throw GapCheck(label: "settings-lock-check-root") }
    }

    private func change(_ step: GapStep, remote: SMBEdit, durable: PendingFolderMove) throws -> [String: Any] {
        let destination = RelativePath(durable.destination)!
        let parent = destination.components.dropLast().joined(separator: "/")
        switch step.change {
        case .none:
            return [:]
        case .respell(let from, let to):
            let spelling = try respell(remote, folder: durable.destination, from: from, to: to, label: step.label)
            plan.setSpelling(step.label, spelling)
            return ["spelling": spelling]
        case .sourceAncestors:
            let renamed = try renameFolder(remote, parent + "/src/Old", parent + "/src/OldGone")
            let replacement = try renameFolder(remote, parent + "/Spare", parent + "/src/Old")
            return ["sourceParentRenamed": renamed.fileID, "sourceParentReplacement": replacement.fileID]
        case .destinationReplacement:
            let ancestor = destination.components.dropLast(2).joined(separator: "/")
            let renamed = try renameFolder(remote, parent, ancestor + "/dstAway")
            let replacement = try renameFolder(remote, ancestor + "/Spare", parent)
            return ["destinationParentRenamed": renamed.fileID, "destinationParentReplacement": replacement.fileID]
        case .root(let domain):
            try finishFirst(domain, durable)
            let renamed = try renameFolder(remote, durable.destination, parent + "/MovedAway")
            try require(renamed == durable.identity, "root-change-identity")
            plan.plan(GapStep(label: step.label, destination: durable.destination, change: .none, inject: false))
            return ["finishedFirst": "owner", "rootRenamed": true]
        }
    }

    /// No-replace SMB rename of one file; the protected listing afterwards gives the server's exact spelling.
    private func respell(_ remote: SMBEdit, folder: String, from: String, to: String, label: String) throws -> String {
        // The lock check's root handle denies sharing; respelling needs that folder as a plain parent.
        try remote.releaseFolderMoveRoot(path: folder)
        let old = folder + "/" + from, new = folder + "/" + to
        _ = try remote.protectRenameParents(source: old, destination: new)
        guard let before = try remote.inspectRename(path: old), before.name.utf8.elementsEqual(from.utf8) else {
            throw GapCheck(label: label + "-respell-admitted-name")
        }
        do {
            try remote.move(source: old, destination: new)
        } catch {
            ledger.record(label, ["respellRefusal": GapErrors.fields(error)])
            return "refused"
        }
        guard let after = try remote.inspectRename(path: new), after.version.identity == before.version.identity,
              after.version.hasSameContents(as: before.version) else {
            throw GapCheck(label: label + "-respell-same-file")
        }
        try remote.releaseRename(path: new)
        if after.name.utf8.elementsEqual(to.utf8) { return "exact-target" }
        return after.name.utf8.elementsEqual(from.utf8) ? "admitted" : "other"
    }

    /// The production no-replace folder rename on a fixture folder, proved by identity before and after.
    private func renameFolder(_ remote: SMBEdit, _ from: String, _ to: String) throws -> EditFileIdentity {
        _ = try remote.protectFolderMoveParents(source: from, destination: to)
        let fromName = RelativePath(from)!.components.last!, toName = RelativePath(to)!.components.last!
        guard let before = try remote.inspectFolderMoveRoot(path: from),
              before.name.utf8.elementsEqual(fromName.utf8) else {
            throw GapCheck(label: "fixture-folder-source")
        }
        guard try remote.inspectFolderMoveRoot(path: to) == nil else { throw GapCheck(label: "fixture-folder-occupied") }
        try remote.moveFolder(source: from, destination: to)
        guard let after = try remote.inspectFolderMoveRoot(path: to), after.identity == before.identity,
              after.name.utf8.elementsEqual(toName.utf8), try remote.inspectFolderMoveRoot(path: from) == nil else {
            throw GapCheck(label: "fixture-folder-moved")
        }
        return before.identity
    }

    /// The durable state left by an interruption after one view finished, under the same protection.
    private func finishFirst(_ domain: String, _ durable: PendingFolderMove) throws {
        guard domain == owner.domainID, let view = durable.views.first(where: { $0.domain == domain }) else {
            throw GapCheck(label: "partial-finish-view")
        }
        let state = try owner.withCatalog {
            try $0.classifyFolderMove(view.move, proofs: view.proofs, allowed: durable.allowedCatalogStates(domain: domain))
        }
        try require(state == (try durable.latestTarget(domain: domain)), "partial-finish-catalog-target")
        var current = durable
        try FolderMoveTransaction.finishDomain(domain, record: &current, outbox: LocationSource.renameOutbox())
        try require(current.state == durable.state && current.finishedDomains == [domain], "partial-finish-durable")
    }

    // MARK: Operations

    /// Repeats only a failed connection that never reached Settings, so its planned change is unconsumed.
    private func move(_ label: String, _ request: FileRenameRequest,
                      connections: Int) throws -> Result<CreateReceipt, Error> {
        var attempt = 1
        while true {
            try awaitRecovery(access, label, seconds: 30)
            // A verified retry reaches Settings without a connection, so the probe's health must be clear.
            try awaitRecovery(probeAccess, label, seconds: 30)
            let planned = plan.isPending
            let reply = GapReply<CreateReceipt>(), began = Date()
            owner.moveFolder(request, progress: Progress(), started: {}) { reply.finish($0) }
            let result = try reply.wait(label, seconds: timeout(connections: connections))
            ledger.operation(label, attempt: attempt, began: began, connections: connections,
                             error: GapErrors.failure(result))
            if let error = GapErrors.failure(result), attempt < 3, GapErrors.isConnectFailure(error),
               planned, plan.isPending {
                Thread.sleep(forTimeInterval: 2)
                attempt += 1
                continue
            }
            try require(!plan.isPending, label + "-settings-not-reached")
            return result
        }
    }

    private func requirePending(_ label: String, _ result: Result<CreateReceipt, Error>, _ request: FileRenameRequest,
                                finished: [String], roots: [(LocationSource, String, String)]) throws -> PendingFolderMove {
        guard let error = GapErrors.failure(result) else { throw GapCheck(label: label + "-completed-despite-change") }
        ledger.record(label, ["pendingError": GapErrors.name(error)])
        try require(error as? UploadError == .unresolved, label + "-pending-error")
        let record = try durable(request)
        try require(record.state == .verified && record.recovery == nil && record.finishedDomains == finished,
                    label + "-stays-pending")
        for (source, id, path) in roots {
            guard let row = try item(source, id), !row.deleted else { throw GapCheck(label: label + "-root-binding-kept") }
            let current = try source.withCatalog { try $0.relativePath(of: id)?.string }
            try require(current?.utf8.elementsEqual(path.utf8) == true, label + "-root-catalog-path")
        }
        do {
            try owner.editNamespace.perform { try owner.editNamespace.requireSettled() }
            throw GapCheck(label: label + "-namespace-unblocked")
        } catch UploadError.pendingWrites {}
        return record
    }

    private func replayUnchanged(_ label: String, _ request: FileRenameRequest, _ completed: PendingFolderMove) throws {
        ledger.enter(label + "-replay")
        let calls = (ledger.snapshot()["settingsCalls"] as? [[String: Any]])?.count
        let result = try move(label + ".replay", request, connections: 0)
        if completed.rootRetired {
            try require(GapErrors.failure(result) as? SourceFailure == .versionChanged, label + "-replay-changed-version")
        } else { try require(try result.get().item == request.item, label + "-replay") }
        try require((ledger.snapshot()["settingsCalls"] as? [[String: Any]])?.count == calls, label + "-replay-no-settings")
        try require(try durable(request) == completed, label + "-replay-unchanged")
    }

    private func requireIndependent(_ found: CatalogRow?, replacing old: CatalogRow, label: String) throws {
        guard let found else { throw GapCheck(label: label + "-respelled-child-discovered") }
        try require(found.id != old.id && !found.deleted, label + "-new-discovery-id")
        try require(!found.keep && !found.keepRequested, label + "-keep-not-transferred")
        let edits = try LocationSource.editOutbox(domainID: owner.domainID)
        try require(found.contentVersion != old.contentVersion && !found.contentVersion.hasPrefix("e1:"),
                    label + "-version-not-transferred")
        try require(try edits.base(item: found.id, contentVersion: found.contentVersion) == nil,
                    label + "-discovered-item-has-no-base")
        try require(try edits.base(item: old.id, contentVersion: old.contentVersion)?.item == old.id,
                    label + "-historical-base-keeps-old-binding")
        do {
            _ = try edits.base(item: found.id, contentVersion: old.contentVersion)
            throw GapCheck(label: label + "-historical-base-accepted-for-new-id")
        } catch UploadError.unresolved {}
    }

    private func requireSavedKeep(_ label: String, _ expected: String) throws {
        let paths = try onMain { () throws -> [String] in
            guard let settings = store.settings else { throw GapCheck(label: "private-settings") }
            return settings.savedKeeps.flatMap(\.paths).map(\.path)
        }
        try require(paths.contains { $0.utf8.elementsEqual(expected.utf8) }, label + "-saved-keep-admitted-spelling")
        ledger.record(label, ["savedKeep": "admitted-spelling-under-destination"])
    }

    private func establishBase(_ source: LocationSource, _ path: String, label: String) throws {
        ledger.enter(label)
        let plain = try catalogRow(source, path)
        try require(plain.kind == .file && plain.allowsEditing && !plain.contentVersion.hasPrefix("e1:"), label + "-plain")
        let staging = directory.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let request = try SourceReadRequest(id: UUID(), item: plain.id, version: plain.contentVersion,
            range: ByteRange(offset: 0, length: plain.size, fileSize: plain.size), background: false,
            establishEditBase: true)
        var attempt = 1
        while true {
            try awaitRecovery(access, label, seconds: 30)
            let began = Date()
            do {
                _ = try source.transfer(request, progress: Progress(), stagingDirectory: staging)
                ledger.operation(label, attempt: attempt, began: began, connections: 1, error: nil)
                break
            } catch {
                ledger.operation(label, attempt: attempt, began: began, connections: 1, error: error)
                guard attempt < 3, GapErrors.isConnectFailure(error) else { throw error }
            }
            Thread.sleep(forTimeInterval: 2)
            attempt += 1
        }
        let based = try catalogRow(source, path)
        try require(based.id == plain.id && based.contentVersion.hasPrefix("e1:"), label + "-e1")
        try require(try LocationSource.editOutbox(domainID: source.domainID)
            .base(item: based.id, contentVersion: based.contentVersion) != nil, label + "-receipt")
    }

    /// Namespace first, then one fresh protected client that disconnects before the namespace is released.
    private func probeSession<T>(_ label: String, inSettings: Bool, _ body: (SMBEdit) throws -> T) throws -> T {
        // The mover waits 60 s for Settings, so a callback gets one connection attempt and a short wait.
        try awaitRecovery(probeAccess, label, seconds: inSettings ? 20 : 30)
        return try probeAccess.editNamespace.perform {
            try probeAccess.withSession { session, _ in
                guard ShareAddress(session.identity.mountFrom) == endpoint else {
                    throw GapCheck(label: "probe-session-endpoint")
                }
                let remote = try connect(label, shareRoot: session.root, attempts: inSettings ? 1 : 3)
                return try withExtendedLifetime(remote) { try body(remote) }
            }
        }
    }

    private func connect(_ label: String, shareRoot: Int32, attempts: Int) throws -> SMBEdit {
        var attempt = 1
        while true {
            let began = Date()
            do {
                let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: shareRoot, progress: Progress())
                ledger.connection(label, attempt: attempt, began: began, error: nil)
                return remote
            } catch {
                ledger.connection(label, attempt: attempt, began: began, error: error)
                guard attempt < attempts, GapErrors.isConnectFailure(error) else { throw error }
            }
            Thread.sleep(forTimeInterval: 2)
            attempt += 1
        }
    }

    // A slow connection can leave normal share-health recovery pending; this waits and never resets it.
    private func awaitRecovery(_ target: ShareAccess, _ label: String, seconds: Int) throws {
        let began = ContinuousClock.now
        let deadline = began + .seconds(seconds)
        var waited = false
        while let refusal = target.refusal() {
            guard refusal == .serverUnreachable else { throw refusal }
            try require(ContinuousClock.now < deadline && Date().timeIntervalSince(started) < Self.budget,
                        "share-recovery-timeout")
            waited = true
            Thread.sleep(forTimeInterval: 0.25)
        }
        if waited { ledger.healthWait(label, seconds: began.duration(to: .now) / .seconds(1)) }
    }

    // MARK: Fixture, catalogs and evidence

    private func validateFixture() throws {
        ledger.enter("fixture")
        try require(access.mountPath() == Self.mount, "existing-loopback-mount-required")
        let markerBytes = Data(("tinymounter-m22-gap:" + runID.uuidString + "\n").utf8)
        endpoint = try access.withSession { session, _ -> ShareAddress in
            try require(session.identity.typeName == "smbfs", "native-smb-session")
            guard let address = ShareAddress(session.identity.mountFrom), address.host == Self.host,
                  address.share == Self.share, address.account == Self.account else {
                throw GapCheck(label: "mount-identity")
            }
            let fd = try session.openFolder(root)
            defer { Darwin.close(fd) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            try require(fcntl(fd, F_GETPATH, &buffer) == 0, "probe-root-path")
            let native = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            try require(native == Self.mount + "/" + root.string, "probe-root-path")
            let marker = try ReadOnlyFile(directoryFD: fd, relativePath: RelativePath("marker.txt")!,
                                          expected: session.identity)
            var bytes = Data(count: markerBytes.count)
            let count = bytes.withUnsafeMutableBytes { pread(marker.descriptor, $0.baseAddress, $0.count, 0) }
            try require(marker.snapshot.size == Int64(markerBytes.count) && count == markerBytes.count
                && bytes == markerBytes, "fixture-marker")
            return address
        }
    }

    private func openSources() throws {
        ledger.enter("sources")
        owner = try makeSource(UUID().uuidString, folder: root)
        try list(owner, "")
        var domains = [owner.domainID]
        if phase == .retry {
            let source = try makeSource(UUID().uuidString, folder: root.appending("root")!)
            overlap = source
            try list(source, "")
            domains.append(source.domainID)
        }
        // Parent teardown finds these domains' receipts and completed intents by ID.
        ledger.record("sources", ["domains": domains])
    }

    private func makeSource(_ domain: String, folder: RelativePath) throws -> LocationSource {
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        for storage in ["Uploads/", "Edits/"] {
            try require(!FileManager.default.fileExists(atPath: support.appending(path: storage + domain).path),
                        "fresh-domain-storage")
        }
        let catalog = try Catalog.create(at: directory.appending(path: domain + ".sqlite"), domainID: domain,
                                         rootName: "M22 gap probe")
        let source = LocationSource(domainID: domain, folder: folder, catalog: catalog, access: access,
                                    renameSettings: { [weak self] intent in
            guard let self else { throw GapCheck(label: "settings-probe-ended") }
            try await self.commitSettings(intent)
        }, signal: { _ in })
        try source.configureWriteMode(bookmark, confirmed: true)
        return source
    }

    private func list(_ source: LocationSource, _ path: String) throws {
        let id = try path.isEmpty ? Catalog.rootItemID : catalogRow(source, path).id
        try awaitRecovery(access, "list", seconds: 30)
        let reply = GapReply<ListReceipt>()
        source.list(id, requestID: UUID(), bounded: false) { reply.finish($0) }
        let receipt = try reply.wait("list", seconds: timeout(connections: 0)).get()
        try require(receipt.skipped == 0, "listing-has-skipped-entries")
    }

    private func catalogRow(_ source: LocationSource, _ path: String) throws -> CatalogRow {
        try source.withCatalog { catalog in
            var id = Catalog.rootItemID
            for name in RelativePath(path)!.components {
                guard let child = try catalog.liveChild(parent: id, nameKey: NameKey(name)),
                      child.name.utf8.elementsEqual(name.utf8) else { throw GapCheck(label: "catalog-path") }
                id = child.id
            }
            guard let found = try catalog.item(id: id) else { throw GapCheck(label: "catalog-row") }
            return found
        }
    }

    private func item(_ source: LocationSource, _ id: String) throws -> CatalogRow? {
        try source.withCatalog { try $0.item(id: id) }
    }

    private func snapshot(_ source: LocationSource, _ paths: [String]) throws -> [GapRow] {
        try paths.map { path in
            let row = try catalogRow(source, path)
            return GapRow(id: row.id, path: path, contentVersion: row.contentVersion, keep: row.keep,
                          keepRequested: row.keepRequested)
        }
    }

    /// Moved descendants keep their IDs, content versions and keeps under the new path.
    private func requirePreserved(_ source: LocationSource, _ saved: [GapRow], from: String, to: String,
                                  label: String) throws {
        for row in saved {
            guard let current = try item(source, row.id), !current.deleted else {
                throw GapCheck(label: label + "-preserved-id")
            }
            try require(current.contentVersion == row.contentVersion && current.keep == row.keep
                && current.keepRequested == row.keepRequested, label + "-preserved-version-and-keep")
            try require(row.path.hasPrefix(from), label + "-snapshot-path")
            let expected = to + row.path.dropFirst(from.count)
            let path = try source.withCatalog { try $0.relativePath(of: row.id)?.string }
            try require(path?.utf8.elementsEqual(expected.utf8) == true, label + "-preserved-path")
        }
    }

    private func moveRequest(_ source: LocationSource, _ path: String, to parent: String) throws -> FileRenameRequest {
        let selected = try catalogRow(source, path), target = try catalogRow(source, parent)
        return try FileRenameRequest(item: selected.id, parent: target.id, name: "Moved",
                                     contentVersion: selected.contentVersion, metadataVersion: selected.metadataVersion)
    }

    private func durable(_ request: FileRenameRequest) throws -> PendingFolderMove {
        guard let record = try LocationSource.renameOutbox().replayFolder(owner: owner.domainID, request: request) else {
            throw GapCheck(label: "durable-intent")
        }
        return record
    }

    private func full(_ path: String) throws -> String {
        guard let relative = RelativePath(path), let result = root.appending(relative) else {
            throw GapCheck(label: "fixture-path")
        }
        return result.string
    }

    /// SettingsStore is main-actor state; the main actor only awaits the probe task meanwhile.
    private func onMain<T: Sendable>(_ body: @MainActor () throws -> T) throws -> T {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }

    private func timeout(connections: Int) throws -> Int {
        let remaining = Int(Self.budget - 10 - Date().timeIntervalSince(started))
        try require(remaining > 30, "phase-time-budget")
        return min(60 + 40 * connections, remaining)
    }

    private func startWatchdog() {
        let remaining = max(0, Self.budget - Date().timeIntervalSince(started))
        DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { [self] in
            // Exclusive creation keeps a report the probe thread may already have written.
            try? writeReport(GapCheck(label: "process-budget"), passed: false)
            print("M22 gap phase failed: process-budget")
            exit(1)
        }
    }

    private func writeReport(_ failure: Error?, passed: Bool) throws {
        var report = ledger.snapshot()
        report["run"] = runID.uuidString
        report["phase"] = phase.rawValue
        report["date"] = ISO8601DateFormatter().string(from: .now)
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["cache"] = "uncontrolled"
        report["entry"] = "LocationSource.moveFolder and its retryFolderMove replay; a private main-actor Settings "
            + "callback makes protected no-replace SMB fixture changes"
        report["seconds"] = Self.seconds(since: started)
        report["passed"] = passed
        report["requiresSuccessfulProcessExit"] = true
        report["untested"] = Self.untested
        if let failure {
            report["failedStep"] = ledger.step ?? "setup"
            report.merge(GapErrors.fields(failure)) { $1 }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try GapFiles.createExclusive(directory.appending(path: phase.rawValue + "-report.json"), data)
    }

    static func seconds(since date: Date) -> Double { (Date().timeIntervalSince(date) * 10).rounded() / 10 }

    private static func form(_ name: String) -> String {
        let bytes = Array(name.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) { return "ascii" }
        if bytes == Array(name.precomposedStringWithCanonicalMapping.utf8) { return "nfc" }
        return bytes == Array(name.decomposedStringWithCanonicalMapping.utf8) ? "nfd" : "mixed"
    }
}
