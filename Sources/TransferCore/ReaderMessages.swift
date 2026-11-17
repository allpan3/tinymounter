import Foundation

/// Bounded JSON between the extension and the app; source values are never logged.
public enum ReaderMessage {
    public static let maxBytes = 8192

    /// The catalog's item IDs: the root constant, or a UUID string as `UUID().uuidString` writes it.
    public static func isItemID(_ id: String) -> Bool {
        id == Catalog.rootItemID || UUID(uuidString: id)?.uuidString == id
    }

    public static func encode(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(message)
        guard data.count <= maxBytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        guard data.count <= maxBytes, let message = try? JSONDecoder().decode(type, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return message
    }
}

public struct ListRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let folder: String

    public init(id: UUID = UUID(), folder: String) throws {
        guard ReaderMessage.isItemID(folder) else { throw CocoaError(.fileReadCorruptFile) }
        self.id = id
        self.folder = folder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      folder: container.decode(String.self, forKey: .folder))
    }
}

public struct ListReceipt: Codable, Equatable, Sendable {
    /// The folder row's `list_gen` after the listing; unchanged if the app held the plan.
    public let generation: Int64
    /// The folder's live children after the listing.
    public let entries: Int
    /// Rows inserted, updated or tombstoned.
    public let changed: Int
    /// Listed names that Finder doesn't show: other kinds, invalid names, collisions, new unreadable.
    public let skipped: Int

    public init(generation: Int64, entries: Int, changed: Int, skipped: Int) throws {
        guard generation >= 0, entries >= 0, changed >= 0, skipped >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        self.generation = generation
        self.entries = entries
        self.changed = changed
        self.skipped = skipped
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(generation: container.decode(Int64.self, forKey: .generation),
                      entries: container.decode(Int.self, forKey: .entries),
                      changed: container.decode(Int.self, forKey: .changed),
                      skipped: container.decode(Int.self, forKey: .skipped))
    }
}

public struct SourceReadRequest: Codable, Equatable, Sendable {
    /// File Provider's limit for a content version.
    public static let maxVersionBytes = 128

    public let id: UUID
    public let item: String
    /// The row's `contentVersion` that the extension checked against the requested version.
    public let version: String
    public let range: ByteRange
    /// A system or speculative fetch, which no user waits for; Pause Downloads stops these.
    public let background: Bool

    public init(id: UUID, item: String, version: String, range: ByteRange, background: Bool) throws {
        guard ReaderMessage.isItemID(item), version.utf8.count <= Self.maxVersionBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.id = id
        self.item = item
        self.version = version
        self.range = range
        self.background = background
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id), item: container.decode(String.self, forKey: .item),
                      version: container.decode(String.self, forKey: .version),
                      range: container.decode(ByteRange.self, forKey: .range),
                      background: container.decode(Bool.self, forKey: .background))
    }
}

/// A worker began the fetch's transfer in the app, so the extension's `StallDeadline` starts.
public struct SourceReadStarted: Codable, Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) { self.id = id }
}

/// Keep Downloaded (`keep` true) or Allow Removal. Only the app writes the requests.
public struct KeepRequest: Codable, Equatable, Sendable {
    /// 100 UUIDs make a message of about 4,000 bytes, within `ReaderMessage.maxBytes`.
    public static let maxItems = 100
    public static let maxItemsPerAction = 1_000

    public let id: UUID
    public let items: [String]
    public let keep: Bool

    /// The root's longer ID would break the message size bound.
    public init(id: UUID = UUID(), items: [String], keep: Bool) throws {
        guard (1...Self.maxItems).contains(items.count),
              items.allSatisfy({ $0 != Catalog.rootItemID && ReaderMessage.isItemID($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.id = id
        self.items = items
        self.keep = keep
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id), items: container.decode([String].self, forKey: .items),
                      keep: container.decode(Bool.self, forKey: .keep))
    }

    /// One action's items in messages of at most `maxItems`; more than `maxItemsPerAction` is refused.
    public static func batches(_ items: [String], keep: Bool) throws -> [KeepRequest] {
        guard items.count <= maxItemsPerAction else { throw CocoaError(.featureUnsupported) }
        return try stride(from: 0, to: items.count, by: maxItems).map {
            try KeepRequest(items: Array(items[$0..<min($0 + maxItems, items.count)]), keep: keep)
        }
    }
}

public struct KeepReceipt: Codable, Equatable, Sendable {
    /// Catalog updates caused by this action, including inherited retention.
    public let changed: Int

    public init(changed: Int) throws {
        guard changed >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        self.changed = changed
    }

    public init(from decoder: any Decoder) throws {
        try self.init(changed: decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .changed))
    }
}

public struct SourceReadReceipt: Codable, Sendable {
    public let stagingName: String
    public let metrics: TransferMetrics

    public init(stagingName: String, metrics: TransferMetrics) {
        self.stagingName = stagingName
        self.metrics = metrics
    }
}

public struct CreateRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let template: String
    public let parent: String
    public let name: String
    public let kind: CatalogRow.Kind
    public let staging: UUID?
    /// The new file's `contentModificationDate`, which the server keeps after the upload.
    public let modified: Date?
    public let recoveringReimport: Bool

    public init(id: UUID = UUID(), template: String, parent: String, name: String,
                kind: CatalogRow.Kind, staging: UUID?, modified: Date? = nil,
                recoveringReimport: Bool = false) throws {
        guard !template.isEmpty, template.utf8.count <= 1024,
              ReaderMessage.isItemID(parent), RelativePath.isValidComponent(name),
              !name.hasPrefix(".tinymounter-"), kind == .file || staging == nil,
              !recoveringReimport || staging == nil else {
            throw UploadError.invalidRequest
        }
        self.id = id
        self.template = template
        self.parent = parent
        self.name = name
        self.kind = kind
        self.staging = staging
        self.modified = modified
        self.recoveringReimport = recoveringReimport
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), template: c.decode(String.self, forKey: .template),
                      parent: c.decode(String.self, forKey: .parent), name: c.decode(String.self, forKey: .name),
                      kind: c.decode(CatalogRow.Kind.self, forKey: .kind), staging: c.decodeIfPresent(UUID.self, forKey: .staging),
                      modified: c.decodeIfPresent(Date.self, forKey: .modified),
                      recoveringReimport: c.decode(Bool.self, forKey: .recoveringReimport))
    }
}

public struct CreateReceipt: Codable, Sendable {
    public let item: String
    public init(item: String) { self.item = item }
}

public struct DeleteItemRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let item: String
    public let contentVersion: String
    public let metadataVersion: String
    public let eventVersion: Data
    public let recursive: Bool

    public init(id: UUID = UUID(), item: String, contentVersion: String, metadataVersion: String,
                eventVersion: Data, recursive: Bool) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID,
              !contentVersion.isEmpty, contentVersion.utf8.count <= 128,
              metadataVersion.utf8.count <= 20, Int64(metadataVersion).map({ $0 >= 0 }) == true,
              !eventVersion.isEmpty, eventVersion.count <= Catalog.maxProviderDomainVersionBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.id = id
        self.item = item
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.eventVersion = eventVersion
        self.recursive = recursive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), item: values.decode(String.self, forKey: .item),
                      contentVersion: values.decode(String.self, forKey: .contentVersion),
                      metadataVersion: values.decode(String.self, forKey: .metadataVersion),
                      eventVersion: values.decode(Data.self, forKey: .eventVersion),
                      recursive: values.decode(Bool.self, forKey: .recursive))
    }
}

public struct DeleteItemReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let item: String

    public init(id: UUID, item: String) { self.id = id; self.item = item }
}

public struct FolderNameRequest: Codable, Sendable {
    public let id: UUID
    public let item: String
    public let parent: String
    public let name: String

    public init(id: UUID = UUID(), item: String, parent: String, name: String) throws {
        guard item != Catalog.rootItemID, ReaderMessage.isItemID(item), ReaderMessage.isItemID(parent),
              RelativePath.isValidComponent(name), !name.contains("\\"), !name.hasPrefix(".tinymounter-") else {
            throw UploadError.invalidRequest
        }
        self.id = id
        self.item = item
        self.parent = parent
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), item: c.decode(String.self, forKey: .item),
                      parent: c.decode(String.self, forKey: .parent), name: c.decode(String.self, forKey: .name))
    }
}


public enum UploadError: Error, Equatable, Sendable {
    case invalidRequest
    case collision
    case unresolved
    case pendingWrites
    case readOnly
    case editConflict
    /// The user stopped the upload; macOS keeps the item on this Mac.
    case excluded
    case reimportRecovery
}

public struct EditRequest: Codable, Sendable {
    public let id: UUID
    public let item: String
    public let parent: String
    public let name: String
    public let baseVersion: String
    public let staging: UUID
    public let failOnConflict: Bool
    /// The saved version's `contentModificationDate`, which the server keeps after the upload.
    public let modified: Date?

    public init(id: UUID = UUID(), item: String, parent: String, name: String, baseVersion: String,
                staging: UUID, failOnConflict: Bool, modified: Date? = nil) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID, ReaderMessage.isItemID(parent),
              RelativePath.isValidComponent(name), !name.contains("\\"), !name.contains(":"),
              baseVersion.utf8.count <= 128, Self.supportsName(name) else { throw UploadError.invalidRequest }
        self.id = id
        self.item = item
        self.parent = parent
        self.name = name
        self.baseVersion = baseVersion
        self.staging = staging
        self.failOnConflict = failOnConflict
        self.modified = modified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), item: c.decode(String.self, forKey: .item),
                      parent: c.decode(String.self, forKey: .parent), name: c.decode(String.self, forKey: .name),
                      baseVersion: c.decode(String.self, forKey: .baseVersion), staging: c.decode(UUID.self, forKey: .staging),
                      failOnConflict: c.decode(Bool.self, forKey: .failOnConflict),
                      modified: c.decodeIfPresent(Date.self, forKey: .modified))
    }

    public static func supportsName(_ name: String) -> Bool {
        let suffix = (name as NSString).pathExtension.lowercased()
        return !["db", "sqlite", "sqlite3", "sqlite-wal", "sqlite-shm", "vmdk", "qcow2", "vdi", "vhd", "vhdx",
                 "dmg", "sparseimage", "sparsebundle"].contains(suffix)
    }
}

public struct EditReceipt: Codable, Sendable {
    public let item: String
    public let contentVersion: String
    public init(item: String, contentVersion: String) {
        self.item = item
        self.contentVersion = contentVersion
    }
}

public struct FileRenameRequest: Codable, Sendable {
    public let id: UUID
    public let item: String
    public let parent: String
    public let name: String
    public let contentVersion: String
    public let metadataVersion: String
    public let changesName: Bool
    public let changesParent: Bool

    public init(id: UUID = UUID(), item: String, parent: String, name: String,
                contentVersion: String, metadataVersion: String,
                changesName: Bool = true, changesParent: Bool = true) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID, ReaderMessage.isItemID(parent),
              Self.supportsName(name), !contentVersion.isEmpty, contentVersion.utf8.count <= 128,
              metadataVersion.utf8.count <= 20, Int64(metadataVersion).map({ $0 >= 0 }) == true,
              changesName || changesParent else {
            throw UploadError.invalidRequest
        }
        self.id = id
        self.item = item
        self.parent = parent
        self.name = name
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.changesName = changesName
        self.changesParent = changesParent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), item: values.decode(String.self, forKey: .item),
                      parent: values.decode(String.self, forKey: .parent), name: values.decode(String.self, forKey: .name),
                      contentVersion: values.decode(String.self, forKey: .contentVersion),
                      metadataVersion: values.decode(String.self, forKey: .metadataVersion),
                      changesName: values.decodeIfPresent(Bool.self, forKey: .changesName) ?? true,
                      changesParent: values.decodeIfPresent(Bool.self, forKey: .changesParent) ?? false)
    }

    public func validateUnchangedFields(in row: CatalogRow) throws {
        guard row.id == item, changesParent || row.parentID == parent,
              changesName || row.name.utf8.elementsEqual(name.utf8) else { throw SourceFailure.versionChanged }
    }

    public static func supportsName(_ name: String) -> Bool {
        RelativePath.isValidComponent(name) && !name.utf8.contains(where: { "\\:*?\"<>|".utf8.contains($0) })
            && !name.hasPrefix(".tinymounter-") && EditRequest.supportsName(name)
    }
}
