// Spike probe for the 0.2.0 password login, run as a signed sandboxed app in the VM.
// See docs/prototype.md, "SMB sign-in, Keychain and CHANGE_NOTIFY". Not part of the product build.
// Usage: probe <command> <server> <account> [share] [--file] [--inet] [--group <access group>]
import Foundation
import Security

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
let fileKeychain = option("--file")
// --inet matches the Internet password Finder saves; TinyMounter's own item is a generic password.
let finderItem = option("--inet")
var accessGroup: String?
if let index = arguments.firstIndex(of: "--group"), index + 1 < arguments.count {
    accessGroup = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: probe <command> <server> <account> [share]\n".utf8))
    exit(64)
}
let (command, server, account) = (arguments[0], arguments[1], arguments[2])
let share = arguments.count > 3 ? arguments[3] : "IPC$"

func describe(_ status: OSStatus) -> String {
    "\(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "?"))"
}

func query(_ extra: [CFString: Any] = [:]) -> [CFString: Any] {
    var query: [CFString: Any] = finderItem
        ? [kSecClass: kSecClassInternetPassword, kSecAttrServer: server, kSecAttrAccount: account,
           kSecAttrProtocol: kSecAttrProtocolSMB]
        : [kSecClass: kSecClassGenericPassword, kSecAttrService: "TinyMounter",
           kSecAttrAccount: "smb://\(account)@\(server)"]
    if !fileKeychain { query[kSecUseDataProtectionKeychain] = true }
    if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
    return query.merging(extra) { $1 }
}

func readStandardInput() -> Data {
    var data = FileHandle.standardInput.readDataToEndOfFile()
    while let last = data.last, last == 0x0a || last == 0x0d { data.removeLast() }
    return data
}

func login(_ password: Data) -> Int32 {
    var result = probe_login_result()
    let error = password.withUnsafeBytes { bytes in
        probe_login(server, share, account, nil, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &result)
    }
    let message = withUnsafeBytes(of: result.message) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    print("login error=\(error)(\(String(cString: strerror(error)))) status=0x\(String(result.status, radix: 16))",
          "dialect=0x\(String(result.dialect, radix: 16)) sealed=\(result.sealed) entries=\(result.entries)",
          "listing_error=\(result.listing_error) message=\"\(message)\"")
    return error
}

switch command {
case "store":
    var password = readStandardInput()
    defer { password.resetBytes(in: 0..<password.count) }
    let attributes: [CFString: Any] = [kSecValueData: password, kSecAttrLabel: "TinyMounter",
                                       kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemAdd(query(attributes) as CFDictionary, nil)
    if status == errSecDuplicateItem {
        status = SecItemUpdate(query() as CFDictionary, [kSecValueData: password] as CFDictionary)
        print("update", describe(status))
    } else { print("add", describe(status)) }
    exit(status == errSecSuccess ? 0 : 1)
case "read":
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query([kSecReturnAttributes: true]) as CFDictionary, &item)
    let found = item as? [CFString: Any]
    print("read", describe(status), "group=\(found?[kSecAttrAccessGroup] as? String ?? "-")",
          "accessible=\(found?[kSecAttrAccessible] as? String ?? "-")")
    exit(status == errSecSuccess ? 0 : 1)
case "secret":
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query([kSecReturnData: true]) as CFDictionary, &item)
    print("secret", describe(status), "bytes=\((item as? Data)?.count ?? 0)")
    exit(status == errSecSuccess ? 0 : 1)
case "login":
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query([kSecReturnData: true]) as CFDictionary, &item)
    guard status == errSecSuccess, let password = item as? Data else { print("copy", describe(status)); exit(1) }
    exit(login(password) == 0 ? 0 : 1)
case "login-stdin":
    var password = readStandardInput()
    defer { password.resetBytes(in: 0..<password.count) }
    exit(login(password) == 0 ? 0 : 1)
case "forget":
    let status = SecItemDelete(query() as CFDictionary)
    print("delete", describe(status))
    exit(status == errSecSuccess || status == errSecItemNotFound ? 0 : 1)
default:
    print("unknown command")
    exit(64)
}
