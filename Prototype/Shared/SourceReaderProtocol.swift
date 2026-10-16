import FileProvider

/// The app's reader, exported to the extension. Requests and replies are `ReaderMessage` JSON.
@objc protocol SourceReaderProtocol {
    /// A `SourceReadRequest`; the reply is a `SourceReadReceipt`.
    func fetch(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    /// A `ListRequest`; the reply is a `ListReceipt` after the listing commits.
    func list(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
    func release(_ requestID: String)
}

/// The extension's side, called by the app.
@objc protocol SourceReaderRegistration {
    func connect(_ domainID: String, reply: @escaping (NSError?) -> Void)
    /// A `SourceReadStarted`, before the fetch's first progress message.
    func started(_ message: Data)
    /// At most every `SourceReaderBridge.progressInterval` during a fetch; bytes done of its range.
    func progress(_ requestID: String, completedBytes: Int64)
}

enum SourceReaderBridge {
    static let serviceName = NSFileProviderServiceName("dev.tinymounter.source-reader")
    static let progressInterval = Duration.milliseconds(500)

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

    /// Only domain and code cross XPC. Classify share I/O in its own context first (plan §7).
    static func error(_ error: Error) -> NSError {
        providerError(SourceFailure.classify(error, context: .fetch))
    }

    /// Plan §7. `unknown` keeps its domain and code; the extension maps it further.
    static func providerError(_ failure: SourceFailure) -> NSError {
        switch failure {
        case .serverUnreachable, .notConnected: NSFileProviderError(.serverUnreachable) as NSError
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
