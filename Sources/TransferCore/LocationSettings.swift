import Darwin
import Foundation

public enum SettingsError: Error, Equatable, Sendable {
    case invalidServer
    case serverInUse
    case shareModeConflict
}

/// Never in the App Group: grants and saved paths are private.
public struct AppSettings: Codable, Equatable, Sendable {
    public var servers: [ServerRecord]
    public var shares: [ServerGrant]
    public var locations: [LocationRecord]
    public var savedKeeps: [SavedKeepList]
    public var serverVolumes: [ServerVolumeRecord]

    public init(servers: [ServerRecord] = [], shares: [ServerGrant] = [], locations: [LocationRecord] = [],
                savedKeeps: [SavedKeepList] = [], serverVolumes: [ServerVolumeRecord] = []) {
        self.servers = servers
        self.shares = shares
        self.locations = locations
        self.savedKeeps = savedKeeps
        self.serverVolumes = serverVolumes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decode([ServerRecord].self, forKey: .servers)
        shares = try container.decode([ServerGrant].self, forKey: .shares)
        locations = try container.decode([LocationRecord].self, forKey: .locations)
        savedKeeps = try container.decode([SavedKeepList].self, forKey: .savedKeeps)
        serverVolumes = try container.decodeIfPresent([ServerVolumeRecord].self, forKey: .serverVolumes) ?? []
        guard shares.allSatisfy({ share in servers.contains { $0.id == share.serverID } }) else {
            throw SettingsError.invalidServer
        }
        try validateServerVolumes()
    }

    /// A missing file is a first launch. Every other failure throws and is never empty settings.
    public static func load(from url: URL) throws -> AppSettings {
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    /// Replaces the file with one rename. The new file is 0600 from its creation.
    public func save(to url: URL) throws {
        try validateServerVolumes()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path(percentEncoded: false)
        let temporary = path + ".new"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open settings") }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // A file left by a failed save keeps its old mode, so set it again.
            guard fchmod(fd, 0o600) == 0 else { throw posixError("fchmod settings") }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary, path) == 0 else { throw posixError("rename settings") }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    public func serverIsUsed(_ id: UUID) -> Bool {
        let grants = Set(shares.filter { $0.serverID == id }.map(\.id))
        return locations.contains { grants.contains($0.grantID) }
            || serverVolumes.contains { grants.contains($0.grantID) }
    }

    private func validateServerVolumes() throws {
        var used: Set<UUID> = []
        for volume in serverVolumes {
            guard let grant = shares.first(where: { $0.id == volume.grantID }),
                  used.insert(volume.id).inserted else { throw SettingsError.invalidServer }
            let related = Set(shares.filter { $0.isSameShare(host: grant.host, share: grant.share) }.map(\.id))
            guard !locations.contains(where: { related.contains($0.grantID) }),
                  serverVolumes.filter({ related.contains($0.grantID) }).count == 1 else {
                throw SettingsError.shareModeConflict
            }
        }
    }

    public func requireMode(_ mode: LocationMode, for grantID: UUID) throws {
        guard let grant = shares.first(where: { $0.id == grantID }) else { throw SettingsError.invalidServer }
        let related = Set(shares.filter { $0.isSameShare(host: grant.host, share: grant.share) }.map(\.id))
        guard !serverVolumes.contains(where: { related.contains($0.grantID) }),
              mode == .fileProvider || !locations.contains(where: { related.contains($0.grantID) }) else {
            throw SettingsError.shareModeConflict
        }
    }

    public func writeBookmark(for grantID: UUID) -> Data? {
        guard let grant = shares.first(where: { $0.id == grantID }) else { return nil }
        return grant.writeBookmark ?? locations.first(where: {
            $0.grantID == grantID && $0.writeBookmark != nil
        })?.writeBookmark
    }

    public mutating func removeServer(_ id: UUID) throws {
        guard !serverIsUsed(id) else { throw SettingsError.serverInUse }
        shares.removeAll { $0.serverID == id }
        servers.removeAll { $0.id == id }
    }

}

public enum LocationMode: String, CaseIterable, Sendable {
    case fileProvider, serverVolume
}

public struct ServerVolumeRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let grantID: UUID

    public init(id: UUID = UUID(), grantID: UUID) {
        self.id = id
        self.grantID = grantID
    }
}

public struct ServerRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let address: URL

    public var host: String { URLComponents(url: address, resolvingAgainstBaseURL: false)?.host ?? "" }
    public var account: String? { URLComponents(url: address, resolvingAgainstBaseURL: false)?.user }

    public init(id: UUID = UUID(), address: ServerAddress) {
        self.id = id
        self.address = address.serverURL
    }

    public func matches(_ other: ServerAddress) -> Bool {
        host.caseInsensitiveCompare(other.host) == .orderedSame && account?.lowercased() == other.account?.lowercased()
    }

    /// Whether a share connected through `other` can belong to this server. macOS reuses an
    /// existing mount of a share, whichever account asked for it, so the mounted account can differ.
    /// A server typed without an account accepts any account.
    public func accepts(account other: String) -> Bool {
        account.map { $0.caseInsensitiveCompare(other) == .orderedSame } ?? true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let url = try container.decode(URL.self, forKey: .address)
        guard let parsed = ServerAddress(typed: url.absoluteString), parsed.share == nil else {
            throw SettingsError.invalidServer
        }
        address = parsed.serverURL
    }
}

/// The bookmark, `mountFrom`, host and account are private: never log them.
public struct ServerGrant: Codable, Equatable, Sendable {
    public let id: UUID
    public var serverID: UUID
    /// App-scoped, with `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess`.
    public var bookmark: Data
    /// Retained permission; each location still controls whether writes are enabled.
    public var writeBookmark: Data?
    /// `f_mntfromname`, "//account@host/share".
    public let mountFrom: String
    /// From `NSURLVolumeURLForRemountingKey`.
    public let host: String, account: String, share: String

    public init(id: UUID = UUID(), serverID: UUID, bookmark: Data, writeBookmark: Data? = nil,
                mountFrom: String, address: ShareAddress) {
        self.id = id
        self.serverID = serverID
        self.bookmark = bookmark
        self.writeBookmark = writeBookmark
        self.mountFrom = mountFrom
        host = address.host
        account = address.account
        share = address.share
    }

    /// The same share, maybe through another account: Apply keeps its kept paths on the location.
    public func isSameShare(host: String, share: String) -> Bool {
        Self.isSameShare(self.host, self.share, host, share)
    }

    /// Host names and SMB share names don't depend on case.
    static func isSameShare(_ host: String, _ share: String, _ otherHost: String, _ otherShare: String) -> Bool {
        host.caseInsensitiveCompare(otherHost) == .orderedSame && share.caseInsensitiveCompare(otherShare) == .orderedSame
    }
}

public struct LocationRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var grantID: UUID
    /// A `RelativePath` from the share root; "" is the full share.
    public var folder: String
    /// The `NSFileProviderDomainIdentifier`, a UUID.
    public var domainID: String
    /// Set while Apply runs: the old domain that is still to be removed.
    public var retiredDomainID: String?
    public var removing = false
    /// Saved Keep Downloaded paths, from the share root, that this location took but hasn't found yet.
    public var pendingKeeps: [KeepPath] = []
    public var writeBookmark: Data?
    public var readOnly = true

    public var activeWriteBookmark: Data? { readOnly ? nil : writeBookmark }

    public init(id: UUID = UUID(), name: String, grantID: UUID, folder: RelativePath,
                domainID: String = UUID().uuidString) {
        self.id = id
        self.name = name
        self.grantID = grantID
        self.folder = folder.string
        self.domainID = domainID
    }

    /// Leading and trailing slashes are trimmed, so "/" and "" are the full share.
    public static func normalizedFolder(_ text: String) -> RelativePath? {
        // Trim scalars, not Characters: a combining mark after "/" makes one Character with it.
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0 != "/" }),
              let last = scalars.lastIndex(where: { $0 != "/" }) else { return .root }
        return RelativePath(String(scalars[first...last]))
    }

    /// "name copy", as Finder names a copy, made unique.
    public static func copyName(_ name: String, among names: some Sequence<String>) -> String {
        uniqueName(name + " copy", among: names)
    }

    /// The path below the location folder for `path` from the share root; nil if it is outside.
    public static func path(_ path: String, inside folder: RelativePath) -> RelativePath? {
        if folder.isRoot { return RelativePath(path) }
        guard path.utf8.count > folder.string.utf8.count + 1, path.utf8.starts(with: (folder.string + "/").utf8) else {
            return nil
        }
        return RelativePath(String(decoding: path.utf8.dropFirst(folder.string.utf8.count + 1), as: UTF8.self))
    }

    /// `name` if no other name has its key, else "name 2", "name 3" and so on.
    public static func uniqueName(_ name: String, among names: some Sequence<String>) -> String {
        // Finder shows each location as a folder on a case-insensitive volume.
        let taken = Set(names.map(NameKey.init))
        guard taken.contains(NameKey(name)) else { return name }
        var number = 2
        while taken.contains(NameKey("\(name) \(number)")) { number += 1 }
        return "\(name) \(number)"
    }
}

public struct SavedKeepList: Codable, Equatable, Sendable {
    /// Not the grant ID, so that a new grant for the same share matches.
    public let host: String, share: String
    /// `RelativePath`s from the share root.
    public var paths: [KeepPath]

    public init(host: String, share: String, paths: [KeepPath]) {
        self.host = host
        self.share = share
        self.paths = paths
    }

    func isFor(host: String, share: String) -> Bool { ServerGrant.isSameShare(self.host, self.share, host, share) }
}

extension AppSettings {
    // Only confirmed nodes are supplied; a deleted folder does not prove its children were deleted.
    public mutating func removeKeptItems(_ items: [KeepPath], host: String, share: String) throws {
        guard !items.isEmpty else { return }
        let deleted = try Set(items.map { item -> KeepPath in
            guard let path = RelativePath(item.path), !path.isRoot else { throw UploadError.invalidRequest }
            return KeepPath(path: NameKey(path.string).value, kind: item.kind)
        })
        func retained(_ paths: [KeepPath]) -> [KeepPath] {
            paths.filter { !deleted.contains(KeepPath(path: NameKey($0.path).value, kind: $0.kind)) }
        }
        let related = Set(shares.filter { ServerGrant.isSameShare($0.host, $0.share, host, share) }.map(\.id))
        for index in locations.indices where related.contains(locations[index].grantID) {
            locations[index].pendingKeeps = retained(locations[index].pendingKeeps)
        }
        for index in savedKeeps.indices where savedKeeps[index].isFor(host: host, share: share) {
            savedKeeps[index].paths = retained(savedKeeps[index].paths)
        }
        savedKeeps.removeAll { $0.isFor(host: host, share: share) && $0.paths.isEmpty }
    }

    public mutating func removeKeptFolder(at path: String, host: String, share: String) throws {
        guard let folder = RelativePath(path), !folder.isRoot else { throw UploadError.invalidRequest }
        let prefix = folder.components.map(NameKey.init)
        let related = Set(shares.filter { ServerGrant.isSameShare($0.host, $0.share, host, share) }.map(\.id))
        let paths = locations.filter { related.contains($0.grantID) }.flatMap(\.pendingKeeps)
            + savedKeeps.filter { $0.isFor(host: host, share: share) }.flatMap(\.paths)
        let removed = try paths.filter { keep in
            guard let current = RelativePath(keep.path) else { throw UploadError.invalidRequest }
            return current.components.count >= prefix.count
                && current.components.prefix(prefix.count).map(NameKey.init) == prefix
                && (current.components.count > prefix.count || keep.kind == .folder)
        }
        try removeKeptItems(removed, host: host, share: share)
    }

    public mutating func moveKeptFolder(from source: String, to destination: String, host: String, share: String) throws {
        guard let sourcePath = RelativePath(source), !sourcePath.isRoot,
              let destinationPath = RelativePath(destination), !destinationPath.isRoot else {
            throw UploadError.invalidRequest
        }
        let prefix = sourcePath.components.map(NameKey.init)
        guard destinationPath.components.count <= prefix.count
            || destinationPath.components.prefix(prefix.count).map(NameKey.init) != prefix else {
            throw UploadError.invalidRequest
        }
        guard destinationPath.components.count >= prefix.count
            || Array(prefix.prefix(destinationPath.components.count)) != destinationPath.components.map(NameKey.init) else {
            throw UploadError.invalidRequest
        }
        func moved(_ paths: [KeepPath]) throws -> [KeepPath] {
            var seen: Set<KeepPath> = []
            return try paths.map { keep in
                guard let path = RelativePath(keep.path) else { throw UploadError.invalidRequest }
                guard path.components.count >= prefix.count,
                      path.components.prefix(prefix.count).map(NameKey.init) == prefix,
                      path.components.count > prefix.count || keep.kind == .folder else { return keep }
                let suffix = path.components.dropFirst(prefix.count)
                guard let target = RelativePath((destinationPath.components + Array(suffix)).joined(separator: "/")) else {
                    throw UploadError.invalidRequest
                }
                return KeepPath(path: target.string, kind: keep.kind)
            }.filter { seen.insert($0).inserted }
        }
        var updated = self
        let related = Set(shares.filter { ServerGrant.isSameShare($0.host, $0.share, host, share) }.map(\.id))
        for index in locations.indices where related.contains(locations[index].grantID) {
            updated.locations[index].pendingKeeps = try moved(locations[index].pendingKeeps)
        }
        for index in savedKeeps.indices where savedKeeps[index].isFor(host: host, share: share) {
            updated.savedKeeps[index].paths = try moved(savedKeeps[index].paths)
        }
        self = updated
    }

    public mutating func moveKeptFile(from source: String, to destination: String, host: String, share: String) throws {
        guard let sourcePath = RelativePath(source), !sourcePath.isRoot,
              let destinationPath = RelativePath(destination), !destinationPath.isRoot else {
            throw UploadError.invalidRequest
        }
        func moved(_ paths: [KeepPath]) -> [KeepPath] {
            var seen: Set<KeepPath> = []
            return paths.map { path in
                path.kind == .file && path.path == source
                    ? KeepPath(path: destination, kind: .file) : path
            }.filter { seen.insert($0).inserted }
        }
        let related = Set(shares.filter { ServerGrant.isSameShare($0.host, $0.share, host, share) }.map(\.id))
        for index in locations.indices where related.contains(locations[index].grantID) {
            locations[index].pendingKeeps = moved(locations[index].pendingKeeps)
        }
        for index in savedKeeps.indices where savedKeeps[index].isFor(host: host, share: share) {
            savedKeeps[index].paths = moved(savedKeeps[index].paths)
        }
    }

    /// Plan §4: a new location takes the saved paths inside its folder out of the share's list.
    public mutating func takeSavedKeeps(host: String, share: String, inside folder: RelativePath) -> [KeepPath] {
        var taken: [KeepPath] = []
        for index in savedKeeps.indices where savedKeeps[index].isFor(host: host, share: share) {
            taken += savedKeeps[index].paths.filter { $0.below(folder) != nil }
            savedKeeps[index].paths.removeAll { $0.below(folder) != nil }
        }
        savedKeeps.removeAll(where: \.paths.isEmpty)
        return taken
    }

    /// Adds paths from the share root to the share's saved list, each once.
    public mutating func saveKeeps(_ paths: [KeepPath], host: String, share: String) {
        guard !paths.isEmpty else { return }
        if let index = savedKeeps.firstIndex(where: { $0.isFor(host: host, share: share) }) {
            let saved = Set(savedKeeps[index].paths)
            var added = Set<KeepPath>()
            savedKeeps[index].paths += paths.filter { !saved.contains($0) && added.insert($0).inserted }
        } else {
            var added = Set<KeepPath>()
            savedKeeps.append(SavedKeepList(host: host, share: share, paths: paths.filter { added.insert($0).inserted }))
        }
    }

    /// The saved paths that a location on this share and folder would take.
    public func savedKeeps(host: String, share: String, inside folder: RelativePath) -> [KeepPath] {
        savedKeeps.filter { $0.isFor(host: host, share: share) }.flatMap(\.paths)
            .filter { $0.below(folder) != nil }
    }
}

/// An SMB share address with an account and never a password.
public struct ShareAddress: Hashable, Sendable {
    public let host: String
    public let account: String
    public let share: String

    public static func withoutEmptyPassword(_ string: String) -> String? {
        guard var components = URLComponents(string: string) else { return nil }
        guard let password = components.password else { return string }
        guard password.isEmpty else { return nil }
        components.password = nil
        return components.string
    }

    /// Parses `f_mntfromname` ("//account@host/share") and a remount URL ("smb://account@host/share").
    public init?(_ string: String) {
        guard let components = URLComponents(string: string),
              components.scheme.map({ $0.lowercased() == "smb" }) ?? string.hasPrefix("//"),
              components.password == nil, components.port == nil, components.query == nil, components.fragment == nil,
              let account = components.user, !account.isEmpty, let host = components.host, !host.isEmpty else {
            return nil
        }
        // Split before decoding, so an encoded "/" can't add a component.
        var parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 3, parts[2].isEmpty { parts.removeLast() }
        guard parts.count == 2, parts[0].isEmpty, let share = parts[1].removingPercentEncoding,
              RelativePath.isValidComponent(share) else { return nil }
        self.host = host
        self.account = account
        self.share = share
    }
}

/// What the user types in Add Share, as in Connect to Server: "smb://server/share", without the
/// scheme, or only the server. The account is optional; a password is never accepted.
public struct ServerAddress: Equatable, Sendable {
    public let url: URL
    public let host: String
    public let account: String?
    /// Nil for only the server: macOS then asks which share to mount.
    public let share: String?
    public let serverURL: URL

    public init?(typed text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        if !text.contains("://") { text = (text.hasPrefix("//") ? "smb:" : "smb://") + text }
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "smb",
              components.password == nil, components.port == nil, components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty, components.user.map({ !$0.isEmpty }) ?? true else {
            return nil
        }
        // Split before decoding, so an encoded "/" can't add a component.
        var parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        guard parts.first?.isEmpty ?? true, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let share = parts[1].removingPercentEncoding, RelativePath.isValidComponent(share) else { return nil }
            self.share = share
        } else {
            share = nil
        }
        components.scheme = "smb"
        components.percentEncodedPath = parts.count == 2 ? "/" + parts[1] : ""
        guard let url = components.url else { return nil }
        self.url = url
        components.percentEncodedPath = ""
        guard let serverURL = components.url else { return nil }
        self.serverURL = serverURL
        self.host = host
        account = components.user
    }

    /// For a share that is already mounted: the same server and share, and the account if typed.
    public func matches(_ mounted: ShareAddress) -> Bool {
        func same(_ typed: String?, _ other: String) -> Bool {
            typed.map { $0.caseInsensitiveCompare(other) == .orderedSame } ?? true
        }
        return same(host, mounted.host) && same(share, mounted.share) && same(account, mounted.account)
    }
}
