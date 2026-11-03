import FileProvider
import Foundation

enum ProviderDomainVersion {
    static func encode(_ version: NSFileProviderDomainVersion) throws -> Data {
        let data = try NSKeyedArchiver.archivedData(withRootObject: version, requiringSecureCoding: true)
        guard !data.isEmpty, data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func decode(_ data: Data) throws -> NSFileProviderDomainVersion {
        guard !data.isEmpty, data.count <= 4096,
              let version = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFileProviderDomainVersion.self,
                                                                 from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return version
    }

    static func matches(_ first: Data, _ second: Data) throws -> Bool {
        try decode(first) == decode(second)
    }
}
