// Isolated candidate only; integration and the parent-operated sequence are in the Python runbook.
import Darwin
import FileProvider
import Foundation
import OSLog

enum M22FinderProbe {
    struct Config: Codable, Equatable, Sendable {
        let run: UUID
        let location: UUID
        let grant: UUID
        let domain: String
        var folder: String { "probe-m22-finder-" + run.uuidString }
    }

    struct Request: Codable {
        let run: UUID
        let id: UUID
        let label: String
    }

    struct Event: Codable {
        let run: UUID
        let domain: String
        let process: Int32
        let time: UInt64
        let date: String
        let call: UUID
        let kind: String
        let fields: [String: String]
        let items: [[String: String]]
    }

    enum Failure: Error { case check(String) }
    static let share = "tinymounter-m19-edit-test"
    static let mount = "/Volumes/" + share
    static let labels: Set<String> = ["baseline", "renamed", "moved", "case", "collision-folder",
        "collision-file", "relisted", "named", "replay"]
    static let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "m22-finder-fixture")

    static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.check(label) }
    }

    static func directory(_ run: UUID) throws -> URL {
        try SharedContainer.url().appending(path: "M22Finder-" + run.uuidString)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.check("exclusive-report-create") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        var info = stat()
        try require(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1 && info.st_size <= 4 << 20, "bounded-regular-report")
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func selected(_ domain: String) -> Config? {
        do {
            let pointer = try SharedContainer.url().appending(path: "M22Finder-active.json")
            guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
            let config = try load(Config.self, from: pointer)
            return config.domain == domain ? config : nil
        } catch {
            logger.error("m22_finder_trace_failed stage=config")
            return nil
        }
    }

    static func emit(_ config: Config, call: UUID, kind: String,
                     fields: [String: String] = [:], items: [[String: String]] = []) {
        do {
            let event = Event(run: config.run, domain: config.domain, process: getpid(),
                time: DispatchTime.now().uptimeNanoseconds, date: ISO8601DateFormatter().string(from: .now),
                call: call, kind: kind, fields: fields, items: items)
            try save(event, to: directory(config.run).appending(path: "events/" + UUID().uuidString + ".json"))
        } catch {
            logger.error("m22_finder_trace_failed run=\(config.run.uuidString, privacy: .public)")
        }
    }

    static func item(_ item: NSFileProviderItem) -> [String: String] {
        var result = ["id": item.itemIdentifier.rawValue, "parent": item.parentItemIdentifier.rawValue,
                      "name": item.filename]
        if let version = item.itemVersion ?? nil {
            result["content"] = version.contentVersion.base64EncodedString()
            result["metadata"] = version.metadataVersion.base64EncodedString()
        }
        return result
    }

    static func failure(_ error: Error?) -> [String: String] {
        guard let error = error as NSError? else { return ["ok": "true"] }
        return ["ok": "false", "errorDomain": error.domain, "errorCode": String(error.code),
                "filenameCollision": String(error.domain == NSFileProviderErrorDomain
                    && error.code == NSFileProviderError.filenameCollision.rawValue)]
    }

    typealias MutationReply = (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void

    static func mutation(domain: String, kind: String, item: NSFileProviderItem,
                         base: NSFileProviderItemVersion?, fields: NSFileProviderItemFields,
                         contents: Bool, options: UInt, reply: @escaping MutationReply) -> MutationReply {
        guard let config = selected(domain) else { return reply }
        let call = UUID()
        var details = ["fields": String(fields.rawValue), "contents": String(contents), "options": String(options),
                       "changesName": String(fields.contains(.filename)),
                       "changesParent": String(fields.contains(.parentItemIdentifier))]
        details["baseContent"] = base?.contentVersion.base64EncodedString()
        details["baseMetadata"] = base?.metadataVersion.base64EncodedString()
        emit(config, call: call, kind: kind + "-begin", fields: details, items: [self.item(item)])
        return { result, pending, fetch, error in
            var details = failure(error)
            details["pendingFields"] = String(pending.rawValue)
            details["fetchContent"] = String(fetch)
            emit(config, call: call, kind: kind + "-end", fields: details,
                 items: result.map { [self.item($0)] } ?? [])
            reply(result, pending, fetch, error)
        }
    }

    static func fetch(domain: String, item: String, version: NSFileProviderItemVersion?, range: NSRange?,
                      reply: @escaping (URL?, NSFileProviderItem?, NSRange, Error?) -> Void)
        -> (URL?, NSFileProviderItem?, NSRange, Error?) -> Void {
        guard let config = selected(domain) else { return reply }
        let call = UUID()
        emit(config, call: call, kind: "fetch-begin", fields: ["item": item,
            "version": version?.contentVersion.base64EncodedString() ?? "unspecified",
            "range": range.map(NSStringFromRange) ?? "full"])
        return { url, result, range, error in
            emit(config, call: call, kind: "fetch-end", fields: failure(error).merging(
                ["item": item, "range": NSStringFromRange(range)]) { _, new in new })
            reply(url, result, range, error)
        }
    }

    static func enumerator(_ wrapped: NSFileProviderEnumerator, domain: String,
                           parent: NSFileProviderItemIdentifier) -> NSFileProviderEnumerator {
        guard let config = selected(domain) else { return wrapped }
        return Enumeration(wrapped: wrapped, config: config, parent: parent.rawValue)
    }

    final class Enumeration: NSObject, NSFileProviderEnumerator {
        let wrapped: NSFileProviderEnumerator
        let config: Config
        let parent: String
        init(wrapped: NSFileProviderEnumerator, config: Config, parent: String) {
            self.wrapped = wrapped; self.config = config; self.parent = parent
        }
        func invalidate() { wrapped.invalidate() }
        func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
            wrapped.currentSyncAnchor?(completionHandler: completionHandler)
        }
        func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
            let call = UUID()
            M22FinderProbe.emit(config, call: call, kind: "enumerate-begin", fields: ["parent": parent,
                "page": page.rawValue.base64EncodedString(),
                "initial": String(page.rawValue == NSFileProviderPage.initialPageSortedByName as Data
                    || page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data)])
            wrapped.enumerateItems(for: Items(observer, config, call, parent), startingAt: page)
        }
        func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
            let call = UUID()
            M22FinderProbe.emit(config, call: call, kind: "changes-begin", fields: ["parent": parent,
                "anchor": anchor.rawValue.base64EncodedString()])
            wrapped.enumerateChanges?(for: Changes(observer, config, call, parent), from: anchor)
        }
    }

    final class Items: NSObject, NSFileProviderEnumerationObserver {
        let wrapped: NSFileProviderEnumerationObserver
        let config: Config
        let call: UUID
        let parent: String
        init(_ wrapped: NSFileProviderEnumerationObserver, _ config: Config, _ call: UUID, _ parent: String) {
            self.wrapped = wrapped; self.config = config; self.call = call; self.parent = parent
        }
        var suggestedPageSize: Int { wrapped.suggestedPageSize ?? 200 }
        func didEnumerate(_ items: [NSFileProviderItem]) {
            M22FinderProbe.emit(config, call: call, kind: "enumerated", fields: ["parent": parent],
                                items: items.map(M22FinderProbe.item))
            wrapped.didEnumerate(items)
        }
        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            M22FinderProbe.emit(config, call: call, kind: "enumerate-end", fields: ["parent": parent, "ok": "true",
                "next": nextPage?.rawValue.base64EncodedString() ?? ""])
            wrapped.finishEnumerating(upTo: nextPage)
        }
        func finishEnumeratingWithError(_ error: Error) {
            M22FinderProbe.emit(config, call: call, kind: "enumerate-end", fields: M22FinderProbe.failure(error).merging(
                ["parent": parent]) { _, new in new })
            wrapped.finishEnumeratingWithError(error)
        }
    }

    final class Changes: NSObject, NSFileProviderChangeObserver {
        let wrapped: NSFileProviderChangeObserver
        let config: Config
        let call: UUID
        let parent: String
        init(_ wrapped: NSFileProviderChangeObserver, _ config: Config, _ call: UUID, _ parent: String) {
            self.wrapped = wrapped; self.config = config; self.call = call; self.parent = parent
        }
        var suggestedBatchSize: Int { wrapped.suggestedBatchSize ?? 200 }
        func didUpdate(_ updatedItems: [NSFileProviderItem]) {
            M22FinderProbe.emit(config, call: call, kind: "updated", fields: ["parent": parent],
                                items: updatedItems.map(M22FinderProbe.item))
            wrapped.didUpdate(updatedItems)
        }
        func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
            M22FinderProbe.emit(config, call: call, kind: "deleted", fields: ["parent": parent],
                 items: deletedItemIdentifiers.map { ["id": $0.rawValue] })
            wrapped.didDeleteItems(withIdentifiers: deletedItemIdentifiers)
        }
        func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
            M22FinderProbe.emit(config, call: call, kind: "changes-end", fields: ["parent": parent, "ok": "true",
                "anchor": anchor.rawValue.base64EncodedString(), "more": String(moreComing)])
            wrapped.finishEnumeratingChanges(upTo: anchor, moreComing: moreComing)
        }
        func finishEnumeratingWithError(_ error: Error) {
            M22FinderProbe.emit(config, call: call, kind: "changes-end", fields: M22FinderProbe.failure(error).merging(
                ["parent": parent]) { _, new in new })
            wrapped.finishEnumeratingWithError(error)
        }
    }
}

#if !M22_FINDER_PROVIDER
extension M22FinderProbe {
    struct Row: Codable, Equatable, Sendable {
        let id: String
        let parent: String?
        let path: String
        let kind: String
        let content: String
        let metadata: String
        let size: Int64
        let keep: Bool
        let requested: Bool
        let complete: Bool
        let listed: Bool
    }

    struct Local: Codable, Sendable {
        let item: String
        let url: String
        var state: String
        var device: Int32?
        var inode: UInt64?
        var flags: UInt32?
        var size: Int64?
        var digest: String?
    }

    struct Snapshot: Codable {
        let config: Config
        let label: String
        let date: String
        let started: UInt64
        let ended: UInt64
        let settingsPreserved: Bool
        let pendingKeeps: [KeepPath]
        let rows: [Row]
        let local: [Local]
        let moves: [PendingFolderMove]
        let pendingItems: Int
    }

    static func rows(_ source: LocationSource) throws -> [Row] {
        try source.withCatalog { catalog in
            var result: [Row] = [], queue = [(Catalog.rootItemID, "")], seen: Set<String> = []
            while !queue.isEmpty {
                let (id, path) = queue.removeFirst()
                try require(seen.insert(id).inserted && seen.count <= 96, "catalog-bound-or-cycle")
                guard let row = try catalog.item(id: id), !row.deleted else { throw Failure.check("live-row-required") }
                result.append(Row(id: row.id, parent: row.parentID, path: path,
                    kind: row.kind == .file ? "file" : "directory", content: row.contentVersion,
                    metadata: row.metadataVersion, size: row.size, keep: row.keep, requested: row.keepRequested,
                    complete: row.listingComplete, listed: row.listGen != nil))
                if row.kind == .folder {
                    let children = try catalog.children(of: id, limit: 97)
                    try require(children.count < 97, "catalog-child-bound")
                    queue += children.map { ($0.id, path.isEmpty ? $0.name : path + "/" + $0.name) }
                }
            }
            return result
        }
    }

    static func hashLocal(_ row: Row, url: URL) throws -> Local {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        try require(old >= 0 && setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0, "disable-materialization")
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old) }
        var info = stat()
        try require(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= 64 << 10, "local-ordinary-file")
        var result = Local(item: row.id, url: url.path, state: "dataless", device: info.st_dev,
            inode: UInt64(info.st_ino), flags: info.st_flags, size: info.st_size)
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return result }
        let file = try ReadOnlyFile(url: url)
        try require(file.filesystem.isLocal && file.snapshot.device == UInt64(UInt32(bitPattern: info.st_dev))
            && file.snapshot.inode == UInt64(info.st_ino) && file.snapshot.size == row.size, "local-stable-open")
        result.digest = try file.checksum(range: ByteRange(offset: 0, length: row.size, fileSize: row.size))
        var after = stat()
        try require(lstat(url.path, &after) == 0 && after.st_dev == info.st_dev && after.st_ino == info.st_ino
            && after.st_flags & UInt32(SF_DATALESS) == 0, "local-stable-path")
        result.state = "hashed-with-materialization-off"
        return result
    }
}

extension LocationController {
    private func m22FinderGrant(_ settings: AppSettings) throws -> (LocationRecord, ServerGrant, Data) {
        guard let reference = settings.locations.first(where: {
            $0.id == UUID(uuidString: "3A9DE695-8327-4D86-B393-2520E71A75D8")
        }), reference.name == "M21 Files", reference.folder == "probe-m21-finder", !reference.removing,
           let bookmark = reference.activeWriteBookmark,
           let grant = settings.shares.first(where: { $0.id == reference.grantID }),
           let endpoint = ShareAddress(grant.mountFrom), endpoint.host == "127.0.0.1",
           endpoint.share == M22FinderProbe.share, endpoint.account == "_tinymounter_m19",
           grant.host == endpoint.host, grant.share == endpoint.share, grant.account == endpoint.account else {
            throw M22FinderProbe.Failure.check("pinned-M21-write-grant")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        try M22FinderProbe.require(!stale && ShareAccess.filePath(url) == M22FinderProbe.mount,
                                   "explicit-share-root-write-bookmark")
        return (reference, grant, bookmark)
    }

    private func m22FinderExclusive(_ settings: AppSettings, folder: String, allowed: UUID?) throws {
        let grants = Set(settings.shares.filter {
            $0.isSameShare(host: "127.0.0.1", share: M22FinderProbe.share)
        }.map(\.id))
        let wanted = NameKey(folder).value
        for record in settings.locations where grants.contains(record.grantID) && record.id != allowed {
            let path = NameKey(record.folder).value
            try M22FinderProbe.require(!path.isEmpty && path != wanted
                && !path.hasPrefix(wanted + "/") && !wanted.hasPrefix(path + "/"), "overlapping-location")
        }
    }

    private func m22FinderSetup(_ run: UUID) async throws -> M22FinderProbe.Config {
        guard let settings = store.settings else { throw M22FinderProbe.Failure.check("settings") }
        let pointer = try SharedContainer.url().appending(path: "M22Finder-active.json")
        try M22FinderProbe.require(!FileManager.default.fileExists(atPath: pointer.path), "existing-trace-session")
        let (reference, grant, bookmark) = try m22FinderGrant(settings)
        let folder = "probe-m22-finder-" + run.uuidString
        try m22FinderExclusive(settings, folder: folder, allowed: nil)
        try M22FinderProbe.require(!settings.savedKeeps.contains { list in
            list.host == grant.host && list.share == grant.share && list.paths.contains {
                let path = NameKey($0.path).value, wanted = NameKey(folder).value
                return path == wanted || path.hasPrefix(wanted + "/")
            }
        }, "existing-saved-keeps-inside-new-fixture")
        guard let source = sources[reference.domainID] else { throw LocationError.catalogClosed }
        try await Self.offMain {
            try source.access.withSession { session, _ in
                guard let endpoint = ShareAddress(session.identity.mountFrom) else {
                    throw M22FinderProbe.Failure.check("session-endpoint")
                }
                try M22FinderProbe.require(source.access.mountPath() == M22FinderProbe.mount
                    && session.identity.typeName == "smbfs" && endpoint.host == "127.0.0.1"
                    && endpoint.share == M22FinderProbe.share && endpoint.account == "_tinymounter_m19", "session-pin")
                let root = try session.locationRoot(RelativePath(folder)!)
                let fd = openat(root, "marker.txt", O_RDONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw M22FinderProbe.Failure.check("fixture-marker-open") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                try M22FinderProbe.require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                    && info.st_nlink == 1 && info.st_size < 128, "ordinary-fixture-marker")
                let marker = try handle.read(upToCount: 128)
                try M22FinderProbe.require(marker == Data(("tinymounter-m22-finder:" + run.uuidString + "\n").utf8),
                                           "fixture-marker")
            }
        }
        let channel = try M22FinderProbe.directory(run)
        try M22FinderProbe.require(mkdir(channel.path, 0o700) == 0, "new-channel-required")
        try M22FinderProbe.require(mkdir(channel.appending(path: "events").path, 0o700) == 0, "new-events-required")
        let privateRoot = URL.applicationSupportDirectory.appending(path: "tinymounter/M22Finder")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        let privateRun = privateRoot.appending(path: run.uuidString)
        try M22FinderProbe.require(mkdir(privateRun.path, 0o700) == 0, "new-private-run-required")
        try M22FinderProbe.save(settings, to: privateRun.appending(path: "original-settings.json"))
        let id = UUID()
        try M22FinderProbe.save(["run": run.uuidString, "location": id.uuidString, "folder": folder],
                                to: channel.appending(path: "setup-started.json"))
        let record = try await add(id: id, name: "M22 Finder " + run.uuidString,
            folder: RelativePath(folder)!, grantID: grant.id, writeBookmark: bookmark)
        let config = M22FinderProbe.Config(run: run, location: id, grant: grant.id, domain: record.domainID)
        try M22FinderProbe.save(config, to: channel.appending(path: "config.json"))
        try M22FinderProbe.save(config, to: pointer)
        return config
    }

    private func m22FinderSnapshot(_ config: M22FinderProbe.Config, label: String) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let settings = store.settings, let record = settings.locations.first(where: { $0.id == config.location }),
              record.folder == config.folder, record.domainID == config.domain, record.grantID == config.grant,
              record.activeWriteBookmark != nil, !record.removing,
              let source = sources[config.domain], let domain = domains[config.domain],
              let manager = NSFileProviderManager(for: domain) else { throw LocationError.catalogClosed }
        _ = try m22FinderGrant(settings)
        try m22FinderExclusive(settings, folder: config.folder, allowed: config.location)
        let originalURL = URL.applicationSupportDirectory.appending(
            path: "tinymounter/M22Finder/" + config.run.uuidString + "/original-settings.json")
        let original = try M22FinderProbe.load(AppSettings.self, from: originalURL)
        var withoutTask = settings
        withoutTask.locations.removeAll { $0.id == config.location }
        let preserved = withoutTask == original
        let rows = try await Self.offMain { try M22FinderProbe.rows(source) }
        var local: [M22FinderProbe.Local] = []
        for row in rows where row.kind == "file" {
            do {
                let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(row.id))
                local.append(try await Self.offMain { try M22FinderProbe.hashLocal(row, url: url) })
            } catch {
                let failure = error as NSError
                local.append(M22FinderProbe.Local(item: row.id, url: "", state:
                    "unverified:" + failure.domain + ":" + String(failure.code)))
            }
        }
        let after = try await Self.offMain { try M22FinderProbe.rows(source) }
        try M22FinderProbe.require(rows == after, "catalog-changed-during-snapshot")
        let saved = try M22FinderProbe.load(AppSettings.self, from: store.url)
        try M22FinderProbe.require(store.settings == settings && saved == settings, "settings-changed-during-snapshot")
        let moves = try await Self.offMain {
            try LocationSource.renameOutbox().intents().compactMap { intent -> PendingFolderMove? in
                guard case .folder(let move) = intent, move.owner == config.domain else { return nil }
                return move
            }
        }
        let pending = try await SystemPendingObserver.read(manager)
        try M22FinderProbe.require(!pending.incomplete, "pending-items-complete")
        let snapshot = M22FinderProbe.Snapshot(config: config, label: label,
            date: ISO8601DateFormatter().string(from: .now), started: started,
            ended: DispatchTime.now().uptimeNanoseconds, settingsPreserved: preserved,
            pendingKeeps: record.pendingKeeps, rows: rows, local: local, moves: moves,
            pendingItems: pending.items.count)
        try M22FinderProbe.save(snapshot, to: M22FinderProbe.directory(config.run).appending(path: label + ".json"))
        try M22FinderProbe.require(preserved, "original-settings-changed")
    }

    // Invoke once after normal launch reconciliation; the parent owns the only running main app.
    func runM22FinderFixture() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--m22-finder") else { return }
        do {
            try M22FinderProbe.require(arguments.count == index + 3 && isReady, "setup-or-resume-run-arguments")
            guard let run = UUID(uuidString: arguments[index + 2]), run.uuidString == arguments[index + 2] else {
                throw M22FinderProbe.Failure.check("uppercase-run-UUID")
            }
            let config: M22FinderProbe.Config
            if arguments[index + 1] == "setup" { config = try await m22FinderSetup(run) }
            else {
                try M22FinderProbe.require(arguments[index + 1] == "resume", "setup-or-resume")
                config = try M22FinderProbe.load(M22FinderProbe.Config.self,
                    from: M22FinderProbe.directory(run).appending(path: "config.json"))
                try M22FinderProbe.require(config.run == run, "resume-run")
                let active = try M22FinderProbe.load(M22FinderProbe.Config.self,
                    from: SharedContainer.url().appending(path: "M22Finder-active.json"))
                try M22FinderProbe.require(active == config, "resume-active-session")
            }
            let channel = try M22FinderProbe.directory(run)
            while !Task.isCancelled {
                let files = try FileManager.default.contentsOfDirectory(at: channel, includingPropertiesForKeys: nil)
                for file in files.filter({ $0.lastPathComponent.hasPrefix("request-") && $0.pathExtension == "json" }) {
                    let request = try M22FinderProbe.load(M22FinderProbe.Request.self, from: file)
                    try M22FinderProbe.require(request.run == run && M22FinderProbe.labels.contains(request.label)
                        && file.lastPathComponent == "request-" + request.id.uuidString + ".json", "request-scope")
                    let result = channel.appending(path: "result-" + request.id.uuidString + ".json")
                    let start = channel.appending(path: "started-" + request.id.uuidString + ".json")
                    if FileManager.default.fileExists(atPath: start.path) { continue }
                    try M22FinderProbe.save(request, to: start)
                    do {
                        try await m22FinderSnapshot(config, label: request.label)
                        try M22FinderProbe.save(["label": request.label, "result": "captured"], to: result)
                    } catch {
                        let failure = error as NSError
                        try M22FinderProbe.save(["label": request.label, "result": "failed",
                            "errorDomain": failure.domain, "errorCode": String(failure.code)], to: result)
                    }
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            let failure = error as NSError
            M22FinderProbe.logger.error("m22_finder_action_failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        }
    }
}
#endif
