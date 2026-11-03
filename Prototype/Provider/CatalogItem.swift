import FileProvider
import OSLog
import UniformTypeIdentifiers

/// File Provider permits creation only in a location with explicit write access.
final class CatalogItem: NSObject, NSFileProviderItem {
    private let row: CatalogRow
    private let contentVersion: String
    init(_ row: CatalogRow, contentVersion: String? = nil) {
        self.row = row
        self.contentVersion = contentVersion ?? row.contentVersion
    }

    private var isFolder: Bool { row.kind == .folder }
    private var allowsEditing: Bool {
        row.allowsWriting && EditRequest.supportsName(row.name) && !contentType.conforms(to: .package)
    }

    // The root row's ID is the root container's raw value.
    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(row.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(row.parentID ?? Catalog.rootItemID)
    }
    var filename: String { row.name }
    var contentType: UTType {
        isFolder ? .folder : UTType(filenameExtension: (row.name as NSString).pathExtension, conformingTo: .data) ?? .data
    }
    var documentSize: NSNumber? { isFolder ? nil : NSNumber(value: row.size) }
    var contentModificationDate: Date? { row.parentID == nil ? nil : row.modificationDate }
    var capabilities: NSFileProviderItemCapabilities {
        var result = organizationCapabilities
        if SourceReaderBridge.deletionEnabled, row.parentID != nil, allowsEditing,
           FileRenameRequest.supportsName(row.name),
           UTType(filenameExtension: (row.name as NSString).pathExtension)?.conforms(to: .package) != true {
            result.insert(.allowsDeleting)
        }
        return result
    }

    private var organizationCapabilities: NSFileProviderItemCapabilities {
        // Finder needs rename permission to choose a new name for an incoming copy in Keep Both.
        if isFolder {
            if SourceReaderBridge.folderOrganizationEnabled, row.parentID != nil, allowsEditing,
               FileRenameRequest.supportsName(row.name),
               UTType(filenameExtension: (row.name as NSString).pathExtension)?.conforms(to: .package) != true {
                return [.allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting]
            }
            return row.allowsWriting ? [.allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming]
                : .allowsContentEnumerating
        }
        if allowsEditing {
            return [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsWriting]
        }
        return row.allowsWriting ? [.allowsReading, .allowsRenaming] : .allowsReading
    }
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        if isFolder { return row.allowsWriting ? [.userReadable, .userWritable, .userExecutable] : [.userReadable, .userExecutable] }
        return allowsEditing ? [.userReadable, .userWritable] : .userReadable
    }
    /// While paused, kept files are lazy, so the system starts no eager downloads (plan §6).
    var contentPolicy: NSFileProviderContentPolicy {
        row.keep && !row.paused ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }
    var namespacePolicy: NSFileProviderNamespacePolicy {
        row.keep && !row.paused ? .materializeEagerly : .materializeLazily
    }
    var userInfo: [AnyHashable: Any]? {
        row.parentID == nil ? nil : ["keep": row.keep ? 1 : 0, "keepRequested": row.keepRequested ? 1 : 0]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(contentVersion.utf8),
                                  metadataVersion: Data(row.metadataVersion.utf8))
    }
}

/// Read-only, opened on first use and again after a failure, never created.
final class CatalogReader: @unchecked Sendable {
    private let domainID: String
    // The system SQLite can't share a connection between threads, so every use takes this lock.
    private let lock = NSLock()
    private var catalog: Catalog?
    private var reported = false
    private let logger = Logger(subsystem: "dev.tinymounter.prototype", category: "catalog")

    init(domainID: String) { self.domainID = domainID }

    /// A failed open or read is "catalog unavailable" (plan §7); `body`'s own errors pass through.
    func read<T>(_ body: (Catalog) throws -> T) throws -> T {
        try lock.withLock {
            let catalog: Catalog
            if let open = self.catalog {
                catalog = open
            } else {
                do {
                    catalog = try Catalog.open(at: SharedContainer.catalogURL(domainID: domainID), domainID: domainID)
                } catch {
                    throw unavailable(error)
                }
                self.catalog = catalog
                reported = false
            }
            do {
                return try body(catalog)
            } catch CatalogError.pageExpired {
                throw NSFileProviderError(.pageExpired)
            } catch CatalogError.anchorExpired {
                throw NSFileProviderError(.syncAnchorExpired)
            } catch let error where error is SQLiteError || error is CatalogError {
                self.catalog = nil
                throw unavailable(error)
            }
        }
    }

    /// Only a tombstone gives `noSuchItem`; an unknown ID is transient (plan §7).
    func liveRow(_ id: String) throws -> CatalogRow {
        guard let row = try read({ try $0.item(id: id) }) else { throw CocoaError(.fileReadUnknown) }
        guard !row.deleted else { throw NSFileProviderError(.noSuchItem) }
        return row
    }

    /// Logs once per outage: a missed fixture domain fails every call.
    private func unavailable(_ error: Error) -> Error {
        if !reported {
            reported = true
            logger.error("""
                catalog_unavailable domain=\(self.domainID, privacy: .public) \(Self.fields(error), privacy: .public)
                """)
        }
        return NSFileProviderError(.serverUnreachable)
    }

    private static func fields(_ error: Error) -> String {
        switch error {
        case let error as SQLiteError: "sqlite=\(error.code) operation=\(error.operation)"
        case let error as CatalogError: "catalog=\(error)"
        default: "error_domain=\((error as NSError).domain) code=\((error as NSError).code)"
        }
    }
}
