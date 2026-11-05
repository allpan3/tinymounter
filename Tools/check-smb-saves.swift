import Darwin
import Foundation

// Standalone harness: production adapter without the app's share-health UI.
enum ShareAccess {
    static func withDirectSMB<T>(_ call: () throws -> T) rethrows -> T { try call() }
}

@main enum SaveCheck {
    static func main() throws {
        guard NSUserName() == "user", CommandLine.arguments.count == 5,
              let mib = Int(CommandLine.arguments[2]), [1, 64].contains(mib),
              let round = Int(CommandLine.arguments[3]), (1...5).contains(round) else {
            throw UploadError.invalidRequest
        }
        let server = CommandLine.arguments[1]
        let evidence = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        guard evidence.lastPathComponent.hasPrefix("saves-"),
              evidence.lastPathComponent.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else { throw UploadError.invalidRequest }
        let input = evidence.appending(path: "input-\(mib).bin")
        let totalStart = ContinuousClock.now
        let remote = try SMBEdit(endpoint: ShareAddress("//tmtest@\(server)/tinymounter-single")!,
                                 folder: RelativePath("simplify-20261105/" + evidence.lastPathComponent)!, root: -1,
                                 progress: Progress())
        let connected = ContinuousClock.now
        let written = try remote.overwrite(path: "direct-\(mib)-\(round).bin", contents: input)
        let completed = ContinuousClock.now
        guard written.fingerprint.size == Int64(mib) << 20 else { throw CocoaError(.fileWriteUnknown) }
        let result: [String: Any] = ["label": "direct", "mib": mib, "round": round,
            "seconds": connected.duration(to: completed) / .seconds(1),
            "totalSeconds": totalStart.duration(to: completed) / .seconds(1), "completed": true]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
