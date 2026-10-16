import Foundation

public enum TransferError: Error, LocalizedError, Equatable {
    case invalidRange
    case invalidBlockSize
    case notRegularFile
    case sourceChanged
    case cancelled
    case stagingMustBeLocal
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "Invalid or out-of-bounds byte range."
        case .invalidBlockSize: return "Block size must be between 4 KiB and 16 MiB."
        case .notRegularFile: return "Select a regular file, not a directory, symlink, or device."
        case .sourceChanged: return "The source changed. Use an immutable test file and retry."
        case .cancelled: return "Transfer cancelled."
        case .stagingMustBeLocal: return "Staging must be on a local filesystem, not the NAS."
        case .checksumMismatch: return "Source and staged range checksums differ."
        }
    }
}

public struct ByteRange: Codable, Equatable, Sendable {
    public let offset: Int64
    public let length: Int64
    public var end: Int64 { offset + length }

    public init(offset: Int64, length: Int64, fileSize: Int64) throws {
        guard offset >= 0, length >= 0, fileSize >= 0,
              offset <= fileSize, length <= fileSize - offset else {
            throw TransferError.invalidRange
        }
        self.offset = offset
        self.length = length
    }

    /// A reader near EOF can ask past it; File Provider passes such ranges through unclipped.
    public static func clampedToEOF(offset: Int64, length: Int64, fileSize: Int64) throws -> ByteRange {
        guard offset >= 0, length >= 0, offset <= fileSize else { throw TransferError.invalidRange }
        return try ByteRange(offset: offset, length: min(length, fileSize - offset), fileSize: fileSize)
    }

    /// Cover the requested range without crossing EOF or overflowing Int64.
    public static func aligned(minimum: ByteRange, alignment: Int64,
                               fileSize: Int64, preferredLength: Int64 = 4 * 1024 * 1024) throws -> ByteRange {
        guard alignment > 0, alignment & (alignment - 1) == 0,
              preferredLength > 0 else { throw TransferError.invalidRange }
        _ = try ByteRange(offset: minimum.offset, length: minimum.length, fileSize: fileSize)
        if minimum.length == 0 { return minimum }
        let start = minimum.offset - minimum.offset % alignment
        let requiredLength = minimum.end - start
        let wantedLength = min(fileSize - start, max(requiredLength, preferredLength))
        let wantedEnd = start + wantedLength
        let remainder = wantedEnd % alignment
        let padding = remainder == 0 ? 0 : min(alignment - remainder, fileSize - wantedEnd)
        return try ByteRange(offset: start, length: wantedLength + padding, fileSize: fileSize)
    }
}
