// Fixture check for change watching (docs/connection-layer-plan.md, step 4). It drives the app's
// SMBWatch and LocationChangeWatch over the built libTinyMounterSMB and changes the share from a
// second connection. Run it through Tools/check-smb-watch.py; output is JSON lines without names.
import Foundation

struct Fixture {
    let host: String, share: String, account: String
    let password: [UInt8]
    var address: ShareAddress { ShareAddress("smb://\(account)@\(host)/\(share)")! }
}

final class Recorder: @unchecked Sendable {
    struct Event {
        let t: Double
        let ids: [String]?
        let notice: ChangeNotice?
        let token: UInt64
        let status: UInt32
        let names: [String]
    }

    private let condition = NSCondition()
    private var events: [Event] = []

    var count: Int { condition.withLock { events.count } }

    func add(ids: [String]? = nil, notice: ChangeNotice? = nil, token: UInt64 = 0, status: UInt32 = 0,
             names: [String] = []) {
        condition.withLock {
            events.append(Event(t: now(), ids: ids, notice: notice, token: token, status: status, names: names))
            condition.broadcast()
        }
    }

    func wait(from start: Int, seconds: Double, _ match: (Event) -> Bool) -> Event? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        return condition.withLock {
            var index = start
            while true {
                while index < events.count {
                    if match(events[index]) { return events[index] }
                    index += 1
                }
                guard condition.wait(until: deadline) else { return nil }
            }
        }
    }

    func all(from start: Int) -> [Event] { condition.withLock { Array(events[min(start, events.count)...]) } }

    /// Waits until nothing arrived for `quiet` seconds, at most `limit`.
    func settle(quiet: Double = 0.5, limit: Double = 5) {
        let end = now() + limit * 1000
        var seen = count, last = now()
        while now() < end && now() - last < quiet * 1000 {
            usleep(20_000)
            if count != seen { seen = count; last = now() }
        }
    }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func check(_ result: Int32, _ what: String) {
    guard result != 0 else { return }
    emit(["fatal": what, "status": String(format: "0x%08x", actor_ntstatus())])
    exit(70)
}

func removeTree(_ path: String) {
    final class Names { var list: [String] = [] }
    let names = Names()
    _ = actor_list(path, { context, name in
        Unmanaged<Names>.fromOpaque(context!).takeUnretainedValue().list.append(String(cString: name!))
    }, Unmanaged.passUnretained(names).toOpaque())
    for name in names.list {
        let child = path + "/" + name
        if actor_is_directory(child) != 0 { removeTree(child) } else { _ = actor_unlink(child) }
    }
    _ = actor_rmdir(path)
}

/// Unicode scalars beyond ASCII, so that a name's normalization shows without the name.
func scalars(_ name: String) -> String {
    name.unicodeScalars.filter { !$0.isASCII }.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
}

func path(_ string: String) -> RelativePath { RelativePath(string)! }

@main
struct CheckSMBWatch {
    static var fixture: Fixture!
    static var root = ""

    static func main() {
        let environment = ProcessInfo.processInfo.environment
        var password = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        while password.last == 10 { password.removeLast() }
        fixture = Fixture(host: environment["TM_WATCH_HOST"]!, share: environment["TM_WATCH_SHARE"]!,
                          account: environment["TM_WATCH_ACCOUNT"]!, password: password)
        let arguments = Array(CommandLine.arguments.dropFirst())
        check(fixture.password.withUnsafeBufferPointer {
            actor_connect(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count)
        }, "actor connect")
        root = String(format: "tm-watch-%08x", UInt32.random(in: 0...UInt32.max))
        check(actor_mkdir(root), "mkdir root")
        switch arguments.first {
        case "coverage": coverage()
        case "overflow": overflow()
        case "names": names()
        case "parents": parents()
        case "restart": restart(seconds: Double(arguments.dropFirst().first ?? "240") ?? 240)
        case "idle": idle(seconds: Double(arguments.dropFirst().first ?? "150") ?? 150)
        case "echo-timeout": echoTimeout()
        case "limit": limit()
        case "delete": deleteWatched()
        default: emit(["fatal": "unknown scenario"])
        }
        removeTree(root)
        emit(["cleanup": actor_is_directory(root) == 0 ? "removed" : "left"])
        actor_disconnect()
    }

    static func openWatcher(_ notice: @escaping @Sendable (ChangeNotice) -> Void) throws -> SMBWatch {
        try fixture.password.withUnsafeBytes { try SMBWatch(share: fixture.address, password: $0, notice: notice) }
    }

    static func locationWatch(_ recorder: Recorder, opens: Recorder? = nil) -> LocationChangeWatch {
        LocationChangeWatch(limit: SMBWatch.folderLimit, open: { notice in
            do {
                let watcher = try openWatcher { notice($0); if case .ended = $0 { opens?.add(notice: $0) } }
                opens?.add(ids: ["opened"])
                return watcher
            } catch {
                opens?.add(ids: ["failed"])
                throw error
            }
        }, excluded: { _ in false }, refresh: { _, ids in recorder.add(ids: ids ?? ["*"]) })
    }

    /// Runs `change` and reports how long until a listing of `folder` was requested.
    static func measure(_ recorder: Recorder, _ name: String, folder: String, seconds: Double = 3,
                        _ change: () -> Int32) {
        recorder.settle()
        let start = recorder.count, began = now()
        let result = change()
        let event = recorder.wait(from: start, seconds: seconds) { $0.ids?.contains(folder) == true }
        emit(["change": name, "folder": folder, "result": Int(result),
              "notice_ms": event.map { (($0.t - began) * 10).rounded() / 10 } ?? NSNull()])
    }

    // MARK: Scenarios

    static func coverage() {
        for folder in ["a", "a/b", "a/b/c", "u"] { check(actor_mkdir("\(root)/\(folder)"), "mkdir") }
        let recorder = Recorder()
        let watch = locationWatch(recorder)
        watch.setFolders([.init(id: "L", parentID: nil, path: .root),
                          .init(id: "a", parentID: "L", path: path("a")),
                          .init(id: "c", parentID: "b", path: path("a/b/c"))],
                         domainID: "domain", root: path(root))
        sleep(2)
        for (id, folder) in [("L", root), ("c", "\(root)/a/b/c")] {
            measure(recorder, "create", folder: id) { actor_write("\(folder)/f.txt", 0, 1, 0) }
            measure(recorder, "write", folder: id) { actor_write("\(folder)/f.txt", 4096, 0, 97) }
            measure(recorder, "same_size_write", folder: id) { actor_write("\(folder)/f.txt", 4096, 0, 98) }
            measure(recorder, "attributes", folder: id) { Int32(bitPattern: actor_set_attributes("\(folder)/f.txt", 2)) }
            measure(recorder, "rename", folder: id) { actor_rename("\(folder)/f.txt", "\(folder)/g.txt") }
            measure(recorder, "delete", folder: id) { actor_unlink("\(folder)/g.txt") }
            measure(recorder, "mkdir", folder: id) { actor_mkdir("\(folder)/sub") }
            measure(recorder, "rmdir", folder: id) { actor_rmdir("\(folder)/sub") }
        }
        // b is not watched: a content edit there must stay unreported, also by its parent's watch.
        check(actor_write("\(root)/a/b/x.txt", 0, 1, 0), "create unwatched")
        recorder.settle(quiet: 1)
        let start = recorder.count
        _ = actor_write("\(root)/a/b/x.txt", 8192, 0, 99)
        let stray = recorder.wait(from: start, seconds: 5) { _ in true }
        emit(["change": "write_unwatched", "notices_in_5s": stray == nil ? 0 : recorder.all(from: start).count,
              "folders": recorder.all(from: start).compactMap(\.ids).flatMap { $0 }])
        watch.cancel()
    }

    static func overflow() {
        check(actor_mkdir("\(root)/burst"), "mkdir")
        let recorder = Recorder(), hold = DispatchSemaphore(value: 0)
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        let watcher = try! openWatcher { notice in
            recorder.add(notice: notice)
            // Keeps the notify thread busy, so the server queues changes with no notify pending.
            if once.first() { hold.wait() }
        }
        watcher.watch([path("\(root)/burst")])
        sleep(1)
        let start = recorder.count
        check(actor_write("\(root)/burst/first.txt", 0, 1, 0), "create first")
        _ = recorder.wait(from: start, seconds: 3) { _ in true }
        let count = 1_100, began = now()
        for index in 0..<count { _ = actor_write(String(format: "\(root)/burst/n%04d", index), 0, 1, 0) }
        let created = now() - began
        let released = recorder.count, releasedAt = now()
        hold.signal()
        let lost = recorder.wait(from: released, seconds: 5) {
            if case .lost = $0.notice { return true } else { return false }
        }
        recorder.settle(quiet: 1)
        let after = recorder.all(from: released).map { event -> String in
            switch event.notice {
            case .changed?: "changed"
            case .lost?: "lost"
            case .ended?: "ended"
            case nil: "none"
            }
        }
        emit(["scenario": "overflow", "creates": count, "create_ms": Int(created),
              "lost_ms": lost.map { Int($0.t - releasedAt) } ?? NSNull(), "notices_after_release": after])
        watcher.cancel()
    }

    static func names() {
        let nfcFolder = "Dossier-\u{E9}", nfdFolder = "Dossier-e\u{301}"
        check(actor_mkdir("\(root)/names"), "mkdir")
        check(actor_mkdir("\(root)/\(nfcFolder)"), "mkdir nfc")
        let recorder = Recorder()
        final class Box { let recorder: Recorder; init(_ r: Recorder) { recorder = r } }
        let box = Unmanaged.passRetained(Box(recorder))
        var error: Int32 = 0, status: UInt32 = 0
        let handle = fixture.password.withUnsafeBufferPointer {
            tm_notify_open(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count, 0,
                           { context, event, token, status, buffer, length in
                let bytes = buffer.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
                let entries = SMBNotifyCompletion.entries(bytes) ?? []
                Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().recorder
                    .add(token: token, status: status, names: entries.map(\.name))
            }, box.toOpaque(), &error, &status)
        }!
        // The watch path is sent composed, so the NFD spelling opens the NFC folder.
        check(tm_notify_watch(handle, 1, "\(root)/names"), "watch")
        check(tm_notify_watch(handle, 2, "\(root)/\(nfdFolder)"), "watch nfd")
        sleep(1)
        let opened = recorder.all(from: 0).filter { $0.token == 2 }.map { String(format: "0x%08x", $0.status) }
        let start = recorder.count
        let created = [("nfc", "Caf\u{E9}.txt"), ("nfd", "Cafe\u{301}-d.txt")]
        for (_, name) in created { check(actor_write("\(root)/names/\(name)", 0, 1, 0), "create") }
        check(actor_write("\(root)/\(nfcFolder)/inside.txt", 0, 1, 0), "create inside")
        recorder.settle(quiet: 1)
        let seen = recorder.all(from: start)
        final class Names { var list: [String] = [] }
        let listed = Names()
        _ = actor_list("\(root)/names", { context, name in
            Unmanaged<Names>.fromOpaque(context!).takeUnretainedValue().list.append(String(cString: name!))
        }, Unmanaged.passUnretained(listed).toOpaque())
        for (form, name) in created {
            let noticed = seen.filter { $0.token == 1 }.flatMap(\.names).filter { $0.hasPrefix("Caf") && ($0.contains("-d") == (form == "nfd")) }
            let inListing = listed.list.filter { $0.hasPrefix("Caf") && ($0.contains("-d") == (form == "nfd")) }
            emit(["sent": form, "sent_scalars": scalars(name),
                  "notice_scalars": Array(Set(noticed.map(scalars))).sorted(),
                  "listing_scalars": inListing.map(scalars)])
        }
        emit(["nfd_watch_path_open_failures": opened,
              "nfc_folder_notices": seen.filter { $0.token == 2 }.count])
        tm_notify_close(handle)
        box.release()
    }

    static func parents() {
        for folder in ["p", "p/q", "p/q/r"] { check(actor_mkdir("\(root)/\(folder)"), "mkdir") }
        let recorder = Recorder()
        let watcher = try! openWatcher { recorder.add(notice: $0) }
        watcher.watch([path("\(root)/p/q/r")])
        sleep(1)
        var result = actor_rename("\(root)/p", "\(root)/p2")
        emit(["change": "rename_grandparent_while_watched", "result": Int(result),
              "status": String(format: "0x%08x", result == 0 ? 0 : actor_ntstatus())])
        if result == 0 {
            recorder.settle()
            let start = recorder.count
            _ = actor_write("\(root)/p2/q/r/n.txt", 0, 1, 0)
            let moved = recorder.wait(from: start, seconds: 3) { $0.notice == .changed(path("\(root)/p/q/r")) }
            emit(["watch_follows_renamed_ancestor": moved != nil])
            check(actor_unlink("\(root)/p2/q/r/n.txt"), "unlink")
            check(actor_rename("\(root)/p2", "\(root)/p"), "rename back")
        }
        let closeBegan = now()
        watcher.watch([])
        emit(["unwatch_settle_ms": ((now() - closeBegan) * 10).rounded() / 10])
        result = actor_rename("\(root)/p", "\(root)/p2")
        emit(["change": "rename_grandparent_after_unwatch", "result": Int(result),
              "status": String(format: "0x%08x", result == 0 ? 0 : actor_ntstatus())])
        if result == 0 { check(actor_rename("\(root)/p2", "\(root)/p"), "rename back") }
        // Another client deletes a watched folder, then its parent.
        watcher.watch([path("\(root)/p/q/r")])
        sleep(1)
        let start = recorder.count, began = now()
        result = actor_rmdir("\(root)/p/q/r")
        let lost = recorder.wait(from: start, seconds: 3) { $0.notice == .lost(path("\(root)/p/q/r")) }
        // Checks the folder itself, not only the rmdir result.
        let gone = actor_is_directory("\(root)/p/q/r") == 0
        let parent = actor_rmdir("\(root)/p/q")
        let parentStatus = parent == 0 ? 0 : actor_ntstatus()
        emit(["change": "rmdir_watched", "result": Int(result), "gone": gone,
              "lost_ms": lost.map { Int($0.t - began) } ?? NSNull(),
              "parent_rmdir_status": String(format: "0x%08x", parentStatus),
              "parent_rmdir_ms": Int(now() - began)])
        recorder.settle()
        emit(["notices_after_rmdir": recorder.all(from: start).count])
        watcher.cancel()
    }

    static func restart(seconds: Double) {
        check(actor_mkdir("\(root)/r"), "mkdir")
        let recorder = Recorder(), opens = Recorder()
        let watch = locationWatch(recorder, opens: opens)
        watch.setFolders([.init(id: "r", parentID: nil, path: path("r"))], domainID: "domain", root: path(root))
        sleep(2)
        measure(recorder, "create_before", folder: "r") { actor_write("\(root)/r/a.txt", 0, 1, 0) }
        let readyAt = now()
        emit(["ready": "restart smbd now"])
        let ended = opens.wait(from: 0, seconds: seconds) { $0.notice != nil }
        let relisted = recorder.wait(from: 0, seconds: seconds) { $0.ids == ["*"] }
        var relistAfterEnded: Any = NSNull()
        if let ended, let relisted { relistAfterEnded = Int(relisted.t - ended.t) }
        emit(["ended_after_ready_ms": ended.map { Int($0.t - readyAt) } ?? NSNull(),
              "relist_after_ended_ms": relistAfterEnded,
              "attempts": opens.all(from: 0).compactMap(\.ids).flatMap { $0 }])
        // The actor's own connection died too.
        actor_disconnect()
        check(fixture.password.withUnsafeBufferPointer {
            actor_connect(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count)
        }, "actor reconnect")
        sleep(1)
        measure(recorder, "create_after_reconnect", folder: "r") { actor_write("\(root)/r/b.txt", 0, 1, 0) }
        watch.cancel()
    }

    static func idle(seconds: Double) {
        check(actor_mkdir("\(root)/i"), "mkdir")
        let recorder = Recorder()
        let watcher = try! openWatcher { recorder.add(notice: $0) }
        watcher.watch([path("\(root)/i")])
        sleep(1)
        let start = recorder.count
        usleep(useconds_t(seconds * 1e6))
        let during = recorder.all(from: start).count
        let began = now()
        _ = actor_write("\(root)/i/after-idle.txt", 0, 1, 0)
        let event = recorder.wait(from: start, seconds: 3) { _ in true }
        emit(["scenario": "idle", "seconds": seconds, "echoes": watcher.echoes, "notices_during_idle": during,
              "notice_ms": event.map { Int($0.t - began) } ?? NSNull()])
        watcher.cancel()
    }

    /// The server stops answering without closing the connection (SIGSTOP on its smbd).
    static func echoTimeout() {
        check(actor_mkdir("\(root)/e"), "mkdir")
        let recorder = Recorder()
        final class Box { let recorder: Recorder; init(_ r: Recorder) { recorder = r } }
        let box = Unmanaged.passRetained(Box(recorder))
        var error: Int32 = 0, status: UInt32 = 0
        let handle = fixture.password.withUnsafeBufferPointer {
            tm_notify_open(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count, 5,
                           { context, event, token, status, _, _ in
                Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().recorder
                    .add(token: UInt64(event), status: status)
            }, box.toOpaque(), &error, &status)
        }!
        check(tm_notify_watch(handle, 1, "\(root)/e"), "watch")
        sleep(1)
        // Only the watcher's smbd should remain for the account.
        actor_disconnect()
        let readyAt = now()
        emit(["ready": "stop the account's smbd now"])
        let ended = recorder.wait(from: 0, seconds: 120) { $0.token == UInt64(TM_NOTIFY_ENDED.rawValue) }
        emit(["scenario": "echo-timeout", "echoes_before": Int(tm_notify_echoes(handle)),
              "ended_after_ready_ms": ended.map { Int($0.t - readyAt) } ?? NSNull(),
              "ended_status": ended.map { String(format: "0x%08x", $0.status) } ?? NSNull()])
        tm_notify_close(handle)
        box.release()
        sleep(3)
        check(fixture.password.withUnsafeBufferPointer {
            actor_connect(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count)
        }, "actor reconnect")
    }

    /// Raw completions when another client deletes a watched folder, with and without entries.
    static func deleteWatched() {
        for folder in ["d", "d/empty", "d/full"] { check(actor_mkdir("\(root)/\(folder)"), "mkdir") }
        check(actor_write("\(root)/d/full/x", 0, 1, 0), "create")
        let recorder = Recorder()
        final class Box { let recorder: Recorder; init(_ r: Recorder) { recorder = r } }
        let box = Unmanaged.passRetained(Box(recorder))
        var error: Int32 = 0, status: UInt32 = 0
        let handle = fixture.password.withUnsafeBufferPointer {
            tm_notify_open(fixture.host, fixture.share, fixture.account, $0.baseAddress, $0.count, 0,
                           { context, event, token, status, buffer, length in
                let bytes = buffer.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
                Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().recorder
                    .add(ids: ["\(event)"], token: token, status: status,
                         names: (SMBNotifyCompletion.entries(bytes) ?? []).map { "\($0.action)" })
            }, box.toOpaque(), &error, &status)
        }!
        check(tm_notify_watch(handle, 1, "\(root)/d/empty"), "watch")
        check(tm_notify_watch(handle, 2, "\(root)/d/full"), "watch")
        check(tm_notify_watch(handle, 3, "\(root)/d"), "watch")
        sleep(1)
        func report(_ name: String, _ change: () -> Int32) {
            recorder.settle()
            let start = recorder.count, began = now()
            let result = change()
            let failure = result == 0 ? 0 : actor_ntstatus()
            recorder.settle(quiet: 1, limit: 5)
            emit(["change": name, "result": Int(result), "status": String(format: "0x%08x", failure),
                  "events": recorder.all(from: start).map {
                      ["event": $0.ids![0], "token": Int($0.token), "status": String(format: "0x%08x", $0.status),
                       "actions": $0.names.joined(separator: ","), "ms": Int($0.t - began)]
                  }])
        }
        report("create_in_empty") { actor_write("\(root)/d/empty/y", 0, 1, 0) }
        report("unlink_in_empty") { actor_unlink("\(root)/d/empty/y") }
        report("rmdir_watched_empty") { actor_rmdir("\(root)/d/empty") }
        report("unlink_in_full") { actor_unlink("\(root)/d/full/x") }
        report("rmdir_watched_full") { actor_rmdir("\(root)/d/full") }
        report("create_in_parent") { actor_write("\(root)/d/z", 0, 1, 0) }
        tm_notify_close(handle)
        box.release()
    }

    static func limit() {
        let folders = (0..<70).map { String(format: "l%02d", $0) }
        for folder in folders { check(actor_mkdir("\(root)/\(folder)"), "mkdir") }
        let recorder = Recorder()
        let watcher = try! openWatcher { recorder.add(notice: $0) }
        watcher.watch(Set(folders.map { path("\(root)/\($0)") }))
        sleep(2)
        emit(["ready": "count the open directories now", "requested": folders.count])
        sleep(25)
        var changed = 0
        for folder in folders {
            let start = recorder.count
            _ = actor_write("\(root)/\(folder)/x", 0, 1, 0)
            if recorder.wait(from: start, seconds: 0.5, { _ in true }) != nil { changed += 1 }
            recorder.settle(quiet: 0.1, limit: 1)
        }
        emit(["scenario": "limit", "folders_with_notices": changed])
        watcher.cancel()
    }
}
