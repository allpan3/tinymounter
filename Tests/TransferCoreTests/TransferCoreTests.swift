import Foundation
import XCTest
@testable import TransferCore

final class TransferCoreTests: XCTestCase {
    private func withFixture(_ body: (URL, URL, Data) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("fixture.bin")
        // Nonzero pattern with a tail that is not aligned to our buffer size.
        let bytes = Data((0..<131_173).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 8)) })
        try bytes.write(to: sourceURL)
        try body(sourceURL, directory, bytes)
    }

    func testFullAndOffsetStagingContainExactBytes() throws {
        try withFixture { url, directory, bytes in
            let source = try ReadOnlyFile(url: url)
            for (offset, length) in [(0, bytes.count), (12_345, 51_119), (bytes.count - 7, 7)] {
                let range = try ByteRange(offset: Int64(offset), length: Int64(length), fileSize: source.snapshot.size)
                let result = try Transfer.run(source: source, range: range, blockSize: 4096, stagingDirectory: directory)
                let stage = try XCTUnwrap(result.stagingURL)
                let stagedBytes = try Data(contentsOf: stage)
                XCTAssertEqual(stagedBytes.count, offset + length)
                XCTAssertEqual(stagedBytes[offset..<(offset + length)], bytes[offset..<(offset + length)])
                XCTAssertTrue(stagedBytes.prefix(offset).allSatisfy { $0 == 0 })
                XCTAssertEqual(result.metrics.bytes, Int64(length))
                try FileManager.default.removeItem(at: stage)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testAlignmentCoversRangeAndOnlyEOFMayBeUnaligned() throws {
        for size: Int64 in [1, 4096, 12_345, Int64.max] {
            for offset in [Int64(0), max(0, size - 1)] {
                let minimum = try ByteRange(offset: offset, length: 1, fileSize: size)
                let range = try ByteRange.aligned(minimum: minimum, alignment: 4096, fileSize: size)
                XCTAssertLessThanOrEqual(range.offset, minimum.offset)
                XCTAssertGreaterThanOrEqual(range.end, minimum.end)
                XCTAssertLessThanOrEqual(range.end, size)
                XCTAssertEqual(range.offset % 4096, 0)
                XCTAssertTrue(range.end == size || range.length % 4096 == 0)
            }
        }
        XCTAssertThrowsError(try ByteRange(offset: Int64.max, length: 1, fileSize: Int64.max))
        XCTAssertThrowsError(try ByteRange(offset: -1, length: 1, fileSize: 1))
        let small = try ByteRange(offset: 0, length: 1, fileSize: 10)
        XCTAssertThrowsError(try ByteRange.aligned(minimum: small, alignment: 3, fileSize: 10))
    }

    func testRangePastEOFIsClampedButStartPastEOFFails() throws {
        let tail = try ByteRange.clampedToEOF(offset: 2_742_681_545, length: 131_072, fileSize: 2_742_783_442)
        XCTAssertEqual(tail.end, 2_742_783_442)
        XCTAssertEqual(try ByteRange.clampedToEOF(offset: 10, length: 5, fileSize: 10).length, 0)
        XCTAssertThrowsError(try ByteRange.clampedToEOF(offset: 11, length: 1, fileSize: 10))
    }

    func testEmptyFileAndRange() throws {
        try withFixture { url, directory, _ in
            try Data().write(to: url)
            let source = try ReadOnlyFile(url: url)
            let range = try ByteRange(offset: 0, length: 0, fileSize: 0)
            let result = try Transfer.run(source: source, range: range, stagingDirectory: directory)
            XCTAssertEqual(result.metrics.bytes, 0)
            XCTAssertNil(result.metrics.firstReadSeconds)
            XCTAssertNil(result.metrics.megabytesPerSecond)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.stagingURL)), Data())
        }
    }

    func testCancellationLeavesNoStagingFile() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let progress = Progress()
            progress.cancel()
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                stagingDirectory: directory, progress: progress)) { error in
                XCTAssertEqual(error as? TransferError, .cancelled)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture.bin"])
        }
    }

    func testChangedSourceRejectedBeforeTransfer() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 3)
            try handle.close()
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                stagingDirectory: directory)) { error in
                XCTAssertEqual(error as? TransferError, .sourceChanged)
            }
        }
    }

    func testMidTransferCancellationRemovesPartialStaging() throws {
        try withFixture { url, directory, _ in
            let source = try ReadOnlyFile(url: url)
            let progress = Progress()
            let observation = progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
                if progress.completedUnitCount >= 4096 { progress.cancel() }
            }
            defer { observation.invalidate() }
            XCTAssertThrowsError(try Transfer.run(source: source,
                range: ByteRange(offset: 0, length: source.snapshot.size, fileSize: source.snapshot.size),
                blockSize: 4096, stagingDirectory: directory, progress: progress)) { error in
                XCTAssertEqual(error as? TransferError, .cancelled)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture.bin"])
        }
    }

    func testSymlinkAndDirectoryRejected() throws {
        try withFixture { url, directory, _ in
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            XCTAssertThrowsError(try ReadOnlyFile(url: link))
            XCTAssertThrowsError(try ReadOnlyFile(url: directory))
        }
    }

    func testHydrationOptInKeepsRegularSourceMetadataChecks() throws {
        try withFixture { url, _, _ in
            let source = try ReadOnlyFile(url: url, allowMaterialization: true)
            XCTAssertFalse(source.ignoresMaterializationChangeTime)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            XCTAssertThrowsError(try source.validateUnchanged()) { error in
                XCTAssertEqual(error as? TransferError, .sourceChanged)
            }
        }
    }

    func testSHA256KnownVector() throws {
        try withFixture { url, _, _ in
            try Data("abc".utf8).write(to: url)
            let source = try ReadOnlyFile(url: url)
            XCTAssertEqual(try source.checksum(range: ByteRange(offset: 0, length: 3, fileSize: 3)),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }

    func testReadAheadStartsOnlyOnSequentialMissAndStaysWithinWindow() throws {
        let mib: Int64 = 1 << 20
        var planner = ReadAheadPlanner(fileSize: 1024 * mib, chunk: 32 * mib, window: 64 * mib, maxInFlight: 1)
        let first = try ByteRange(offset: 0, length: 16 * mib, fileSize: 1024 * mib)
        XCTAssertEqual(planner.classify(offset: 0, length: mib), .demand(sequential: false))
        XCTAssertEqual(planner.demandCompleted(first, sequential: false), [])

        XCTAssertEqual(planner.classify(offset: 16 * mib, length: mib), .demand(sequential: true))
        let second = try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: 1024 * mib)
        let planned = planner.demandCompleted(second, sequential: true)
        XCTAssertEqual(planned.map(\.offset), [32 * mib])

        var requested = planned
        while let range = requested.popLast() {
            XCTAssertEqual(planner.classify(offset: range.offset, length: range.length), .speculative(current: true))
            requested += planner.speculativeFinished(range)
        }
        // Speculative completions alone never pass the limit set by the last demand miss.
        XCTAssertEqual(planner.speculativeFinished(try ByteRange(offset: 32 * mib, length: 32 * mib, fileSize: 1024 * mib)), [])
        XCTAssertEqual(planner.classify(offset: 64 * mib, length: mib), .demand(sequential: true))

        // The window grows with the consumed run but stops at its configured maximum.
        requested = planner.demandCompleted(try ByteRange(offset: 64 * mib, length: 16 * mib, fileSize: 1024 * mib),
                                            sequential: true)
        var end: Int64 = 0
        while let range = requested.popLast() {
            XCTAssertEqual(planner.classify(offset: range.offset, length: range.length), .speculative(current: true))
            end = range.end
            requested += planner.speculativeFinished(range)
        }
        XCTAssertEqual(end, 144 * mib)
    }

    func testReadAheadReaderMissAtPlannedOffsetStaysDemand() throws {
        let mib: Int64 = 1 << 20
        let size = 1024 * mib
        var planner = ReadAheadPlanner(fileSize: size, chunk: 16 * mib, window: 256 * mib, maxInFlight: 1)
        _ = planner.demandCompleted(try ByteRange(offset: 0, length: 16 * mib, fileSize: size), sequential: false)
        let planned = planner.demandCompleted(try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: size),
                                              sequential: true)
        XCTAssertEqual(planned.map(\.offset), [32 * mib])

        // The reader's 1 MiB miss reaches the planned chunk first; it is a demand, not our request.
        XCTAssertEqual(planner.classify(offset: 32 * mib, length: mib), .demand(sequential: true))
        let next = planner.demandCompleted(try ByteRange(offset: 32 * mib, length: 16 * mib, fileSize: size),
                                           sequential: true)
        XCTAssertEqual(next.map(\.offset), [48 * mib])
        // The system's later delivery of the already covered request is dismissed as stale.
        XCTAssertEqual(planner.classify(offset: 32 * mib, length: 16 * mib), .speculative(current: false))
    }

    func testReadAheadOverlappingMissIsSequential() throws {
        let mib: Int64 = 1 << 20
        let size = 1024 * mib
        var planner = ReadAheadPlanner(fileSize: size, chunk: 16 * mib, window: 128 * mib, maxInFlight: 1)
        _ = planner.demandCompleted(try ByteRange(offset: 0, length: 16 * mib, fileSize: size), sequential: false)
        XCTAssertEqual(planner.classify(offset: 16 * mib - 64 * 1024, length: mib), .demand(sequential: true))
        XCTAssertEqual(planner.classify(offset: 512 * mib, length: mib), .demand(sequential: false))
    }

    func testReadAheadSeekMakesOutstandingRequestsStale() throws {
        let mib: Int64 = 1 << 20
        let size = 100 * mib
        var planner = ReadAheadPlanner(fileSize: size, chunk: 32 * mib, window: 256 * mib, maxInFlight: 1)
        _ = planner.demandCompleted(try ByteRange(offset: 0, length: 16 * mib, fileSize: size), sequential: false)
        let planned = planner.demandCompleted(try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: size),
                                              sequential: true)
        XCTAssertEqual(planned.map(\.offset), [32 * mib])

        XCTAssertEqual(planner.classify(offset: 80 * mib, length: mib), .demand(sequential: false))
        XCTAssertEqual(planner.demandCompleted(try ByteRange(offset: 80 * mib, length: 16 * mib, fileSize: size),
                                               sequential: false), [])
        XCTAssertEqual(planner.classify(offset: 32 * mib, length: 32 * mib), .speculative(current: false))
        planner.speculativeFailed(offset: 32 * mib)

        // A stale failure does not stop the new run, and the window is clipped at EOF.
        let tail = planner.demandCompleted(try ByteRange(offset: 80 * mib, length: 16 * mib, fileSize: size),
                                           sequential: true)
        XCTAssertEqual(tail.map(\.offset), [96 * mib])
        XCTAssertEqual(tail.map(\.length), [4 * mib])
    }

    func testReadAheadContinuesAfterReaderOvertakesRequest() throws {
        let mib: Int64 = 1 << 20, kib: Int64 = 1024
        let size = 1024 * mib
        var planner = ReadAheadPlanner(fileSize: size, chunk: 16 * mib, window: 128 * mib, maxInFlight: 1)
        _ = planner.demandCompleted(try ByteRange(offset: 0, length: 16 * mib, fileSize: size), sequential: false)
        _ = planner.classify(offset: 16 * mib, length: mib)
        XCTAssertEqual(planner.demandCompleted(try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: size),
                                               sequential: true).map(\.offset), [32 * mib])

        // The system never delivers the request; the reader misses 16 KiB before it instead.
        XCTAssertEqual(planner.classify(offset: 32 * mib - 16 * kib, length: 64 * kib), .demand(sequential: true))
        let demand = try ByteRange(offset: 32 * mib - 16 * kib, length: 16 * mib, fileSize: size)
        XCTAssertEqual(planner.demandCompleted(demand, sequential: true).map(\.offset), [demand.end])
        XCTAssertEqual(planner.classify(offset: 32 * mib, length: 16 * mib), .speculative(current: false))
    }

    func testReadAheadSkipsDeliveredRanges() throws {
        let mib: Int64 = 1 << 20
        let size = 1024 * mib
        var planner = ReadAheadPlanner(fileSize: size, chunk: 16 * mib, window: 128 * mib, maxInFlight: 1)
        _ = planner.demandCompleted(try ByteRange(offset: 40 * mib, length: 16 * mib, fileSize: size), sequential: false)
        _ = planner.classify(offset: 0, length: mib)
        _ = planner.demandCompleted(try ByteRange(offset: 0, length: 16 * mib, fileSize: size), sequential: false)
        _ = planner.classify(offset: 16 * mib, length: mib)
        var planned = planner.demandCompleted(try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: size),
                                              sequential: true)
        var requested: [ByteRange] = []
        while let range = planned.popLast() {
            requested.append(range)
            XCTAssertEqual(planner.classify(offset: range.offset, length: range.length), .speculative(current: true))
            planned += planner.speculativeFinished(range)
        }
        // The chunk before the delivered range stops at it, and the next one starts after it.
        XCTAssertEqual(requested.map(\.offset), [32 * mib, 56 * mib])
        XCTAssertEqual(requested.map(\.length), [8 * mib, 8 * mib])
        XCTAssertEqual(planner.deliveredStart(after: 10 * mib), 10 * mib)
        XCTAssertNil(planner.deliveredStart(after: 64 * mib))
    }

    func testDemandExtentNeverRewritesDeliveredBytes() throws {
        // Misses from IINA's two read positions on 2026-10-15 (run 1), in arrival order.
        let misses: [(Int64, Int64)] = [
            (0, 131_072), (20_298_257, 32_768), (16_718_424, 65_536), (43_903_301, 32_768), (37_035_969, 65_536),
            (64_888_661, 32_768), (60_653_990, 65_536), (87_199_003, 32_768), (81_610_855, 65_536),
            (108_975_772, 32_768), (103_921_279, 65_536), (134_426_369, 32_768), (125_698_816, 65_536),
            (159_549_100, 32_768), (151_138_316, 65_536), (183_359_813, 32_768), (176_289_833, 65_536),
            (211_784_386, 32_768), (200_073_606, 65_536), (211_817_154, 38_834),
        ]
        let size: Int64 = 2_742_783_442, alignment: Int64 = 4096, extent: Int64 = 16 << 20
        var registry = ReadAheadRegistry(chunk: 16 << 20, window: 128 << 20, maxInFlight: 1)
        var delivered: [ByteRange] = []
        for (offset, length) in misses {
            let required = try ByteRange.clampedToEOF(offset: offset, length: length, fileSize: size)
            if delivered.contains(where: { $0.offset <= required.offset && required.end <= $0.end }) { continue }
            let kind = registry.classify(item: "A", version: "v1", fileSize: size, offset: offset - offset % alignment,
                                         length: required.end - (offset - offset % alignment))
            let range = try registry.extent(item: "A", version: "v1", covering: required, alignment: alignment,
                                            fileSize: size, preferredLength: extent)
            // Only the aligned bytes the reader asked for may be returned again.
            let asked = try ByteRange.aligned(minimum: required, alignment: alignment, fileSize: size, preferredLength: 1)
            XCTAssertTrue(range.offset <= asked.offset && asked.end <= range.end)
            for old in delivered where old.offset < range.end && range.offset < old.end {
                XCTAssertGreaterThanOrEqual(max(old.offset, range.offset), asked.offset, "offset \(offset)")
                XCTAssertLessThanOrEqual(min(old.end, range.end), asked.end, "offset \(offset)")
            }
            delivered.append(range)
            if case .demand(let sequential) = kind {
                _ = registry.demandCompleted(item: "A", version: "v1", range: range, sequential: sequential)
            }
        }
        XCTAssertGreaterThan(delivered.count, 10)
    }

    func testFingerprintMatchesStatAndVersionFormat() throws {
        try withFixture { url, _, bytes in
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_001, tv_nsec: 5)]
            XCTAssertEqual(utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0), 0)
            var info = stat()
            XCTAssertEqual(stat(url.path(percentEncoded: false), &info), 0)
            let ctimeNs = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
            let fingerprint = try ReadOnlyFile(url: url).snapshot.fingerprint
            XCTAssertEqual(fingerprint, ContentFingerprint(size: Int64(bytes.count), mtimeNs: 1_700_000_001_000_000_005,
                                                           ctimeNs: ctimeNs))
            XCTAssertEqual(fingerprint.contentVersion, "f1:\(bytes.count):1700000001000000005:\(ctimeNs)")
            XCTAssertEqual(ContentFingerprint(size: .min, mtimeNs: .min, ctimeNs: .min).contentVersion.utf8.count, 65)

            // APFS stores times before 1678 as Int64.min nanoseconds; reading one must not trap.
            times[1] = timespec(tv_sec: -11_644_473_600, tv_nsec: 0)
            XCTAssertEqual(utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0), 0)
            XCTAssertEqual(try ReadOnlyFile(url: url).snapshot.fingerprint.mtimeNs, .min)
        }
        for (seconds, nanoseconds, expected): (Int64, Int64, Int64) in [
            (0, 0, 0), (-1, 500_000_000, -500_000_000), (1_700_000_000, 7, 1_700_000_000_000_000_007),
            (-9_223_372_037, 145_224_192, .min), (9_223_372_036, 854_775_807, .max),
            (-11_644_473_600, 0, .min), (910_692_730_085, 0, .max),
        ] {
            XCTAssertEqual(ContentFingerprint.nanoseconds(seconds: seconds, nanoseconds: nanoseconds), expected)
        }
    }

    func testRegistryKeepsIndependentRunsPerItem() throws {
        let mib: Int64 = 1 << 20
        let size = 1024 * mib
        var registry = ReadAheadRegistry(chunk: 16 * mib, window: 128 * mib, maxInFlight: 1)
        for item in ["A", "B"] {
            XCTAssertEqual(registry.classify(item: item, version: "v1", fileSize: size, offset: 0, length: mib),
                           .demand(sequential: false))
            XCTAssertEqual(registry.demandCompleted(item: item, version: "v1", range: try ByteRange(
                offset: 0, length: 16 * mib, fileSize: size), sequential: false), [])
        }
        for item in ["A", "B"] {
            XCTAssertEqual(registry.classify(item: item, version: "v1", fileSize: size, offset: 16 * mib, length: mib),
                           .demand(sequential: true))
            XCTAssertEqual(registry.demandCompleted(item: item, version: "v1", range: try ByteRange(
                offset: 16 * mib, length: 16 * mib, fileSize: size), sequential: true).map(\.offset), [32 * mib])
        }

        // A seek on A makes only A's planned request stale.
        XCTAssertEqual(registry.classify(item: "A", version: "v1", fileSize: size, offset: 512 * mib, length: mib),
                       .demand(sequential: false))
        XCTAssertEqual(registry.classify(item: "B", version: "v1", fileSize: size, offset: 32 * mib, length: 16 * mib),
                       .speculative(current: true))
        XCTAssertEqual(registry.classify(item: "A", version: "v1", fileSize: size, offset: 32 * mib, length: 16 * mib),
                       .speculative(current: false))
        XCTAssertEqual(registry.speculativeFinished(item: "B", version: "v1", range: try ByteRange(offset: 32 * mib, length: 16 * mib, fileSize: size)).map(\.offset), [48 * mib])
        XCTAssertEqual(registry.count, 2)
    }

    func testRegistryEvictsLeastRecentlyUsedAndRestartsOnVersionChange() throws {
        let mib: Int64 = 1 << 20
        let size = 64 * mib
        let first = try ByteRange(offset: 0, length: 16 * mib, fileSize: size)
        let second = try ByteRange(offset: 16 * mib, length: 16 * mib, fileSize: size)
        var registry = ReadAheadRegistry(chunk: 16 * mib, window: 128 * mib, maxInFlight: 1)
        XCTAssertEqual(registry.capacity, 8)
        for item in (0..<9).map(String.init) {
            if item == "8" {
                // Using item 0 again leaves item 1 as the least recently used.
                XCTAssertEqual(registry.speculativeFinished(item: "0", version: "v1", range: first), [])
            }
            _ = registry.classify(item: item, version: "v1", fileSize: size, offset: 0, length: mib)
            _ = registry.demandCompleted(item: item, version: "v1", range: first, sequential: false)
            _ = registry.classify(item: item, version: "v1", fileSize: size, offset: 16 * mib, length: mib)
            XCTAssertEqual(registry.demandCompleted(item: item, version: "v1", range: second, sequential: true)
                .map(\.offset), [32 * mib], item)
        }
        XCTAssertEqual(registry.count, 8)
        // A held item still has its planned request; an evicted one starts again with a demand.
        for item in ["0"] + (2..<9).map(String.init) {
            XCTAssertEqual(registry.classify(item: item, version: "v1", fileSize: size, offset: 32 * mib,
                                             length: 16 * mib), .speculative(current: true), item)
        }

        // A new content version gets a new planner; calls for the old version do nothing.
        XCTAssertEqual(registry.classify(item: "0", version: "v2", fileSize: size, offset: 32 * mib, length: 16 * mib),
                       .demand(sequential: false))
        XCTAssertEqual(registry.count, 8)
        XCTAssertEqual(registry.speculativeFinished(item: "0", version: "v1", range: try ByteRange(offset: 32 * mib, length: 16 * mib, fileSize: size)), [])
        XCTAssertEqual(registry.demandCompleted(item: "0", version: "v1", range: second, sequential: true), [])

        // Checked last, because a new planner for item 1 evicts another item.
        XCTAssertEqual(registry.classify(item: "1", version: "v1", fileSize: size, offset: 32 * mib, length: 16 * mib),
                       .demand(sequential: false))
        XCTAssertEqual(registry.count, 8)
    }
}
