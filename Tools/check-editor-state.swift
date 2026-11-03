// Included only in the isolated VM candidate by prepare-folder-candidate.py.
extension M22FinderProbe {
    struct EditorState: Codable {
        let config: Config
        let date: String
        let connected: Bool
        let rows: [Row]
        let local: [Local]
        let edits: [PendingEdit]
        let verifiedPayloads: [UUID]
        let pending: [[String: String]]
        let pendingSetCapped: Bool
    }

    static func editedLocal(_ row: Row, url: URL) throws -> Local {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        try require(lstat(url.path, &info) == 0, "editor-local-stat")
        let current = Row(id: row.id, parent: row.parent, path: row.path, kind: row.kind,
            content: row.content, metadata: row.metadata, size: info.st_size, keep: row.keep,
            requested: row.requested, complete: row.complete, listed: row.listed)
        return try hashLocal(current, url: url)
    }
}

extension LocationController {
    private func checkEditorState(_ config: M22FinderProbe.Config, label: String) async throws {
        guard let settings = store.settings,
              let record = settings.locations.first(where: { $0.id == config.location }),
              record.folder == config.folder, record.domainID == config.domain,
              record.grantID == config.grant, !record.removing,
              let source = sources[config.domain], let domain = domains[config.domain],
              let manager = NSFileProviderManager(for: domain) else { throw LocationError.catalogClosed }
        let rows = try await Self.offMain { try M22FinderProbe.rows(source) }
        var local: [M22FinderProbe.Local] = []
        for row in rows where row.kind == "file" {
            do {
                let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(row.id))
                local.append(try await Self.offMain { try M22FinderProbe.editedLocal(row, url: url) })
            } catch {
                let failure = error as NSError
                local.append(M22FinderProbe.Local(item: row.id, url: "", state:
                    "unverified:" + failure.domain + ":" + String(failure.code)))
            }
        }
        let (edits, verified) = try await Self.offMain {
            try source.uploadLock.readForStatus {
                let outbox = try LocationSource.editOutbox(domainID: config.domain)
                let records = try outbox.records()
                var verified: [UUID] = []
                for edit in records where edit.isPending {
                    try outbox.validateContents(edit)
                    verified.append(edit.id)
                }
                return (records, verified)
            }
        }
        let enumerator = manager.enumeratorForPendingItems()
        defer { enumerator.invalidate() }
        let observer = EditorPendingObserver()
        var page: NSFileProviderPage? = NSFileProviderPage(Data())
        while let current = page { page = try await observer.next(enumerator, page: current) }
        try M22FinderProbe.require(rows == (try await Self.offMain { try M22FinderProbe.rows(source) }),
                                   "editor-catalog-changed-during-snapshot")
        let snapshot = M22FinderProbe.EditorState(config: config,
            date: ISO8601DateFormatter().string(from: .now), connected: source.access.mountPath() != nil,
            rows: rows, local: local, edits: edits, verifiedPayloads: verified,
            pending: observer.items, pendingSetCapped: enumerator.isMaximumSizeReached)
        try M22FinderProbe.save(snapshot,
            to: M22FinderProbe.directory(config.run).appending(path: label + ".json"))
    }
}

private final class EditorPendingObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var found: [[String: String]] = []
    private var waiting: CheckedContinuation<NSFileProviderPage?, Error>?
    var items: [[String: String]] { lock.withLock { found } }

    func next(_ enumerator: NSFileProviderEnumerator, page: NSFileProviderPage) async throws -> NSFileProviderPage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            enumerator.enumerateItems(for: self, startingAt: page)
        }
    }

    func didEnumerate(_ items: [NSFileProviderItem]) {
        let values = items.map { item in
            M22FinderProbe.item(item).merging([
                "uploaded": item.isUploaded.map { String($0) } ?? "unspecified",
                "uploading": item.isUploading.map { String($0) } ?? "unspecified"
            ]) { _, new in new }
        }
        lock.withLock { found += values }
    }

    func finishEnumerating(upTo page: NSFileProviderPage?) { take()?.resume(returning: page) }
    func finishEnumeratingWithError(_ error: Error) { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<NSFileProviderPage?, Error>? {
        lock.withLock { defer { waiting = nil }; return waiting }
    }
}
