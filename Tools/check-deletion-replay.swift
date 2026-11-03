import FileProvider
import Foundation

#if !M22_FINDER_PROVIDER
extension LocationController {
    func checkDeletionReaderCapacity(_ config: M22FinderProbe.Config, label: String) async throws {
        let phases = ["hold", "release-one", "drain", "verify"]
        let phase = String(label.dropFirst("check-reader-jobs-".count))
        try M22FinderProbe.require(phases.contains(phase), "reader-job-phase")
        guard let source = sources[config.domain],
              let row = try M22FinderProbe.rows(source).first(where: { $0.path == "Deletion/Neighbor.txt" }) else {
            throw M22FinderProbe.Failure.check("reader-job-fixture-item")
        }
        let report = try reader.checkDeletionReaderJobs(domain: config.domain, item: row.id, phase: phase)
        try M22FinderProbe.save(report,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-jobs.json"))
    }

    func checkStoppedDeletionReplay(_ config: M22FinderProbe.Config, label: String) async throws {
        guard let source = sources[config.domain] else { throw LocationError.catalogClosed }
        let before = try await Self.offMain { try LocationSource.deletionOutbox().records() }
        let stopped = before.filter {
            $0.plan.owner == config.domain && $0.isComplete && $0.selectedOutcome == .stopped
                && $0.plan.selected.path.hasPrefix(config.folder + "/Deletion/")
        }
        try M22FinderProbe.require(!stopped.isEmpty, "completed-stopped-record-required")
        var checked: [String] = []
        for record in stopped {
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
            try M22FinderProbe.require(request.contentVersion != record.plan.request.contentVersion
                || request.metadataVersion != record.plan.request.metadataVersion, "refreshed-base-required")
            let result: Result<PendingDeletion, Error> = await withCheckedContinuation { continuation in
                source.deleteItem(request, recursive: true, progress: Progress(), started: {}) {
                    continuation.resume(returning: $0)
                }
            }
            guard case .failure(let error) = result, error as? ItemDeletionError == .stopped else {
                throw M22FinderProbe.Failure.check("original-stopped-outcome-required")
            }
            checked.append(record.id.uuidString)
        }
        try M22FinderProbe.require(!checked.isEmpty, "live-stopped-item-required")
        let after = try await Self.offMain { try LocationSource.deletionOutbox().records() }
        try M22FinderProbe.require(before == after, "replay-records-unchanged")
        try M22FinderProbe.save(checked,
            to: M22FinderProbe.directory(config.run).appending(path: label + "-replay.json"))
    }
}
#endif
