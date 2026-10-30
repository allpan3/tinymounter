import Foundation

public struct RenameDirectoryEntry: Sendable {
    public let name: String
    public let identity: EditFileIdentity
    public let attributes: UInt32

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
                let identity = try EditFileIdentity(fileID: integer(offset + 72, 8),
                                                    birthMicroseconds: ticks / 10 - 11_644_473_600_000_000)
                result.append(RenameDirectoryEntry(name: name, identity: identity,
                                                   attributes: UInt32(try integer(offset + 56, 4))))
            }
            if next == 0 { return result }
            guard next >= 80 + length, next % 8 == 0, next < bytes.count - offset else {
                throw UploadError.unresolved
            }
            offset += next
        }
    }
}
