import XCTest
@testable import TransferCore

final class ChangeWatchingTests: XCTestCase {
    private func entry(_ action: UInt32, _ name: String, last: Bool) -> [UInt8] {
        let units = Array(name.utf16)
        var bytes: [UInt8] = []
        func word(_ value: UInt32) { bytes += withUnsafeBytes(of: value.littleEndian, Array.init) }
        let length = 12 + units.count * 2, padded = (length + 3) / 4 * 4
        word(last ? 0 : UInt32(padded))
        word(action)
        word(UInt32(units.count * 2))
        for unit in units { bytes += withUnsafeBytes(of: unit.littleEndian, Array.init) }
        if !last { bytes += Array(repeating: 0, count: padded - length) }
        return bytes
    }

    private func path(_ string: String) -> RelativePath { RelativePath(string)! }

    func testRepliesDecodeIntoEntriesWithSlashSeparators() {
        let buffer = entry(4, "old.txt", last: false) + entry(5, "sub\\Café.txt", last: true)
        let completion = SMBNotifyCompletion(status: 0, buffer: buffer)
        XCTAssertEqual(completion, .changed([.init(action: 4, name: "old.txt"), .init(action: 5, name: "sub/Café.txt")]))
        XCTAssertEqual(completion.notice(for: path("a/b")), .changed(path("a/b")))
    }

    func testNamesKeepTheServersNormalization() throws {
        let decomposed = "Cafe\u{301}.txt"
        guard case .changed(let entries) = SMBNotifyCompletion(status: 0, buffer: entry(1, decomposed, last: true)) else {
            return XCTFail()
        }
        XCTAssertEqual(Array(try XCTUnwrap(entries.first).name.unicodeScalars), Array(decomposed.unicodeScalars))
    }

    func testOverflowAndUnreadableRepliesNeedAListing() {
        let folder = path("folder")
        for completion in [SMBNotifyCompletion(status: 0x0000_010C, buffer: []),
                           SMBNotifyCompletion(status: 0, buffer: []),
                           SMBNotifyCompletion(status: 0, buffer: Array(entry(1, "a", last: true).dropLast())),
                           SMBNotifyCompletion(status: 0, buffer: [1, 0, 0, 0] + Array(repeating: 0, count: 12))] {
            XCTAssertEqual(completion, .overflow)
            XCTAssertEqual(completion.notice(for: folder), .lost(folder))
        }
    }

    func testDeletedFolderIsLostAndOtherEndingsEndTheWatcher() {
        let folder = path("folder")
        XCTAssertEqual(SMBNotifyCompletion(status: 0xC000_0056, buffer: []).notice(for: folder), .lost(folder))
        // STATUS_NOTIFY_CLEANUP that the app did not cause: the server closed the handle.
        XCTAssertEqual(SMBNotifyCompletion(status: 0x0000_010B, buffer: []).notice(for: folder),
                       .ended(.unknown(domain: "SMB2 NTSTATUS", code: 0x10B)))
        XCTAssertEqual(SMBNotifyCompletion.openFailure(0xC000_0034, folder: folder), .lost(folder))
        XCTAssertNil(SMBNotifyCompletion.openFailure(0xC000_0022, folder: folder))
        XCTAssertEqual(SMBNotifyCompletion.failure(0), .serverUnreachable)
    }

    func testTableOpensAndClosesOnlyTheDifference() {
        var table = WatchTable()
        let first = table.replace(with: [path("a"), path("a/b")], limit: 64)
        XCTAssertEqual(first.open.map(\.path), [path("a"), path("a/b")])
        XCTAssertEqual(first.close, [])
        let tokenB = first.open[1].token
        let second = table.replace(with: [path("a"), path("c")], limit: 64)
        XCTAssertEqual(second.open.map(\.path), [path("c")])
        XCTAssertEqual(second.close, [tokenB])
        XCTAssertNil(table.path(of: tokenB))
        XCTAssertEqual(table.watched, [path("a"), path("c")])
        XCTAssertNotEqual(second.open[0].token, tokenB)
    }

    func testEndedWatchStaysOffUntilTheSetDropsItsFolder() {
        var table = WatchTable()
        let token = table.replace(with: [path("gone")], limit: 64).open[0].token
        XCTAssertEqual(table.end(token), path("gone"))
        XCTAssertEqual(table.replace(with: [path("gone")], limit: 64).open.count, 0)
        XCTAssertEqual(table.replace(with: [], limit: 64).close, [])
        XCTAssertEqual(table.replace(with: [path("gone")], limit: 64).open.map(\.path), [path("gone")])
        XCTAssertNil(table.end(token))
    }

    func testTableNeverExceedsItsLimit() {
        var table = WatchTable()
        let folders = Set((0..<100).map { path("f\($0)") })
        XCTAssertEqual(table.replace(with: folders, limit: 64).open.count, 64)
        XCTAssertEqual(table.replace(with: folders.union([path("a")]), limit: 64).open.map(\.path), [path("a")])
        XCTAssertEqual(table.watched.count, 64)
    }

    func testPlanUnitesLocationsAndPrefersShallowFolders() {
        var plan = ChangeWatchPlan()
        plan.setFolders([.init(id: "root", parentID: nil, path: .root),
                         .init(id: "deep", parentID: "mid", path: path("x/y/z"))], domainID: "one", root: path("Photos"))
        plan.setFolders([.init(id: "r2", parentID: nil, path: .root)], domainID: "two", root: path("Photos"))
        XCTAssertEqual(plan.paths(limit: 64), [path("Photos"), path("Photos/x/y/z")])
        XCTAssertEqual(plan.paths(limit: 1), [path("Photos")])
        XCTAssertEqual(plan.paths(limit: 64) { $0.string.hasPrefix("Photos/x") }, [path("Photos")])
        let routes = plan.routes(for: .changed(path("Photos")))
        XCTAssertEqual(routes.map(\.domainID), ["one", "two"])
        XCTAssertEqual(routes.map(\.folderIDs), [["root"], ["r2"]])
        plan.removeLocation("two")
        XCTAssertEqual(plan.routes(for: .changed(path("Photos"))).map(\.folderIDs), [["root"]])
    }

    func testLostFolderListsItsParentAndUnknownPathsListNothing() {
        var plan = ChangeWatchPlan()
        plan.setFolders([.init(id: "deep", parentID: "mid", path: path("x/y"))], domainID: "one", root: .root)
        XCTAssertEqual(plan.routes(for: .lost(path("x/y"))).map(\.folderIDs), [["deep", "mid"]])
        XCTAssertEqual(plan.routes(for: .changed(path("x/y"))).map(\.folderIDs), [["deep"]])
        XCTAssertTrue(plan.routes(for: .changed(path("x"))).isEmpty)
        XCTAssertTrue(plan.routes(for: .ended(.serverUnreachable)).isEmpty)
    }

    func testNoticesBecomeOneDebouncedListingPerFolder() {
        var plan = ChangeWatchPlan(), refresh = DirectoryRefresh()
        plan.setFolders([.init(id: "folder", parentID: "parent", path: path("folder")),
                         .init(id: "parent", parentID: nil, path: .root)], domainID: "one", root: .root)
        refresh.replaceFolders(["folder", "parent"], now: .zero)
        for _ in 0..<2 { _ = refresh.next(now: .zero) }
        refresh.finished("folder", succeeded: true, now: .seconds(1))
        refresh.finished("parent", succeeded: true, now: .seconds(1))
        // A create arrives as ADDED and then MODIFIED; both ask for the same listing.
        for second in [10, 10] {
            for route in plan.routes(for: .changed(path("folder"))) {
                for id in route.folderIDs { refresh.changed(id, now: .seconds(Int64(second))) }
            }
        }
        XCTAssertNil(refresh.next(now: .milliseconds(10_499)))
        XCTAssertEqual(refresh.next(now: .milliseconds(10_500)), "folder")
        XCTAssertNil(refresh.next(now: .seconds(11)))
        refresh.finished("folder", succeeded: true, now: .seconds(11))
        for route in plan.routes(for: .lost(path("folder"))) {
            for id in route.folderIDs { refresh.changed(id, now: .seconds(11)) }
        }
        XCTAssertEqual(refresh.next(now: .milliseconds(11_500)), "parent")
        XCTAssertNil(refresh.next(now: .milliseconds(12_999)))
        XCTAssertEqual(refresh.next(now: .seconds(13)), "folder")
    }

    func testRetryBacksOffUntilAWatcherStaysOpen() {
        var retry = WatchRetry()
        XCTAssertEqual(retry.nextDelay(now: .zero), .seconds(5))
        XCTAssertEqual(retry.nextDelay(now: .seconds(5)), .seconds(10))
        retry.opened(now: .seconds(15))
        XCTAssertEqual(retry.nextDelay(now: .seconds(16)), .seconds(20))
        for _ in 0..<3 { _ = retry.nextDelay(now: .seconds(40)) }
        XCTAssertEqual(retry.nextDelay(now: .seconds(100)), .seconds(60))
        retry.opened(now: .seconds(200))
        XCTAssertEqual(retry.nextDelay(now: .seconds(260)), .seconds(5))
        _ = retry.nextDelay(now: .seconds(265))
        retry.reset()
        XCTAssertEqual(retry.nextDelay(now: .seconds(270)), .seconds(5))
    }
}
