import Darwin
import Foundation

enum M24FinderCrash {
    struct Control: Codable {
        let run: UUID
        let id: UUID
        let item: String
        let source: String
        let node: Int
        let checkpoint: String
        let action: String?
    }

    struct Hit: Codable {
        let control: Control
        let checkpoint: String
        let process: Int32
        let date: String
        let plan: DeletionPlan
        let progress: DeletionProgress
    }

    static let checkpoints: Set<String> = ["attempting-before", "attempting-after",
        "closeAcknowledged-before", "closeAcknowledged-after", "deleted-before", "deleted-after",
        "admitted", "settings", "settled", "marked"]

    enum Injection: Error { case failed, timeout }

    static func checkpoint(_ plan: DeletionPlan, outbox: DeletionOutbox, node: Int,
                           stage: String) throws {
        guard let (control, directory) = try capture(plan, outbox: outbox, node: node, stage: stage) else { return }
        if control.action == "fail" || control.action == "fail-repeated" { throw Injection.failed }
        if control.action == "hold" {
            let release = directory.appending(path: "deletion-release-" + control.id.uuidString)
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while !FileManager.default.fileExists(atPath: release.path) {
                guard ContinuousClock.now < deadline else { throw Injection.timeout }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return
        }
        try M22FinderProbe.require(control.action == nil || control.action == "stop", "deletion-fault-action")
        raise(SIGSTOP)
    }

    static func settings(_ record: PendingDeletion) async throws {
        guard let (control, directory) = try capture(record.plan, outbox: LocationSource.deletionOutbox(),
                                                     node: 0, stage: "settings") else { return }
        try M22FinderProbe.require(control.action == "hold", "deletion-settings-action")
        let release = directory.appending(path: "deletion-release-" + control.id.uuidString)
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !FileManager.default.fileExists(atPath: release.path) {
            guard ContinuousClock.now < deadline else { throw Injection.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func capture(_ plan: DeletionPlan, outbox: DeletionOutbox, node: Int,
                                stage: String) throws -> (Control, URL)? {
        guard let config = M22FinderProbe.selected(plan.owner),
              let directory = M22FinderCrash.export.lock.withLock({ M22FinderCrash.export.url }),
              checkpoints.contains(stage) else { return nil }
        let scopedURL = directory.appending(path: "deletion-fault-" + stage + ".json")
        let controlURL = FileManager.default.fileExists(atPath: scopedURL.path) ? scopedURL
            : directory.appending(path: "deletion-fault.json")
        guard FileManager.default.fileExists(atPath: controlURL.path) else { return nil }
        let control = try M22FinderProbe.load(Control.self, from: controlURL)
        try M22FinderProbe.require(control.run == config.run && checkpoints.contains(control.checkpoint),
                                  "deletion-fault-control-scope")
        guard stage == control.checkpoint, node == control.node, plan.request.item == control.item,
              plan.selected.path.utf8.elementsEqual((config.folder + "/" + control.source).utf8) else { return nil }
        try M22FinderProbe.require(RelativePath(control.source) != nil
            && control.source.hasPrefix("Deletion/"), "deletion-fault-subtree")
        let hitURL = directory.appending(path: "deletion-fault-hit-" + control.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: hitURL.path) {
            return control.action == "fail-repeated" ? (control, directory) : nil
        }
        let progress = try outbox.durableProgress(of: plan)
        try M22FinderProbe.save(Hit(control: control, checkpoint: stage, process: getpid(),
            date: ISO8601DateFormatter().string(from: .now), plan: plan, progress: progress), to: hitURL)
        M22FinderProbe.logger.notice("m24_crash_checkpoint run=\(config.run.uuidString, privacy: .public) stage=\(stage, privacy: .public)")
        return (control, directory)
    }
}

final class M24FinderRemote: DeletionRemote {
    let remote: DeletionRemote
    let plan: DeletionPlan
    let outbox: DeletionOutbox
    let node: Int

    init(_ remote: DeletionRemote, plan: DeletionPlan, outbox: DeletionOutbox, node: Int) {
        self.remote = remote
        self.plan = plan
        self.outbox = outbox
        self.node = node
    }

    func protectParents(of path: String) throws -> [ItemDeletionParent] { try remote.protectParents(of: path) }
    func inspect(path: String, kind: CatalogRow.Kind) throws -> ItemDeletionLookup {
        try remote.inspect(path: path, kind: kind)
    }
    func list(path: String) throws -> ItemDeletionListing { try remote.list(path: path) }
    func markDeletion(path: String) throws {
        try remote.markDeletion(path: path)
        try M24FinderCrash.checkpoint(plan, outbox: outbox, node: node, stage: "marked")
    }
    func closeTarget(path: String) throws { try remote.closeTarget(path: path) }
    func parentsAfterDeletion(_ parents: [ItemDeletionParent]) throws -> [ItemDeletionParent] {
        try remote.parentsAfterDeletion(parents)
    }
}
