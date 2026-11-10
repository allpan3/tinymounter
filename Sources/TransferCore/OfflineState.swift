import Foundation

public enum OfflineState: String, Equatable, Sendable {
    case requested, updateInProgress, availableOffline, notSufficientSpace

    public init(status: URLUbiquitousItemDownloadingStatus?, downloading: Bool?, ubiquitous: Bool?,
                size: Int?, modified: Date?, expectedSize: Int64, expectedModified: Date) {
        guard ubiquitous == true, let status else { self = .requested; return }
        if downloading == true || status == .downloaded {
            self = .updateInProgress
            return
        }
        guard status == .current, downloading == false, let size, let modified else {
            self = .requested
            return
        }
        guard Int64(size) == expectedSize, abs(modified.timeIntervalSince(expectedModified)) < 1e-6 else {
            self = .updateInProgress
            return
        }
        self = .availableOffline
    }
}

public struct OfflineVerification: Sendable {
    /// By item ID, the content versions that a synchronized check found applied locally.
    public private(set) var versions: [String: String]

    public init(versions: [String: String] = [:]) {
        self.versions = versions
    }

    public mutating func states(snapshot: FolderKeepSnapshot, files: [String: OfflineState],
                                folders: Set<String>, synchronized: Bool,
                                spaceBlocked: Set<String> = []) -> [String: OfflineState] {
        var current: [String: String] = [:]
        var checked = files
        for row in snapshot.items where row.kind == .file {
            guard files[row.id] == .availableOffline else { continue }
            // Matching local metadata alone cannot prove that a new provider version was applied.
            if synchronized || versions[row.id] == row.contentVersion {
                current[row.id] = row.contentVersion
            } else {
                checked[row.id] = .requested
            }
        }
        versions = current
        for id in spaceBlocked where checked[id] != .availableOffline { checked[id] = .notSufficientSpace }
        return snapshot.states(files: checked, folders: folders)
    }
}

/// Each domain's `OfflineVerification` versions, kept across a relaunch in the app's own container.
/// Only the running app changes a catalog, and a check still needs current local metadata that
/// matches the row, so a version verified in an earlier run is as good as one from this run.
public enum VerifiedVersions {
    public typealias Domains = [String: [String: String]]
    public static let fileName = "VerifiedVersions.json"

    /// A missing file is empty; an unreadable one throws.
    public static func load(from url: URL) throws -> Domains {
        do {
            let domains = try JSONDecoder().decode(Domains.self, from: Data(contentsOf: url))
            try validate(domains)
            return domains
        } catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    public static func save(_ domains: Domains, to url: URL) throws {
        try validate(domains)
        try JSONEncoder().encode(domains.filter { !$0.value.isEmpty }).write(to: url, options: .atomic)
    }

    private static func validate(_ domains: Domains) throws {
        for (domain, versions) in domains {
            guard UUID(uuidString: domain)?.uuidString == domain,
                  versions.allSatisfy({ ReaderMessage.isItemID($0.key) && !$0.value.isEmpty }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
}
