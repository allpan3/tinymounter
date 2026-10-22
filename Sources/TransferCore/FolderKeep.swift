import Foundation

public struct KeepPath: Codable, Hashable, Sendable {
    public let path: String
    public let kind: CatalogRow.Kind

    public init(path: String, kind: CatalogRow.Kind) {
        self.path = path
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let legacy = try? single.decode(String.self) {
            self.init(path: legacy, kind: .file)
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(path: try values.decode(String.self, forKey: .path),
                      kind: try values.decode(CatalogRow.Kind.self, forKey: .kind))
        }
        guard let relative = RelativePath(path), !relative.isRoot || kind == .folder else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Invalid kept path")
        }
    }

    public func below(_ folder: RelativePath) -> RelativePath? {
        if path.utf8.elementsEqual(folder.string.utf8) { return kind == .folder ? .root : nil }
        return LocationRecord.path(path, inside: folder)
    }
}

public struct FolderKeepSnapshot: Equatable, Sendable {
    public let items: [CatalogRow]
    public var requests: [CatalogRow] { items.filter(\.keepRequested) }

    public func states(files: [String: OfflineState], folders: Set<String>) -> [String: OfflineState] {
        let children = Dictionary(grouping: items, by: \.parentID)
        return Dictionary(uniqueKeysWithValues: requests.map { root in
            guard root.kind == .folder else { return (root.id, files[root.id] ?? .requested) }
            var pending = [root]
            var seen: Set<String> = []
            var state = OfflineState.availableOffline
            var incomplete = false
            while let row = pending.popLast() {
                guard seen.insert(row.id).inserted else { incomplete = true; continue }
                if row.kind == .folder {
                    if !row.listingComplete || row.listGen == nil
                        || row.id != Catalog.rootItemID && !folders.contains(row.id) { incomplete = true }
                    pending += children[row.id] ?? []
                } else {
                    switch files[row.id] ?? .requested {
                    case .notSufficientSpace: return (root.id, .notSufficientSpace)
                    case .requested: incomplete = true
                    case .updateInProgress: state = .updateInProgress
                    case .availableOffline: break
                    }
                }
            }
            return (root.id, incomplete ? .requested : state)
        })
    }
}

extension Catalog {
    public func keepSnapshot() throws -> FolderKeepSnapshot {
        FolderKeepSnapshot(items: try keptItems())
    }

    public func keepRequests() throws -> [CatalogRow] {
        try items("SELECT \(CatalogRow.columns) FROM items WHERE keep_request = 1 AND deleted = 0 ORDER BY row")
    }
}
