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
        "closeAcknowledged-before", "closeAcknowledged-after", "deleted-before", "deleted-after"]

    static func checkpoint(_ plan: DeletionPlan, outbox: DeletionOutbox, node: Int,
                           stage: String) throws {
        guard let config = M22FinderProbe.selected(plan.owner),
              let directory = M22FinderCrash.export.lock.withLock({ M22FinderCrash.export.url }),
              checkpoints.contains(stage) else { return }
        let controlURL = directory.appending(path: "deletion-fault.json")
        guard FileManager.default.fileExists(atPath: controlURL.path) else { return }
        let control = try M22FinderProbe.load(Control.self, from: controlURL)
        try M22FinderProbe.require(control.run == config.run && checkpoints.contains(control.checkpoint),
                                  "deletion-fault-control-scope")
        guard stage == control.checkpoint, node == control.node, plan.request.item == control.item,
              plan.selected.path.utf8.elementsEqual((config.folder + "/" + control.source).utf8) else { return }
        try M22FinderProbe.require(RelativePath(control.source) != nil
            && control.source.hasPrefix("Deletion/"), "deletion-fault-subtree")
        let hitURL = directory.appending(path: "deletion-fault-hit-" + control.id.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: hitURL.path) else { return }
        let progress = try outbox.durableProgress(of: plan)
        try M22FinderProbe.save(Hit(control: control, checkpoint: stage, process: getpid(),
            date: ISO8601DateFormatter().string(from: .now), plan: plan, progress: progress), to: hitURL)
        M22FinderProbe.logger.notice("m24_crash_checkpoint run=\(config.run.uuidString, privacy: .public) stage=\(stage, privacy: .public)")
        raise(SIGSTOP)
    }
}
