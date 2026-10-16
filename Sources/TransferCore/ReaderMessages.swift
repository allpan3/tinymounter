import Foundation

/// JSON between the extension and the app's reader. Messages hold IDs and counts, never names.
public enum ReaderMessage {
    public static let maxBytes = 4096

    /// The catalog's item IDs: the root constant, or a UUID string as `UUID().uuidString` writes it.
    public static func isItemID(_ id: String) -> Bool {
        id == Catalog.rootItemID || UUID(uuidString: id)?.uuidString == id
    }

    public static func encode(_ message: some Encodable) throws -> Data {
        let data = try JSONEncoder().encode(message)
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
    /// The folder row's `list_gen` after the listing; unchanged if the app held the plan (D5).
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

    public init(id: UUID, item: String, version: String, range: ByteRange) throws {
        guard ReaderMessage.isItemID(item), version.utf8.count <= Self.maxVersionBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.id = id
        self.item = item
        self.version = version
        self.range = range
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id), item: container.decode(String.self, forKey: .item),
                      version: container.decode(String.self, forKey: .version),
                      range: container.decode(ByteRange.self, forKey: .range))
    }
}

/// A worker began the fetch's transfer in the app, so the extension's `StallDeadline` starts (D2).
public struct SourceReadStarted: Codable, Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) { self.id = id }
}

public struct SourceReadReceipt: Codable, Sendable {
    public let stagingName: String
    public let metrics: TransferMetrics

    public init(stagingName: String, metrics: TransferMetrics) {
        self.stagingName = stagingName
        self.metrics = metrics
    }
}
