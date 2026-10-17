import Darwin
import Foundation

public enum SettingsError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

/// Never in the App Group: grants and saved paths are private.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public private(set) var version = AppSettings.currentVersion
    public var servers: [ServerGrant]
    public var locations: [LocationRecord]
    public var savedKeeps: [SavedKeepList]
    public var showInMenuBar = true
    public var notifications = true

    public init(servers: [ServerGrant] = [], locations: [LocationRecord] = [], savedKeeps: [SavedKeepList] = []) {
        self.servers = servers
        self.locations = locations
        self.savedKeeps = savedKeeps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // No migrations: a file from another version is a problem to show, not settings to guess.
        guard version == Self.currentVersion else { throw SettingsError.unsupportedVersion(version) }
        servers = try container.decode([ServerGrant].self, forKey: .servers)
        locations = try container.decode([LocationRecord].self, forKey: .locations)
        savedKeeps = try container.decode([SavedKeepList].self, forKey: .savedKeeps)
        showInMenuBar = try container.decode(Bool.self, forKey: .showInMenuBar)
        notifications = try container.decode(Bool.self, forKey: .notifications)
    }

    /// A missing file is a first launch. Every other failure throws and is never empty settings.
    public static func load(from url: URL) throws -> AppSettings {
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return AppSettings() }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    /// Replaces the file with one rename. The new file is 0600 from its creation.
    public func save(to url: URL) throws {
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
}

/// The bookmark, `mountFrom`, host and account are private: never log them.
public struct ServerGrant: Codable, Equatable, Sendable {
    public let id: UUID
    /// App-scoped, with `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess`.
    public var bookmark: Data
    /// `f_mntfromname`, "//account@host/share".
    public let mountFrom: String
    /// From `NSURLVolumeURLForRemountingKey`.
    public let host: String, account: String, share: String

    public init(id: UUID = UUID(), bookmark: Data, mountFrom: String, address: ShareAddress) {
        self.id = id
        self.bookmark = bookmark
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
    public var serverID: UUID
    /// A `RelativePath` from the share root; "" is the full share.
    public var folder: String
    /// The `NSFileProviderDomainIdentifier`, a UUID.
    public var domainID: String
    /// Set while Apply runs: the old domain that is still to be removed.
    public var retiredDomainID: String?
    public var removing = false
    /// Saved Keep Downloaded paths, from the share root, that this location took but hasn't found yet.
    public var pendingKeeps: [String] = []

    public init(id: UUID = UUID(), name: String, serverID: UUID, folder: RelativePath,
                domainID: String = UUID().uuidString) {
        self.id = id
        self.name = name
        self.serverID = serverID
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
    public var paths: [String]

    public init(host: String, share: String, paths: [String]) {
        self.host = host
        self.share = share
        self.paths = paths
    }

    func isFor(host: String, share: String) -> Bool { ServerGrant.isSameShare(self.host, self.share, host, share) }
}

extension AppSettings {
    /// Plan §4: a new location takes the saved paths inside its folder out of the share's list.
    public mutating func takeSavedKeeps(host: String, share: String, inside folder: RelativePath) -> [String] {
        var taken: [String] = []
        for index in savedKeeps.indices where savedKeeps[index].isFor(host: host, share: share) {
            taken += savedKeeps[index].paths.filter { LocationRecord.path($0, inside: folder) != nil }
            savedKeeps[index].paths.removeAll { LocationRecord.path($0, inside: folder) != nil }
        }
        savedKeeps.removeAll(where: \.paths.isEmpty)
        return taken
    }

    /// Adds paths from the share root to the share's saved list, each once.
    public mutating func saveKeeps(_ paths: [String], host: String, share: String) {
        guard !paths.isEmpty else { return }
        if let index = savedKeeps.firstIndex(where: { $0.isFor(host: host, share: share) }) {
            let saved = Set(savedKeeps[index].paths)
            var added = Set<String>()
            savedKeeps[index].paths += paths.filter { !saved.contains($0) && added.insert($0).inserted }
        } else {
            var added = Set<String>()
            savedKeeps.append(SavedKeepList(host: host, share: share, paths: paths.filter { added.insert($0).inserted }))
        }
    }

    /// The saved paths that a location on this share and folder would take.
    public func savedKeeps(host: String, share: String, inside folder: RelativePath) -> [String] {
        savedKeeps.filter { $0.isFor(host: host, share: share) }.flatMap(\.paths)
            .filter { LocationRecord.path($0, inside: folder) != nil }
    }
}

/// An SMB share address with an account and never a password.
public struct ShareAddress: Hashable, Sendable {
    public let host: String
    public let account: String
    public let share: String

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
