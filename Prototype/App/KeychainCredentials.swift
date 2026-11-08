import Foundation
import Security

/// Generic-password items in the login (file-based) keychain, one per server account. The data
/// protection keychain needs a provisioning profile, which the Personal Team build lacks.
/// A generic-password item never matches Finder's internet-password item for the same server.
struct KeychainCredentialStore: CredentialStore {
    func password(for account: ServerAccount) throws -> Data? {
        var query = Self.query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.error(status) }
        return data
    }

    /// Reads only the item's attributes, so it never shows a Keychain prompt.
    func hasPassword(for account: ServerAccount) throws -> Bool {
        var query = Self.query(account)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.error(status) }
        return true
    }

    func savePassword(_ password: Data, for account: ServerAccount) throws {
        var attributes = Self.query(account)
        attributes[kSecValueData] = password
        attributes[kSecAttrLabel] = "TinyMounter: " + Self.itemAccount(account)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(Self.query(account) as CFDictionary, [kSecValueData: password] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    func deletePassword(for account: ServerAccount) throws {
        let status = SecItemDelete(Self.query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    static func service(_ remoteProtocol: RemoteProtocol) -> String { "dev.tinymounter." + remoteProtocol.rawValue }

    /// `account@host`: host names don't depend on case, so one server has one item.
    static func itemAccount(_ account: ServerAccount) -> String { account.account + "@" + account.host.lowercased() }

    // The login keychain never synchronizes, so the query needs no kSecAttrSynchronizable.
    private static func query(_ account: ServerAccount) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service(account.remoteProtocol),
         kSecAttrAccount: itemAccount(account)]
    }

    private static func error(_ status: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
