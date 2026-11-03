import FileProvider
import Foundation

// This fixture probe refuses every deletion before it reaches the app or server.
extension FileProviderExtension: NSFileProviderDomainState {
    var domainVersion: NSFileProviderDomainVersion {
        let sequence = (try? catalog.read { try $0.counts().lastSeq }) ?? 0
        precondition((0...10_000).contains(sequence))
        var version = NSFileProviderDomainVersion()
        for _ in 0..<sequence { version = version.next() }
        return version
    }

    var userInfo: [AnyHashable: Any] { [:] }

    func probeDeletionDomain(_ identifier: NSFileProviderItemIdentifier,
                             base: NSFileProviderItemVersion, request: NSFileProviderRequest,
                             reply: @escaping (Error?) -> Void) -> Progress {
        do {
            guard let config = M22FinderProbe.selected(domain.identifier.rawValue) else {
                throw M22FinderProbe.Failure.check("domain-probe-scope")
            }
            let current = domainVersion
            let received = request.domainVersion
            func encoded(_ version: NSFileProviderDomainVersion?) throws -> String {
                guard let version else { return "nil" }
                return try NSKeyedArchiver.archivedData(withRootObject: version,
                    requiringSecureCoding: true).base64EncodedString()
            }
            let reject = try M22FinderProbe.directory(config.run).appending(path: "domain-reject")
            let rejected = FileManager.default.fileExists(atPath: reject.path)
            try M22FinderProbe.emit(config, call: UUID(), kind: "deletion-domain", fields: [
                "item": identifier.rawValue, "metadata": base.metadataVersion.base64EncodedString(),
                "requestDomain": encoded(received), "currentDomain": encoded(current),
                "requestPredatesCurrent": String(received.map { $0 < current } ?? false),
                "rejected": String(rejected)])
            reply(deletionError(NSFileProviderError(rejected ? .deletionRejected : .cannotSynchronize),
                                item: identifier))
        } catch {
            reply(NSFileProviderError(.cannotSynchronize))
        }
        return Progress()
    }
}
