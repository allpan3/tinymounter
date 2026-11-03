import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class EditDiskSpaceTests: XCTestCase {
    func testRealDiskExhaustionPreservesThePreviousCompleteSave() throws {
        guard let path = ProcessInfo.processInfo.environment["TINYMOUNTER_SAVE_SPACE_FIXTURE"] else {
            throw XCTSkip("Run Tools/check-save-space.py in the VM with a disposable disk image")
        }
        let volume = URL(fileURLWithPath: path, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
        var disk = statfs(), boot = statfs()
        guard statfs(volume.path, &disk) == 0, statfs(temporary.path, &boot) == 0 else {
            throw posixError("inspect fixture volume")
        }
        let mountedAt = withUnsafePointer(to: &disk.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard mountedAt == volume.path, disk.f_fsid.val.0 != boot.f_fsid.val.0,
              Int64(disk.f_blocks) * Int64(disk.f_bsize) <= 5 << 30,
              try String(contentsOf: volume.appending(path: "fixture.txt"), encoding: .utf8)
                == "tinymounter-save-space\n" else { throw UploadError.invalidRequest }
        let directory = volume.appending(path: UUID().uuidString)
        let inputs = temporary.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: inputs) }
        let source = inputs.appending(path: "document.txt")
        let olderBytes = Data(repeating: 65, count: 256 << 10)
        try olderBytes.write(to: source, options: .withoutOverwriting)
        let metadata = Data("UTF-8;134217984".utf8)
        XCTAssertEqual(metadata.withUnsafeBytes {
            setxattr(source.path, "com.apple.TextEncoding", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let outboxURL = directory.appending(path: "Outbox")
        let outbox = try EditOutbox(directory: outboxURL), item = UUID().uuidString
        func prepare(_ box: EditOutbox, check: ((Int64) throws -> Void)? = nil) throws -> PendingEdit {
            try box.prepare(item: item, parent: Catalog.rootItemID,
                path: XCTUnwrap(RelativePath("document.txt")), baseVersion: "fixture-base",
                failOnConflict: false, contents: source, progress: Progress(), checkSpace: check)
        }
        let older = try prepare(outbox)
        let newerBytes = Data(repeating: 78, count: 32 << 20)
        try newerBytes.write(to: source)
        let space = DownloadSpace { try DownloadSpace.available(at: volume) }
        let filler = directory.appending(path: "filler.bin")
        defer { try? FileManager.default.removeItem(at: filler) }

        let reserveFill = try fill(filler, volume: volume, leave: DownloadSpace.reserveBytes - (1 << 20))
        let reserveAvailable = try DownloadSpace.available(at: volume)
        XCTAssertLessThan(reserveAvailable, DownloadSpace.reserveBytes)
        XCTAssertThrowsError(try space.begin(UUID(), bytes: Int64(newerBytes.count))) {
            XCTAssertTrue(DownloadSpace.isFull($0))
        }
        XCTAssertEqual(try outbox.records(), [older])
        try outbox.validateContents(older)
        try FileManager.default.removeItem(at: filler)

        let request = UUID()
        try space.begin(request, bytes: Int64(newerBytes.count))
        defer { space.end(request) }
        var filledAfter: Int64 = 0, fullFill: Int64 = 0
        var failure: NSError?
        do {
            _ = try prepare(outbox) { completed in
                try space.check(request, completedBytes: completed)
                if completed > 0, filledAfter == 0 {
                    filledAfter = completed
                    // Another writer can exhaust storage between a successful check and the next write.
                    fullFill = try self.fill(filler, volume: volume, leave: nil)
                }
            }
            XCTFail("The next payload write must fail on the exhausted image")
        } catch { failure = error as NSError }
        let error = try XCTUnwrap(failure)
        XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(error.code, Int(ENOSPC))
        XCTAssertGreaterThan(filledAfter, 0)
        XCTAssertLessThan(filledAfter, Int64(newerBytes.count))
        let fullAvailable = try DownloadSpace.available(at: volume)
        try outbox.validateContents(older)
        XCTAssertEqual(try Data(contentsOf: outbox.contentURL(older)), olderBytes)
        let exported = inputs.appending(path: "exported.txt")
        try outbox.export(older, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), olderBytes)
        var exportedMetadata = Data(count: metadata.count)
        XCTAssertEqual(exportedMetadata.withUnsafeMutableBytes {
            getxattr(exported.path, "com.apple.TextEncoding", $0.baseAddress, $0.count, 0, 0)
        }, metadata.count)
        XCTAssertEqual(exportedMetadata, metadata)
        let interrupted = try XCTUnwrap(outbox.records().last)
        XCTAssertEqual(interrupted.state, .preparing)
        XCTAssertNotEqual(interrupted.id, older.id)
        let partialSize = try FileManager.default.attributesOfItem(atPath: outbox.contentURL(interrupted).path)[.size]
        XCTAssertLessThan(try XCTUnwrap(partialSize as? NSNumber).int64Value, interrupted.size)
        try FileManager.default.removeItem(at: filler)
        space.end(request)

        let reopened = try EditOutbox(directory: outboxURL)
        XCTAssertEqual(try reopened.order(item: item).head?.id, older.id)
        try reopened.validateContents(older)
        let retry = UUID()
        try space.begin(retry, bytes: Int64(newerBytes.count))
        defer { space.end(retry) }
        let newer = try prepare(reopened) { try space.check(retry, completedBytes: $0) }
        try reopened.validateContents(newer)
        try reopened.validateContents(older)
        XCTAssertEqual(try reopened.order(item: item).head?.id, newer.id)
        XCTAssertEqual(try Data(contentsOf: reopened.contentURL(newer)), newerBytes)
        let report: [String: Any] = ["reserveFillBytes": reserveFill, "reserveAvailableBytes": reserveAvailable,
            "exhaustionFillBytes": fullFill, "exhaustionAvailableBytes": fullAvailable,
            "completedBeforeExhaustion": filledAfter, "errorDomain": error.domain, "errorCode": error.code,
            "olderSaveAndMetadataExported": true, "reopenedWithOlderHead": true,
            "newerSaveRetried": true, "bothCompleteCopiesRetained": true]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: directory.appending(path: "report.json"), options: .withoutOverwriting)
        print("Actual disk exhaustion: \(String(decoding: data, as: UTF8.self))")
    }

    private func fill(_ url: URL, volume: URL, leave: Int64?) throws -> Int64 {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create fixture filler") }
        defer { close(fd) }
        let block = Data(repeating: 90, count: 1 << 20)
        var total: Int64 = 0
        while total < 5 << 30 {
            if let leave, try DownloadSpace.available(at: volume) <= leave { break }
            let written = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == ENOSPC, leave == nil { return total }
            guard written > 0 else { throw posixError("fill fixture image") }
            total += Int64(written)
        }
        guard leave != nil, total < 5 << 30 else { throw UploadError.invalidRequest }
        guard fsync(fd) == 0 else { throw posixError("sync fixture filler") }
        return total
    }
}
