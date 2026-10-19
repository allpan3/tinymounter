import FileProvider

final class FinderDownloadProgress: @unchecked Sendable {
    private final class Publication {
        let progress: Progress
        var users = 1
        var url: URL?
        var scoped = false

        init(size: Int64) {
            progress = Progress(totalUnitCount: size)
            progress.kind = .file
            progress.fileOperationKind = .downloading
            progress.isCancellable = false
            progress.isPausable = false
        }

        func stop() {
            guard let url else { return }
            progress.unpublish()
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private let lock = NSLock()
    private var publications: [String: Publication] = [:]
    private var closed = false

    func track(item: CatalogRow, progress: Progress, catalog: CatalogReader,
               manager: NSFileProviderManager) -> () -> Void {
        let folders: [String] = (try? catalog.read { catalog in
            var folders: [String] = []
            var parent = item.parentID
            var seen: Set<String> = []
            while let id = parent, seen.insert(id).inserted, let row = try catalog.item(id: id), !row.deleted {
                if row.keep { folders.append(id) }
                parent = row.parentID
            }
            return folders
        }) ?? []
        let items: [String] = [item.id] + folders
        let created: [(String, Publication)] = self.lock.withLock {
            guard !closed else { return [] }
            var created: [(String, Publication)] = []
            for id in items {
                if let current = self.publications[id] {
                    current.users += 1
                    continue
                }
                let publication = Publication(size: id == item.id ? item.size : 0)
                self.publications[id] = publication
                created.append((id, publication))
            }
            return created
        }
        for (id, publication) in created {
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(id)) { [weak self] url, _ in
                guard let self, let url else { return }
                self.lock.withLock {
                    guard self.publications[id] === publication else { return }
                    publication.scoped = url.startAccessingSecurityScopedResource()
                    publication.url = url
                    publication.progress.fileURL = url
                    publication.progress.publish()
                }
            }
        }
        let observation = progress.observe(\.completedUnitCount, options: [.initial]) { [weak self] observed, _ in
            guard let self else { return }
            self.lock.withLock {
                guard let publication = self.publications[item.id] else { return }
                publication.progress.completedUnitCount = max(publication.progress.completedUnitCount,
                                                             min(item.size, observed.completedUnitCount))
            }
        }
        return { [self] in
            observation.invalidate()
            self.lock.withLock {
                for id in items {
                    guard let publication = self.publications[id] else { continue }
                    publication.users -= 1
                    if publication.users == 0 {
                        self.publications[id] = nil
                        publication.stop()
                    }
                }
            }
        }
    }

    func invalidate() {
        self.lock.withLock {
            closed = true
            publications.values.forEach { $0.stop() }
            publications.removeAll()
        }
    }
}
