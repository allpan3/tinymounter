import CryptoKit
import Darwin
import Foundation

// Replace TinyMounterApp.swift only in the disposable signed archive.
@main
enum M23SaveRecoveryHelper {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 5, let mode = M23Mode(args),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  let location = UUID(uuidString: args[4]) else { throw UploadError.invalidRequest }
            let caseID = args[2]
            let originalURL = URL.applicationSupportDirectory.appending(path: "tinymounter/Settings.json")
            let original = try Data(contentsOf: originalURL)
            let current = try JSONDecoder().decode(AppSettings.self, from: original)
            guard let record = current.locations.first(where: { $0.id == location }),
                  !record.removing, let bookmark = record.activeWriteBookmark,
                  let grant = current.shares.first(where: { $0.id == record.grantID }),
                  let endpoint = ShareAddress(grant.mountFrom), endpoint.host == "127.0.0.1",
                  endpoint.share == "tinymounter-m19-edit-test", endpoint.account == "_tinymounter_m19",
                  grant.host == endpoint.host, grant.share == endpoint.share, grant.account == endpoint.account,
                  let server = current.servers.first(where: { $0.id == grant.serverID }) else {
                throw UploadError.readOnly
            }
            var stale = false
            let scoped = try URL(resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            guard !stale, ShareAccess.filePath(scoped) == "/Volumes/tinymounter-m19-edit-test" else {
                throw UploadError.readOnly
            }
            let fixtureName = "probe-m23-final" + (args[1] == "--m23-fresh" ? "-" + run.uuidString : "")
            let parent = URL.applicationSupportDirectory.appending(path: "tinymounter/" + fixtureName)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let local = parent.appending(path: "caller-" + caseID + (mode.claim.isEmpty ? "" : "-" + mode.claim))
            guard mkdir(local.path, 0o700) == 0 else { throw UploadError.unresolved }
            let settings = local.appending(path: "Settings.json")
            try AppSettings(servers: [server], shares: [grant], locations: []).save(to: settings)
            let store = SettingsStore(url: settings)
            let access = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
            let folder = RelativePath(fixtureName)!, domain = UUID().uuidString
            let catalog = try Catalog.create(at: local.appending(path: "catalog.sqlite"),
                                             domainID: domain, rootName: "M23 recovery probe")
            let source = LocationSource(domainID: domain, folder: folder, catalog: catalog,
                                        access: access, renameSettings: { _ in }, signal: { _ in })
            defer { source.close(); access.editNamespace.unregister(domain) }
            try source.configureWriteMode(bookmark)
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                source.runM23FinalProbe(mode, caseID: caseID, run: run) { reply.resume(with: $0) }
            }
            guard try Data(contentsOf: originalURL) == original else { throw UploadError.unresolved }
            if case .inspection = mode {
                print("M23 final-state inspection passed: " + caseID + "; historical preservation remains unverified")
            } else {
                print("M23 recovery probe passed: " + caseID
                      + (mode.claim.isEmpty ? "" : " " + mode.claim + ", with limits in its report"))
            }
        } catch {
            let failure = error as NSError
            print("M23 recovery probe failed: " + failure.domain + " " + String(failure.code))
            exit(1)
        }
    }
}

/// A continuation resumes one interrupted case from its exact private state; it never re-admits.
enum M23Mode: Sendable {
    case original
    case continuation
    case inspection(M23Pins)

    init?(_ args: [String]) {
        switch (args[1], args[2], args.count) {
        case ("--m23-final", let caseID, 5) where ["c01", "c02", "c03", "c04"].contains(caseID): self = .original
        case ("--m23-fresh", "c03", 5): self = .original
        case ("--m23-continue", "c02", 5): self = .continuation
        case ("--m23-inspect", "c03", 8):
            guard let pins = M23Pins(retired: args[5], retiredStage: args[6], occupant: args[7]) else { return nil }
            self = .inspection(pins)
        default: return nil
        }
    }

    var claim: String {
        switch self {
        case .original: ""
        case .continuation: "continue"
        case .inspection: "inspect"
        }
    }
}

/// Parent-kept evidence: a record UUID and SMB identities as FILEID:BIRTH_MICROSECONDS, or "-".
struct M23Pins: Sendable {
    var retired: UUID?
    var retiredStage: EditFileIdentity?
    var occupant: EditFileIdentity?

    init?(retired: String, retiredStage: String, occupant: String) {
        if retired != "-" {
            guard let id = UUID(uuidString: retired), id.uuidString == retired else { return nil }
            self.retired = id
        }
        if retiredStage != "-" {
            guard let identity = Self.identity(retiredStage) else { return nil }
            self.retiredStage = identity
        }
        if occupant != "-" {
            guard let identity = Self.identity(occupant) else { return nil }
            self.occupant = identity
        }
    }

    private static func identity(_ text: String) -> EditFileIdentity? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let fileID = UInt64(parts[0]), let birth = UInt64(parts[1]),
              text == "\(fileID):\(birth)" else { return nil }
        return try? EditFileIdentity(fileID: fileID, birthMicroseconds: birth)
    }
}

extension LocationSource {
    func runM23FinalProbe(_ mode: M23Mode, caseID: String, run: UUID,
                          completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        access.enqueue { [self] in
            completion(Result { try editNamespace.perform { try uploadLock.withLock {
                guard !mutationsSuspended, let bookmark = writeBookmark,
                      ["probe-m23-final", "probe-m23-final-" + run.uuidString].contains(folder.string) else {
                    throw UploadError.readOnly
                }
                try editNamespace.requireSettled()
                let progress = Progress()
                try withWriteSession(bookmark, progress: progress) { session, root in
                    guard session.identity.typeName == "smbfs",
                          let endpoint = ShareAddress(session.identity.mountFrom),
                          endpoint.host == "127.0.0.1", endpoint.account == "_tinymounter_m19",
                          endpoint.share == "tinymounter-m19-edit-test" else { throw UploadError.readOnly }
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(root, F_GETPATH, &path) == 0 else { throw UploadError.readOnly }
                    let nativePath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    guard nativePath == "/Volumes/tinymounter-m19-edit-test/" + folder.string else {
                        throw UploadError.readOnly
                    }
                    let marker = try ReadOnlyFile(directoryFD: root, relativePath: RelativePath("marker.txt")!,
                                                  expected: session.identity)
                    let expected = Data(("tinymounter-m23-final:" + run.uuidString + "\n").utf8)
                    var bytes = Data(count: expected.count)
                    let count = bytes.withUnsafeMutableBytes { pread(marker.descriptor, $0.baseAddress, $0.count, 0) }
                    guard marker.snapshot.size == expected.count, count == expected.count, bytes == expected else {
                        throw UploadError.readOnly
                    }
                    try M23FinalProbe.run(mode, caseID, run: run, endpoint: endpoint, folder: folder, root: root,
                                          identity: session.identity, progress: progress)
                }
            } } })
        }
    }
}

private enum M23FinalProbe {
    enum Failure: Error, Equatable { case assertion, expectedFailure, injected }

    /// Names the step in progress, so a report says where a probe stopped without naming paths.
    final class Trace {
        private(set) var step: String?
        private(set) var completed: [String] = []
        private(set) var connections: [[String: Any]] = []
        var observed: [String: Any] = [:]

        func enter(_ next: String?) {
            if let step { completed.append(step) }
            step = next
        }

        func connection(_ label: String, attempt: Int, started: Date, error: Error?) {
            var entry: [String: Any] = ["step": label, "attempt": attempt,
                                        "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
            if let failure = error.map({ $0 as NSError }) {
                entry["errorDomain"] = failure.domain
                entry["errorCode"] = failure.code
            }
            connections.append(entry)
        }
    }

    final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64) { self.bytes = bytes }
        func read() -> Int64 { lock.withLock { bytes } }
        func set(_ bytes: Int64) { lock.withLock { self.bytes = bytes } }
    }

    final class Fault: EditRemote {
        let remote: SMBEdit
        var beforeMove = false
        var beforeRemoval: String?
        var afterRemoval: String?
        var inspected: [String] = []
        var removed: [String] = []
        init(_ remote: SMBEdit) { self.remote = remote }
        func stage(path: String, contents: URL, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            try remote.stage(path: path, contents: contents, created: created)
        }
        func inspect(path: String, original: Bool) throws -> EditFileVersion? {
            inspected.append(path)
            return try remote.inspect(path: path, original: original)
        }
        func backup(original: String, path: String, created: (EditFileIdentity) throws -> Void) throws -> EditFileVersion {
            try remote.backup(original: original, path: path, created: created)
        }
        func move(source: String, destination: String) throws {
            if beforeMove { throw Failure.injected }
            try remote.move(source: source, destination: destination)
        }
        func update(work: String, stage: String, size: Int64) throws {
            try remote.update(work: work, stage: stage, size: size)
        }
        func removeArtifact(path: String, version: EditFileVersion) throws {
            removed.append(path)
            if path == beforeRemoval { throw Failure.injected }
            try remote.removeArtifact(path: path, version: version)
            if path == afterRemoval { throw Failure.injected }
        }
        func proveAbsent(path: String) throws { try remote.proveAbsent(path: path) }
    }

    struct Share {
        static let connectAttempts = 3
        let endpoint: ShareAddress
        let folder: RelativePath
        let root: Int32
        let identity: MountIdentity
        let progress: Progress
        let trace: Trace

        /// Retries only a failed connection; a failed operation is reported, never repeated.
        func connect(_ label: String, progress: Progress) throws -> SMBEdit {
            var attempt = 1
            trace.enter(label + ".connect")
            while true {
                let started = Date()
                do {
                    let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
                    trace.connection(label, attempt: attempt, started: started, error: nil)
                    return remote
                } catch {
                    trace.connection(label, attempt: attempt, started: started, error: error)
                    guard attempt < Self.connectAttempts, !progress.isCancelled else { throw error }
                }
                Thread.sleep(forTimeInterval: 2)
                attempt += 1
            }
        }

        func withRemote<T>(_ label: String, path: String, progress: Progress? = nil,
                           _ body: (SMBEdit) throws -> T) throws -> T {
            let remote = try connect(label, progress: progress ?? self.progress)
            trace.enter(label + ".ancestors")
            try remote.protectAncestors(of: path)
            trace.enter(label)
            return try body(remote)
        }

        func names(_ caseID: String) throws -> Set<String> {
            let listing = try DirectoryListing.list(locationRoot: root, relativePath: RelativePath(caseID)!,
                                                    expected: identity, limit: 64)
            try M23FinalProbe.require(listing.unreadable.isEmpty && listing.collisionLosers.isEmpty
                && listing.skipped == DirectoryListing.Skipped())
            try M23FinalProbe.require(listing.entries.allSatisfy { $0.kind == .file })
            return Set(listing.entries.map(\.name))
        }
    }

    struct Fixture {
        let share: Share
        let path: String
        let local: URL
        let output: URL
        let item: String
        let original: EditFileVersion
        let neighbor: EditFileVersion
        let base: EditBaseReceipt
        let outbox: EditOutbox
        var root: Int32 { share.root }
        var identity: MountIdentity { share.identity }
        var trace: Trace { share.trace }

        init(_ caseID: String, share: Share, local: URL) throws {
            let path = caseID + "/document.txt"
            self.share = share
            self.path = path
            self.local = local
            output = local
            item = UUID().uuidString
            outbox = try EditOutbox(directory: local.appending(path: "Outbox"))
            let versions: (EditFileVersion, EditFileVersion) = try share.withRemote("admit", path: path) { remote in
                (try remote.readVersion(path: path), try remote.readVersion(path: caseID + "/neighbor.txt"))
            }
            original = versions.0
            neighbor = versions.1
            base = try EditBaseReceipt(item: item, version: original)
            try outbox.storeBase(base)
        }

        // A continuation adopts the recorded item and base receipt; it never stores a new base.
        init(resuming caseID: String, share: Share, local: URL, output: URL, outbox: EditOutbox,
             item: String, base: EditBaseReceipt, neighbor: EditFileVersion) {
            self.share = share
            path = caseID + "/document.txt"
            self.local = local
            self.output = output
            self.item = item
            original = base.version
            self.neighbor = neighbor
            self.base = base
            self.outbox = outbox
        }

        func withRemote<T>(_ label: String, progress: Progress? = nil, _ body: (SMBEdit) throws -> T) throws -> T {
            try share.withRemote(label, path: path, progress: progress, body)
        }

        func prepare(_ bytes: Data, checkSpace: ((Int64) throws -> Void)? = nil) throws -> PendingEdit {
            let input = output.appending(path: UUID().uuidString + ".input")
            try bytes.write(to: input, options: .withoutOverwriting)
            return try outbox.prepare(item: item, parent: Catalog.rootItemID, path: RelativePath(path)!,
                                      baseVersion: base.contentVersion, failOnConflict: false, contents: input,
                                      progress: Progress(), checkSpace: checkSpace)
        }

        func finish(_ record: inout PendingEdit) throws {
            try withRemote("finish") { remote in
                trace.enter("finish.publish")
                try EditTransaction.publish(&record, outbox: outbox, remote: remote)
                try M23FinalProbe.require(record.state == .published)
                trace.enter("finish.complete")
                try outbox.complete(&record, item: record.item)
                trace.enter("finish.cleanup")
                try EditTransaction.cleanup(&record, outbox: outbox, remote: remote)
            }
            trace.enter("finish.result")
            try M23FinalProbe.require(record.state == .completed && !record.recoveryRetained && !record.conflict)
        }

        func export(_ record: PendingEdit, expected: Data) throws {
            let url = output.appending(path: UUID().uuidString + ".export")
            try outbox.export(record, to: url)
            try M23FinalProbe.require(Data(contentsOf: url) == expected)
        }

        func verifyRemote(_ record: PendingEdit) throws {
            try withRemote("verify-remote") { remote in
                let final = try remote.readVersion(path: path)
                try M23FinalProbe.require(final.identity == original.identity && final.size == record.size
                                         && final.digest == record.digest)
                let other = try remote.readVersion(path: path.replacingOccurrences(of: "document.txt", with: "neighbor.txt"))
                try M23FinalProbe.require(other == neighbor)
            }
        }

        func reopened() throws -> EditOutbox { try EditOutbox(directory: local.appending(path: "Outbox")) }
    }

    static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.assertion }
    }

    static func failure(_ body: () throws -> Void) throws -> Error {
        switch Result(catching: body) {
        case .success: throw Failure.expectedFailure
        case .failure(let error): return error
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ mode: M23Mode, _ caseID: String, run: UUID, endpoint: ShareAddress, folder: RelativePath,
                    root: Int32, identity: MountIdentity, progress: Progress) throws {
        guard ["c01", "c02", "c03", "c04"].contains(caseID) else { throw Failure.assertion }
        let parent = URL.applicationSupportDirectory.appending(path: "tinymounter/" + folder.string)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let local = parent.appending(path: caseID), output: URL
        if mode.claim.isEmpty {
            guard mkdir(local.path, 0o700) == 0 else { throw Failure.assertion }
            output = local
        } else {
            // A continuation keeps the case's evidence in place and writes only inside its own claim.
            try requireDirectory(local)
            output = local.appending(path: mode.claim)
            guard mkdir(output.path, 0o700) == 0 else { throw Failure.assertion }
            try syncDirectory(local)
        }
        let share = Share(endpoint: endpoint, folder: folder, root: root, identity: identity,
                          progress: progress, trace: Trace())
        let result = Result {
            switch mode {
            case .original:
                let fixture = try Fixture(caseID, share: share, local: local)
                switch caseID {
                case "c01": try admission(fixture)
                case "c02": try partialStage(fixture)
                case "c03": try cleanup(fixture, loseReply: false)
                default: try cleanup(fixture, loseReply: true)
                }
            case .continuation: try continuePartialStage(share, local: local, output: output)
            case .inspection(let pins): try inspectCleanup(share, local: local, pins: pins)
            }
        }
        var report: [String: Any] = ["case": caseID, "mode": mode.claim.isEmpty ? "final" : mode.claim,
                                     "run": run.uuidString, "date": ISO8601DateFormatter().string(from: Date()),
                                     "cache": "uncontrolled", "injected": mode.claim.isEmpty, "passed": false]
        switch result {
        case .success:
            share.trace.enter(nil)
            if case .inspection = mode {
                report["inspectionPassed"] = true
            } else {
                report["passed"] = true
                if caseID == "c03" { report["historicalOccupantPreservationVerified"] = true }
            }
        case .failure(let error):
            let nsError = error as NSError
            report["failedStep"] = share.trace.step ?? "setup"
            report["errorDomain"] = nsError.domain
            report["errorCode"] = nsError.code
            if let status = SMBEdit.serverStatus(error) { report["ntStatus"] = String(format: "0x%08X", status) }
        }
        report["completedSteps"] = share.trace.completed
        report["requiresSuccessfulProcessExit"] = true
        if case .inspection = mode {
            report["historicalOccupantPreservationVerified"] = false
            if report["inspectionPassed"] == nil { report["inspectionPassed"] = false }
        }
        report["connections"] = share.trace.connections
        if !share.trace.observed.isEmpty { report["observed"] = share.trace.observed }
        let gaps = limits(mode)
        if !gaps.isEmpty { report["limits"] = gaps }
        try writeReport(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                        to: output.appending(path: "report.json"))
        try result.get()
    }

    static func limits(_ mode: M23Mode) -> [String] {
        switch mode {
        case .original:
            return []
        case .continuation:
            return ["This continuation does not identify the original failure; the original report keeps it.",
                    "The original run never recorded the neighbor identity; equality covers this continuation.",
                    "The original run's native stage inode is lost; inode stability covers this continuation."]
        case .inspection(let pins):
            var notes = ["The original run left no report, so its final occupant and pending checks have no result.",
                         "Final-state inspection cannot prove historical occupant preservation through cleanup, even with identity pins.",
                         "The original full occupant version, including metadata, was not persisted; c03 acceptance remains incomplete.",
                         "The original run never recorded the neighbor identity; only its contents are checked."]
            notes.append(pins.occupant == nil
                ? "The original run never recorded the occupant identity; ownership rests on name, bytes and time."
                : "The occupant identity matches a parent-kept pin, not a record from the original run.")
            if pins.retired == nil {
                notes.append("Without a pinned retired record, the occupant is tied to it only as the sole stage.")
            }
            if pins.retiredStage == nil {
                notes.append("Without a pinned retired stage, the occupant differs from it only by creation time.")
            }
            return notes
        }
    }

    /// Created once and flushed, so no later process can replace or silently lose a report.
    static func writeReport(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create probe report") }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("write probe report") }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open probe directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError("sync probe directory") }
    }

    static func requireDirectory(_ url: URL) throws {
        var value = stat()
        try require(lstat(url.path, &value) == 0)
        try require(value.st_mode & S_IFMT == S_IFDIR)
    }

    // EditOutbox creates missing directories, so a continuation proves they exist first.
    static func existingOutbox(_ local: URL) throws -> EditOutbox {
        let directory = local.appending(path: "Outbox")
        try requireDirectory(directory)
        try requireDirectory(directory.appending(path: "Contents"))
        return try EditOutbox(directory: directory)
    }

    static func receipts(_ local: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: local.appending(path: "Outbox").path)
            .filter { $0.hasSuffix(".base") }.count
    }

    static func admission(_ fixture: Fixture) throws {
        let trace = fixture.trace
        trace.enter("reserve")
        try require(DownloadSpace.reserveBytes == 2 << 30)
        let firstBytes = Data("first complete save\n".utf8), nextBytes = Data(repeating: 78, count: 4096)
        trace.enter("prepare-first")
        let first = try fixture.prepare(firstBytes)
        trace.enter("reserve-loss-begin")
        let required = DownloadSpace.reserveBytes + Int64(nextBytes.count) * 2 + 65536
        let capacity = Capacity(required - 1), id = UUID()
        let space = DownloadSpace { capacity.read() }
        try require(DownloadSpace.isFull(try failure { try space.begin(id, bytes: Int64(nextBytes.count)) }))
        try require(fixture.outbox.records() == [first])
        try fixture.export(first, expected: firstBytes)
        trace.enter("reserve-loss-check")
        capacity.set(required)
        try space.begin(id, bytes: Int64(nextBytes.count))
        defer { space.end(id) }
        capacity.set(required - 1)
        try require(DownloadSpace.isFull(try failure {
            _ = try fixture.prepare(nextBytes) { try space.check(id, completedBytes: $0) }
        }))
        try require(fixture.outbox.records() == [first])
        trace.enter("reserve-loss-copy")
        capacity.set(required)
        try require(DownloadSpace.isFull(try failure {
            _ = try fixture.prepare(nextBytes) { completed in
                if completed > 0 { capacity.set(DownloadSpace.reserveBytes - 1) }
                try space.check(id, completedBytes: completed)
            }
        }))
        try fixture.export(first, expected: firstBytes)
        trace.enter("reopen")
        let reopened = try fixture.reopened()
        guard var latest = try reopened.order(item: fixture.item).head else { throw Failure.assertion }
        try require(latest.id != first.id)
        try fixture.export(latest, expected: nextBytes)
        try fixture.withRemote("original-unchanged") {
            try require($0.readVersion(path: fixture.path) == fixture.original)
        }
        trace.enter("discard-first")
        try reopened.discard(first)
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        trace.enter("pending-count")
        try require(reopened.pendingCount == 0)
    }

    static func partialStage(_ fixture: Fixture) throws {
        let trace = fixture.trace
        trace.enter("prepare-first")
        let firstBytes = Data(repeating: 65, count: 2 << 20)
        var first = try fixture.prepare(firstBytes)
        let progress = Progress()
        let observer = progress.observe(\.completedUnitCount) { value, _ in
            if value.completedUnitCount >= 1 << 20 { value.cancel() }
        }
        defer { observer.invalidate() }
        let error = try failure {
            try fixture.withRemote("cancelled-publish", progress: progress) {
                try EditTransaction.publish(&first, outbox: fixture.outbox, remote: $0)
            }
        }
        trace.enter("cancelled-state")
        try require(error as? TransferError == .cancelled)
        try require(first.state == .creatingStage && first.stageIdentity != nil && first.stageVersion == nil)
        var before = stat()
        try require(fstatat(fixture.root, first.stagePath, &before, AT_SYMLINK_NOFOLLOW) == 0)
        try require(before.st_size == 1 << 20)
        try fixture.export(first, expected: firstBytes)
        try fixture.withRemote("original-unchanged") {
            try require($0.readVersion(path: fixture.path) == fixture.original)
        }
        trace.enter("prepare-latest")
        var latest = try fixture.prepare(Data("latest complete save\n".utf8))
        try fixture.withRemote("refused-retire") { remote in
            let fault = Fault(remote)
            let refused = try failure { try EditTransaction.retire(&first, outbox: fixture.outbox, remote: fault) }
            try require(refused as? UploadError == .unresolved && fault.removed.isEmpty)
        }
        trace.enter("retain-first")
        try fixture.outbox.retainSuperseded(&first)
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        trace.enter("retained-first")
        try require(fixture.reopened().records().first(where: { $0.id == first.id })?.state == .retired)
        try fixture.export(first, expected: firstBytes)
        var after = stat()
        try require(fstatat(fixture.root, first.stagePath, &after, AT_SYMLINK_NOFOLLOW) == 0)
        try require(after.st_size == before.st_size && after.st_ino == before.st_ino)
        try fixture.withRemote("stage-unchanged") { remote in
            let stage = try remote.inspect(path: first.stagePath, original: false)
            let digest = SHA256.hash(data: Data(repeating: 65, count: 1 << 20))
                .map { String(format: "%02x", $0) }.joined()
            try require(stage?.identity == first.stageIdentity && stage?.size == 1 << 20 && stage?.digest == digest)
        }
    }

    static func cleanup(_ fixture: Fixture, loseReply: Bool) throws {
        let trace = fixture.trace
        trace.enter("prepare-first")
        let firstBytes = Data("superseded complete save\n".utf8)
        var first = try fixture.prepare(firstBytes)
        let stopped = try failure {
            try fixture.withRemote("interrupted-publish") { remote in
                let fault = Fault(remote)
                fault.beforeMove = true
                try EditTransaction.publish(&first, outbox: fixture.outbox, remote: fault)
            }
        }
        trace.enter("interrupted-state")
        try require(stopped as? Failure == .injected)
        try require(first.state == .movingOriginal && first.stageVersion != nil && first.backupVersion != nil)
        let recovered = try failure {
            try fixture.withRemote("refused-recovery") {
                try EditTransaction.recover(&first, outbox: fixture.outbox, remote: $0)
            }
        }
        trace.enter("recovery-state")
        try require(recovered as? UploadError == .unresolved)
        try require(first.state == .backedUp)
        trace.enter("prepare-latest")
        var latest = try fixture.prepare(Data("latest complete save\n".utf8))
        let interrupted = try failure {
            try fixture.withRemote("interrupted-retire") { remote in
                let fault = Fault(remote)
                if loseReply { fault.afterRemoval = first.stagePath }
                else { fault.beforeRemoval = first.recoveryPath }
                try EditTransaction.retire(&first, outbox: fixture.outbox, remote: fault)
            }
        }
        trace.enter("retired-state")
        try require(interrupted as? Failure == .injected)
        let reopened = try fixture.reopened()
        guard let retained = try reopened.records().first(where: { $0.id == first.id }) else {
            throw Failure.assertion
        }
        try require(retained.state == .retired && (retained.retiredStageRemoved == true) == !loseReply)
        try fixture.export(first, expected: firstBytes)
        var replacement: EditFileVersion?
        if !loseReply {
            trace.enter("stage-gone")
            _ = try DirectoryListing.list(locationRoot: fixture.root, relativePath: RelativePath("c03")!,
                                          expected: fixture.identity)
            var gone = stat()
            try require(fstatat(fixture.root, first.stagePath, &gone, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT)
            let input = fixture.output.appending(path: "occupant.input")
            try Data("new occupant\n".utf8).write(to: input, options: .withoutOverwriting)
            replacement = try fixture.withRemote("occupant") {
                try $0.stage(path: first.stagePath, contents: input) { _ in }
            }
            trace.enter("occupant-checkpoint")
            guard let replacement, let retiredStage = first.stageVersion else { throw Failure.assertion }
            let evidence = OccupantEvidence(retired: first.id, retiredStage: retiredStage,
                occupant: replacement, original: fixture.original, neighbor: fixture.neighbor)
            try writeReport(JSONEncoder().encode(evidence), to: fixture.output.appending(path: "occupant-before.json"))
        }
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        if loseReply {
            try fixture.withRemote("retained-cleanup") { remote in
                let fault = Fault(remote)
                let retainedError = try failure {
                    try EditTransaction.cleanupRetired(&first, outbox: reopened, remote: fault)
                }
                try require(retainedError as? UploadError == .unresolved)
                try require(fault.inspected == [first.stagePath] && fault.removed.isEmpty)
            }
            trace.enter("uncertain-state")
            guard let uncertain = try reopened.records().first(where: { $0.id == first.id }) else {
                throw Failure.assertion
            }
            try require(uncertain.retiredStageRemoved != true && uncertain.retiredBackupRemoved != true
                && uncertain.retiredCleanupStarted != true)
            try fixture.export(first, expected: firstBytes)
            try fixture.withRemote("backup-retained") {
                try require($0.inspect(path: first.recoveryPath, original: false) == first.backupVersion)
            }
            trace.enter("pending-count")
            try require(reopened.pendingCount == 1)
        } else {
            try fixture.withRemote("retired-cleanup") {
                try EditTransaction.cleanupRetired(&first, outbox: reopened, remote: $0)
            }
            try fixture.withRemote("occupant-retained") {
                guard let occupant = try $0.inspect(path: first.stagePath, original: false),
                      let retiredStage = first.stageVersion else { throw Failure.assertion }
                try require(occupant == replacement)
                let evidence = OccupantEvidence(retired: first.id, retiredStage: retiredStage,
                    occupant: occupant, original: fixture.original, neighbor: fixture.neighbor)
                try writeReport(JSONEncoder().encode(evidence), to: fixture.output.appending(path: "occupant-after.json"))
            }
            trace.enter("pending-count")
            try require(reopened.pendingCount == 0)
        }
    }

    struct OccupantEvidence: Codable {
        let retired: UUID
        let retiredStage: EditFileVersion
        let occupant: EditFileVersion
        let original: EditFileVersion
        let neighbor: EditFileVersion
    }

    /// Publishes c02's already prepared newest save; the retired partial stage must stay untouched.
    static func continuePartialStage(_ share: Share, local: URL, output: URL) throws {
        let trace = share.trace, caseID = "c02", path = "c02/document.txt"
        let baseBytes = Data("base c02\n".utf8), neighborBytes = Data("neighbor c02\n".utf8)
        let firstBytes = Data(repeating: 65, count: 2 << 20), partialBytes = Data(repeating: 65, count: 1 << 20)
        let latestBytes = Data("latest complete save\n".utf8)
        trace.enter("original-report")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: local.appending(path: "report.json")))
        guard let original = decoded as? [String: Any], original["case"] as? String == caseID,
              original["passed"] as? Bool == false, let domain = original["errorDomain"] as? String,
              let code = original["errorCode"] as? Int else { throw Failure.assertion }
        trace.observed["originalError"] = ["errorDomain": domain, "errorCode": code] as [String: Any]
        trace.enter("preserve-outbox")
        let outbox = try existingOutbox(local)
        try FileManager.default.copyItem(at: local.appending(path: "Outbox"),
                                         to: output.appending(path: "Outbox-before"))
        trace.enter("records")
        let records = try outbox.records()
        guard records.count == 2, let first = records.first, var latest = records.last,
              let stageIdentity = first.stageIdentity,
              let base = try outbox.base(item: first.item, contentVersion: first.baseVersion) else {
            throw Failure.assertion
        }
        for record in records {
            try require(record.item == first.item && record.baseVersion == first.baseVersion
                && record.parent == Catalog.rootItemID && record.path == path)
            try require(record.destination == path && !record.failOnConflict && !record.conflict
                && record.previous == nil)
            try require(record.backupIdentity == nil && record.backupVersion == nil && record.stageVersion == nil
                && record.published == nil && record.completedItem == nil)
        }
        try require(first.sequence == 1 && first.state == .retired && first.recoveryRetained)
        try require(first.size == Int64(firstBytes.count) && first.digest == digest(firstBytes))
        try require(first.retiredStageRemoved == nil && first.retiredBackupRemoved == nil
            && first.retiredCleanupStarted == nil)
        try require(latest.sequence == 2 && latest.state == .prepared && !latest.recoveryRetained
            && latest.stageIdentity == nil)
        try require(latest.size == Int64(latestBytes.count) && latest.digest == digest(latestBytes))
        try require(base.version.size == Int64(baseBytes.count) && base.version.digest == digest(baseBytes))
        try require(receipts(local) == 1 && outbox.pendingCount == 2)
        try require(outbox.order(item: latest.item) == EditOrder(head: latest))
        trace.observed["retiredStage"] = ["fileID": stageIdentity.fileID,
                                          "birthMicroseconds": stageIdentity.birthMicroseconds] as [String: Any]
        trace.enter("native-before")
        let stageName = String(first.stagePath.dropFirst(caseID.count + 1))
        try require(share.names(caseID) == ["document.txt", "neighbor.txt", stageName])
        var inode = stat()
        try require(fstatat(share.root, first.stagePath, &inode, AT_SYMLINK_NOFOLLOW) == 0)
        try require(inode.st_size == 1 << 20)
        let absent = [first.recoveryPath, first.workPath, latest.stagePath, latest.recoveryPath, latest.workPath]
        let before = try snapshot(share, "before", first: first, absent: absent)
        trace.enter("document-before")
        try require(before.document.hasSameContents(as: base.version)
            && before.document.modifiedMicroseconds == base.version.modifiedMicroseconds)
        trace.enter("document-before-metadata")
        try require(before.document == base.version)
        trace.enter("neighbor-before")
        try require(before.neighbor.size == Int64(neighborBytes.count)
            && before.neighbor.digest == digest(neighborBytes))
        trace.enter("stage-before")
        try require(before.stage.identity == stageIdentity && before.stage.size == 1 << 20
            && before.stage.digest == digest(partialBytes))
        let fixture = Fixture(resuming: caseID, share: share, local: local, output: output, outbox: outbox,
                              item: first.item, base: base, neighbor: before.neighbor)
        trace.enter("export-before")
        try fixture.export(first, expected: firstBytes)
        try fixture.export(latest, expected: latestBytes)
        try fixture.finish(&latest)
        let after = try snapshot(share, "after", first: first, absent: absent)
        trace.enter("document-after")
        try require(after.document.identity == base.version.identity && after.document.size == latest.size
            && after.document.digest == latest.digest)
        trace.enter("neighbor-after")
        try require(after.neighbor == before.neighbor)
        trace.enter("stage-after")
        try require(after.stage.identity == stageIdentity && after.stage.size == before.stage.size
            && after.stage.digest == before.stage.digest)
        trace.enter("stage-after-metadata")
        try require(after.stage == before.stage)
        trace.enter("native-after")
        var native = stat()
        try require(fstatat(share.root, first.stagePath, &native, AT_SYMLINK_NOFOLLOW) == 0)
        try require(native.st_size == inode.st_size && native.st_ino == inode.st_ino)
        trace.enter("records-after")
        let reopened = try fixture.reopened()
        try require(reopened.records() == [first, latest] && reopened.pendingCount == 1)
        trace.enter("export-after")
        try fixture.export(first, expected: firstBytes)
    }

    // Comparisons happen outside the session, so each failed one has its own step label.
    static func snapshot(_ share: Share, _ label: String, first: PendingEdit, absent: [String]) throws
        -> (document: EditFileVersion, neighbor: EditFileVersion, stage: EditFileVersion) {
        try share.withRemote(label, path: first.path) { remote in
            for name in absent { try require(remote.renameSourceEntry(path: name) == nil) }
            try require(remote.renameSourceEntry(path: first.stagePath)?.identity == first.stageIdentity)
            let neighbor = first.path.replacingOccurrences(of: "document.txt", with: "neighbor.txt")
            return (document: try remote.readVersion(path: first.path),
                    neighbor: try remote.readVersion(path: neighbor),
                    stage: try remote.readVersion(path: first.stagePath))
        }
    }

    /// Read-only: c03's retired cleanup already ran, so nothing here may remove or replay it.
    static func inspectCleanup(_ share: Share, local: URL, pins: M23Pins) throws {
        let trace = share.trace, caseID = "c03", path = "c03/document.txt"
        let baseBytes = Data("base c03\n".utf8), neighborBytes = Data("neighbor c03\n".utf8)
        let latestBytes = Data("latest complete save\n".utf8), occupantBytes = Data("new occupant\n".utf8)
        trace.enter("original-report")
        var missing = stat()
        try require(lstat(local.appending(path: "report.json").path, &missing) == -1 && errno == ENOENT)
        trace.enter("occupant-input")
        let input = local.appending(path: "occupant.input")
        var created = stat()
        try require(lstat(input.path, &created) == 0)
        try require(created.st_mode & S_IFMT == S_IFREG && Data(contentsOf: input) == occupantBytes)
        let inputBirth = UInt64(created.st_birthtimespec.tv_sec) * 1_000_000
            + UInt64(created.st_birthtimespec.tv_nsec / 1_000)
        trace.enter("records")
        let outbox = try existingOutbox(local)
        let records = try outbox.records()
        guard records.count == 1, let latest = records.first, let receipt = latest.published,
              let stageIdentity = latest.stageIdentity, let backupIdentity = latest.backupIdentity,
              let base = try outbox.base(item: latest.item, contentVersion: latest.baseVersion) else {
            throw Failure.assertion
        }
        try require(latest.sequence == 2 && latest.state == .completed && !latest.recoveryRetained
            && !latest.conflict)
        try require(latest.parent == Catalog.rootItemID && latest.path == path && latest.destination == path
            && !latest.failOnConflict)
        try require(latest.size == Int64(latestBytes.count) && latest.digest == digest(latestBytes))
        try require(latest.completedItem == latest.item && receipt.item == latest.item)
        try require(latest.completedStageRemoved == true && latest.completedBackupRemoved == true
            && latest.completedCleanupStarted == true)
        try require(base.version.size == Int64(baseBytes.count) && base.version.digest == digest(baseBytes))
        try require(receipt.version.identity == base.version.identity
            && latest.previous?.identity == base.version.identity)
        try require(receipt.version.size == latest.size && receipt.version.digest == latest.digest)
        try require(outbox.base(item: latest.item, contentVersion: receipt.contentVersion) == receipt)
        try require(receipts(local) == 2 && outbox.pendingCount == 0)
        trace.enter("native-listing")
        let names = try share.names(caseID)
        let artifacts = names.subtracting(["document.txt", "neighbor.txt"])
        guard names.count == artifacts.count + 2, artifacts.count == 1, let name = artifacts.first,
              name.hasPrefix(".tinymounter-"), name.hasSuffix(".stage"),
              let owner = UUID(uuidString: String(name.dropFirst(13).dropLast(6))),
              name == ".tinymounter-" + owner.uuidString + ".stage" else { throw Failure.assertion }
        trace.observed["occupantRecord"] = owner.uuidString
        try require(owner != latest.id && pins.retired.map { $0 == owner } != false)
        let prefix = caseID + "/.tinymounter-" + owner.uuidString
        let absent = [latest.stagePath, latest.recoveryPath, latest.workPath, prefix + ".recovery", prefix + ".work"]
        let versions: (EditFileVersion, EditFileVersion, EditFileVersion) = try share.withRemote(
            "inspect", path: path) { remote in
            let occupant = try remote.readVersion(path: prefix + ".stage")
            try require(remote.renameSourceEntry(path: prefix + ".stage")?.identity == occupant.identity)
            for artifact in absent { try require(remote.renameSourceEntry(path: artifact) == nil) }
            return (try remote.readVersion(path: path),
                    try remote.readVersion(path: caseID + "/neighbor.txt"), occupant)
        }
        let (document, neighbor, occupant) = versions
        trace.observed["occupant"] = ["fileID": occupant.identity.fileID,
                                      "birthMicroseconds": occupant.identity.birthMicroseconds] as [String: Any]
        let window: [String: Any] = ["inputBirthMicroseconds": inputBirth,
                                     "successorStageBirthMicroseconds": stageIdentity.birthMicroseconds]
        trace.observed["creationWindow"] = window
        trace.enter("document")
        try require(document.identity == base.version.identity && document.size == latest.size
            && document.digest == latest.digest)
        trace.enter("neighbor")
        try require(neighbor.size == Int64(neighborBytes.count) && neighbor.digest == digest(neighborBytes))
        trace.enter("occupant")
        try require(occupant.size == Int64(occupantBytes.count) && occupant.digest == digest(occupantBytes))
        try require(![base.version.identity, stageIdentity, backupIdentity].contains(occupant.identity))
        try require(pins.occupant.map { $0 == occupant.identity } != false)
        if let pin = pins.retiredStage {
            try require(pin != occupant.identity && pin.birthMicroseconds < inputBirth)
        }
        // Loopback server and helper share one clock: the occupant must be born between both steps.
        trace.enter("creation-window")
        try require(inputBirth <= occupant.identity.birthMicroseconds
            && occupant.identity.birthMicroseconds <= stageIdentity.birthMicroseconds)
    }
}
