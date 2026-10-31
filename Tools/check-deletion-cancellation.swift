import Darwin
import Foundation

// Replace only TinyMounterApp.swift in a private signed archive; see the companion runbook.
@main
enum M24CancellationHelper {
    @MainActor
    static func main() async {
        let began = ContinuousClock.now
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 550) {
            print("M24 cancellation failed: process-deadline; retain all artifacts")
            exit(124)
        }
        do {
            let args = CommandLine.arguments
            guard args.count == 5, args[1] == "--m24-cancellation",
                  let phase = CancellationPhase(rawValue: args[2]),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  args[4] == "3A9DE695-8327-4D86-B393-2520E71A75D8" else {
                throw CancellationCheck(label: "arguments")
            }
            let probe = try CancellationProbe(phase: phase, run: run, began: began)
            try await Task.detached { try probe.run() }.value
            print("M24 cancellation phase passed: " + phase.rawValue + "; limits are in its report")
            exit(0)
        } catch {
            print("M24 cancellation failed: " + cancellationError(error))
            exit(1)
        }
    }
}

private enum CancellationPhase: String, CaseIterable {
    case cancel, joined, close, unsettled, stopped, uncertain, reconcile

    var previous: Self? {
        let index = Self.allCases.firstIndex(of: self)!
        return index == 0 ? nil : Self.allCases[index - 1]
    }
}

private struct CancellationCheck: Error { let label: String }
private enum CancellationInjection: Error { case lostCloseReply }

private func demand(_ condition: Bool, _ label: String) throws {
    guard condition else { throw CancellationCheck(label: label) }
}

private func cancellationError(_ error: Error) -> String {
    if let error = error as? CancellationCheck { return error.label }
    if error is ItemDeletionError || error is SourceFailure || error is UploadError || error is TransferError
        || error is LocationError || error is CancellationInjection { return String(describing: error) }
    let value = error as NSError
    return value.domain + ":" + String(value.code)
}

private final class CancellationReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var first: Result<Value, Error>?
    private var received = 0

    func finish(_ result: Result<Value, Error>) {
        lock.withLock {
            received += 1
            if first == nil { first = result }
        }
        ready.signal()
    }

    var count: Int { lock.withLock { received } }

    func wait(_ label: String, until deadline: DispatchTime) throws -> Result<Value, Error> {
        try demand(ready.wait(timeout: deadline) == .success, "timeout:" + label)
        return lock.withLock { first! }
    }
}

private final class CancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func add() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

// The gate suspends only the injected Settings callback, leaving the main actor and lane free.
private final class CancellationSettingsGate: @unchecked Sendable {
    let entered = CancellationReply<PendingDeletion>()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(_ record: PendingDeletion) async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                self.continuation = continuation
                return false
            }
            entered.finish(.success(record))
            if resume { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

// These barriers hold no catalog, namespace, native file or SMB client lock.
private final class CancellationLaneGate: @unchecked Sendable {
    let entered = CancellationReply<Void>()
    let ended = CancellationReply<Void>()
    private let releaseSignal = DispatchSemaphore(value: 0)

    func enqueue(on access: ShareAccess, until deadline: DispatchTime) {
        access.enqueue { [self] in
            entered.finish(.success(()))
            ended.finish(Result {
                try demand(releaseSignal.wait(timeout: deadline) == .success, "lane-gate-timeout")
            })
        }
    }

    func release() { releaseSignal.signal() }
}

// The real close completes; only its reply to the transaction is lost.
private final class CancellationLostClose: DeletionRemote {
    let remote: DeletionRemote
    let fired: CancellationCount

    init(_ remote: DeletionRemote, fired: CancellationCount) {
        self.remote = remote
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
        fired.add()
        throw CancellationInjection.lostCloseReply
    }
}

private struct CancellationIdentity: Codable {
    let run: UUID
    let owner: String
}

private enum CancellationFiles {
    static func create(_ url: URL, _ data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create cancellation evidence") }
        defer { Darwin.close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fcntl(fd, F_FULLFSYNC) == 0 else {
            throw posixError("sync cancellation evidence")
        }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError("open cancellation evidence directory") }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw posixError("sync cancellation evidence directory") }
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private static let mount = "/Volumes/tinymounter-m19-edit-test"
    private static let host = "127.0.0.1"
    private static let share = "tinymounter-m19-edit-test"
    private static let account = "_tinymounter_m19"
    private static let files = ["cancel/Tree/a.txt", "cancel/Tree/b.txt", "joined/file.txt",
                                "close/Tree/a.txt", "close/Tree/b.txt", "uncertain/file.txt", "neighbor.txt"]
    private static let keeps: [(String, CatalogRow.Kind)] = [
        ("cancel/Tree", .folder), ("cancel/Tree/a.txt", .file), ("joined/file.txt", .file),
        ("close/Tree", .folder), ("close/Tree/a.txt", .file), ("uncertain/file.txt", .file),
        ("neighbor.txt", .file)]
    private static let missing = [
        "Finder, File Provider, IPC, controller launch/reconnect triggers and the controller Settings callback.",
        "Cancellation within an active protected node or the KVO-before-lock race; no production hook forces either.",
        "A completion racing an unqueued Stop; the counted-Stop case forces queued checkpoints only.",
        "Source closure during delayed Settings, or primary cancellation while a joined request waits.",
        "Explicit retryDeletion resuming an unsettled plan, and Dismiss.",
        "Real crash, network loss, remount, storage failure, multiple catalog views and active read/watch draining.",
        "Late duplicate replies beyond the bounded observation window or after process exit.",
        "Network request counts: unchanged progress and inventory establish no resumed deletion, not zero SMB traffic."
    ]

    let phase: CancellationPhase
    let identity: CancellationIdentity
    let root: RelativePath
    let directory: URL
    let began: ContinuousClock.Instant
    let store: SettingsStore
    let access: ShareAccess
    let bookmark: Data
    let originalURL: URL
    let original: Data
    let settingsGate = CancellationSettingsGate()
    let settingsCalls = CancellationCount()
    let settingsWrites = CancellationCount()
    private var source: LocationSource!
    private var endpoint: ShareAddress!
    private var forced: [String] = []
    private var replies: [String: () -> Int] = [:]
    private var details: [String: Any] = [:]
    private var step = "setup"
    private var foreign: [PendingDeletion] = []

    @MainActor
    init(phase: CancellationPhase, run: UUID, began: ContinuousClock.Instant) throws {
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        let local = support.appending(path: "M24Cancellation/" + run.uuidString)
        let settingsURL = support.appending(path: "Settings.json")
        let bytes = try Data(contentsOf: settingsURL)
        let current = try JSONDecoder().decode(AppSettings.self, from: bytes)
        guard let location = current.locations.first(where: {
            $0.id.uuidString == "3A9DE695-8327-4D86-B393-2520E71A75D8"
        }), !location.removing, location.smbOnlyEditing == true, let write = location.activeWriteBookmark,
              let grant = current.shares.first(where: { $0.id == location.serverID }),
              let address = ShareAddress(grant.mountFrom), address.host == Self.host,
              address.share == Self.share, address.account == Self.account,
              grant.host == Self.host, grant.share == Self.share, grant.account == Self.account,
              let server = current.servers.first(where: { $0.id == grant.serverID }) else {
            throw CancellationCheck(label: "approved-fixture-write-grant")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: write, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        try demand(!stale && ShareAccess.filePath(url) == Self.mount, "fixture-write-bookmark")
        let probeRoot = RelativePath("probe-m24-cancellation-" + run.uuidString)!
        if let previous = phase.previous {
            identity = try JSONDecoder().decode(CancellationIdentity.self,
                from: Data(contentsOf: local.appending(path: "identity.json")))
            try demand(identity.run == run && UUID(uuidString: identity.owner)?.uuidString == identity.owner,
                       "private-run-identity")
            let data = try Data(contentsOf: local.appending(path: previous.rawValue + "-report.json"))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try demand(report?["passed"] as? Bool == true && report?["run"] as? String == run.uuidString,
                       "previous-phase-report")
            try demand(try Data(contentsOf: local.appending(path: "original-settings.bin")) == bytes,
                       "original-settings-between-phases")
        } else {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try demand(mkdir(local.path, 0o700) == 0, "exclusive-run-directory")
            identity = CancellationIdentity(run: run, owner: UUID().uuidString)
            try CancellationFiles.create(local.appending(path: "identity.json"), JSONEncoder().encode(identity))
            try CancellationFiles.create(local.appending(path: "original-settings.bin"), bytes)
            let paths = Self.keeps.map { KeepPath(path: probeRoot.string + "/" + $0.0, kind: $0.1) }
            try AppSettings(servers: [server], shares: [grant], locations: [],
                savedKeeps: [SavedKeepList(host: Self.host, share: Self.share, paths: paths)])
                .save(to: local.appending(path: "Settings.json"))
        }
        try CancellationFiles.create(local.appending(path: phase.rawValue + "-started.txt"),
            Data((ISO8601DateFormatter().string(from: .now) + "\n").utf8))
        self.phase = phase
        self.began = began
        root = probeRoot
        directory = local
        originalURL = settingsURL
        original = bytes
        bookmark = write
        store = SettingsStore(url: local.appending(path: "Settings.json"))
        access = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
    }

    func run() throws {
        var failure: Error?
        do {
            try validateFixture()
            foreign = try records().filter { $0.plan.owner != identity.owner }
            try openSource()
            switch phase {
            case .cancel: try cancelAtAdmission(close: false)
            case .joined: try cancelJoined()
            case .close: try cancelAtAdmission(close: true)
            case .unsettled: try automaticUnsettledAndCountedStops()
            case .stopped: try automaticSettlement(path: "close/Tree", uncertain: false)
            case .uncertain: try prepareUncertainty()
            case .reconcile: try automaticSettlement(path: "uncertain/file.txt", uncertain: true)
            }
            step = "final-evidence"
            try barrier()
            try healthWait()
            try verifyFixture()
            try verifyKeeps()
            try verifyInventory()
            try verifyCatalog()
            try observeReplies()
            try verifyRecoveryDrained()
            try demand(try records().filter { $0.plan.owner != identity.owner } == foreign,
                       "other-deletion-records-unchanged")
        } catch { failure = error }
        do {
            let equal = try Data(contentsOf: originalURL) == original
            details["originalSettingsEqual"] = equal
            try demand(equal, "original-settings-unchanged")
        } catch { if failure == nil { failure = error } }
        try report(failure)
        if let failure { throw failure }
    }

    private func cancelAtAdmission(close: Bool) throws {
        let path = close ? "close/Tree" : "cancel/Tree"
        try listRootAndTree(path)
        let request = try request(path), progress = Progress()
        let observed = CancellationReply<PendingDeletion>(), once = CancellationCount()
        source.onChange { [self] in
            guard once.add() == 1 else { return }
            observed.finish(Result {
                if close { source.close() } else { progress.cancel() }
                try demand(progress.isCancelled, "admission-progress-cancelled")
                if close {
                    try demand(source.deletionRecoveryLock.withLock { source.deletionStops.isEmpty },
                               "close-does-not-queue-token-stop-in-callback")
                }
                let admitted = try record(path)
                try demand(!admitted.isSettled && admitted.progress.next == 0
                    && admitted.progress.current == .prepared && admitted.progress.stopped == nil,
                    "admission-before-any-node")
                return admitted
            })
        }
        step = close ? "close-at-admission" : "cancel-at-admission"
        let reply = start(request, progress: progress, label: "primary", recursive: true)
        let admitted = try observed.wait("admission-callback", until: deadline()).get()
        try demand(admitted.plan.nodes.count == 3, "three-node-plan")
        let result = try reply.wait("primary", until: deadline())
        try failure(result, label: "primary") { error in
            close ? error is LocationError : error as? TransferError == .cancelled
        }
        try barrier()
        let durable = try record(path)
        if close {
            try demand(durable == admitted && !durable.isSettled && settingsCalls.count == 0,
                       "close-keeps-unsettled-plan")
            try demand(source.deletionRecoveryLock.withLock { source.deletionStops.isEmpty },
                       "close-does-not-queue-token-stop")
            forced.append("close-after-admission-without-token-stop")
        } else {
            try demand(durable.isComplete && durable.progress.stopped == 0
                && durable.summary[.stopped] == 3 && durable.confirmedDeletedKeepPaths.isEmpty,
                "cancel-stops-every-node")
            try demand(settingsWrites.count == 1, "cancel-settings-settled")
            forced.append("cancel-after-durable-admission-before-node-execution")
        }
        details["admissionCancelled"] = progress.isCancelled
    }

    private func cancelJoined() throws {
        try listRootAndTree("joined")
        let request = try request("joined/file.txt")
        step = "primary-awaiting-settings"
        let primary = start(request, progress: Progress(), label: "primary", recursive: false)
        defer { settingsGate.release() }
        let held = try settingsGate.entered.wait("settings-entered", until: deadline()).get()
        try demand(held.isSettled && !held.isComplete && held.selectedOutcome == .deleted,
                   "remote-deleted-before-joined-cancel")
        let progress = Progress()
        let joined = start(request, progress: progress, label: "joined", recursive: false)
        try barrier()
        let joinedCount = try lane {
            self.source.deletionRecoveries[held.id]?.replies.count ?? 0
        }
        try demand(joinedCount == 2 && primary.count == 0 && joined.count == 0, "joined-before-release")
        let gate = try blockLane()
        defer { gate.release() }
        progress.cancel()
        let stops = source.deletionRecoveryLock.withLock { source.deletionStops[held.id] ?? 0 }
        try demand(stops == 1 && primary.count == 0 && joined.count == 0, "joined-cancel-queued-stop")
        details["joinedQueuedStops"] = stops
        gate.release()
        try gate.ended.wait("joined-gate-ended", until: deadline()).get()
        try barrier()
        try demand(try record("joined/file.txt") == held && settingsWrites.count == 0
            && primary.count == 0 && joined.count == 0, "settings-still-delayed-after-stop")
        forced.append("joined-cancellation-while-settings-suspended")
        settingsGate.release()
        let first = try primary.wait("primary", until: deadline()).get()
        let second = try joined.wait("joined", until: deadline()).get()
        let durable = try record("joined/file.txt")
        try demand(first == durable && second == durable && durable.isComplete
            && durable.selectedOutcome == .deleted && settingsWrites.count == 1,
            "late-cancellation-success-requires-confirmed-deletion")
        try source.requireDeleted(durable)
        details["joinedCancellationResult"] = "success-after-confirmed-deletion-and-tombstone"
    }

    private func automaticUnsettledAndCountedStops() throws {
        let before = try record("close/Tree")
        try demand(!before.isSettled && before.progress.current == .prepared, "reopened-unsettled")
        step = "automatic-unsettled"
        source.retryDeletions()
        source.retryDeletions()
        try barrier()
        try pause(2)
        try barrier()
        let recoveries = try lane { self.source.deletionRecoveries.count }
        try demand(try record("close/Tree") == before && settingsCalls.count == 0 && recoveries == 0,
                   "automatic-retry-left-unsettled-plan-alone")
        try verifyInventory()
        forced.append("automatic-retry-of-unsettled-inventory")
        step = "counted-stops-before-close"
        let firstGate = try blockLane(), secondGate = CancellationLaneGate()
        defer { firstGate.release(); secondGate.release() }
        let first = trackedReply("stop-1", as: Void.self), second = trackedReply("stop-2", as: Void.self)
        source.stopDeletion(before.id) { first.finish($0) }
        secondGate.enqueue(on: access, until: deadline())
        source.stopDeletion(before.id) { second.finish($0) }
        try demand(source.deletionRecoveryLock.withLock { source.deletionStops[before.id] == 2 },
                   "two-explicit-stops-counted")
        source.close()
        try demand(first.count == 0 && second.count == 0, "stop-replies-blocked-on-lane")
        firstGate.release()
        try firstGate.ended.wait("first-gate-ended", until: deadline()).get()
        try secondGate.entered.wait("between-stops", until: deadline()).get()
        try first.wait("first-stop", until: deadline()).get()
        try demand(source.deletionRecoveryLock.withLock { source.deletionStops[before.id] == 1 }
            && second.count == 0, "second-stop-count-survives-first")
        let stopped = try record("close/Tree")
        try demand(stopped.isSettled && !stopped.isComplete && stopped.progress.stopped == 0
            && stopped.summary[.stopped] == 3, "first-stop-durable-after-close")
        secondGate.release()
        try secondGate.ended.wait("second-gate-ended", until: deadline()).get()
        try second.wait("second-stop", until: deadline()).get()
        try barrier()
        try demand(try record("close/Tree") == stopped && settingsCalls.count == 0
            && source.deletionRecoveryLock.withLock { source.deletionStops.isEmpty },
            "second-stop-idempotent-after-close")
        forced.append("two-counted-explicit-stops-survive-source-close")
        details["stopCounts"] = [2, 1, 0]
    }

    private func automaticSettlement(path: String, uncertain: Bool) throws {
        let before = try record(path)
        try demand(before.isSettled && !before.isComplete && before.hasUnconfirmed == uncertain,
                   "automatic-settlement-input")
        step = "automatic-settlement"
        source.retryDeletions()
        source.retryDeletions()
        try waitUntil("automatic-domain-completion") { try self.record(path).isComplete }
        try barrier()
        let after = try record(path)
        try demand(after.plan == before.plan && after.progress.next == before.progress.next
            && after.progress.current == before.progress.current && after.progress.stopped == before.progress.stopped
            && after.progress.exceptions == before.progress.exceptions && after.isPending == uncertain
            && settingsWrites.count == 1, "automatic-settlement-preserves-outcomes")
        forced.append(uncertain ? "automatic-settlement-of-unconfirmed-record" : "automatic-settlement-of-stopped-record")
        let calls = settingsCalls.count
        let replay = start(before.plan.request, progress: Progress(), label: "replay", recursive: !uncertain)
        try failure(try replay.wait("settled-replay", until: deadline()), label: "replay") { error in
            uncertain ? error as? ItemDeletionError == .unresolved : error as? TransferError == .cancelled
        }
        try barrier()
        try demand(try record(path) == after && settingsCalls.count == calls, "replay-no-new-settlement")
    }

    private func prepareUncertainty() throws {
        try listRootAndTree("uncertain")
        let request = try request("uncertain/file.txt")
        step = "uncertain-admission"
        let admitted = try lane {
            try self.source.prepareDeletionOnLane(request, recursive: false, progress: Progress()) { _ in }
        }
        try demand(admitted.plan.nodes.count == 1, "uncertain-one-node")
        let fired = CancellationCount()
        step = "lost-close-reply"
        try lane { [self] in
            var current = try record("uncertain/file.txt")
            let write = try source.editNamespace.perform { () -> Data in
                try source.editNamespace.requireSettled(excluding: current.id)
                return try source.renameAccess()
            }
            do {
                try source.withWriteSession(write) { share, _ in
                    try RecursiveDeletionTransaction.run(&current, outbox: LocationSource.deletionOutbox(),
                        endpoint: endpoint, owner: identity.owner) { body in
                        let remote = try SMBEdit(endpoint: endpoint, folder: .root, root: share.root,
                                                 progress: Progress())
                        try body(CancellationLostClose(remote, fired: fired))
                    }
                }
                throw CancellationCheck(label: "lost-close-not-reached")
            } catch CancellationInjection.lostCloseReply {
                try demand(fired.count == 1, "lost-close-fired-once")
            }
        }
        try healthWait()
        let inFlight = try record("uncertain/file.txt")
        try demand(!inFlight.isSettled && inFlight.progress.current == .attempting,
                   "lost-close-remains-in-flight")
        let gate = try blockLane()
        defer { gate.release() }
        let stop = trackedReply("uncertain-stop", as: Void.self)
        source.stopDeletion(inFlight.id) { stop.finish($0) }
        source.close()
        gate.release()
        try gate.ended.wait("uncertain-gate-ended", until: deadline()).get()
        try stop.wait("uncertain-stop", until: deadline()).get()
        try barrier()
        let after = try record("uncertain/file.txt")
        try demand(after.isSettled && !after.isComplete && after.isPending && after.hasUnconfirmed
            && after.selectedOutcome == .unconfirmed && settingsCalls.count == 0,
            "stopped-lost-reply-retains-uncertainty")
        forced.append("lost-close-reply-followed-by-explicit-stop-and-close")
    }

    @MainActor
    private func cleanSettings(_ record: PendingDeletion, paths: [KeepPath]) throws {
        let confirmed = record.plan.nodes.indices.filter { record.outcome(at: $0) == .deleted }.map {
            KeepPath(path: record.plan.nodes[$0].path, kind: record.plan.nodes[$0].evidence.kind)
        }
        try demand(record.plan.owner == identity.owner && record.isSettled && confirmed == paths,
                   "settings-confirmed-paths-only")
        try demand(try LocationSource.deletionOutbox().reload(record) == record, "settings-durable-record")
        try store.update { try $0.removeKeptItems(paths, host: Self.host, share: Self.share) }
        settingsWrites.add()
    }

    private func openSource() throws {
        let url = directory.appending(path: identity.owner + ".sqlite")
        let catalog: Catalog
        if phase == .cancel {
            let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
            for storage in ["Edits/", "Uploads/"] {
                try demand(!FileManager.default.fileExists(atPath: support.appending(path: storage + identity.owner).path),
                           "fresh-domain-storage")
            }
            try demand(try LocationSource.renameOutbox().intents().allSatisfy {
                !$0.domains.contains(identity.owner)
            }, "fresh-domain-renames")
            try demand(try records().allSatisfy { !$0.plan.views.contains { $0.domain == identity.owner } },
                       "fresh-private-domain")
            catalog = try Catalog.create(at: url, domainID: identity.owner, rootName: "M24 cancellation probe")
        } else { catalog = try Catalog.openWriter(at: url, domainID: identity.owner) }
        source = LocationSource(domainID: identity.owner, folder: root, catalog: catalog, access: access,
            renameSettings: { _ in throw UploadError.readOnly }, deletionSettings: { [weak self] record, paths in
                guard let self else { throw LocationError.catalogClosed }
                let call = self.settingsCalls.add()
                if self.phase == .joined && call == 1 { await self.settingsGate.wait(record) }
                try await self.cleanSettings(record, paths: paths)
            }, signal: { _ in })
        try source.configureWriteMode(bookmark, confirmed: true)
    }

    private func validateFixture() throws {
        try demand(access.mountPath() == Self.mount, "existing-loopback-mount")
        endpoint = try access.withSession { session, _ in
            try demand(session.identity.typeName == "smbfs", "native-smbfs")
            guard let address = ShareAddress(session.identity.mountFrom), address.host == Self.host,
                  address.share == Self.share, address.account == Self.account else {
                throw CancellationCheck(label: "native-endpoint")
            }
            let fd = try session.openFolder(root)
            defer { Darwin.close(fd) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            try demand(fcntl(fd, F_GETPATH, &buffer) == 0, "native-root-path")
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            try demand(path == Self.mount + "/" + root.string, "native-root-path")
            let expected = Data(("tinymounter-m24-cancellation:" + identity.run.uuidString + "\n").utf8)
            try demand(try readNative(fd, "marker.txt") == expected, "fixture-marker")
            return address
        }
    }

    private func verifyFixture() throws {
        let removed = Set(phase == .cancel ? [] : ["joined/file.txt"])
            .union([.uncertain, .reconcile].contains(phase) ? ["uncertain/file.txt"] : [])
        try access.withSession { session, _ in
            let fd = try session.openFolder(root)
            defer { Darwin.close(fd) }
            for name in Self.files {
                if phase == .uncertain && name == "uncertain/file.txt" {
                    details["nativeAbsenceDeferredToBackingAudit"] = true
                    continue
                }
                if removed.contains(name) {
                    var info = stat()
                    try demand(fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW_ANY) != 0 && errno == ENOENT,
                               "expected-native-absence")
                } else {
                    let expected = Data(String(repeating: "m24-cancellation:" + identity.run.uuidString
                        + ":" + name + "\n", count: 4).utf8)
                    try demand(try readNative(fd, name) == expected, "native-survivor-bytes")
                }
            }
        }
        details["nativeFixtureMatches"] = true
    }

    private func readNative(_ root: Int32, _ path: String) throws -> Data {
        let fd = openat(root, path, O_RDONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("read cancellation fixture") }
        defer { Darwin.close(fd) }
        var info = stat()
        try demand(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= 64 << 10, "bounded-fixture-file")
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        try demand(count == data.count, "complete-fixture-read")
        return data
    }

    private func listRootAndTree(_ path: String) throws {
        var folder = ""
        try list(folder)
        for component in RelativePath(path)!.components {
            folder = folder.isEmpty ? component : folder + "/" + component
            try list(folder)
        }
    }

    private func list(_ path: String) throws {
        try healthWait()
        let id = try path.isEmpty ? Catalog.rootItemID : row(path).id
        let reply = CancellationReply<ListReceipt>()
        source.list(id, requestID: UUID(), bounded: false) { reply.finish($0) }
        let receipt = try reply.wait("listing", until: deadline()).get()
        try demand(receipt.skipped == 0, "complete-catalog-listing")
    }

    private func row(_ path: String) throws -> CatalogRow {
        try source.withCatalog { catalog in
            var id = Catalog.rootItemID
            for name in RelativePath(path)!.components {
                guard let child = try catalog.liveChild(parent: id, nameKey: NameKey(name)),
                      child.name.utf8.elementsEqual(name.utf8) else {
                    throw CancellationCheck(label: "live-catalog-path")
                }
                id = child.id
            }
            guard let item = try catalog.item(id: id) else { throw CancellationCheck(label: "catalog-item") }
            return item
        }
    }

    private func request(_ path: String) throws -> DeletionRequest {
        let item = try row(path)
        return DeletionRequest(item: item.id, contentVersion: item.contentVersion, metadataVersion: item.metadataVersion)
    }

    private func start(_ request: DeletionRequest, progress: Progress, label: String,
                       recursive: Bool) -> CancellationReply<PendingDeletion> {
        let reply = trackedReply(label, as: PendingDeletion.self), started = CancellationCount()
        replies[label + "-started"] = { started.count }
        source.deleteItem(request, recursive: recursive, progress: progress,
                          started: { started.add() }) { reply.finish($0) }
        return reply
    }

    private func trackedReply<T>(_ label: String, as type: T.Type) -> CancellationReply<T> {
        let reply = CancellationReply<T>()
        replies[label] = { reply.count }
        return reply
    }

    private func failure<T>(_ result: Result<T, Error>, label: String, matching: (Error) -> Bool) throws {
        guard case .failure(let error) = result else { throw CancellationCheck(label: label + "-false-success") }
        details[label + "Error"] = cancellationError(error)
        try demand(matching(error), label + "-unexpected-error")
    }

    private func records() throws -> [PendingDeletion] { try LocationSource.deletionOutbox().records() }

    private func record(_ path: String) throws -> PendingDeletion {
        let selected = root.string + "/" + path
        let matching = try records().filter { $0.plan.owner == identity.owner && $0.plan.selected.path == selected }
        try demand(matching.count == 1, "unique-durable-record")
        return matching[0]
    }

    private func verifyInventory() throws {
        let all = try records(), owned = all.filter { $0.plan.owner == identity.owner }
        let expected = phase == .cancel ? 1 : phase == .joined ? 2 : [.uncertain, .reconcile].contains(phase) ? 4 : 3
        try demand(owned.count == expected, "durable-record-count")
        for record in owned {
            try demand(record.plan.views.count == 1 && record.plan.views[0].domain == identity.owner
                && record.plan.views[0].folder == root.string && record.plan.endpoint.matches(endpoint)
                && record.plan.nodes.allSatisfy { $0.path.hasPrefix(root.string + "/") }, "owned-record-boundary")
        }
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter")
        let editName = EditOutbox.deletionGuardName, renameName = FileRenameOutbox.deletionGuardName
        let edit = support.appending(path: "Edits/" + identity.owner + "/" + editName)
        let rename = support.appending(path: "Renames/" + renameName)
        func guardMatches(_ url: URL, name: String, needed: Bool) -> Bool {
            if needed { return DeletionGuard.isExact(url, named: name) }
            var info = stat()
            return lstat(url.path, &info) != 0 && errno == ENOENT
        }
        try demand(guardMatches(edit, name: editName, needed: owned.contains(where: \.isPending)), "domain-guard")
        try demand(guardMatches(rename, name: renameName, needed: all.contains(where: \.isPending)), "shared-guard")
        details["guardsMatchInventory"] = true
        details["inventory"] = owned.map { record -> [String: Any] in
            ["id": record.id.uuidString, "nodes": record.plan.nodes.count, "next": record.progress.next,
             "current": record.progress.current.rawValue, "stopped": record.progress.stopped as Any? ?? NSNull(),
             "settled": record.isSettled, "complete": record.isComplete, "pending": record.isPending,
             "unconfirmed": record.hasUnconfirmed, "finishedViews": record.progress.finishedDomains.count,
             "outcomes": record.plan.nodes.indices.map { record.outcome(at: $0)?.rawValue ?? "pending" }]
        }
    }

    private func verifyKeeps() throws {
        let expected = Set(Self.keeps.filter { phase == .cancel || $0.0 != "joined/file.txt" }.map {
            KeepPath(path: root.string + "/" + $0.0, kind: $0.1)
        })
        let actual = try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { () -> Set<KeepPath> in
                guard let settings = store.settings else { throw CancellationCheck(label: "private-settings-ready") }
                return Set(settings.savedKeeps.flatMap(\.paths))
            }
        }
        try demand(actual == expected, "only-confirmed-keeps-removed")
        details["keepsMatchOutcomes"] = true
    }

    private func verifyCatalog() throws {
        let catalog = try Catalog.open(at: directory.appending(path: identity.owner + ".sqlite"),
                                       domainID: identity.owner)
        for record in try records().filter({ $0.plan.owner == identity.owner }) {
            for item in record.plan.views[0].items {
                guard let row = try catalog.item(id: item.item) else {
                    throw CancellationCheck(label: "admitted-catalog-row-retained")
                }
                let shouldDelete = record.selectedOutcome == .deleted
                    || (record.hasUnconfirmed && record.isComplete)
                try demand(row.deleted == shouldDelete, "catalog-outcome")
                if !shouldDelete {
                    let path = try catalog.relativePath(of: row.id)
                    try demand(row.contentVersion == item.contentVersion
                        && path?.string == item.path, "survivor-catalog-binding")
                }
            }
        }
        details["catalogMatchesOutcomes"] = true
    }

    private func observeReplies() throws {
        try pause(2)
        try barrier()
        for (label, count) in replies { try demand(count() == 1, "exactly-once:" + label) }
        let expected = [.cancel, .joined, .stopped, .reconcile].contains(phase) ? 1 : 0
        try demand(settingsCalls.count == expected && settingsWrites.count == expected,
                   "exact-settings-call-and-write-counts")
        details["replyObservationSeconds"] = 2
    }

    private func verifyRecoveryDrained() throws {
        try lane { [self] in
            try demand(source.deletionRecoveries.isEmpty, "recoveries-drained")
            try demand(source.deletionRecoveryLock.withLock {
                source.deletionStops.isEmpty && source.deletionCancellations.isEmpty
                    && source.deletionProgress.isEmpty
            }, "recovery-observers-and-progress-drained")
        }
        details["recoveryStateDrained"] = true
    }

    private func lane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        try healthWait()
        let reply = CancellationReply<T>()
        access.enqueue { reply.finish(Result { try body() }) }
        return try reply.wait("lane", until: deadline()).get()
    }

    private func barrier() throws { try lane {} }

    private func blockLane() throws -> CancellationLaneGate {
        try healthWait()
        let gate = CancellationLaneGate()
        gate.enqueue(on: access, until: deadline())
        try gate.entered.wait("lane-gate-entered", until: deadline()).get()
        return gate
    }

    private func deadline() -> DispatchTime {
        .now() + max(0, 520 - began.duration(to: .now) / .seconds(1))
    }

    private func pause(_ seconds: TimeInterval) throws {
        try demand(began.duration(to: .now) < .seconds(520 - seconds), "phase-budget")
        Thread.sleep(forTimeInterval: seconds)
    }

    private func waitUntil(_ label: String, _ predicate: () throws -> Bool) throws {
        while try !predicate() {
            try demand(began.duration(to: .now) < .seconds(510), "timeout:" + label)
            try pause(0.1)
        }
    }

    // Expected slow failures recover through ShareAccess's own probes, outside its lane.
    private func healthWait() throws {
        let began = ContinuousClock.now
        while let refusal = access.refusal() {
            guard refusal == .serverUnreachable else { throw refusal }
            try demand(began.duration(to: .now) < .seconds(30), "share-health-timeout")
            try pause(0.25)
        }
        let seconds = began.duration(to: .now) / .seconds(1)
        if seconds >= 0.25 { details["healthWaitSeconds"] = (details["healthWaitSeconds"] as? Double ?? 0) + seconds }
    }

    private func report(_ failure: Error?) throws {
        var output = details
        output["run"] = identity.run.uuidString
        output["phase"] = phase.rawValue
        output["date"] = ISO8601DateFormatter().string(from: .now)
        output["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        output["cache"] = "uncontrolled"
        output["seconds"] = began.duration(to: .now) / .seconds(1)
        output["passed"] = failure == nil
        output["requiresSuccessfulProcessExit"] = true
        output["forced"] = forced
        output["replyCounts"] = replies.mapValues { $0() }
        output["settingsCalls"] = settingsCalls.count
        output["settingsWrites"] = settingsWrites.count
        output["untested"] = Self.missing
        if let failure {
            output["failedStep"] = step
            output["error"] = cancellationError(failure)
        }
        try CancellationFiles.create(directory.appending(path: phase.rawValue + "-report.json"),
            JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]))
    }
}
