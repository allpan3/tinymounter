import Foundation

/// No cursor holds a name, and all stay far below File Provider's 500-byte limit.
public enum CatalogCursor {
    static let anchorLength = 25
    static let pageLength = 9
    private static let anchorTag: UInt8 = 0x01
    private static let folderPageTag: UInt8 = 0x02
    private static let workingSetPageTag: UInt8 = 0x03

    public static func folderPage(after row: Int64) -> Data { Data([folderPageTag]) + bigEndian(row) }

    public static func workingSetPage(after row: Int64) -> Data { Data([workingSetPageTag]) + bigEndian(row) }

    public static func folderPageRow(_ page: Data) -> Int64? { row(page, tag: folderPageTag) }

    public static func workingSetPageRow(_ page: Data) -> Int64? { row(page, tag: workingSetPageTag) }

    static func anchor(epoch: Data, changeSeq: Int64) -> Data {
        Data([anchorTag]) + epoch + bigEndian(changeSeq)
    }

    /// The anchor's sequence; nil if it is malformed, from another catalog, or above `lastSeq`.
    static func anchorSeq(_ anchor: Data, epoch: Data, lastSeq: Int64) -> Int64? {
        guard anchor.count == anchorLength, anchor.first == anchorTag, anchor.dropFirst().prefix(16) == epoch else {
            return nil
        }
        let seq = int64(anchor, at: 17)
        return seq >= 0 && seq <= lastSeq ? seq : nil
    }

    private static func row(_ page: Data, tag: UInt8) -> Int64? {
        guard page.count == pageLength, page.first == tag else { return nil }
        let row = int64(page, at: 1)
        return row > 0 ? row : nil
    }

    private static func bigEndian(_ value: Int64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private static func int64(_ data: Data, at offset: Int) -> Int64 {
        data.withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int64.self)) }
    }
}
