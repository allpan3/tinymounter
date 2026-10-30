import Foundation

extension LocationSource {
    /// One inventory for every share; guards close the edit and rename outboxes to older builds.
    static func deletionOutbox() throws -> DeletionOutbox {
        let support = URL.applicationSupportDirectory.appending(path: "tinymounter", directoryHint: .isDirectory)
        return try DeletionOutbox(directory: support.appending(path: "Deletions", directoryHint: .isDirectory),
                                  compatibilityGuards: { domain in
            // A plan admits only canonical domain IDs, so no other value can need a guard.
            guard UUID(uuidString: domain)?.uuidString == domain else { return [] }
            return [support.appending(path: "Edits/\(domain)/" + EditOutbox.deletionGuardName),
                    support.appending(path: "Renames/" + FileRenameOutbox.deletionGuardName)]
        })
    }
}
