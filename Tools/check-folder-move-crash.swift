import Darwin
import Foundation

enum M22FinderCrash {
    struct Control: Codable {
        let run: UUID
        let id: UUID
        let item: String
        let source: String
        let checkpoint: String
    }

    struct Hit: Codable {
        let control: Control
        let checkpoint: String
        let process: Int32
        let date: String
        let record: PendingFolderMove
    }

    final class Export: @unchecked Sendable {
        let lock = NSLock()
        var url: URL?
    }

    static let export = Export()
    static let checkpoints: Set<String> = ["attempting", "moved", "verified", "catalog",
        "settings", "finished-domain", "before-reply"]

    static func setExport(_ url: URL?) {
        export.lock.withLock { export.url = url }
    }

    static func checkpoint(_ admitted: PendingFolderMove, stage: String) throws {
        guard let config = M22FinderProbe.selected(admitted.owner),
              let directory = export.lock.withLock({ export.url }),
              checkpoints.contains(stage) else { return }
        let controlURL = directory.appending(path: "fault.json")
        guard FileManager.default.fileExists(atPath: controlURL.path) else { return }
        let control = try M22FinderProbe.load(Control.self, from: controlURL)
        try M22FinderProbe.require(control.run == config.run && checkpoints.contains(control.checkpoint),
                                  "fault-control-scope")
        guard stage == control.checkpoint,
              admitted.views.first(where: { $0.domain == config.domain })?.move.item == control.item,
              admitted.source == config.folder + "/" + control.source else { return }
        try M22FinderProbe.require(RelativePath(control.source) != nil
            && control.source.hasPrefix("Recovery/")
            && admitted.destination.hasPrefix(config.folder + "/Recovery/"), "fault-recovery-subtree")
        let hitURL = directory.appending(path: "fault-hit-" + control.id.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: hitURL.path) else { return }
        let record = try LocationSource.renameOutbox().reloadFolder(admitted)
        try M22FinderProbe.save(Hit(control: control, checkpoint: stage, process: getpid(),
            date: ISO8601DateFormatter().string(from: .now), record: record), to: hitURL)
        M22FinderProbe.logger.notice("m22_crash_checkpoint run=\(config.run.uuidString, privacy: .public) stage=\(stage, privacy: .public)")
        // The operator kills this stopped process after inspecting the durable checkpoint.
        raise(SIGSTOP)
    }
}
