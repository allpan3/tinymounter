import Foundation

public struct PendingChange: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let originalPath: String?

    public init(item: String, name: String, parent: String, trashed: Bool, organizationRefused: Bool,
                hasUnresolvedRename: Bool, catalog: Catalog) throws {
        id = item
        path = try catalog.relativePath(of: parent)?.appending(name)?.string ?? name
        if organizationRefused, !trashed, !hasUnresolvedRename,
           let row = try catalog.item(id: item), !row.deleted {
            originalPath = try catalog.relativePath(of: item)?.string
        } else {
            originalPath = nil
        }
    }
}
