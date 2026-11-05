import Foundation

public struct RenameDirectoryEntry: Sendable {
    public let name: String
    public let identity: RemoteFileIdentity
    public let attributes: UInt32
    public let size: Int64
    public let modifiedMicroseconds: UInt64
    public let changedMicroseconds: UInt64

    public var fingerprint: ContentFingerprint {
        get throws {
            try ContentFingerprint(smbSize: kind == .folder ? 0 : size,
                modifiedMicroseconds: modifiedMicroseconds, changedMicroseconds: changedMicroseconds)
        }
    }

    public var kind: CatalogRow.Kind? {
        guard attributes & 0x440 == 0 else { return nil }
        return attributes & 0x10 == 0 ? .file : .folder
    }

    public static func parse(_ bytes: [UInt8]) throws -> [RenameDirectoryEntry] {
        func integer(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset <= bytes.count - count else { throw UploadError.unresolved }
            return (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        guard !bytes.isEmpty else { throw UploadError.unresolved }
        var result: [RenameDirectoryEntry] = [], offset = 0
        while true {
            let next = Int(try integer(offset, 4)), length = Int(try integer(offset + 60, 4))
            guard length > 0, length % 2 == 0, offset <= bytes.count - 80,
                  length <= bytes.count - offset - 80 else { throw UploadError.unresolved }
            let nameBytes = Data(bytes[(offset + 80)..<(offset + 80 + length)])
            guard let name = String(data: nameBytes, encoding: .utf16LittleEndian) else { throw UploadError.unresolved }
            if name != ".", name != ".." {
                let ticks = try integer(offset + 8, 8)
                guard ticks / 10 > 11_644_473_600_000_000 else { throw UploadError.unresolved }
                let identity = try RemoteFileIdentity(fileID: integer(offset + 72, 8),
                                                    birthMicroseconds: ticks / 10 - 11_644_473_600_000_000)
                let size = try integer(offset + 40, 8)
                let modified = try integer(offset + 24, 8), changed = try integer(offset + 32, 8)
                let epoch: UInt64 = 116_444_736_000_000_000
                guard size <= Int64.max, modified >= epoch, changed >= epoch else { throw UploadError.unresolved }
                result.append(RenameDirectoryEntry(name: name, identity: identity,
                    attributes: UInt32(try integer(offset + 56, 4)), size: Int64(size),
                    modifiedMicroseconds: (modified - epoch) / 10, changedMicroseconds: (changed - epoch) / 10))
            }
            if next == 0 { return result }
            guard next >= 80 + length, next % 8 == 0, next < bytes.count - offset else {
                throw UploadError.unresolved
            }
            offset += next
        }
    }
}
