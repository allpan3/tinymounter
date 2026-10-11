import Foundation

/// Deliberately a single immutable fixture per domain, not the production metadata store.
struct FixtureConfiguration: Codable, Sendable {
    let domainID: String
    let filename: String
    let bookmark: Data
    let snapshot: FileSnapshot
    var keepDownloaded: Bool = false
    var generation: UInt64 = 1

    static let itemID = "fixture"

    static func directory() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TinyMounterAppGroup") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "The shared App Group is unavailable. Configure signing and the same App Group on both targets."])
        }
        let directory = container.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func url(for domainID: String) throws -> URL {
        guard UUID(uuidString: domainID) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return try directory().appendingPathComponent(domainID + ".json")
    }

    static func load(domainID: String) throws -> FixtureConfiguration {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url(for: domainID)))
        guard config.domainID == domainID else { throw CocoaError(.fileReadCorruptFile) }
        return config
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.url(for: domainID), options: .atomic)
    }

    func resolveSource() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "The test file bookmark is stale. Remove this test domain and select the file again."])
        }
        return url
    }
}
