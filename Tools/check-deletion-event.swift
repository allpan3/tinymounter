import FileProvider
import Foundation

@main
enum DeletionEventCheck {
    static func main() throws {
        let original = NSFileProviderDomainVersion()
        let binary = try ProviderDomainVersion.encode(original)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.outputFormat = .xml
        archiver.encode(original, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let xml = archiver.encodedData
        precondition(binary != xml)
        let same = try ProviderDomainVersion.matches(binary, xml)
        precondition(same)
        let newer = try ProviderDomainVersion.encode(original.next())
        let different = try !ProviderDomainVersion.matches(binary, newer)
        let increasing = try ProviderDomainVersion.decode(binary) < ProviderDomainVersion.decode(newer)
        precondition(different && increasing)
        let foreign = try NSKeyedArchiver.archivedData(withRootObject: "wrong class" as NSString,
                                                      requiringSecureCoding: true)
        for invalid in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: 4097), foreign] {
            do {
                _ = try ProviderDomainVersion.decode(invalid)
                preconditionFailure("Accepted an invalid deletion event")
            } catch {}
        }
        print("Deletion event: semantic archive equality, ordering and invalid data passed")
    }
}
