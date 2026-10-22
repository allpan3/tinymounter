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
    private var versions: [String: String] = [:]

    public init() {}

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
