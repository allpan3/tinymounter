import Combine
import Foundation
import dnssd

struct SMBService: Hashable, Identifiable {
    let name: String
    let type: String
    let domain: String
    var id: Self { self }

    static func address(host: String, port: UInt16) -> String? {
        guard port == 445 else { return nil }
        let host = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return "smb://" + host.lowercased()
    }
}

struct SMBServiceList {
    private var interfaces: [SMBService: Set<UInt32>] = [:]

    var services: [SMBService] {
        interfaces.keys.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return ($0.name, $0.domain, $0.type) < ($1.name, $1.domain, $1.type)
        }
    }

    mutating func update(_ service: SMBService, interface: UInt32, added: Bool) {
        if added {
            interfaces[service, default: []].insert(interface)
        } else {
            interfaces[service]?.remove(interface)
            if interfaces[service]?.isEmpty == true { interfaces.removeValue(forKey: service) }
        }
    }
}

@MainActor
final class SMBServerDiscovery: ObservableObject {
    enum Failure {
        case permissionDenied, browseFailed, resolveFailed, unsupportedPort
    }

    @Published private(set) var services: [SMBService] = []
    @Published private(set) var resolving: SMBService?
    @Published private(set) var failure: Failure?

    private var found = SMBServiceList()
    private var browseRef: DNSServiceRef?
    private var resolveRef: DNSServiceRef?
    private var timeout: Task<Void, Never>?
    private var completion: ((String) -> Void)?

    isolated deinit {
        if let browseRef { DNSServiceRefDeallocate(browseRef) }
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        timeout?.cancel()
    }

    func start() {
        stop()
        failure = nil
        let error = DNSServiceBrowse(&browseRef, 0, 0, "_smb._tcp", "local.",
                                    Self.browseReply, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let browseRef else {
            failBrowsing(error)
            return
        }
        let scheduled = DNSServiceSetDispatchQueue(browseRef, .main)
        if scheduled != kDNSServiceErr_NoError { failBrowsing(scheduled) }
    }

    func stop() {
        cancelResolution()
        if let browseRef { DNSServiceRefDeallocate(browseRef) }
        browseRef = nil
        found = SMBServiceList()
        services = []
    }

    func resolve(_ service: SMBService, completion: @escaping (String) -> Void) {
        cancelResolution()
        failure = nil
        guard services.contains(service) else {
            failure = .resolveFailed
            return
        }
        resolving = service
        self.completion = completion
        let error = DNSServiceResolve(&resolveRef, 0, 0, service.name, service.type, service.domain,
                                     Self.resolveReply, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let resolveRef else {
            failResolution(error)
            return
        }
        let scheduled = DNSServiceSetDispatchQueue(resolveRef, .main)
        guard scheduled == kDNSServiceErr_NoError else {
            failResolution(scheduled)
            return
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.failResolution(DNSServiceErrorType(kDNSServiceErr_Timeout))
        }
    }

    func cancelResolution() {
        timeout?.cancel()
        timeout = nil
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        resolveRef = nil
        resolving = nil
        completion = nil
    }

    private func failBrowsing(_ error: DNSServiceErrorType) {
        stop()
        failure = error == kDNSServiceErr_PolicyDenied ? .permissionDenied : .browseFailed
    }

    private func failResolution(_ error: DNSServiceErrorType) {
        cancelResolution()
        failure = error == kDNSServiceErr_PolicyDenied ? .permissionDenied : .resolveFailed
    }

    private static let browseReply: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
        guard let context else { return }
        // DNS-SD callbacks and deallocation share the main queue to keep the context alive.
        MainActor.assumeIsolated {
            let owner = Unmanaged<SMBServerDiscovery>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError else { owner.failBrowsing(error); return }
            guard let name, let type, let domain else { return }
            let service = SMBService(name: String(cString: name), type: String(cString: type),
                                     domain: String(cString: domain))
            owner.found.update(service, interface: interface, added: flags & UInt32(kDNSServiceFlagsAdd) != 0)
            owner.services = owner.found.services
            if let resolving = owner.resolving, !owner.services.contains(resolving) {
                owner.failResolution(DNSServiceErrorType(kDNSServiceErr_NoSuchName))
            }
        }
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
        guard let context else { return }
        MainActor.assumeIsolated {
            let owner = Unmanaged<SMBServerDiscovery>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let host else { owner.failResolution(error); return }
            let port = UInt16(bigEndian: port)
            let address = SMBService.address(host: String(cString: host), port: port)
            let completion = owner.completion
            owner.cancelResolution()
            if let address { completion?(address) }
            else { owner.failure = port == 445 ? .resolveFailed : .unsupportedPort }
        }
    }
}
