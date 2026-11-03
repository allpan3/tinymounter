import FileProvider
import Foundation

#if !M22_FINDER_PROVIDER
@MainActor
private enum M24ClosedSourceProbe {
    static var record: PendingDeletion?
}

extension LocationController {
    func checkDeletionSourceClose(_ config: M22FinderProbe.Config, label: String) async throws {
        guard let source = sources[config.domain] else { throw LocationError.catalogClosed }
        if label == "check-source-close" {
            let records = try await Self.offMain { try LocationSource.deletionOutbox().records() }
            let pending = records.filter { $0.plan.owner == config.domain && !$0.isComplete }
            try M22FinderProbe.require(M24ClosedSourceProbe.record == nil && pending.count == 1
                && pending[0].isSettled && pending[0].plan.selected.path == config.folder + "/Deletion/SourceClose.txt",
                "one-settled-source-close-fixture-required")
            let record = pending[0]
            let held: Bool = await withCheckedContinuation { continuation in
                source.access.enqueue {
                    continuation.resume(returning: source.deletionRecoveries[record.id]?.settingsPending == true)
                }
            }
            try M22FinderProbe.require(held, "real-settings-completion-held")
            M24ClosedSourceProbe.record = record
            source.close()
        }
        guard let record = M24ClosedSourceProbe.record else {
            throw M22FinderProbe.Failure.check("closed-source-probe-required")
        }
        let drained: Bool = await withCheckedContinuation { continuation in
            source.access.enqueue { continuation.resume(returning: source.deletionRecoveries.isEmpty) }
        }
        try M22FinderProbe.require(drained && source.deletionRecoveryLock.withLock {
            source.deletionCancellation.isClosed && !source.deletionCancellation.isStopping(record.id)
        }, "closed-source-drained-without-stop")
        let current = try await Self.offMain { try LocationSource.deletionOutbox().reload(record) }
        try M22FinderProbe.require(current == record, "closed-source-retains-record")
        try M22FinderProbe.save(["sourceClosed": true, "recoveriesDrained": true,
            "recordPreserved": true, "noStop": true],
            to: M22FinderProbe.directory(config.run).appending(path: label + "-state.json"))
    }

    func checkJoinedDeletionJobs(_ config: M22FinderProbe.Config, label: String) async throws {
        let phase = String(label.dropFirst("check-joined-jobs-".count))
        try M22FinderProbe.require(["hold", "release", "cancel", "verify"].contains(phase), "joined-job-phase")
        let report = try await reader.checkJoinedDeletionJobs(domain: config.domain, phase: phase)
        try M22FinderProbe.save(report,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-jobs.json"))
    }

    func checkProviderDeletionCancellation(_ config: M22FinderProbe.Config, label: String) async throws {
        let records = try await Self.offMain { try LocationSource.deletionOutbox().records() }
        let active = records.filter { $0.plan.owner == config.domain && !$0.isSettled }
        try M22FinderProbe.require(active.count == 1, "one-active-deletion-required")
        let record = active[0]
        try M22FinderProbe.require(record.plan.selected.path.hasPrefix(config.folder + "/Deletion/"),
                                  "provider-cancel-fixture-scope")
        let command = M24ProviderCancellation.Command(run: config.run, item: record.plan.request.item,
            event: record.plan.request.eventVersion, id: UUID())
        let directory = try M22FinderProbe.directory(config.run)
        try M22FinderProbe.save(command,
            to: directory.appending(path: "deletion-cancel-" + command.item + ".json"))
        try M22FinderProbe.save(command, to: directory.appending(path: label + "-command.json"))
    }

    func checkDeletionSession(_ config: M22FinderProbe.Config, label: String) throws {
        let invalidate = label.hasPrefix("check-deletion-session-invalidate-")
        try M22FinderProbe.require(invalidate || label.hasPrefix("check-deletion-session-state-"),
                                  "deletion-session-phase")
        let report = try reader.checkDeletionSession(domain: config.domain, invalidate: invalidate)
        try M22FinderProbe.save(report,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-session.json"))
    }

    func checkDeletionReaderCapacity(_ config: M22FinderProbe.Config, label: String) async throws {
        let phases = ["hold", "release-one", "drain", "verify"]
        let suffix = String(label.dropFirst("check-reader-jobs-".count))
        guard let phase = phases.first(where: { suffix == $0 || suffix.hasPrefix($0 + "-") }) else {
            throw M22FinderProbe.Failure.check("reader-job-phase")
        }
        guard let source = sources[config.domain],
              let row = try M22FinderProbe.rows(source).first(where: { $0.path == "Deletion/Neighbor.txt" }) else {
            throw M22FinderProbe.Failure.check("reader-job-fixture-item")
        }
        let report = try reader.checkDeletionReaderJobs(domain: config.domain, item: row.id, phase: phase)
        try M22FinderProbe.save(report,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-jobs.json"))
    }

    func checkCompletedDeletionReplay(_ config: M22FinderProbe.Config, label: String) async throws {
        guard let source = sources[config.domain] else { throw LocationError.catalogClosed }
        let uncertain = label.hasPrefix("check-unconfirmed-replay-")
        let outcome: DeletionNodeOutcome = uncertain ? .unconfirmed : .stopped
        let expected: ItemDeletionError = uncertain ? .unresolved : .stopped
        let before = try await Self.offMain { try LocationSource.deletionOutbox().records() }
        let completed = before.filter {
            $0.plan.owner == config.domain && $0.isComplete && $0.selectedOutcome == outcome
                && $0.plan.selected.path.hasPrefix(config.folder + "/Deletion/")
        }
        try M22FinderProbe.require(!completed.isEmpty, "completed-record-required")
        var checked: [String] = [], refreshed = 0
        for record in completed {
            guard let row = try source.withCatalog({ try $0.item(id: record.plan.request.item) }),
                  !row.deleted else { continue }
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.outputFormat = .xml
            archiver.encode(try ProviderDomainVersion.decode(record.plan.request.eventVersion),
                            forKey: NSKeyedArchiveRootObjectKey)
            archiver.finishEncoding()
            let event = archiver.encodedData
            try M22FinderProbe.require(event != record.plan.request.eventVersion,
                                      "different-archive-required")
            let request = DeletionRequest(item: row.id, contentVersion: row.contentVersion,
                                          metadataVersion: row.metadataVersion, eventVersion: event)
            if request.contentVersion != record.plan.request.contentVersion
                || request.metadataVersion != record.plan.request.metadataVersion { refreshed += 1 }
            let result: Result<PendingDeletion, Error> = await withCheckedContinuation { continuation in
                source.deleteItem(request, recursive: true, progress: Progress(), started: {}) {
                    continuation.resume(returning: $0)
                }
            }
            guard case .failure(let error) = result, error as? ItemDeletionError == expected else {
                throw M22FinderProbe.Failure.check("original-outcome-required")
            }
            checked.append(record.id.uuidString)
        }
        try M22FinderProbe.require(!checked.isEmpty, "live-item-required")
        try M22FinderProbe.require(refreshed > 0, "refreshed-base-required")
        let after = try await Self.offMain { try LocationSource.deletionOutbox().records() }
        try M22FinderProbe.require(before == after, "replay-records-unchanged")
        try M22FinderProbe.save(checked,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-replay.json"))
    }
}
#endif
