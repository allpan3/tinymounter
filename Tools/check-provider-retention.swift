import FileProvider
import Foundation

@main
enum ProviderRetentionCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try Catalog.create(at: directory.appending(path: "catalog.sqlite"),
                                         domainID: UUID().uuidString, rootName: "test")
        try list(catalog, Catalog.rootItemID, [entry("kept"), entry("plain"), entry("tree", .folder)])
        let kept = try child(catalog, Catalog.rootItemID, "kept")
        let plain = try child(catalog, Catalog.rootItemID, "plain")
        let tree = try child(catalog, Catalog.rootItemID, "tree")
        try list(catalog, tree.id, [entry("inherited")])
        let inherited = try child(catalog, tree.id, "inherited")
        try catalog.setKeep(ids: [kept.id, tree.id], value: true)

        for paused in [false, true, false] {
            try catalog.setPaused(paused)
            for original in [kept, tree, inherited] {
                let row = try catalog.item(id: original.id)!
                precondition(row.contentVersion == original.contentVersion)
                precondition(row.keep && row.paused == paused)
                precondition(CatalogItem(row).contentPolicy == .downloadEagerlyAndKeepDownloaded,
                             "Pause made kept contents evictable")
            }
            let folder = CatalogItem(try catalog.item(id: tree.id)!)
            let ordinary = CatalogItem(try catalog.item(id: plain.id)!)
            precondition(folder.namespacePolicy == (paused ? .materializeLazily : .materializeEagerly))
            precondition(ordinary.contentPolicy == .downloadLazily)
        }

        try catalog.setPaused(true)
        try list(catalog, tree.id, [entry("inherited"), entry("new")])
        let new = try child(catalog, tree.id, "new")
        precondition(new.keep && !new.keepRequested && new.paused)
        precondition(CatalogItem(new).contentPolicy == .downloadEagerlyAndKeepDownloaded)
        try catalog.setKeep(ids: [kept.id], value: false)
        let released = CatalogItem(try catalog.item(id: kept.id)!)
        let stillKept = CatalogItem(try catalog.item(id: inherited.id)!)
        precondition(released.contentPolicy == .downloadLazily)
        precondition(stillKept.contentPolicy == .downloadEagerlyAndKeepDownloaded)
        try catalog.setKeep(ids: [tree.id], value: false)
        for original in [tree, inherited, new] {
            let item = CatalogItem(try catalog.item(id: original.id)!)
            precondition(item.contentPolicy == .downloadLazily)
        }
        print("Provider retention: explicit and inherited keeps, Pause, Resume and Allow Removal passed")
    }

    private static func child(_ catalog: Catalog, _ parent: String, _ name: String) throws -> CatalogRow {
        guard let row = try catalog.liveChild(parent: parent, nameKey: NameKey(name)) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return row
    }

    private static func list(_ catalog: Catalog, _ parent: String, _ entries: [DirectoryListing.Parsed]) throws {
        try catalog.reconcile(folder: parent, listing: DirectoryListing(entries)) { _ in true }
    }

    private static func entry(_ name: String, _ kind: DirectoryListing.Entry.Kind = .file) -> DirectoryListing.Parsed {
        .entry(.init(name: name, kind: kind, size: kind == .file ? 1 : 0, mtimeNs: 1, ctimeNs: 1, fileID: 1))
    }
}
