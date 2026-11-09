import Foundation

/// One page of an enumeration and the token of the next; `next` nil ends it.
public struct CatalogPage: Sendable {
    public static let defaultSize = 200
    public static let maxSize = 1000

    public let rows: [CatalogRow]
    public let next: Data?

    /// The system's suggestion, or 200, kept within 1...1,000.
    public static func size(suggested: Int?) -> Int { min(max(suggested ?? defaultSize, 1), maxSize) }

    init(rows: [CatalogRow], size: Int, token: (Int64) -> Data) {
        self.rows = rows
        next = rows.count < size ? nil : rows.last.map { token($0.row) }
    }
}

/// A reimport `createItem` with `.mayAlreadyExist`.
public enum ReimportDecision: Sendable {
    /// The disk item is this live row's copy; `fetchContent` when its data may be another version.
    case existing(CatalogRow, fetchContent: Bool)
    /// Complete with nil, which deletes the disk copy: a file without contents that no row has.
    case discard
    /// Keep `fileWriteNoPermission`: the disk item can be the user's only copy.
    case reject
}

extension Catalog {
    /// `token` nil is the first page. A malformed token, or another folder's row, gives `pageExpired`.
    public func folderPage(_ folderID: String, token: Data?, size: Int) throws -> CatalogPage {
        let after = try token.map { token in
            guard let row = CatalogCursor.folderPageRow(token) else { throw CatalogError.pageExpired }
            return row
        }
        return CatalogPage(rows: try children(of: folderID, afterRow: after, limit: size), size: size,
                           token: CatalogCursor.folderPage(after:))
    }

    public func workingSetPage(token: Data?, size: Int) throws -> CatalogPage {
        let after = try token.map { token in
            guard let row = CatalogCursor.workingSetPageRow(token) else { throw CatalogError.pageExpired }
            return row
        }
        return CatalogPage(rows: try workingSet(afterRow: after, limit: size), size: size,
                           token: CatalogCursor.workingSetPage(after:))
    }

    /// `kind`, `size` and `modified` are the template's; `kind` is nil if not a file or a folder.
    public func reimportDecision(parent parentID: String, name: String, kind: CatalogRow.Kind?,
                                 hasContents: Bool, size: Int64?, modified: Date?) throws -> ReimportDecision {
        // Only a complete listing of the parent can show that no row matches.
        guard let kind, let parent = try item(id: parentID), parent.kind == .folder, !parent.deleted,
              parent.listGen != nil else { return .reject }
        if let match = try liveChild(parent: parentID, nameKey: NameKey(name)) {
            guard match.kind == kind else { return .reject }
            guard kind == .file, hasContents else { return .existing(match, fetchContent: false) }
            // The NAS is the source of truth, so disk data that may be another version is fetched.
            let current = size == match.size && Self.matchesMtime(modified, of: match)
            return .existing(match, fetchContent: !current)
        }
        return kind == .file && !hasContents ? .discard : .reject
    }

    /// Under 1 µs apart as Dates measure it: a Date can't carry the NAS's nanoseconds.
    private static func matchesMtime(_ date: Date?, of row: CatalogRow) -> Bool {
        date.map { abs($0.timeIntervalSince(row.modificationDate)) < 1e-6 } ?? false
    }
}
