import Darwin
import Foundation

public struct FileRenameView: Codable, Equatable, Sendable {
    public let domain: String
    public let folder: String
    public let item: String
    public let parent: String
    public let path: String
    public let contentVersion: String
    public let nativeID: UInt64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let destinationParent: String?

    public var targetParent: String { destinationParent ?? parent }

    public init(domain: String, folder: RelativePath, row: CatalogRow, path: RelativePath, nativeID: UInt64,
                destinationParent: String? = nil) throws {
        guard row.kind == .file, !row.deleted, let parent = row.parentID else { throw UploadError.unresolved }
        self.domain = domain
        self.folder = folder.string
        item = row.id
        self.parent = parent
        self.path = path.string
        contentVersion = row.contentVersion
        self.nativeID = nativeID
        size = row.size
        mtimeNs = row.mtimeNs
        ctimeNs = row.ctimeNs
        self.destinationParent = destinationParent
    }
}

public struct FileRenameParent: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let identity: EditFileIdentity

    public init(path: String, name: String, identity: EditFileIdentity) {
        self.path = path
        self.name = name
        self.identity = identity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.identity == rhs.identity
    }
}

public struct PendingFileRename: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, attempting, verified, completed, refused }
    public enum Refusal: String, Codable, Sendable { case collision, changed, unsupported }

    public let id: UUID
    public let owner: String
    public let base: EditBaseReceipt
    public let metadataVersion: String
    public let source: String
    public let destination: String
    public let views: [FileRenameView]
    public var state: State = .prepared
    public var refusal: Refusal?
    public var verified: EditFileVersion?
    public var parents: [FileRenameParent]?

    public var isPending: Bool { state != .completed && state != .refused }
    public var name: String { RelativePath(destination)?.components.last ?? "" }
    public var oldName: String { RelativePath(source)?.components.last ?? "" }

    func validate() throws {
        guard UUID(uuidString: owner)?.uuidString == owner,
              let source = RelativePath(source), let destination = RelativePath(destination),
              !source.isRoot, !destination.isRoot,
              parents != nil || source.components.dropLast() == destination.components.dropLast(),
              FileRenameRequest.supportsName(name), FileRenameRequest.supportsName(oldName),
              !source.string.utf8.elementsEqual(destination.string.utf8),
              Int64(metadataVersion).map({ $0 >= 0 }) == true,
              !views.isEmpty, Set(views.map(\.domain)).count == views.count,
              views.contains(where: { $0.domain == owner && $0.item == base.item
                  && (!$0.contentVersion.hasPrefix("e1:") || $0.contentVersion == base.contentVersion) }),
              parents != nil || views.contains(where: { $0.domain == owner && $0.contentVersion == base.contentVersion }),
              (state == .refused) == (refusal != nil),
              ![.verified, .completed].contains(state) || verified?.hasSameContents(as: base.version) == true else {
            throw UploadError.invalidRequest
        }
        for view in views {
            guard UUID(uuidString: view.domain)?.uuidString == view.domain,
                  ReaderMessage.isItemID(view.item), view.item != Catalog.rootItemID,
                  ReaderMessage.isItemID(view.parent), ReaderMessage.isItemID(view.targetParent),
                  view.nativeID != 0, view.size >= 0,
                  !view.contentVersion.isEmpty, view.contentVersion.utf8.count <= 128,
                  let folder = RelativePath(view.folder), let path = RelativePath(view.path),
                  folder.appending(path)?.string == source.string,
                  destination.components.count > folder.components.count,
                  destination.components.prefix(folder.components.count).map(NameKey.init)
                    == folder.components.map(NameKey.init) else {
                throw UploadError.invalidRequest
            }
        }
        if let parents {
            let required = Set([source, destination].flatMap { path in
                (0..<path.components.count).map { path.components.prefix($0).joined(separator: "/") }
            })
            guard Set(parents.map(\.path)) == required, parents.count == required.count else {
                throw UploadError.invalidRequest
            }
            for parent in parents {
                guard let path = RelativePath(parent.path), parent.name == (path.components.last ?? "") else {
                    throw UploadError.invalidRequest
                }
            }
        }
    }
}

/// One intent includes every affected catalog, so none can be removed during uncertain publication.
public final class FileRenameOutbox {
    private let directory: URL
    private let directorySync: (Int32) throws -> Void

    public convenience init(directory: URL) throws {
        try self.init(directory: directory, directorySync: { fd in
            guard fsync(fd) == 0 else { throw posixError("sync rename directory") }
        })
    }

    init(directory: URL, directorySync: @escaping (Int32) throws -> Void) throws {
        self.directory = directory
        self.directorySync = directorySync
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open rename outbox") }
        defer { close(fd) }
        guard try FileSystemInfo(fd: fd).isLocal else { throw UploadError.invalidRequest }
    }

    public func records() throws -> [PendingFileRename] {
        try intents().map {
            guard case .file(let record) = $0 else { throw UploadError.pendingWrites }
            return record
        }
    }

    public func intents() throws -> [RenameIntent] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "rename" }
            .map { url in
                let record = try decode(Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == record.id.uuidString else {
                    throw UploadError.invalidRequest
                }
                return record
            }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func pendingCount(domain: String) throws -> Int {
        try records().filter { $0.isPending && $0.views.contains { $0.domain == domain } }.count
    }

    public func replay(owner: String, request: FileRenameRequest) throws -> PendingFileRename? {
        let records = try records()
        if let match = Self.match(records, owner: owner, request: request) { return match }
        guard !records.contains(where: { record in
            record.isPending && record.views.contains { $0.domain == owner && $0.item == request.item }
        }) else { throw UploadError.pendingWrites }
        return nil
    }

    /// Like `replay`, but reads a shared inventory; any pending folder move in this domain blocks.
    public func replayFile(owner: String, request: FileRenameRequest) throws -> PendingFileRename? {
        let inventory = try intents()
        let files = inventory.compactMap { intent -> PendingFileRename? in
            if case .file(let record) = intent { return record }
            return nil
        }
        if let match = Self.match(files, owner: owner, request: request) { return match }
        guard !inventory.contains(where: { intent in
            guard intent.isPending else { return false }
            switch intent {
            case .file(let record): return record.views.contains { $0.domain == owner && $0.item == request.item }
            case .folder: return intent.domains.contains(owner)
            }
        }) else { throw UploadError.pendingWrites }
        return nil
    }

    private static func match(_ records: [PendingFileRename], owner: String,
                              request: FileRenameRequest) -> PendingFileRename? {
        records.first(where: {
            $0.owner == owner && $0.base.item == request.item
                && $0.metadataVersion == request.metadataVersion && $0.name.utf8.elementsEqual(request.name.utf8)
                && $0.views.contains(where: { $0.domain == owner && $0.targetParent == request.parent
                    && $0.contentVersion == request.contentVersion })
                && $0.state != .refused
        })
    }

    public func prepare(owner: String, request: FileRenameRequest, base: EditBaseReceipt,
                        source: RelativePath, views: [FileRenameView], destination: RelativePath? = nil,
                        parents: [FileRenameParent]? = nil) throws -> PendingFileRename {
        if let existing = try replay(owner: owner, request: request) { return existing }
        return try create(owner: owner, request: request, base: base, source: source, views: views,
                          destination: destination, parents: parents)
    }

    public func prepareFile(owner: String, request: FileRenameRequest, base: EditBaseReceipt,
                            source: RelativePath, views: [FileRenameView], destination: RelativePath? = nil,
                            parents: [FileRenameParent]? = nil) throws -> PendingFileRename {
        if let existing = try replayFile(owner: owner, request: request) { return existing }
        return try create(owner: owner, request: request, base: base, source: source, views: views,
                          destination: destination, parents: parents)
    }

    private func create(owner: String, request: FileRenameRequest, base: EditBaseReceipt,
                        source: RelativePath, views: [FileRenameView], destination: RelativePath?,
                        parents: [FileRenameParent]?) throws -> PendingFileRename {
        guard request.item == base.item,
              views.contains(where: { $0.domain == owner && $0.targetParent == request.parent
                  && $0.contentVersion == request.contentVersion }),
              let parent = RelativePath(source.components.dropLast().joined(separator: "/")),
              let destination = destination ?? parent.appending(request.name),
              destination.components.last?.utf8.elementsEqual(request.name.utf8) == true else {
            throw UploadError.invalidRequest
        }
        let record = PendingFileRename(id: UUID(), owner: owner, base: base, metadataVersion: request.metadataVersion,
                                       source: source.string, destination: destination.string, views: views, parents: parents)
        try save(record)
        return record
    }

    public func save(_ record: PendingFileRename) throws {
        try record.validate()
        if let existing = try existing(record.id) {
            guard case .file(let previous) = existing,
                  previous.owner == record.owner, previous.base == record.base,
                  previous.metadataVersion == record.metadataVersion, previous.views == record.views,
                  previous.source.utf8.elementsEqual(record.source.utf8),
                  previous.destination.utf8.elementsEqual(record.destination.utf8),
                  previous.parents == record.parents else { throw UploadError.invalidRequest }
        }
        try persist(try JSONEncoder().encode(record), id: record.id)
    }

    public func save(_ record: PendingFolderMove) throws {
        try record.validate()
        if let existing = try existing(record.id) {
            guard case .folder(let previous) = existing else { throw UploadError.invalidRequest }
            try record.validateUpdate(from: previous)
        } else {
            guard record.state == .prepared, record.removedDomains.isEmpty else { throw UploadError.invalidRequest }
        }
        try persist(try JSONEncoder().encode(record), id: record.id)
    }

    private func existing(_ id: UUID) throws -> RenameIntent? {
        let url = directory.appending(path: id.uuidString + ".rename")
        do {
            let record = try decode(Data(contentsOf: url))
            guard record.id == id else { throw UploadError.invalidRequest }
            return record
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.fileReadNoSuchFile.rawValue { return nil }
    }

    private func decode(_ data: Data) throws -> RenameIntent {
        struct Header: Decodable { let kind: String? }
        let decoder = JSONDecoder()
        if let kind = try decoder.decode(Header.self, from: data).kind {
            guard kind == "folder" else { throw UploadError.invalidRequest }
            let record = try decoder.decode(PendingFolderMove.self, from: data)
            try record.validate()
            return .folder(record)
        }
        let record = try decoder.decode(PendingFileRename.self, from: data)
        try record.validate()
        return .file(record)
    }

    private func persist(_ data: Data, id: UUID) throws {
        let final = directory.appending(path: id.uuidString + ".rename")
        let temporary = directory.appending(path: UUID().uuidString + ".new")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("create rename intent") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write rename intent") }
                offset += written
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw posixError("sync rename intent") }
        guard rename(temporary.path, final.path) == 0 else { throw posixError("publish rename intent") }
        try syncDirectory()
    }

    func syncDirectory() throws {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError("open rename directory") }
        defer { close(parent) }
        try directorySync(parent)
    }

    public func removeCompleted(owner: String) throws {
        let records = try records()
        guard !records.contains(where: { $0.isPending && $0.views.contains { $0.domain == owner } }) else {
            throw UploadError.pendingWrites
        }
        for record in records where record.owner == owner {
            try FileManager.default.removeItem(at: directory.appending(path: record.id.uuidString + ".rename"))
        }
    }

    public func pendingIntentCount(domain: String) throws -> Int {
        try intents().filter { $0.isPending && $0.domains.contains(domain) }.count
    }

    // Call after domain removal succeeds; pendingIntentCount supplies the earlier preflight.
    public func removeCompletedIntents(removedDomain domain: String) throws {
        let records = try intents()
        guard !records.contains(where: { $0.isPending && $0.domains.contains(domain) }) else {
            throw UploadError.pendingWrites
        }
        for intent in records {
            switch intent {
            case .file(let record) where record.owner == domain:
                try FileManager.default.removeItem(at: directory.appending(path: record.id.uuidString + ".rename"))
            case .folder(var record) where intent.domains.contains(domain):
                if !record.removedDomains.contains(domain) { record.removedDomains.append(domain) }
                if Set(record.removedDomains) == Set(intent.domains) {
                    try FileManager.default.removeItem(at: directory.appending(path: record.id.uuidString + ".rename"))
                } else {
                    try save(record)
                }
            default: break
            }
        }
        try syncDirectory()
    }
}

public enum RenameIntent: Equatable, Sendable {
    case file(PendingFileRename)
    case folder(PendingFolderMove)

    public var id: UUID {
        switch self {
        case .file(let record): record.id
        case .folder(let record): record.id
        }
    }

    public var owner: String {
        switch self {
        case .file(let record): record.owner
        case .folder(let record): record.owner
        }
    }

    public var domains: [String] {
        switch self {
        case .file(let record): record.views.map(\.domain)
        case .folder(let record): record.views.map(\.domain)
        }
    }

    public var isPending: Bool {
        switch self {
        case .file(let record): record.isPending
        case .folder(let record): record.isPending
        }
    }
}

public struct FileRenameEvidence: Sendable {
    public let version: EditFileVersion
    public let name: String

    public init(version: EditFileVersion, name: String) {
        self.version = version
        self.name = name
    }
}

public protocol FileRenameRemote {
    func protectRenameParents(source: String, destination: String) throws -> [FileRenameParent]
    func inspectRename(path: String) throws -> FileRenameEvidence?
    func releaseRename(path: String) throws
    func move(source: String, destination: String) throws
}

public enum FileRenameTransaction {
    public static func publish(_ record: inout PendingFileRename, outbox: FileRenameOutbox,
                               remote: FileRenameRemote,
                               checkpoint: (PendingFileRename.State) throws -> Void = { _ in }) throws {
        try record.validate()
        if record.state == .completed { return }
        if record.state == .refused { throw refusalError(record.refusal) }
        let parents = try remote.protectRenameParents(source: record.source, destination: record.destination)
        if let recorded = record.parents {
            guard parents == recorded else { throw UploadError.unresolved }
        }
        let attempted = record.state != .prepared
        let target = try remote.inspectRename(path: record.destination)
        if let target, target.version.hasSameContents(as: record.base.version),
           SMBName.same(target.name, record.name) {
            record.verified = target.version
            record.state = .verified
            try outbox.save(record)
            try checkpoint(.verified)
            return
        }
        try remote.releaseRename(path: record.destination)
        guard let source = try remote.inspectRename(path: record.source),
              source.version.hasSameContents(as: record.base.version),
              SMBName.same(source.name, record.oldName) else {
            if !attempted { try refuse(&record, .changed, outbox: outbox) }
            throw UploadError.unresolved
        }
        if let target, target.version.identity != source.version.identity {
            try refuse(&record, .collision, outbox: outbox)
        }
        record.state = .attempting
        try outbox.save(record)
        try checkpoint(.attempting)
        do { try remote.move(source: record.source, destination: record.destination) }
        catch UploadError.collision { try refuse(&record, .collision, outbox: outbox) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            if error.code == Int(EEXIST) { try refuse(&record, .collision, outbox: outbox) }
            if [Int(EACCES), Int(EPERM), Int(ENOTSUP), Int(EINVAL), Int(EXDEV)].contains(error.code) {
                try refuse(&record, .unsupported, outbox: outbox)
            }
            throw error
        }
        guard let published = try remote.inspectRename(path: record.destination),
              published.version.hasSameContents(as: record.base.version),
              SMBName.same(published.name, record.name) else { throw UploadError.unresolved }
        record.verified = published.version
        record.state = .verified
        try outbox.save(record)
        try checkpoint(.verified)
    }

    private static func refuse(_ record: inout PendingFileRename, _ reason: PendingFileRename.Refusal,
                               outbox: FileRenameOutbox) throws -> Never {
        record.state = .refused
        record.refusal = reason
        try outbox.save(record)
        throw refusalError(reason)
    }

    private static func refusalError(_ reason: PendingFileRename.Refusal?) -> Error {
        switch reason {
        case .collision: return UploadError.collision
        case .changed: return SourceFailure.versionChanged
        case .unsupported: return CocoaError(.featureUnsupported)
        case nil: return UploadError.unresolved
        }
    }
}
