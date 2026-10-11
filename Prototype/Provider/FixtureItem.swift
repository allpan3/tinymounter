import FileProvider
import UniformTypeIdentifiers

final class FixtureItem: NSObject, NSFileProviderItem {
    let config: FixtureConfiguration
    let isRoot: Bool
    init(config: FixtureConfiguration, isRoot: Bool = false) {
        self.config = config
        self.isRoot = isRoot
    }

    var itemIdentifier: NSFileProviderItemIdentifier { isRoot ? .rootContainer : .init(FixtureConfiguration.itemID) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { isRoot ? "tinymounter Test" : config.filename }
    var contentType: UTType { isRoot ? .folder : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data }
    var documentSize: NSNumber? { isRoot ? nil : NSNumber(value: config.snapshot.size) }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading] }
    var contentPolicy: NSFileProviderContentPolicy {
        !isRoot && config.keepDownloaded ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: isRoot ? Data("root".utf8) : config.snapshot.versionData,
            metadataVersion: Data(String(config.generation).utf8))
    }
}

final class FixtureEnumerator: NSObject, NSFileProviderEnumerator {
    let domainID: String
    let empty: Bool
    init(domainID: String, empty: Bool = false) { self.domainID = domainID; self.empty = empty }
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            let config = try FixtureConfiguration.load(domainID: domainID)
            guard page.rawValue == NSFileProviderPage.initialPageSortedByName as Data ||
                  page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data else {
                throw NSFileProviderError(.pageExpired)
            }
            if !empty { observer.didEnumerate([FixtureItem(config: config)]) }
            observer.finishEnumerating(upTo: nil)
        } catch { observer.finishEnumeratingWithError(providerError(error)) }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        do {
            let config = try FixtureConfiguration.load(domainID: domainID)
            guard let text = String(data: anchor.rawValue, encoding: .utf8),
                  let old = UInt64(text), old <= config.generation else {
                throw NSFileProviderError(.syncAnchorExpired)
            }
            // Only the pin policy can change in this single-file fixture model.
            if !empty && old < config.generation { observer.didUpdate([FixtureItem(config: config)]) }
            observer.finishEnumeratingChanges(upTo: .init(Data(String(config.generation).utf8)), moreComing: false)
        } catch { observer.finishEnumeratingWithError(providerError(error)) }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let config = try? FixtureConfiguration.load(domainID: domainID)
        completionHandler(config.map { .init(Data(String($0.generation).utf8)) })
    }
}

func providerError(_ error: Error) -> Error {
    if let transfer = error as? TransferError {
        switch transfer {
        case .cancelled: return CocoaError(.userCancelled)
        case .sourceChanged: return NSFileProviderError(.versionNoLongerAvailable)
        default: return CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: error])
        }
    }
    let ns = error as NSError
    if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain { return error }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
        return CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: error])
    }
    // A missing mount/path is not evidence that the fixture was deleted remotely.
    return NSFileProviderError(.serverUnreachable, userInfo: [NSUnderlyingErrorKey: error])
}
