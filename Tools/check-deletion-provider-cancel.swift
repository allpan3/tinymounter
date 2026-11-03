import FileProvider
import Foundation

final class M24ProviderCancellation: @unchecked Sendable {
    struct Command: Codable {
        let run: UUID
        let item: String
        let event: Data
        let id: UUID
    }

    private let timer: DispatchSourceTimer

    init?(domain: String, item: String, event: NSFileProviderDomainVersion?, progress: Progress) {
        guard let config = M22FinderProbe.selected(domain), let event,
              let archive = try? ProviderDomainVersion.encode(event),
              let directory = try? M22FinderProbe.directory(config.run) else { return nil }
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler {
            let url = directory.appending(path: "deletion-cancel-" + item + ".json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let command = try? M22FinderProbe.load(Command.self, from: url),
                  command.run == config.run, command.item == item,
                  (try? ProviderDomainVersion.matches(command.event, archive)) == true else { return }
            do {
                try FileManager.default.moveItem(at: url,
                    to: directory.appending(path: "deletion-cancel-used-" + command.id.uuidString + ".json"))
                M22FinderProbe.emit(config, call: command.id, kind: "delete-progress-cancel",
                                    fields: ["item": item])
                progress.cancel()
            } catch {}
        }
        timer.activate()
    }

    func stop() {
        timer.setEventHandler(handler: nil)
        timer.cancel()
    }
    deinit { timer.cancel() }
}
