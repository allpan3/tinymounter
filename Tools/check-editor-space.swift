// Included only in the isolated VM candidate by prepare-folder-candidate.py.
enum EditorSpaceProbe {
    static func marker(_ role: String) throws -> URL {
        guard ["app", "provider"].contains(role) else { throw CocoaError(.fileReadCorruptFile) }
        return try SharedContainer.url().appending(path: "M22Finder-low-space-" + role)
    }

    static func activeRun() throws -> String {
        let pointer = try SharedContainer.url().appending(path: "M22Finder-active.json")
        let active = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: pointer))
        guard let run = active["run"], UUID(uuidString: run)?.uuidString == run else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return run
    }

    static func available(at directory: URL, role: String) throws -> Int64 {
        let actual = try DownloadSpace.available(at: directory)
        let marker = try marker(role)
        guard FileManager.default.fileExists(atPath: marker.path) else { return actual }
        guard try Data(contentsOf: marker) == Data(activeRun().utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return min(actual, DownloadSpace.reserveBytes - 1)
    }

    static func set(_ role: String?, run: UUID) throws {
        guard try activeRun() == run.uuidString else { throw CocoaError(.fileReadCorruptFile) }
        for name in ["app", "provider"] {
            let file = try marker(name)
            if FileManager.default.fileExists(atPath: file.path) {
                guard try Data(contentsOf: file) == Data(run.uuidString.utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try FileManager.default.removeItem(at: file)
            }
        }
        if let role { try Data(run.uuidString.utf8).write(to: marker(role), options: .atomic) }
    }
}
