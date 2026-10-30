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
            guard args.count == 5, args[1] == "--m23-final", ["c01", "c02", "c03", "c04"].contains(args[2]),
                  let run = UUID(uuidString: args[3]), run.uuidString == args[3],
                  let location = UUID(uuidString: args[4]) else { throw UploadError.invalidRequest }
            let originalURL = URL.applicationSupportDirectory.appending(path: "tinymounter/Settings.json")
            let original = try Data(contentsOf: originalURL)
            let current = try JSONDecoder().decode(AppSettings.self, from: original)
            guard let record = current.locations.first(where: { $0.id == location }),
                  !record.removing, record.smbOnlyEditing == true, let bookmark = record.activeWriteBookmark,
                  let grant = current.shares.first(where: { $0.id == record.serverID }),
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
            let parent = URL.applicationSupportDirectory.appending(path: "tinymounter/probe-m23-final")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let local = parent.appending(path: "caller-" + args[2])
            guard mkdir(local.path, 0o700) == 0 else { throw UploadError.unresolved }
            let settings = local.appending(path: "Settings.json")
            try AppSettings(servers: [server], shares: [grant], locations: []).save(to: settings)
            let store = SettingsStore(url: settings)
            let access = ShareAccess(grant: grant, store: store, onRecovery: { _ in })
            let folder = RelativePath("probe-m23-final")!, domain = UUID().uuidString
            let catalog = try Catalog.create(at: local.appending(path: "catalog.sqlite"),
                                             domainID: domain, rootName: "M23 recovery probe")
            let source = LocationSource(domainID: domain, folder: folder, catalog: catalog,
                                        access: access, renameSettings: { _ in }, signal: { _ in })
            defer { source.close(); access.editNamespace.unregister(domain) }
            try source.configureWriteMode(bookmark, confirmed: true)
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                source.runM23FinalProbe(args[2], run: run) { reply.resume(with: $0) }
            }
            guard try Data(contentsOf: originalURL) == original else { throw UploadError.unresolved }
            print("M23 recovery probe passed: " + args[2])
        } catch {
            print("M23 recovery probe failed: " + String((error as NSError).code))
            exit(1)
        }
    }
}

extension LocationSource {
    func runM23FinalProbe(_ caseID: String, run: UUID,
                          completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        access.enqueue { [self] in
            completion(Result { try editNamespace.perform { try uploadLock.withLock {
                guard !mutationsSuspended, let bookmark = writeBookmark,
                      folder.string == "probe-m23-final" else { throw UploadError.readOnly }
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
                    guard nativePath == "/Volumes/tinymounter-m19-edit-test/probe-m23-final" else {
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
                    try M23FinalProbe.run(caseID, endpoint: endpoint, folder: folder, root: root,
                                          identity: session.identity, progress: progress)
                }
            } } })
        }
    }
}

private enum M23FinalProbe {
    enum Failure: Error, Equatable { case assertion, expectedFailure, injected }

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
    }

    struct Fixture {
        let endpoint: ShareAddress
        let folder: RelativePath
        let root: Int32
        let identity: MountIdentity
        let progress: Progress
        let path: String
        let local: URL
        let item = UUID().uuidString
        let original: EditFileVersion
        let neighbor: EditFileVersion
        let base: EditBaseReceipt
        let outbox: EditOutbox

        init(_ caseID: String, endpoint: ShareAddress, folder: RelativePath, root: Int32,
             identity: MountIdentity, progress: Progress, local: URL) throws {
            self.endpoint = endpoint
            self.folder = folder
            self.root = root
            self.identity = identity
            self.progress = progress
            path = caseID + "/document.txt"
            self.local = local
            outbox = try EditOutbox(directory: local.appending(path: "Outbox"))
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress)
            try remote.protectAncestors(of: path)
            original = try remote.readVersion(path: path)
            neighbor = try remote.readVersion(path: caseID + "/neighbor.txt")
            base = try EditBaseReceipt(item: item, version: original)
            try outbox.storeBase(base)
        }

        func withRemote<T>(progress: Progress? = nil, _ body: (SMBEdit) throws -> T) throws -> T {
            let remote = try SMBEdit(endpoint: endpoint, folder: folder, root: root, progress: progress ?? self.progress)
            try remote.protectAncestors(of: path)
            return try body(remote)
        }

        func prepare(_ bytes: Data, checkSpace: ((Int64) throws -> Void)? = nil) throws -> PendingEdit {
            let input = local.appending(path: UUID().uuidString + ".input")
            try bytes.write(to: input, options: .withoutOverwriting)
            return try outbox.prepare(item: item, parent: Catalog.rootItemID, path: RelativePath(path)!,
                                      baseVersion: base.contentVersion, failOnConflict: false, contents: input,
                                      progress: Progress(), checkSpace: checkSpace)
        }

        func finish(_ record: inout PendingEdit) throws {
            try withRemote { remote in
                try EditTransaction.publish(&record, outbox: outbox, remote: remote)
                try M23FinalProbe.require(record.state == .published)
                try outbox.complete(&record, item: record.item)
                try EditTransaction.cleanup(&record, outbox: outbox, remote: remote)
            }
            try M23FinalProbe.require(record.state == .completed && !record.recoveryRetained && !record.conflict)
        }

        func export(_ record: PendingEdit, expected: Data) throws {
            let url = local.appending(path: UUID().uuidString + ".export")
            try outbox.export(record, to: url)
            try M23FinalProbe.require(Data(contentsOf: url) == expected)
        }

        func verifyRemote(_ record: PendingEdit) throws {
            try withRemote { remote in
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

    static func run(_ caseID: String, endpoint: ShareAddress, folder: RelativePath, root: Int32,
                    identity: MountIdentity, progress: Progress) throws {
        guard ["c01", "c02", "c03", "c04"].contains(caseID) else { throw Failure.assertion }
        let parent = URL.applicationSupportDirectory.appending(path: "tinymounter/probe-m23-final")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let local = parent.appending(path: caseID)
        guard mkdir(local.path, 0o700) == 0 else { throw Failure.assertion }
        let result = Result {
            let fixture = try Fixture(caseID, endpoint: endpoint, folder: folder, root: root,
                                      identity: identity, progress: progress, local: local)
            switch caseID {
            case "c01": try admission(fixture)
            case "c02": try partialStage(fixture)
            case "c03": try cleanup(fixture, loseReply: false)
            default: try cleanup(fixture, loseReply: true)
            }
        }
        var report: [String: Any] = ["case": caseID, "date": ISO8601DateFormatter().string(from: Date()),
                                     "cache": "uncontrolled", "injected": true, "passed": false]
        switch result {
        case .success: report["passed"] = true
        case .failure(let error):
            report["errorDomain"] = (error as NSError).domain
            report["errorCode"] = (error as NSError).code
        }
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            .write(to: local.appending(path: "report.json"), options: .withoutOverwriting)
        try result.get()
    }

    static func admission(_ fixture: Fixture) throws {
        try require(DownloadSpace.reserveBytes == 2 << 30)
        let firstBytes = Data("first complete save\n".utf8), nextBytes = Data(repeating: 78, count: 4096)
        let first = try fixture.prepare(firstBytes)
        let required = DownloadSpace.reserveBytes + Int64(nextBytes.count) * 2 + 65536
        let capacity = Capacity(required - 1), id = UUID()
        let space = DownloadSpace { capacity.read() }
        try require(DownloadSpace.isFull(try failure { try space.begin(id, bytes: Int64(nextBytes.count)) }))
        try require(fixture.outbox.records() == [first])
        try fixture.export(first, expected: firstBytes)
        capacity.set(required)
        try space.begin(id, bytes: Int64(nextBytes.count))
        defer { space.end(id) }
        capacity.set(required - 1)
        try require(DownloadSpace.isFull(try failure {
            _ = try fixture.prepare(nextBytes) { try space.check(id, completedBytes: $0) }
        }))
        try require(fixture.outbox.records() == [first])
        capacity.set(required)
        try require(DownloadSpace.isFull(try failure {
            _ = try fixture.prepare(nextBytes) { completed in
                if completed > 0 { capacity.set(DownloadSpace.reserveBytes - 1) }
                try space.check(id, completedBytes: completed)
            }
        }))
        try fixture.export(first, expected: firstBytes)
        let reopened = try fixture.reopened()
        guard var latest = try reopened.order(item: fixture.item).head else { throw Failure.assertion }
        try require(latest.id != first.id)
        try fixture.export(latest, expected: nextBytes)
        try fixture.withRemote { try require($0.readVersion(path: fixture.path) == fixture.original) }
        try reopened.discard(first)
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        try require(reopened.pendingCount == 0)
    }

    static func partialStage(_ fixture: Fixture) throws {
        let firstBytes = Data(repeating: 65, count: 2 << 20)
        var first = try fixture.prepare(firstBytes)
        let progress = Progress()
        let observer = progress.observe(\.completedUnitCount) { value, _ in
            if value.completedUnitCount >= 1 << 20 { value.cancel() }
        }
        defer { observer.invalidate() }
        let error = try failure {
            try fixture.withRemote(progress: progress) {
                try EditTransaction.publish(&first, outbox: fixture.outbox, remote: $0)
            }
        }
        try require(error as? TransferError == .cancelled)
        try require(first.state == .creatingStage && first.stageIdentity != nil && first.stageVersion == nil)
        var before = stat()
        try require(fstatat(fixture.root, first.stagePath, &before, AT_SYMLINK_NOFOLLOW) == 0)
        try require(before.st_size == 1 << 20)
        try fixture.export(first, expected: firstBytes)
        try fixture.withRemote { try require($0.readVersion(path: fixture.path) == fixture.original) }
        var latest = try fixture.prepare(Data("latest complete save\n".utf8))
        try fixture.withRemote { remote in
            let fault = Fault(remote)
            let refused = try failure { try EditTransaction.retire(&first, outbox: fixture.outbox, remote: fault) }
            try require(refused as? UploadError == .unresolved && fault.removed.isEmpty)
        }
        try fixture.outbox.retainSuperseded(&first)
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        try require(fixture.reopened().records().first(where: { $0.id == first.id })?.state == .retired)
        try fixture.export(first, expected: firstBytes)
        var after = stat()
        try require(fstatat(fixture.root, first.stagePath, &after, AT_SYMLINK_NOFOLLOW) == 0)
        try require(after.st_size == before.st_size && after.st_ino == before.st_ino)
        try fixture.withRemote { remote in
            let stage = try remote.inspect(path: first.stagePath, original: false)
            let digest = SHA256.hash(data: Data(repeating: 65, count: 1 << 20))
                .map { String(format: "%02x", $0) }.joined()
            try require(stage?.identity == first.stageIdentity && stage?.size == 1 << 20 && stage?.digest == digest)
        }
    }

    static func cleanup(_ fixture: Fixture, loseReply: Bool) throws {
        let firstBytes = Data("superseded complete save\n".utf8)
        var first = try fixture.prepare(firstBytes)
        let stopped = try failure {
            try fixture.withRemote { remote in
                let fault = Fault(remote)
                fault.beforeMove = true
                try EditTransaction.publish(&first, outbox: fixture.outbox, remote: fault)
            }
        }
        try require(stopped as? Failure == .injected)
        try require(first.state == .movingOriginal && first.stageVersion != nil && first.backupVersion != nil)
        let recovered = try failure {
            try fixture.withRemote { try EditTransaction.recover(&first, outbox: fixture.outbox, remote: $0) }
        }
        try require(recovered as? UploadError == .unresolved)
        try require(first.state == .backedUp)
        var latest = try fixture.prepare(Data("latest complete save\n".utf8))
        let interrupted = try failure {
            try fixture.withRemote { remote in
                let fault = Fault(remote)
                if loseReply { fault.afterRemoval = first.stagePath }
                else { fault.beforeRemoval = first.recoveryPath }
                try EditTransaction.retire(&first, outbox: fixture.outbox, remote: fault)
            }
        }
        try require(interrupted as? Failure == .injected)
        let reopened = try fixture.reopened()
        guard let retained = try reopened.records().first(where: { $0.id == first.id }) else {
            throw Failure.assertion
        }
        try require(retained.state == .retired && (retained.retiredStageRemoved == true) == !loseReply)
        try fixture.export(first, expected: firstBytes)
        var replacement: EditFileVersion?
        if !loseReply {
            _ = try DirectoryListing.list(locationRoot: fixture.root, relativePath: RelativePath("c03")!,
                                          expected: fixture.identity)
            var gone = stat()
            try require(fstatat(fixture.root, first.stagePath, &gone, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT)
            let input = fixture.local.appending(path: "occupant.input")
            try Data("new occupant\n".utf8).write(to: input, options: .withoutOverwriting)
            replacement = try fixture.withRemote { try $0.stage(path: first.stagePath, contents: input) { _ in } }
        }
        try fixture.finish(&latest)
        try fixture.verifyRemote(latest)
        if loseReply {
            try fixture.withRemote { remote in
                let fault = Fault(remote)
                let retainedError = try failure {
                    try EditTransaction.cleanupRetired(&first, outbox: reopened, remote: fault)
                }
                try require(retainedError as? UploadError == .unresolved)
                try require(fault.inspected == [first.stagePath] && fault.removed.isEmpty)
            }
            guard let uncertain = try reopened.records().first(where: { $0.id == first.id }) else {
                throw Failure.assertion
            }
            try require(uncertain.retiredStageRemoved != true && uncertain.retiredBackupRemoved != true
                && uncertain.retiredCleanupStarted != true)
            try fixture.export(first, expected: firstBytes)
            try fixture.withRemote { try require($0.inspect(path: first.recoveryPath, original: false) == first.backupVersion) }
            try require(reopened.pendingCount == 1)
        } else {
            try fixture.withRemote { try EditTransaction.cleanupRetired(&first, outbox: reopened, remote: $0) }
            try fixture.withRemote { try require($0.inspect(path: first.stagePath, original: false) == replacement) }
            try require(reopened.pendingCount == 0)
        }
    }
}
