import Darwin
import Foundation

// Replace TinyMounterApp.swift only in an isolated signed archive; the runbook is in the .py file.
@main
enum M24RuntimeHelper {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--m24-recursive", let phase = M24Phase(rawValue: args[2]),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  let location = UUID(uuidString: args[4]), location.uuidString == args[4] else {
                throw M24Check(label: "arguments")
            }
            let probe = try M24Probe(phase: phase, run: run, location: location)
            try await Task.detached { try probe.run() }.value
            print("M24 runtime phase passed: " + phase.rawValue + "; untested gates are listed in its report")
            exit(0)
        } catch {
            // Errors can carry private paths, so only a probe label reaches stdout.
            print("M24 runtime phase failed: " + ((error as? M24Check)?.label ?? "see-private-report"))
            exit(1)
        }
    }
}

/// One deletion case per process, so no run needs more than nine fresh SMB connections.
private enum M24Phase: String, CaseIterable {
    case refuse, delete, interrupt, recover, admit, compete, remote, replace

    var previous: M24Phase? {
        let all = Self.allCases, index = all.firstIndex(of: self)!
        return index == 0 ? nil : all[index - 1]
    }
}

private struct M24Check: Error {
    let label: String
}

private enum M24Injected: Error {
    case lostCloseReply
}

private func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw M24Check(label: label) }
}

private enum M24Errors {
    static func failure<Value>(_ result: Result<Value, Error>) -> Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    /// SMBEdit's connect failure; any other error may follow a request and is never retried here.
    static func isConnectFailure(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSPOSIXErrorDomain && failure.localizedDescription.hasPrefix("connect protected save")
    }

    /// The traversal refuses a changed claim as versionChanged, or as unresolved when native and SMB metadata disagree.
    static func isChangeRefusal(_ error: Error) -> Bool {
        error as? SourceFailure == .versionChanged || error as? UploadError == .unresolved
    }

    static func name(_ error: Error) -> String {
        if error is ItemDeletionError || error is SourceFailure || error is UploadError || error is TransferError
            || error is M24Injected { return String(describing: error) }
        if let check = error as? M24Check { return "probe:" + check.label }
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

private final class M24Reply<Value>: @unchecked Sendable {
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
            throw M24Check(label: "timeout:" + label)
        }
        return lock.withLock { result! }
    }
}

private final class M24Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class M24Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}

/// Names each step, connection and operation, so a report says where a phase stopped without paths.
private final class M24Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?
    private var completed: [String] = []
    private var operations: [[String: Any]] = []
    private var connections: [[String: Any]] = []
    private var cases: [String: [String: Any]] = [:]
    private var identities: [String: UInt64] = [:]

    var step: String? { lock.withLock { current } }

    func enter(_ next: String?) {
        lock.withLock {
            if let previous = current { completed.append(previous) }
            current = next
        }
    }

    func connection(_ label: String, attempt: Int, began: Date, error: Error?) {
        var entry: [String: Any] = ["label": label, "attempt": attempt, "seconds": Self.seconds(since: began)]
        if let error { entry.merge(M24Errors.fields(error)) { $1 } }
        lock.withLock { connections.append(entry) }
    }

    func operation(_ label: String, attempt: Int, began: Date, connections expected: Int, error: Error?) {
        var entry: [String: Any] = ["label": label, "attempt": attempt, "expectedConnections": expected,
                                    "seconds": Self.seconds(since: began), "result": error == nil ? "success" : "failure"]
        if let error { entry.merge(M24Errors.fields(error)) { $1 } }
        lock.withLock { operations.append(entry) }
    }

    func record(_ label: String, _ values: [String: Any]) {
        lock.withLock { cases[label, default: [:]].merge(values) { $1 } }
    }

    func identity(_ label: String, _ value: UInt64) { lock.withLock { identities[label] = value } }

    func snapshot() -> [String: Any] {
        lock.withLock {
            ["completedSteps": completed, "operations": operations, "connections": connections, "cases": cases,
             "nativeIdentities": identities]
        }
    }

    private static func seconds(since date: Date) -> Double { (Date().timeIntervalSince(date) * 10).rounded() / 10 }
}

private struct M24SavedRow: Codable, Equatable {
    let id: String
    let contentVersion: String
    let nativeID: UInt64
}

private struct M24SavedRecord: Codable {
    let plan: DeletionPlan
    let progress: DeletionProgress

    func matches(_ record: PendingDeletion) -> Bool { plan == record.plan && progress == record.progress }
}

extension M24SavedRecord {
    init(_ record: PendingDeletion) { self.init(plan: record.plan, progress: record.progress) }
}

private struct M24State: Codable {
    let run: UUID
    let owner: String
    let overlap: String
    var neighbors: [String: [String: M24SavedRow]] = [:]
    var requests: [String: DeletionRequest] = [:]
    var records: [String: M24SavedRecord] = [:]
    var tracked: [String: M24SavedRow] = [:]
    var keeps: [String] = []
}

/// The helper's own refusal-case writes go through the native mount, as one more client of the share.
private enum M24Native {
    static let flags = O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC

    static func changeInPlace(_ root: Int32, _ path: String, inode: UInt64) throws {
        let fd = openat(root, path, O_WRONLY | flags)
        guard fd >= 0 else { throw posixError("open changed fixture file") }
        defer { Darwin.close(fd) }
        var before = stat()
        try require(fstat(fd, &before) == 0 && before.st_mode & S_IFMT == S_IFREG && before.st_nlink == 1
            && UInt64(before.st_ino) == inode && before.st_size >= 8, "changed-file-identity")
        let marker = Array("CHANGED!".utf8)
        let written = marker.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        try require(written == marker.count && fsync(fd) == 0, "changed-file-write")
        var after = stat()
        try require(fstat(fd, &after) == 0 && after.st_ino == before.st_ino && after.st_size == before.st_size,
                    "changed-file-after")
    }

    static func read(_ root: Int32, _ path: String, inode: UInt64) throws -> Data {
        let fd = openat(root, path, O_RDONLY | flags)
        guard fd >= 0 else { throw posixError("open fixture file") }
        defer { Darwin.close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && UInt64(info.st_ino) == inode
            && info.st_size >= 0 && info.st_size <= 64 << 10, "fixture-file-identity")
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        try require(count == Int(info.st_size), "fixture-file-read")
        return data
    }

    static func create(_ root: Int32, _ path: String, _ bytes: Data) throws -> UInt64 {
        let fd = openat(root, path, O_WRONLY | O_CREAT | O_EXCL | flags, 0o600)
        guard fd >= 0 else { throw posixError("create fixture occupant") }
        defer { Darwin.close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        try require(written == bytes.count && fsync(fd) == 0, "fixture-occupant-write")
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_size == Int64(bytes.count), "fixture-occupant-size")
        return UInt64(info.st_ino)
    }

    /// Moves the original aside without replacing anything, then creates an identical-byte occupant.
    static func replaceIdentical(_ root: Int32, _ path: String, hold: String, inode: UInt64) throws -> UInt64 {
        let bytes = try read(root, path, inode: inode)
        try require(try identity(root, path, directory: false) == inode, "moved-identity")
        try require(renameatx_np(root, path, root, hold, UInt32(RENAME_EXCL)) == 0, "moved-exclusively")
        try require(try identity(root, hold, directory: false) == inode, "moved-held")
        let occupant = try create(root, path, bytes)
        try require(occupant != inode, "replacement-identity")
        return occupant
    }

    static func identity(_ root: Int32, _ path: String, directory: Bool) throws -> UInt64 {
        var info = stat()
        guard fstatat(root, path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else { throw posixError("inspect fixture entry") }
        try require(info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), "fixture-entry-kind")
        return UInt64(info.st_ino)
    }

    static func isAbsent(_ root: Int32, _ path: String) -> Bool {
        var info = stat()
        return fstatat(root, path, &info, AT_SYMLINK_NOFOLLOW_ANY) != 0 && errno == ENOENT
    }
}

/// Delivers the real close, then loses its reply before the transaction can record it.
private final class M24LostClose: DeletionRemote {
    private let remote: DeletionRemote
    private let target: String
    private let fired: M24Flag

    init(_ remote: DeletionRemote, target: String, fired: M24Flag) {
        self.remote = remote
        self.target = target
        self.fired = fired
    }

    func protectParents(of path: String) throws -> [ItemDeletionParent] { try remote.protectParents(of: path) }

    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
        try remote.inspect(path: path, kind: kind)
    }

    func list(path: String) throws -> ItemDeletionListing { try remote.list(path: path) }

    func markDeletion(path: String) throws { try remote.markDeletion(path: path) }

    func closeTarget(path: String) throws {
        try remote.closeTarget(path: path)
        guard path == target else { return }
        fired.raise()
        throw M24Injected.lostCloseReply
    }
}

private enum M24Files {
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

private final class M24Probe: @unchecked Sendable {
    private static let mount = "/Volumes/tinymounter-m19-edit-test"
    private static let host = "127.0.0.1"
    private static let share = "tinymounter-m19-edit-test"
    private static let account = "_tinymounter_m19"
    // Below the parent's 600 s action timeout, so the report is written before any kill.
    private static let budget: TimeInterval = 560
    private static let ownerFolders = [
        "", "c01", "c01/Tree", "c01/Tree/Nested", "c01/Sibling", "c02", "c02/Stale", "c02/Changed", "c02/Replaced",
        "c02/Populated", "c02/Unsupported", "c02/WithPackage", "c02/Linked", "c02/Symlinked", "c02/Hold",
        "c03", "c03/Hold", "c03/Tree", "c03/Tree/Arrival", "c03/Tree/Sub", "c04", "c04/Tree", "c05"]
    // The overlapping view never lists Tree/Nested, so the traversal must find leaf.txt itself.
    private static let overlapFolders = ["", "Tree", "Sibling"]
    private static let ownerNeighbors = ["neighbor.txt", "c01/neighbor.txt", "c01/Sibling", "c01/Sibling/keep.txt",
                                         "c03/neighbor.txt", "c04/neighbor.txt", "c05/neighbor.txt"]
    private static let overlapNeighbors = ["neighbor.txt", "Sibling", "Sibling/keep.txt"]
    private static let c03Nodes = ["c03/Tree/Arrival/z.txt", "c03/Tree/Arrival", "c03/Tree/Sub/x.txt", "c03/Tree/Sub",
                                   "c03/Tree/changed.txt", "c03/Tree/replaced.txt", "c03/Tree/y.txt", "c03/Tree"]
    // Saved Settings keeps on this share; only confirmed-deleted nodes may lose theirs.
    private static let seededKeeps: [(String, CatalogRow.Kind)] = [
        ("c01/Tree/a.txt", .file), ("c01/Tree/Nested", .folder), ("c04/Tree", .folder), ("c04/Tree/a.txt", .file),
        ("c05/file.txt", .file), ("neighbor.txt", .file)]
    private static let untested = [
        "Directory pagination beyond one SMB listing buffer: every fixture folder is small.",
        "The 10,000-node admission limit.",
        "A real app crash or network reply loss: interruptions are an injected lost close reply and process exits.",
        "Finder warnings and Delete controls, File Provider callbacks, IPC and capability routing.",
        "Launch/reconnect triggers and the controller Settings callback: the helper uses a private Settings callback.",
        "Location pending keeps: keep cleanup is checked only on private saved keeps.",
        "Receipt-only e1 refusal: the changed e1 child also changes the catalog fingerprint.",
        "The missing-folder listing fallback: c03 lists ancestors first, so it may never reach it.",
        "Competing-open sharing violations, read-only attributes, access denial, stop and dismiss.",
        "Draining active reads and watches: none are open during admission.",
        "Older builds' handling of the deletion guards.",
        "Two-view settlement after a restart: c01 settles within its own process.",
        "Confirmation-delayed listings: every reconciled folder keeps a known child by design.",
        "Symbolic-link handling beyond one capture-only observation.",
    ]

    let phase: M24Phase
    let runID: UUID
    let root: RelativePath
    let directory: URL
    let store: SettingsStore
    let access: ShareAccess
    let bookmark: Data
    let originalSettingsURL: URL
    let originalSettings: Data
    let ledger = M24Ledger()
    let settingsCalls = M24Counter()
    let started = Date()
    private var state: M24State
    private var owner: LocationSource!
    private var overlap: LocationSource!
    private var endpoint: ShareAddress!

    @MainActor
    init(phase: M24Phase, run: UUID, location: UUID) throws {
        let probeRoot = RelativePath("probe-m24-recursive-" + run.uuidString)!
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        let local = support.appending(path: "M24Recursive/" + run.uuidString)
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
            throw M24Check(label: "explicit-fixture-write-grant-required")
        }
        var stale = false
        let scoped = try URL(resolvingBookmarkData: write, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        try require(!stale && ShareAccess.filePath(scoped) == Self.mount, "write-bookmark-is-share-root")
        let privateSettings = local.appending(path: "Settings.json")
        if let previous = phase.previous {
            let saved = try JSONDecoder().decode(M24State.self, from: Data(contentsOf: local.appending(path: "state.json")))
            try require(saved.run == run, "run-identity")
            state = saved
            let data = try Data(contentsOf: local.appending(path: previous.rawValue + "-report.json"))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try require(report?["passed"] as? Bool == true && report?["run"] as? String == run.uuidString,
                        "previous-phase-passed")
        } else {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try require(mkdir(local.path, 0o700) == 0, "new-run-directory-required")
            state = M24State(run: run, owner: UUID().uuidString, overlap: UUID().uuidString,
                             keeps: Self.seededKeeps.map { $0.0 })
            let keeps = Self.seededKeeps.map { KeepPath(path: probeRoot.string + "/" + $0.0, kind: $0.1) }
            try AppSettings(servers: [server], shares: [grant], locations: [],
                            savedKeeps: [SavedKeepList(host: grant.host, share: grant.share, paths: keeps)])
                .save(to: privateSettings)
        }
        // A second launch of a phase stops here, leaving the first launch's evidence untouched.
        try M24Files.createExclusive(local.appending(path: phase.rawValue + "-started.txt"),
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
    }

    func run() throws {
        var failure: Error?
        do {
            try validateFixture()
            try openSources()
            try require(try keptPaths() == Set(state.keeps), "saved-keeps-at-start")
            switch phase {
            case .refuse: try refusePhase()
            case .delete: try deletePhase()
            case .interrupt: try interruptPhase()
            case .recover: try recoverPhase()
            case .admit: try admitPhase()
            case .compete: try competePhase()
            case .remote: try remotePhase()
            case .replace: try replacePhase()
            }
            ledger.enter("neighbors")
            try verifyNeighbors()
            ledger.enter("original-settings")
            try require(Data(contentsOf: originalSettingsURL) == originalSettings, "user-settings-unchanged")
            ledger.enter(nil)
        } catch {
            failure = error
        }
        try writeReport(failure)
        if let failure { throw failure }
        for source in [owner, overlap].compactMap({ $0 }) {
            source.close()
            access.editNamespace.unregister(source.domainID)
        }
    }

    // MARK: Phases

    /// Refusals only; no case may leave a deletion record.
    private func refusePhase() throws {
        ledger.enter("owner-listing")
        for path in Self.ownerFolders { try list(owner, path, allowSkipped: path == "c02/Symlinked") }
        try establishBase(owner, "c01/Tree/a.txt", label: "c01-base")
        try establishBase(owner, "c02/Changed/x.txt", label: "c02-changed-base")
        // After the bases, so this view's fingerprints follow anything the protected reads changed.
        ledger.enter("overlap-listing")
        for path in Self.overlapFolders { try list(overlap, path) }
        let nested = try catalogRow(overlap, "Tree/Nested")
        try require(try overlap.liveChild(of: nested.id, named: "leaf.txt") == nil, "overlap-nested-unlisted")
        state.neighbors = try [owner.domainID: snapshot(owner, Self.ownerNeighbors),
                               overlap.domainID: snapshot(overlap, Self.overlapNeighbors)]
        try saveState()
        try require(try viewRecords().isEmpty, "fresh-deletion-inventory")

        try refuse("protected-root", deletionRequest(owner, "c01"), recursive: false, connections: 0) {
            $0 as? UploadError == .readOnly
        }

        let stale = try deletionRequest(owner, "c02/Stale/file.txt")
        let staleInode = try nativeID(owner, path: "c02/Stale/file.txt")
        try mutate("stale-change") { try M24Native.changeInPlace($0, "c02/Stale/file.txt", inode: staleInode) }
        try refuse("stale-request", stale, recursive: false, connections: 0) {
            $0 as? SourceFailure == .versionChanged
        }
        let relisted = try catalogRow(owner, "c02/Stale/file.txt")
        try require(relisted.id == stale.item && relisted.contentVersion != stale.contentVersion, "stale-catalog-layer")

        let changedChild = try catalogRow(owner, "c02/Changed/x.txt")
        try require(changedChild.contentVersion.hasPrefix("e1:"), "changed-child-e1")
        let changed = try deletionRequest(owner, "c02/Changed")
        let changedInode = try nativeID(owner, item: changedChild.id)
        try mutate("changed-e1-change") { try M24Native.changeInPlace($0, "c02/Changed/x.txt", inode: changedInode) }
        try refuse("changed-e1-child", changed, recursive: true, connections: 1) { M24Errors.isChangeRefusal($0) }
        // Admission relists only the selected folder's parent, so the protected traversal refused the child.
        try require(try catalogRow(owner, "c02/Changed/x.txt").contentVersion == changedChild.contentVersion,
                    "changed-traversal-layer")

        let replaced = try deletionRequest(owner, "c02/Replaced")
        let replacedInode = try nativeID(owner, path: "c02/Replaced/x.txt")
        var occupant: UInt64 = 0
        try mutate("replaced-swap") {
            occupant = try M24Native.replaceIdentical($0, "c02/Replaced/x.txt", hold: "c02/Hold/replaced-x.txt",
                                                      inode: replacedInode)
        }
        ledger.identity("c02-replaced-occupant", occupant)
        try refuse("replaced-child", replaced, recursive: true, connections: 1) { M24Errors.isChangeRefusal($0) }

        try refuse("non-recursive-populated", deletionRequest(owner, "c02/Populated"), recursive: false,
                   connections: 1) { $0 as? ItemDeletionError == .directoryNotEmpty }
        for (label, path) in [("unsupported-name", "c02/Unsupported"), ("package-child", "c02/WithPackage"),
                              ("hard-link", "c02/Linked")] {
            try refuse(label, deletionRequest(owner, path), recursive: true, connections: 1) {
                $0 as? ItemDeletionError == .unsupported
            }
        }
        try observeSymlink()
        try require(try viewRecords().isEmpty, "refusals-left-no-record")
    }

    /// c01: a populated tree seen by two overlapping views, through the full provider entry.
    private func deletePhase() throws {
        ledger.enter("c01-before")
        let ownerIDs = try ["c01/Tree", "c01/Tree/a.txt", "c01/Tree/Nested", "c01/Tree/Nested/leaf.txt"]
            .map { try catalogRow(owner, $0).id }
        let overlapIDs = try ["Tree", "Tree/a.txt", "Tree/Nested"].map { try catalogRow(overlap, $0).id }
        try require(try catalogRow(owner, "c01/Tree/a.txt").contentVersion.hasPrefix("e1:"), "c01-e1-row")
        let nested = try catalogRow(overlap, "Tree/Nested")
        try require(try overlap.liveChild(of: nested.id, named: "leaf.txt") == nil, "c01-overlap-unlisted-child")
        let c01 = try deletionRequest(owner, "c01/Tree")
        state.requests["c01"] = c01
        try saveState()

        ledger.enter("c01-delete")
        let deleted = try delete("c01.delete", c01, recursive: true, connections: 5).get()
        try requireNodes(deleted, ["c01/Tree/Nested/leaf.txt", "c01/Tree/Nested", "c01/Tree/a.txt", "c01/Tree"], "c01")
        // Every node deleted also shows the capture handles closed before the node sessions opened.
        try require(deleted.isComplete && deleted.summary == [.deleted: 4] && deleted.progress.exceptions.isEmpty,
                    "c01-all-nodes-deleted")
        let views = Dictionary(uniqueKeysWithValues: deleted.plan.views.map { ($0.domain, $0) })
        try require(views.count == 2 && views.values.allSatisfy { $0.catalogAdmission != nil }, "c01-two-views")
        try require(views[owner.domainID]?.items.count == 4, "c01-owner-view-items")
        try require(views[overlap.domainID]?.items.count == 3, "c01-overlap-view-items")
        try require(Set(deleted.progress.finishedDomains) == Set(views.keys), "c01-every-view-finished")
        ledger.record("c01", Self.summary(deleted))
        ledger.enter("c01-catalogs")
        try requireTombstoned(owner, ownerIDs, "c01-owner")
        try requireTombstoned(overlap, overlapIDs, "c01-overlap")
        try requireKeeps("c01-keeps", removed: ["c01/Tree/a.txt", "c01/Tree/Nested"])
        try replayUnchanged("c01", c01, deleted, recursive: true, expected: nil)
        ledger.enter("c01-relisting")
        try list(owner, "c01")
        try list(overlap, "")
        let parent = try catalogRow(owner, "c01")
        try require(try owner.liveChild(of: parent.id, named: "Tree") == nil, "c01-owner-relisted")
        try require(try overlap.liveChild(of: Catalog.rootItemID, named: "Tree") == nil, "c01-overlap-relisted")
        state.records["c01"] = M24SavedRecord(deleted)
        try saveState()
    }

    /// c04: the selected folder's close reaches the server, but its reply is lost; the process then exits.
    private func interruptPhase() throws {
        ledger.enter("c04-admit")
        let c04 = try deletionRequest(owner, "c04/Tree")
        state.requests["c04"] = c04
        try saveState()
        let admitted = try admitOnly("c04", c04, path: full("c04/Tree"), recursive: true)
        try requireNodes(admitted, ["c04/Tree/a.txt", "c04/Tree"], "c04")
        try require(admitted.plan.views.map(\.domain) == [owner.domainID] && admitted.progress == DeletionProgress(),
                    "c04-admitted-unrun")
        state.records["c04-admitted"] = M24SavedRecord(admitted)
        try saveState()
        let interrupted = try lostCloseRun("c04", id: admitted.id, target: full("c04/Tree"))
        try require(interrupted.plan == admitted.plan && interrupted.progress.exceptions.isEmpty, "c04-plan-unchanged")
        try require(interrupted.progress.next == 1 && interrupted.progress.current == .attempting,
                    "c04-close-in-flight")
        state.records["c04-interrupted"] = M24SavedRecord(interrupted)
        var details = Self.summary(interrupted)
        details["interruption"] = "injected error after a successful close reply, then a clean process exit"
        ledger.record("c04", details)
        try saveState()
    }

    /// c04 after restart: the absent folder stays unconfirmed, and replay never deletes again.
    private func recoverPhase() throws {
        ledger.enter("c04-restart")
        guard let c04 = state.requests["c04"], let interrupted = state.records["c04-interrupted"] else {
            throw M24Check(label: "c04-state")
        }
        let c04IDs = try ["c04/Tree/a.txt", "c04/Tree"].map { try catalogRow(owner, $0).id }
        try require(interrupted.matches(try storedRecord(interrupted.plan.id)), "c04-durable-after-restart")
        ledger.enter("c04-recovery")
        let recovery = try delete("c04.replay-after-restart", c04, recursive: true, connections: 1)
        let recovered = try storedRecord(interrupted.plan.id)
        ledger.record("c04", Self.summary(recovered))
        try requireFailure(recovery, "c04-callback-refused") { $0 as? ItemDeletionError == .unresolved }
        try require(recovered.plan == interrupted.plan, "c04-plan-unchanged")
        try require(recovered.outcome(at: 0) == .deleted, "c04-child-deleted")
        try require(recovered.selectedOutcome == .unconfirmed, "c04-folder-unconfirmed")
        try require(recovered.isComplete && recovered.hasUnconfirmed && recovered.isPending
            && !recovered.progress.dismissed, "c04-uncertainty-retained")
        // The catalog drops the absent rows after a fresh listing; only the record keeps the uncertainty.
        try requireTombstoned(owner, c04IDs, "c04-catalog")
        try require(guardsPresent(owner.domainID), "c04-guards-retained")
        try requireKeeps("c04-keeps", removed: ["c04/Tree/a.txt"])
        try replayUnchanged("c04", c04, recovered, recursive: true) { $0 as? ItemDeletionError == .unresolved }
        state.records["c04"] = M24SavedRecord(recovered)
        try saveState()
    }

    /// c03 admission only; the Python competitor changes the backing store before the next process.
    private func admitPhase() throws {
        ledger.enter("c03-admit")
        for path in Self.c03Nodes {
            let current = try catalogRow(owner, path)
            state.tracked[path] = M24SavedRow(id: current.id, contentVersion: current.contentVersion,
                                              nativeID: try nativeID(owner, item: current.id))
        }
        let c03 = try deletionRequest(owner, "c03/Tree")
        state.requests["c03"] = c03
        try saveState()
        let admitted = try admitOnly("c03", c03, path: full("c03/Tree"), recursive: true)
        try requireNodes(admitted, Self.c03Nodes, "c03")
        try require(admitted.progress == DeletionProgress(), "c03-admitted-unrun")
        state.records["c03-admitted"] = M24SavedRecord(admitted)
        ledger.record("c03", Self.summary(admitted))
        try saveState()
    }

    /// c03 after server-side changes: the stored plan governs, and settlement needs fresh listings.
    private func competePhase() throws {
        ledger.enter("c03-resume")
        guard let c03 = state.requests["c03"], let admitted = state.records["c03-admitted"] else {
            throw M24Check(label: "c03-state")
        }
        let id = admitted.plan.id
        try require(admitted.matches(try storedRecord(id)), "c03-durable-after-restart")
        let resumed = try laneDeletion("c03.resume", connections: 7, resumable: { try self.activePrepared(id) }) {
            [self] in try owner.resumeDeletionOnLane(id, progress: Progress())
        }
        let expected: [DeletionNodeOutcome?] = [.deleted, .directoryNotEmpty, .parentChanged, .unconfirmed,
                                                .changed, .replaced, .deleted, .directoryNotEmpty]
        var details = Self.summary(resumed)
        details["missingAncestor"] = resumed.outcome(at: 2)?.rawValue ?? "pending"
        ledger.record("c03", details)
        let outcomes = resumed.plan.nodes.indices.map { resumed.outcome(at: $0) }
        try require(resumed.isSettled && resumed.plan == admitted.plan, "c03-settled-stored-plan")
        try require(outcomes == expected, "c03-node-outcomes")

        ledger.enter("c03-settlement")
        let completion = try delete("c03.settle", c03, recursive: true, connections: 0)
        try requireFailure(completion, "c03-callback-refused") { $0 as? ItemDeletionError == .directoryNotEmpty }
        let settled = try storedRecord(id)
        try require(settled.plan == admitted.plan && settled.isComplete && settled.hasUnconfirmed, "c03-complete")
        try require(settled.progress.exceptions == resumed.progress.exceptions, "c03-settled-unchanged")

        ledger.enter("c03-catalog")
        try requireTombstoned(owner, ["c03/Tree/Arrival/z.txt", "c03/Tree/Sub/x.txt", "c03/Tree/Sub", "c03/Tree/y.txt"]
            .map { try tracked($0).id }, "c03-removed")
        for path in ["c03/Tree", "c03/Tree/Arrival", "c03/Tree/changed.txt", "c03/Tree/replaced.txt"] {
            try require(try item(owner, tracked(path).id)?.deleted == false, "c03-survivor-live")
        }
        let changed = try tracked("c03/Tree/changed.txt"), replaced = try tracked("c03/Tree/replaced.txt")
        try require(try item(owner, changed.id)?.contentVersion != changed.contentVersion, "c03-changed-relisted")
        guard let arrived = try owner.liveChild(of: tracked("c03/Tree/Arrival").id, named: "new.txt") else {
            throw M24Check(label: "c03-arrival-listed")
        }
        // Read natively only now, so no earlier lookup could refresh the mount's caches for settlement.
        ledger.enter("c03-native")
        let sub = try tracked("c03/Tree/Sub")
        var occupant: UInt64 = 0, arrival: UInt64 = 0
        try owner.withWriteSession(bookmark) { _, root in
            occupant = try M24Native.identity(root, "c03/Tree/replaced.txt", directory: false)
            arrival = try M24Native.identity(root, "c03/Tree/Arrival/new.txt", directory: false)
            try require(try M24Native.read(root, "c03/Tree/replaced.txt", inode: occupant)
                == payload("c03/Tree/replaced.txt"), "c03-occupant-bytes")
            try require(try M24Native.read(root, "c03/Tree/Arrival/new.txt", inode: arrival) == arrivalBytes,
                        "c03-arrival-bytes")
            try require(try M24Native.read(root, "c03/Tree/changed.txt", inode: changed.nativeID)
                == changedBytes("c03/Tree/changed.txt"), "c03-changed-bytes")
            try require(M24Native.isAbsent(root, "c03/Tree/Sub")
                && M24Native.identity(root, "c03/Hold/Sub", directory: true) == sub.nativeID, "c03-sub-moved")
        }
        ledger.identity("c03-replaced-occupant", occupant)
        ledger.identity("c03-arrival", arrival)
        try require(occupant != replaced.nativeID && nativeID(owner, item: replaced.id) == occupant,
                    "c03-occupant-listed-under-same-id")
        try require(try nativeID(owner, item: arrived.id) == arrival, "c03-arrival-identity")
        try replayUnchanged("c03", c03, settled, recursive: true) { $0 as? ItemDeletionError == .directoryNotEmpty }
        state.records["c03"] = M24SavedRecord(settled)
        try saveState()
    }

    /// c05: remote deletion without settlement; the Python step then puts a replacement at the name.
    private func remotePhase() throws {
        ledger.enter("c05-remote")
        let selected = try catalogRow(owner, "c05/file.txt")
        state.tracked["c05/file.txt"] = M24SavedRow(id: selected.id, contentVersion: selected.contentVersion,
                                                    nativeID: try nativeID(owner, item: selected.id))
        let c05 = try deletionRequest(owner, "c05/file.txt")
        state.requests["c05"] = c05
        try saveState()
        let remote = try laneDeletion("c05.delete-without-settlement", connections: 2,
                                      resumable: { try self.resumable(c05) }) { [self] in
            let progress = Progress()
            let admitted = try owner.prepareDeletionOnLane(c05, recursive: false, progress: progress) { _ in }
            return try owner.resumeDeletionOnLane(admitted.id, progress: progress)
        }
        ledger.record("c05", Self.summary(remote))
        try require(remote.isSettled && !remote.isComplete && remote.plan.nodes.count == 1, "c05-remote-only")
        try require(remote.selectedOutcome == .deleted, "c05-remotely-deleted")
        state.records["c05-remote"] = M24SavedRecord(remote)
        try saveState()
    }

    /// Final replays, then c05's settlement after an intervening catalog write and a live replacement.
    private func replacePhase() throws {
        let finals: [(String, ((Error) -> Bool)?)] = [
            ("c01", nil), ("c03", { $0 as? ItemDeletionError == .directoryNotEmpty }),
            ("c04", { $0 as? ItemDeletionError == .unresolved })]
        for (label, expected) in finals {
            ledger.enter(label + "-final-replay")
            guard let request = state.requests[label], let saved = state.records[label] else {
                throw M24Check(label: label + "-state")
            }
            let restarted = try storedRecord(saved.plan.id)
            try require(saved.matches(restarted), label + "-durable-after-restart")
            try replayUnchanged(label + "-final", request, restarted, recursive: true, expected: expected)
        }

        ledger.enter("c05-before-settlement")
        guard let c05 = state.requests["c05"], let remote = state.records["c05-remote"],
              let original = state.tracked["c05/file.txt"] else { throw M24Check(label: "c05-state") }
        try require(remote.matches(try storedRecord(remote.plan.id)), "c05-durable-after-restart")
        try require(try item(owner, c05.item)?.deleted == false && nativeID(owner, item: c05.item) == original.nativeID,
                    "c05-catalog-before-settlement")
        // Any catalog write after admission forbids a direct tombstone and forces fresh listing evidence.
        try require(try owner.keep([catalogRow(owner, "c05/neighbor.txt").id], value: true) > 0, "c05-intervening-write")

        ledger.enter("c05-settlement")
        let result = try delete("c05.settle-after-replacement", c05, recursive: false, connections: 0)
        let after = try storedRecord(remote.plan.id)
        var details = Self.summary(after)
        let live = try item(owner, c05.item)?.deleted == false
        details["selectedRowLive"] = live
        ledger.record("c05", details)
        try requireFailure(result, "c05-live-replacement-refused") { $0 as? SourceFailure == .versionChanged }
        try require(after.plan == remote.plan && after.progress.exceptions == remote.progress.exceptions,
                    "c05-remote-outcome-unchanged")
        try require(after.selectedOutcome == .deleted, "c05-remote-deletion-kept")
        let calls = settingsCalls.count
        ledger.enter("c05-replay")
        let again = try delete("c05.replay", c05, recursive: false, connections: 0)
        let final = try storedRecord(remote.plan.id)
        ledger.record("c05", ["replaySettingsCalls": settingsCalls.count - calls, "completeAfterReplay": final.isComplete])
        try requireFailure(again, "c05-replay-refused") { $0 as? SourceFailure == .versionChanged }
        try require(final.plan == remote.plan && final.progress.exceptions == after.progress.exceptions,
                    "c05-replay-no-new-deletion")

        ledger.enter("c05-native")
        var occupant: UInt64 = 0
        try owner.withWriteSession(bookmark) { _, root in
            occupant = try M24Native.identity(root, "c05/file.txt", directory: false)
            try require(try M24Native.read(root, "c05/file.txt", inode: occupant) == replacementBytes,
                        "c05-occupant-bytes")
        }
        ledger.identity("c05-occupant", occupant)
        try require(occupant != original.nativeID, "c05-new-occupant")
        try require(live && nativeID(owner, item: c05.item) == occupant, "c05-replacement-kept-selected-id")
        try requireKeeps("c05-keeps", removed: ["c05/file.txt"])
        try ledger.record("records", ["pending": viewRecords().filter(\.isPending).map { Self.summary($0) }])
    }

    // MARK: Production calls

    @MainActor
    private func cleanupSettings(_ record: PendingDeletion, paths: [KeepPath]) throws {
        let confirmed = record.plan.nodes.indices.filter { record.outcome(at: $0) == .deleted }.map {
            KeepPath(path: record.plan.nodes[$0].path, kind: record.plan.nodes[$0].evidence.kind)
        }
        try require(record.plan.owner == state.owner && record.isSettled && paths == confirmed,
                    "settings-confirmed-paths")
        try require(try LocationSource.deletionOutbox().reload(record) == record, "settings-current-record")
        try store.update { try $0.removeKeptItems(paths, host: Self.host, share: Self.share) }
        settingsCalls.add()
    }

    /// The app deletion entry. A failed connection leaves no request in flight, so its production
    /// replay is the only repetition; a deletion body is never retried here.
    private func delete(_ label: String, _ request: DeletionRequest, recursive: Bool,
                        connections: Int) throws -> Result<PendingDeletion, Error> {
        var attempt = 1
        while true {
            let reply = M24Reply<PendingDeletion>(), began = Date()
            owner.deleteItem(request, recursive: recursive, progress: Progress(), started: {}) { reply.finish($0) }
            let result = try reply.wait(label, seconds: timeout(connections: connections))
            ledger.operation(label, attempt: attempt, began: began, connections: connections,
                             error: M24Errors.failure(result))
            if let error = M24Errors.failure(result), attempt < 3, M24Errors.isConnectFailure(error),
               try resumable(request) {
                Thread.sleep(forTimeInterval: 2)
                attempt += 1
                continue
            }
            return result
        }
    }

    private func laneDeletion(_ label: String, connections: Int, resumable: () throws -> Bool,
                              _ body: @escaping @Sendable () throws -> PendingDeletion) throws -> PendingDeletion {
        var attempt = 1
        while true {
            do {
                return try onLane(label, attempt: attempt, connections: connections, body)
            } catch {
                guard attempt < 3, M24Errors.isConnectFailure(error), try resumable() else { throw error }
            }
            Thread.sleep(forTimeInterval: 2)
            attempt += 1
        }
    }

    private func onLane<T: Sendable>(_ label: String, attempt: Int = 1, connections: Int,
                                     _ body: @escaping @Sendable () throws -> T) throws -> T {
        let reply = M24Reply<T>(), began = Date()
        access.enqueue { reply.finish(Result { try body() }) }
        let result = try reply.wait(label, seconds: timeout(connections: connections))
        ledger.operation(label, attempt: attempt, began: began, connections: connections,
                         error: M24Errors.failure(result))
        return try result.get()
    }

    /// SettingsStore is main-actor state; the main actor only awaits the probe task meanwhile.
    private func onMain<T: Sendable>(_ body: @MainActor () throws -> T) throws -> T {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }

    private func resumable(_ request: DeletionRequest) throws -> Bool {
        guard let record = try LocationSource.deletionOutbox().replay(endpoint: endpoint, owner: owner.domainID,
                                                                      request: request) else { return true }
        return !record.isSettled && record.progress.current == .prepared
    }

    private func activePrepared(_ id: UUID) throws -> Bool {
        let record = try storedRecord(id)
        return !record.isSettled && record.progress.current == .prepared
    }

    /// A nil expectation requires success.
    private func replayUnchanged(_ label: String, _ request: DeletionRequest, _ settled: PendingDeletion,
                                 recursive: Bool, expected: ((Error) -> Bool)?) throws {
        ledger.enter(label + "-replay")
        let calls = settingsCalls.count
        let result = try delete(label + ".replay", request, recursive: recursive, connections: 0)
        if let expected {
            try requireFailure(result, label + "-replay", expected)
        } else if let error = M24Errors.failure(result) {
            ledger.record(label + "-replay", M24Errors.fields(error))
            throw M24Check(label: label + "-replay-succeeds")
        }
        try require(try storedRecord(settled.id) == settled && settingsCalls.count == calls, label + "-replay-no-new-work")
    }

    // MARK: Admission without its run

    // Admission is separate so competitor changes and lost replies use the stored production plan.
    private func admitOnly(_ label: String, _ request: DeletionRequest, path: RelativePath,
                           recursive: Bool) throws -> PendingDeletion {
        try laneDeletion(label + ".admit", connections: 1, resumable: { try self.resumable(request) }) { [self] in
            let record = try owner.prepareDeletionOnLane(request, recursive: recursive, progress: Progress()) { _ in }
            try require(record.plan.selected.path.utf8.elementsEqual(path.string.utf8), label + "-admitted-path")
            return record
        }
    }

    /// RecursiveDeletionTransaction with fresh helper sessions; only the target's close reply is lost.
    private func lostCloseRun(_ label: String, id: UUID, target: RelativePath) throws -> PendingDeletion {
        let targetPath = target.string
        return try onLane(label + ".run", connections: 2) { [self] in
            var record = try storedRecord(id)
            let namespace = owner.editNamespace
            let write = try namespace.perform { () -> Data in
                try namespace.requireSettled(excluding: id)
                return try owner.renameAccess()
            }
            let fired = M24Flag()
            var sessions = 0
            do {
                try owner.withWriteSession(write) { share, _ in
                    guard let address = ShareAddress(share.identity.mountFrom) else { throw UploadError.readOnly }
                    try RecursiveDeletionTransaction.run(&record, outbox: LocationSource.deletionOutbox(),
                                                         endpoint: address, owner: owner.domainID) { body in
                        sessions += 1
                        let remote = try connect(label + ".node-session-" + String(sessions), shareRoot: share.root)
                        try body(M24LostClose(remote, target: targetPath, fired: fired))
                    }
                }
                throw M24Check(label: label + "-lost-close-not-reached")
            } catch M24Injected.lostCloseReply {
                try require(fired.value, label + "-lost-close-fired")
            }
            return try storedRecord(id)
        }
    }

    /// Server presentation of a link is unknown, so this observation captures and releases, never deletes.
    private func observeSymlink() throws {
        let label = "symlink-capture-only"
        ledger.enter(label)
        let path = try full("c02/Symlinked"), folder = try catalogRow(owner, "c02/Symlinked")
        let folderID = try nativeID(owner, item: folder.id)
        let before = try viewRecords().map(\.id)
        let observed: String = try onLane(label, connections: 1) { [self] in
            let expectation = try DeletionExpectation(path: path, row: folder, nativeID: folderID, receipt: nil)
            return try owner.editNamespace.perform {
                try owner.withWriteSession(bookmark) { share, _ in
                    let remote = try connect(label + ".capture", shareRoot: share.root)
                    do {
                        let traversal = try remote.captureDeletionTraversal(of: path, recursive: true,
                                                                            expecting: [expectation])
                        try remote.releaseDeletionTraversal()
                        return "admitted-objects-" + String(traversal.objects.count)
                    } catch {
                        return "refused-" + M24Errors.name(error)
                    }
                }
            }
        }
        try require(try viewRecords().map(\.id) == before, label + "-no-record")
        ledger.record(label, ["observed": observed, "deletionAttempted": false])
    }

    private func connect(_ label: String, shareRoot: Int32) throws -> SMBEdit {
        var attempt = 1
        while true {
            let began = Date()
            do {
                let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: shareRoot, progress: Progress())
                ledger.connection(label, attempt: attempt, began: began, error: nil)
                return remote
            } catch {
                ledger.connection(label, attempt: attempt, began: began, error: error)
                guard attempt < 3, M24Errors.isConnectFailure(error) else { throw error }
            }
            Thread.sleep(forTimeInterval: 2)
            attempt += 1
        }
    }

    // MARK: Fixture, catalogs and evidence

    private func validateFixture() throws {
        ledger.enter("fixture")
        try require(access.mountPath() == Self.mount, "existing-loopback-mount-required")
        let markerBytes = Data(("tinymounter-m24-recursive:" + runID.uuidString + "\n").utf8)
        endpoint = try access.withSession { session, _ -> ShareAddress in
            try require(session.identity.typeName == "smbfs", "native-smb-session")
            guard let address = ShareAddress(session.identity.mountFrom), address.host == Self.host,
                  address.share == Self.share, address.account == Self.account else {
                throw M24Check(label: "mount-identity")
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
        let fresh = phase == .refuse
        owner = try makeSource(state.owner, folder: root, fresh: fresh)
        overlap = try makeSource(state.overlap, folder: root.appending("c01")!, fresh: fresh)
    }

    private func makeSource(_ domain: String, folder: RelativePath, fresh: Bool) throws -> LocationSource {
        if fresh {
            let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
            for storage in ["Uploads/", "Edits/"] {
                try require(!FileManager.default.fileExists(atPath: support.appending(path: storage + domain).path),
                            "fresh-domain-storage")
            }
            try require(try !LocationSource.renameOutbox().intents().contains { $0.domains.contains(domain) },
                        "fresh-rename-domain")
            try require(try !LocationSource.deletionOutbox().records().contains {
                $0.plan.views.contains { $0.domain == domain }
            }, "fresh-deletion-domain")
        }
        let url = directory.appending(path: domain + ".sqlite")
        let catalog = try fresh ? Catalog.create(at: url, domainID: domain, rootName: "M24 runtime probe")
            : Catalog.openWriter(at: url, domainID: domain)
        let source = LocationSource(domainID: domain, folder: folder, catalog: catalog, access: access,
                                    renameSettings: { _ in throw UploadError.readOnly },
                                    deletionSettings: { [weak self] record, paths in
            guard let self else { throw M24Check(label: "settings-probe-ended") }
            try await self.cleanupSettings(record, paths: paths)
        }, signal: { _ in })
        try source.configureWriteMode(bookmark, confirmed: true)
        return source
    }

    private func list(_ source: LocationSource, _ path: String, allowSkipped: Bool = false) throws {
        let id = try path.isEmpty ? Catalog.rootItemID : catalogRow(source, path).id
        let reply = M24Reply<ListReceipt>()
        source.list(id, requestID: UUID(), bounded: false) { reply.finish($0) }
        let receipt = try reply.wait("list", seconds: timeout(connections: 0)).get()
        try require(allowSkipped || receipt.skipped == 0, "listing-has-skipped-entries")
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
            let began = Date()
            do {
                _ = try source.transfer(request, progress: Progress(), stagingDirectory: staging)
                ledger.operation(label, attempt: attempt, began: began, connections: 1, error: nil)
                break
            } catch {
                ledger.operation(label, attempt: attempt, began: began, connections: 1, error: error)
                guard attempt < 3, M24Errors.isConnectFailure(error) else { throw error }
            }
            Thread.sleep(forTimeInterval: 2)
            attempt += 1
        }
        let based = try catalogRow(source, path)
        try require(based.id == plain.id && based.contentVersion.hasPrefix("e1:"), label + "-e1")
        try require(try LocationSource.editOutbox(domainID: source.domainID)
            .base(item: based.id, contentVersion: based.contentVersion) != nil, label + "-receipt")
    }

    private func refuse(_ label: String, _ request: DeletionRequest, recursive: Bool, connections: Int,
                        _ expected: (Error) -> Bool) throws {
        ledger.enter(label)
        let before = try viewRecords().map(\.id)
        let result = try delete(label, request, recursive: recursive, connections: connections)
        try requireFailure(result, label, expected)
        try require(try viewRecords().map(\.id) == before, label + "-no-record")
    }

    private func requireFailure(_ result: Result<PendingDeletion, Error>, _ label: String,
                                _ expected: (Error) -> Bool) throws {
        guard let error = M24Errors.failure(result) else { throw M24Check(label: label + "-unexpected-success") }
        var details = M24Errors.fields(error)
        details["expected"] = expected(error)
        ledger.record(label, details)
        try require(expected(error), label + "-error")
    }

    private func mutate(_ label: String, _ body: (Int32) throws -> Void) throws {
        ledger.enter(label)
        try owner.withWriteSession(bookmark) { _, locationRoot in try body(locationRoot) }
    }

    private func requireKeeps(_ label: String, removed: [String]) throws {
        state.keeps.removeAll { removed.contains($0) }
        let actual = try keptPaths()
        try require(actual == Set(state.keeps), label)
        try saveState()
    }

    private func keptPaths() throws -> Set<String> {
        let prefix = root.string + "/"
        return try onMain {
            guard let settings = store.settings else { throw M24Check(label: "private-settings") }
            return Set(settings.savedKeeps.flatMap(\.paths).map {
                $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.path
            })
        }
    }

    private func catalogRow(_ source: LocationSource, _ path: String) throws -> CatalogRow {
        try source.withCatalog { catalog in
            var id = Catalog.rootItemID
            for name in RelativePath(path)!.components {
                guard let child = try catalog.liveChild(parent: id, nameKey: NameKey(name)),
                      child.name.utf8.elementsEqual(name.utf8) else { throw M24Check(label: "catalog-path") }
                id = child.id
            }
            guard let found = try catalog.item(id: id) else { throw M24Check(label: "catalog-row") }
            return found
        }
    }

    private func item(_ source: LocationSource, _ id: String) throws -> CatalogRow? {
        try source.withCatalog { try $0.item(id: id) }
    }

    private func nativeID(_ source: LocationSource, item id: String) throws -> UInt64 {
        guard let value = try source.withCatalog({ try $0.remoteIdentity(id) }) else {
            throw M24Check(label: "catalog-native-id")
        }
        return value
    }

    private func nativeID(_ source: LocationSource, path: String) throws -> UInt64 {
        try nativeID(source, item: catalogRow(source, path).id)
    }

    private func tracked(_ path: String) throws -> M24SavedRow {
        guard let saved = state.tracked[path] else { throw M24Check(label: "tracked-row") }
        return saved
    }

    private func deletionRequest(_ source: LocationSource, _ path: String) throws -> DeletionRequest {
        let selected = try catalogRow(source, path)
        return DeletionRequest(item: selected.id, contentVersion: selected.contentVersion,
                               metadataVersion: selected.metadataVersion)
    }

    private func full(_ path: String) throws -> RelativePath {
        guard let relative = RelativePath(path), let result = root.appending(relative) else {
            throw M24Check(label: "fixture-path")
        }
        return result
    }

    private func requireNodes(_ record: PendingDeletion, _ paths: [String], _ label: String) throws {
        let expected = try paths.map { try full($0).string }
        try require(record.plan.nodes.map(\.path) == expected, label + "-node-order")
    }

    private func requireTombstoned(_ source: LocationSource, _ ids: [String], _ label: String) throws {
        for id in ids { try require(try item(source, id)?.deleted == true, label + "-tombstoned") }
    }

    private func storedRecord(_ id: UUID) throws -> PendingDeletion {
        guard let record = try LocationSource.deletionOutbox().records().first(where: { $0.id == id }) else {
            throw M24Check(label: "durable-record")
        }
        return record
    }

    private func viewRecords() throws -> [PendingDeletion] {
        let domains = [state.owner, state.overlap]
        return try LocationSource.deletionOutbox().records().filter { record in
            record.plan.views.contains { domains.contains($0.domain) }
        }
    }

    private func guardsPresent(_ domain: String) -> Bool {
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        let edit = EditOutbox.deletionGuardName, rename = FileRenameOutbox.deletionGuardName
        return DeletionGuard.isExact(support.appending(path: "Edits/" + domain + "/" + edit), named: edit)
            && DeletionGuard.isExact(support.appending(path: "Renames/" + rename), named: rename)
    }

    private func snapshot(_ source: LocationSource, _ paths: [String]) throws -> [String: M24SavedRow] {
        var result: [String: M24SavedRow] = [:]
        for path in paths {
            let current = try catalogRow(source, path)
            result[path] = M24SavedRow(id: current.id, contentVersion: current.contentVersion,
                                       nativeID: try nativeID(source, item: current.id))
        }
        return result
    }

    private func verifyNeighbors() throws {
        for (source, paths) in [(owner!, Self.ownerNeighbors), (overlap!, Self.overlapNeighbors)] {
            guard let saved = state.neighbors[source.domainID], saved.count == paths.count else {
                throw M24Check(label: "neighbor-snapshot")
            }
            for (path, expected) in saved {
                let current = try catalogRow(source, path)
                let identity = try nativeID(source, item: current.id)
                try require(current.id == expected.id && current.contentVersion == expected.contentVersion
                    && identity == expected.nativeID, "neighbor-unchanged")
            }
        }
    }

    private func timeout(connections: Int) throws -> Int {
        let remaining = Int(Self.budget - Date().timeIntervalSince(started))
        try require(remaining > 30, "phase-time-budget")
        return min(60 + 40 * connections, remaining)
    }

    // The Python fixture writes the same bytes.
    private func payload(_ path: String) -> Data {
        Data(String(repeating: "m24-recursive:" + runID.uuidString + ":" + path + "\n", count: 4).utf8)
    }

    private func changedBytes(_ path: String) -> Data { Data("CHANGED!".utf8) + payload(path).dropFirst(8) }
    private var arrivalBytes: Data { Data(("m24-arrival:" + runID.uuidString + "\n").utf8) }
    private var replacementBytes: Data { Data(("m24-replacement:" + runID.uuidString + "\n").utf8) }

    private func saveState() throws {
        try JSONEncoder().encode(state).write(to: directory.appending(path: "state.json"), options: .atomic)
    }

    private static func summary(_ record: PendingDeletion) -> [String: Any] {
        ["record": record.id.uuidString, "nodes": record.plan.nodes.count, "views": record.plan.views.count,
         "outcomes": record.plan.nodes.indices.map { record.outcome(at: $0)?.rawValue ?? "pending" },
         "selected": record.selectedOutcome?.rawValue ?? "pending", "settled": record.isSettled,
         "complete": record.isComplete, "pending": record.isPending, "unconfirmed": record.hasUnconfirmed,
         "finishedViews": record.progress.finishedDomains.count, "inFlight": record.progress.current.rawValue,
         "sharingViolations": record.summary[.sharingViolation] ?? 0]
    }

    private func writeReport(_ failure: Error?) throws {
        var report = ledger.snapshot()
        report["run"] = runID.uuidString
        report["phase"] = phase.rawValue
        report["date"] = ISO8601DateFormatter().string(from: .now)
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["cache"] = "uncontrolled"
        report["entry"] = "LocationSource admission, deletion scheduler and settlement bridge in the signed app module"
        report["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        report["passed"] = failure == nil
        report["requiresSuccessfulProcessExit"] = true
        report["untested"] = Self.untested
        if let failure {
            report["failedStep"] = ledger.step ?? "setup"
            report.merge(M24Errors.fields(failure)) { $1 }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try M24Files.createExclusive(directory.appending(path: phase.rawValue + "-report.json"), data)
    }
}
