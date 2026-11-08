import CryptoKit
import Darwin
import Foundation

// Standalone harness: SMBClient and SMBEdit over password sessions, without the app's connections.

struct Failed: Error, CustomStringConvertible {
    let description: String
}

extension CatalogRow {
    /// A live row as a listing would store it, for proofs that take catalog rows.
    init(id: String, parentID: String, entry: DirectoryListing.Entry) {
        row = 1
        self.id = id
        self.parentID = parentID
        name = entry.name
        kind = entry.kind == .folder ? .folder : .file
        size = entry.size
        mtimeNs = entry.mtimeNs
        ctimeNs = entry.ctimeNs
        keep = false
        keepRequested = false
        listingComplete = false
        deleted = false
        listGen = nil
        listedAt = nil
        changeSeq = 1
        paused = false
        allowsWriting = true
        editVersion = nil
    }
}

/// Arguments: server account password-file case [share]. The password file holds UTF-8 bytes.
@main enum PasswordCheck {
    static var server = "", account = "", password = Data()

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, NSUserName() == "user" else {
            print(#"{"error":"usage: check-smb-password server account password-file case [share]"}"#)
            exit(64)
        }
        server = arguments[1]
        account = arguments[2]
        password = FileManager.default.contents(atPath: arguments[3]) ?? Data()
        let share = arguments.count > 5 ? arguments[5] : ""
        var result: [String: Any] = ["case": arguments[4]]
        do {
            switch arguments[4] {
            case "signin": result["listed"] = try signIn(share: share)
            case "wrong-password": result["failure"] = try refusal(share: share, password: password + Data("x".utf8))
            case "share-refusal": result["failure"] = try refusal(share: share, password: password)
            case "share-names": result["shares"] = try SMBClient().shareNames(on: login(account), password: password)
            case "account-forms": result["forms"] = try accountForms(share: share)
            case "hold": result["held"] = try hold(share: share)
            case "operations": result["steps"] = try operations(share: share)
            default: throw Failed(description: "unknown case")
            }
            result["ok"] = true
        } catch {
            result["ok"] = false
            result["error"] = String(describing: error)
        }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                     as: UTF8.self))
        exit(result["ok"] as? Bool == true ? 0 : 1)
    }

    static func login(_ account: String) -> ServerAccount {
        ServerAccount(remoteProtocol: .smb, host: server, account: account)
    }

    static func address(_ share: String, account: String = account) throws -> ShareAddress {
        let user = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let address = ShareAddress("//\(user)@\(server)/\(share)") else { throw Failed(description: "address") }
        return address
    }

    static func session(_ share: String, folder: RelativePath = .root, account: String = account,
                        password: Data = password) throws -> any RemoteSession {
        try SMBClient().openSession(address(share, account: account), password: password, folder: folder,
                                    progress: Progress())
    }

    static func signIn(share: String) throws -> Int {
        try session(share).list(.root, progressed: {}).entries.count
    }

    static func refusal(share: String, password: Data) throws -> String {
        do {
            _ = try session(share, password: password)
        } catch let failure as SourceFailure {
            return String(describing: failure)
        }
        throw Failed(description: "signed in")
    }

    static func accountForms(share: String) throws -> [String: String] {
        let name = account
        var forms: [String: String] = [:]
        for (label, form) in [("name", name), ("WORKGROUP\\name", "WORKGROUP\\\(name)"),
                              ("OTHER\\name", "OTHER\\\(name)"), ("WORKGROUP;name", "WORKGROUP;\(name)"),
                              ("name@WORKGROUP", "\(name)@WORKGROUP"), ("name@other.example", "\(name)@other.example")] {
            do {
                _ = try session(share, account: form).list(.root, progressed: {})
                forms[label] = "signed in"
            } catch {
                forms[label] = String(describing: error)
            }
        }
        return forms
    }

    /// Keeps one password session open so the fixture's smbstatus can show its signing and encryption.
    static func hold(share: String) throws -> Int {
        let held = try session(share)
        _ = try held.list(.root, progressed: {})
        sleep(20)
        return try held.list(.root, progressed: {}).entries.count
    }

    static func operations(share: String) throws -> [String] {
        var steps: [String] = [], at = ""
        func step(_ name: String, _ body: () throws -> Void) throws {
            at = ""
            do { try body() } catch { throw Failed(description: "\(name) \(at): \(error)") }
            steps.append(name)
        }
        let run = "step2-" + UUID().uuidString.prefix(8).lowercased()
        let local = FileManager.default.temporaryDirectory.appending(path: run, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: local) }
        let first = local.appending(path: "first.bin"), second = local.appending(path: "second.bin")
        try Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255) }).write(to: first)
        try Data((0..<(1 << 20) + 17).map { _ in UInt8.random(in: 0...255) }).write(to: second)
        let root = RelativePath(run)!, location = RelativePath("\(run)/Named")!
        var named: RemoteFolderIdentity!

        // M18 creation and initial naming, each on its own password session.
        try step("create-folder") {
            _ = try session(share).createFolder(root, expected: nil) { _ in }
            _ = try session(share).createFolder(RelativePath("\(run)/untitled folder")!, expected: nil) { named = $0 }
        }
        try step("name-folder") {
            let id = try session(share).nameFolder(from: RelativePath("\(run)/untitled folder")!, to: location,
                                                   expected: named, recoveryOnly: false)
            guard id == named.fileID else { throw Failed(description: "identity") }
        }
        try step("upload") {
            let remote = try session(share, folder: location)
            _ = try remote.createUpload(path: "a.bin")
            let written = try remote.writeUpload(path: "a.bin", contents: first)
            guard written.size == 3 << 20 else { throw Failed(description: "size") }
        }
        try step("listing") {
            let listing = try session(share, folder: location).list(.root, progressed: {})
            guard listing.entries.map(\.name) == ["a.bin"], listing.entries[0].size == 3 << 20 else {
                throw Failed(description: "entries")
            }
        }
        try step("checksum-read") { try requireContents(share, location, "a.bin", equal: first, staging: local) }
        try step("overwrite") {
            let before = try session(share, folder: location).readMetadata(path: "a.bin").fingerprint
            _ = try session(share, folder: location).overwrite(path: "a.bin", contents: second, expected: before)
            try requireContents(share, location, "a.bin", equal: second, staging: local)
        }
        try step("rename") {
            // FileRenameTransaction.publish's order of calls.
            let remote = try session(share, folder: location)
            _ = try remote.protectRenameParents(source: "a.bin", destination: "b.bin")
            guard try remote.inspectRename(path: "b.bin") == nil else { throw Failed(description: "target") }
            try remote.releaseRename(path: "b.bin")
            guard let source = try remote.inspectRename(path: "a.bin") else { throw Failed(description: "source") }
            try remote.move(source: "a.bin", destination: "b.bin")
            guard let published = try remote.inspectRename(path: "b.bin"),
                  published.version.identity == source.version.identity else { throw Failed(description: "published") }
        }
        try step("folder-move") {
            _ = try session(share).createFolder(RelativePath("\(run)/Dest")!, expected: nil) { _ in }
            let listed = try session(share).list(root, progressed: {})
            let inner = try session(share).list(location, progressed: {})
            guard let folder = listed.entries.first(where: { $0.name == "Named" }),
                  let file = inner.entries.first(where: { $0.name == "b.bin" }) else { throw Failed(description: "rows") }
            // Item IDs are UUIDs, as in a catalog.
            let item = UUID().uuidString, child = UUID().uuidString, dest = UUID().uuidString
            let entries = try [
                CatalogFolderMoveEntry(row: CatalogRow(id: item, parentID: Catalog.rootItemID, entry: folder),
                                       path: RelativePath("Named")!, nativeID: folder.fileID),
                CatalogFolderMoveEntry(row: CatalogRow(id: child, parentID: item, entry: file),
                                       path: RelativePath("Named/b.bin")!, nativeID: file.fileID),
            ]
            let move = CatalogFolderMove(item: item, destinationParent: dest, destinationName: "Named",
                                         destinationParentPath: RelativePath("Dest")!, entries: entries)
            let source = "\(run)/Named", destination = "\(run)/Dest/Named"
            try moveFolder(share, source: source, destination: destination, move: move, folder: root) { at = $0 }
            at = "listing"
            let moved = try session(share).list(RelativePath(destination)!, progressed: {})
            guard moved.entries.map(\.name) == ["b.bin"] else { throw Failed(description: "moved") }
        }
        try step("deletion-traversal") {
            let path = RelativePath("\(run)/Dest/Named")!
            let parent = try session(share).list(RelativePath("\(run)/Dest")!, progressed: {})
            guard let folder = parent.entries.first(where: { $0.name == "Named" }) else { throw Failed(description: "row") }
            let expectation = try DeletionExpectation(path: path, row: CatalogRow(id: UUID().uuidString,
                                                      parentID: UUID().uuidString, entry: folder),
                                                      nativeID: folder.fileID)
            let remote = try session(share) as! SMBEdit
            at = "capture"
            let traversal = try remote.captureDeletionTraversal(of: path, recursive: true, expecting: [expectation])
            guard traversal.objects.count == 2 else { throw Failed(description: "objects") }
            try remote.releaseDeletionTraversal()
        }
        try step("permanent-deletion") {
            for (path, kind) in [("\(run)/Dest/Named/b.bin", CatalogRow.Kind.file), ("\(run)/Dest/Named", .folder),
                                 ("\(run)/Dest", .folder), (run, .folder)] {
                try delete(share, path, kind)
            }
            let top = try session(share).list(.root, progressed: {})
            guard !top.entries.contains(where: { $0.name == run }) else { throw Failed(description: "left") }
        }
        return steps
    }

    /// FolderMoveTransaction's order of calls. The session closes on return: its handles deny delete.
    static func moveFolder(_ share: String, source: String, destination: String, move: CatalogFolderMove,
                           folder: RelativePath, at: (String) -> Void) throws {
        let remote = try session(share)
        at("protect")
        let parents = try remote.protectFolderMoveParents(source: source, destination: destination)
        at("target")
        guard try remote.inspectFolderMoveRoot(path: destination) == nil else { throw Failed(description: "target") }
        at("proofs")
        guard try remote.captureFolderMoveProofs(move: move, folder: folder).count == 2 else {
            throw Failed(description: "proofs")
        }
        at("move")
        try remote.releaseFolderMoveDescendants()
        try remote.moveFolder(source: source, destination: destination)
        at("parents")
        _ = try remote.folderMoveParentsAfterRename(parents)
    }

    /// The admission session closes before removal: its deny-all handle would refuse the removal's open.
    static func admit(_ share: String, _ path: String, _ kind: CatalogRow.Kind) throws -> PendingItemDeletion {
        let admission = try session(share)
        let parents = try admission.protectParents(of: path)
        guard case .present(let selected) = try admission.inspect(path: path, kind: kind) else {
            throw Failed(description: "absent")
        }
        return try PendingItemDeletion(path: RelativePath(path)!, selected: selected, parents: parents)
    }

    static func requireContents(_ share: String, _ folder: RelativePath, _ path: String, equal local: URL,
                                staging: URL) throws {
        let remote = try session(share, folder: folder)
        let (_, fingerprint) = try remote.readMetadata(path: path)
        let range = try ByteRange(offset: 0, length: fingerprint.size, fileSize: fingerprint.size)
        let output = try remote.transfer(path: path, range: range, stagingDirectory: staging, progress: Progress(),
                                         checkSpace: nil)
        guard let staged = output.stagingURL else { throw Failed(description: "staging") }
        defer { try? FileManager.default.removeItem(at: staged) }
        let read = SHA256.hash(data: try Data(contentsOf: staged)), wrote = SHA256.hash(data: try Data(contentsOf: local))
        guard read == wrote, remote.readBytes == fingerprint.size else { throw Failed(description: "checksum") }
    }

    /// ItemDeletionTransaction as LocationDeletions runs it: admission on one session, removal on another.
    static func delete(_ share: String, _ path: String, _ kind: CatalogRow.Kind) throws {
        var record = try admit(share, path, kind)
        var stored = record
        let removal = try session(share)
        try ItemDeletionTransaction.remove(&record, remote: removal, load: { stored }, checkpoint: { stored = $0 })
        guard record.state == .deleted else { throw Failed(description: "state \(record.state)") }
    }
}
