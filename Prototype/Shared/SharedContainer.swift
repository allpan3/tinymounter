import Foundation

/// The App Group holds catalogs, transfer staging and the shared free-space preference.
enum SharedContainer {
    private static let group = Bundle.main.object(forInfoDictionaryKey: "TinyMounterAppGroup") as? String
    static let reserveKey = "freeSpaceReserveGB"
    static let preferences: UserDefaults? = group.flatMap { $0.isEmpty ? nil : UserDefaults(suiteName: $0) }

    static var reserveBytes: Int64 {
        let gigabytes = preferences?.integer(forKey: reserveKey) ?? 0
        return DownloadSpace.reserveBytes(gigabytes: gigabytes)
            ?? Int64(DownloadSpace.defaultReserveGB) * DownloadSpace.bytesPerGB
    }

    static func url() throws -> URL {
        guard let group, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
                NSLocalizedDescriptionKey:
                    "The shared App Group is unavailable. Configure signing and the same App Group on both targets."
            ])
        }
        return container
    }

    /// Not created here: only the app creates it, before its first `Catalog.create`.
    static func catalogsDirectory() throws -> URL {
        try url().appending(path: "Catalogs", directoryHint: .isDirectory)
    }

    static func catalogURL(domainID: String) throws -> URL {
        guard isDomainID(domainID) else { throw CocoaError(.fileReadCorruptFile) }
        return try catalogsDirectory().appending(path: domainID + ".sqlite", directoryHint: .notDirectory)
    }

    /// The domain IDs of the catalogs on disk; none before the app creates the folder.
    static func catalogDomainIDs() throws -> Set<String> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: catalogsDirectory().path(percentEncoded: false))
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return Set(names.compactMap { name in
            guard name.hasSuffix(".sqlite") else { return nil }
            let id = String(name.dropLast(7))
            return isDomainID(id) ? id : nil
        })
    }

    static func stagingDirectory() throws -> URL {
        let url = try url().appending(path: "ReaderStaging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func uploadInbox(_ id: UUID) throws -> URL {
        let directory = try url().appending(path: "UploadInbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: id.uuidString + ".data")
    }

    private static func isDomainID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString == id }
}
