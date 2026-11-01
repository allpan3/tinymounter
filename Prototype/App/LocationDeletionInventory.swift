import Foundation

extension LocationSource {
    /// One inventory for every share.
    static func deletionOutbox() throws -> DeletionOutbox {
        try DeletionOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Deletions", directoryHint: .isDirectory))
    }
}
