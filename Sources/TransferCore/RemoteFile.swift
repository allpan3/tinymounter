import Foundation

public struct RemoteFileIdentity: Codable, Equatable, Sendable {
    public let fileID: UInt64
    public let birthMicroseconds: UInt64

    public init(fileID: UInt64, birthMicroseconds: UInt64) throws {
        guard fileID != 0, birthMicroseconds != 0 else { throw UploadError.unresolved }
        self.fileID = fileID
        self.birthMicroseconds = birthMicroseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fileID: values.decode(UInt64.self, forKey: .fileID),
                      birthMicroseconds: values.decode(UInt64.self, forKey: .birthMicroseconds))
    }
}

public struct RemoteFileVersion: Codable, Equatable, Sendable {
    public let identity: RemoteFileIdentity
    public let size: Int64
    public let modifiedMicroseconds: UInt64
    public let changedMicroseconds: UInt64
    public let attributes: UInt32

    public init(identity: RemoteFileIdentity, size: Int64, modifiedMicroseconds: UInt64,
                changedMicroseconds: UInt64, attributes: UInt32) throws {
        guard size >= 0 else { throw UploadError.unresolved }
        self.identity = identity
        self.size = size
        self.modifiedMicroseconds = modifiedMicroseconds
        self.changedMicroseconds = changedMicroseconds
        self.attributes = attributes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: values.decode(RemoteFileIdentity.self, forKey: .identity),
                      size: values.decode(Int64.self, forKey: .size),
                      modifiedMicroseconds: values.decode(UInt64.self, forKey: .modifiedMicroseconds),
                      changedMicroseconds: values.decode(UInt64.self, forKey: .changedMicroseconds),
                      attributes: values.decode(UInt32.self, forKey: .attributes))
    }

    public func hasSameDataVersion(as other: RemoteFileVersion) -> Bool {
        identity == other.identity && size == other.size && modifiedMicroseconds == other.modifiedMicroseconds
    }

    public var fingerprint: ContentFingerprint {
        get throws {
            try ContentFingerprint(smbSize: size, modifiedMicroseconds: modifiedMicroseconds,
                                   changedMicroseconds: changedMicroseconds)
        }
    }
}

public struct FileRevision: Codable, Equatable, Sendable {
    public let id: UUID
    public let item: String
    public let version: RemoteFileVersion
    public var contentVersion: String { "r1:" + id.uuidString }

    public init(id: UUID = UUID(), item: String, version: RemoteFileVersion) throws {
        guard ReaderMessage.isItemID(item), item != Catalog.rootItemID else { throw UploadError.invalidRequest }
        self.id = id
        self.item = item
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), item: values.decode(String.self, forKey: .item),
                      version: values.decode(RemoteFileVersion.self, forKey: .version))
    }
}
