import FileProvider

/// The app's reader, exported to the extension. Requests and replies are `ReaderMessage` JSON.
@objc protocol SourceReaderProtocol {
    /// A `SourceReadRequest`; the reply is a `SourceReadReceipt`.
    func fetch(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    /// A `ListRequest`; the reply is a `ListReceipt` after the listing commits.
    func list(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    /// A `KeepRequest`; the reply is a `KeepReceipt` after the catalog write commits.
    func keep(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func create(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func edit(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func nameFolder(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func renameFile(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func moveFolder(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func deleteItem(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func deletePermanently(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func cancelDeletion(_ requestID: String)
    func release(_ requestID: String)
}

/// The extension's side, called by the app.
@objc protocol SourceReaderRegistration {
    func connect(_ domainID: String, reply: @escaping (NSError?) -> Void)
    /// A `SourceReadStarted`, before the fetch's first progress message.
    func started(_ message: Data)
    /// At most every `SourceReaderBridge.progressInterval` during a fetch; bytes done of its range.
    func progress(_ requestID: String, completedBytes: Int64)
    /// Sent after the app set `paused` in the domain's catalog: background fetches stop now.
    func pauseDownloads()
}

enum SourceReaderBridge {
    static let folderOrganizationEnabled = true
    static let deletionEnabled = true
    static let permanentDeletionEnabled = true
    /// Only an enabled route admits a deletion record, so Retry may continue its recorded request.
    static var deletionResumeEnabled: Bool { deletionEnabled || permanentDeletionEnabled }
    static let serviceName = NSFileProviderServiceName("dev.tinymounter.source-reader")
    static let progressInterval = Duration.milliseconds(500)
    static let refusedOrganizationKey = "dev.tinymounter.refused-organization"
    static let pendingWritesKey = "dev.tinymounter.pending-writes"
    static let pendingWritesDescription = "Other changes on this share must finish first."

    static var pendingWritesError: NSError {
        NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                userInfo: [pendingWritesKey: true, NSLocalizedDescriptionKey: pendingWritesDescription])
    }

    static func isPendingWrites(_ error: NSError?) -> Bool {
        error?.domain == NSFileProviderErrorDomain
            && error?.code == NSFileProviderError.cannotSynchronize.rawValue
            && error?.userInfo[pendingWritesKey] as? Bool == true
    }

    static var refusedOrganizationError: NSError {
        NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                userInfo: [refusedOrganizationKey: true,
                           NSLocalizedDescriptionKey: "The item changed before it could be renamed or moved."])
    }

    static func isRefusedOrganization(_ error: NSError?) -> Bool {
        error?.domain == NSFileProviderErrorDomain
            && error?.code == NSFileProviderError.cannotSynchronize.rawValue
            && error?.userInfo[refusedOrganizationKey] as? Bool == true
    }

    static let reimportRecoveryKey = "dev.tinymounter.reimport-recovery"
    static let reimportRecoveryDescription = "Local contents need recovery. Export this item and compare it with the server copy. If Finder cannot copy it, remove the location; macOS keeps unsent files in a recovery folder. Retry does not choose a copy."

    static var reimportRecoveryError: NSError {
        // A synchronization error can make macOS retry a reimport as an ordinary new upload.
        NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                userInfo: [reimportRecoveryKey: true, NSLocalizedDescriptionKey: reimportRecoveryDescription])
    }

    static func isReimportRecovery(_ error: NSError?) -> Bool {
        error?.domain == NSCocoaErrorDomain
            && error?.code == CocoaError.fileWriteNoPermission.rawValue
            && error?.userInfo[reimportRecoveryKey] as? Bool == true
    }

    static func requirement(forProvider: Bool) throws -> String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TinyMounterAppGroup") as? String,
              let team = group.split(separator: ".").first.map(String.init),
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let bundle = Bundle.main.bundleIdentifier else { throw CocoaError(.executableNotLoadable) }
        let base = bundle.hasSuffix(".provider") ? String(bundle.dropLast(9)) : bundle
        guard base.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw CocoaError(.executableNotLoadable)
        }
        let peer = forProvider ? base + ".provider" : base
        return "anchor apple generic and identifier \"\(peer)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func stagingURL(named name: String) throws -> URL {
        guard name.hasPrefix("tinymounter-"), name.hasSuffix(".stage"),
              UUID(uuidString: String(name.dropFirst(12).dropLast(6))) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try SharedContainer.stagingDirectory().appending(path: name, directoryHint: .notDirectory)
    }

    /// Only domain and code cross XPC. Classify share I/O in its own context first.
    static func error(_ error: Error) -> NSError {
        if DownloadSpace.isFull(error) { return CocoaError(.fileWriteOutOfSpace) as NSError }
        return providerError(SourceFailure.classify(error, context: .fetch))
    }

    /// docs/architecture.md §7, "Provider errors". `unknown` keeps its domain and code; the
    /// extension maps it further.
    static func providerError(_ failure: SourceFailure) -> NSError {
        switch failure {
        case .serverUnreachable, .notConnected, .localNetworkDenied: NSFileProviderError(.serverUnreachable) as NSError
        case .notAuthenticated: NSFileProviderError(.notAuthenticated) as NSError
        case .noPermission, .pathRejected: CocoaError(.fileReadNoPermission) as NSError
        case .missing: CocoaError(.fileReadNoSuchFile) as NSError
        case .versionChanged: NSFileProviderError(.versionNoLongerAvailable) as NSError
        case .cancelled: CocoaError(.userCancelled) as NSError
        case .tooManyEntries, .listingIncomplete: CocoaError(.fileReadUnknown) as NSError
        case .unknown(let domain, let code): NSError(domain: domain, code: code)
        }
    }
}
