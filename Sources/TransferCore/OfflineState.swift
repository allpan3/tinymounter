import Foundation

public enum OfflineState: String, Equatable, Sendable {
    case requested, updateInProgress, availableOffline

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
