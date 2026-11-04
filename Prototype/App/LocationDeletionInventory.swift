import Foundation

struct DeletionAttemptStatus: Sendable {
    let active: Bool
    let failure: DeletionFailure?
    let date: Date
}

struct DeletionStatus: Identifiable, Sendable {
    let record: PendingDeletion
    let path: String
    let items: [DeletionItemProgress]
    let attempt: DeletionAttemptStatus?

    var id: UUID { record.id }
    var canRetry: Bool {
        !record.isComplete && attempt?.active != true && (record.isSettled || SourceReaderBridge.deletionResumeEnabled)
    }

    init(record: PendingDeletion, domain: String, attempt: DeletionAttemptStatus?) throws {
        self.record = record
        path = try record.selectedPath(in: domain)
        items = try record.itemProgress(in: domain)
        self.attempt = attempt
    }
}

extension LocationSource {
    /// One inventory for every share.
    static func deletionOutbox() throws -> DeletionOutbox {
        try DeletionOutbox(directory: URL.applicationSupportDirectory
            .appending(path: "tinymounter/Deletions", directoryHint: .isDirectory))
    }

    func deletionAttempt(_ id: UUID) -> DeletionAttemptStatus? {
        deletionRecoveryLock.withLock { deletionAttempts[id] }
    }

    func noteDeletionAttempt(_ id: UUID, active: Bool, error: Error? = nil) {
        let status = DeletionAttemptStatus(active: active, failure: error.map(DeletionFailure.classify), date: .now)
        deletionRecoveryLock.withLock { deletionAttempts[id] = status }
    }
}
