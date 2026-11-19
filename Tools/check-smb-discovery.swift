import Foundation

@main
enum SMBDiscoveryCheck {
    static func main() {
        let service = SMBService(name: "Office NAS", type: "_smb._tcp.", domain: "local.")
        let other = SMBService(name: "Archive", type: service.type, domain: service.domain)
        var list = SMBServiceList()
        list.update(service, interface: 1, added: true)
        list.update(service, interface: 1, added: true)
        list.update(service, interface: 2, added: true)
        precondition(list.services == [service], "One server appeared twice across interfaces")
        list.update(service, interface: 1, added: false)
        list.update(service, interface: 3, added: false)
        precondition(list.services == [service], "Removing one interface removed a reachable server")
        list.update(other, interface: 2, added: true)
        precondition(list.services == [other, service])
        list.update(service, interface: 2, added: false)
        precondition(list.services == [other], "A withdrawn service stayed in the list")
        list.update(other, interface: 2, added: false)
        precondition(list.services.isEmpty)

        precondition(SMBService.address(host: "Office-NAS.local.", port: 445) == "smb://office-nas.local")
        precondition(SMBService.address(host: "nas.local", port: 445) == "smb://nas.local")
        for port: UInt16 in [0, 139, 1445, 65535] {
            precondition(SMBService.address(host: "nas.local.", port: port) == nil)
        }
        for host in ["", ".", "nas..local", "-nas.local", "nas-.local", "nas.local..", "name@nas.local",
                     "nas.local/share", "nas.local:1445", "nas.local?x", "nas.local#x", "nas%2elocal",
                     "nas\\032.local", "nas local", "nas\n.local", String(repeating: "n", count: 64) + ".local",
                     Array(repeating: String(repeating: "n", count: 63), count: 4).joined(separator: ".")] {
            precondition(SMBService.address(host: host, port: 445) == nil, "Accepted an invalid target")
        }
        print("SMB discovery: interface deduplication, withdrawals, hostname validation and ports passed")
    }
}
