import Foundation
import Security

/// Minimal Keychain wrapper for string values, scoped to this app's service.
///
/// Used to persist the OAuth access token (and, in dev builds, the mock
/// bearer token entered manually). Values are stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they survive across
/// app launches but never sync to iCloud and are unreadable while the device
/// is locked after a reboot.
public enum GSKeychain {
    private static let service = "com.grandshooting.gsmobile.tokens"

    public enum KeychainError: Error, Sendable {
        case unhandled(OSStatus)
        case dataConversion
    }

    public static func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversion
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attrs) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.unhandled(addStatus)
            }
            return
        }
        throw KeychainError.unhandled(updateStatus)
    }

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
