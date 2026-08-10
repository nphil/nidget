import Foundation
import Security
import os

// MARK: - KeychainStore
//
// Minimal string-valued Keychain wrapper (ARCHITECTURE §9). All items are
// kSecClassGenericPassword under service "app.nidget", protected with
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (readable in background after the first
// unlock, never migrated to a new device via backup).
//
// Keys used by AppStore: `actual.serverURL`, `actual.password`, `actual.token`,
// `actual.fileID`, `actual.groupID`, `actual.e2ePassword`.
//
// Values are secrets — they are NEVER logged; only OSStatus codes are.

enum KeychainStore {
    private static let service = "app.nidget"
    private static let log = Logger(subsystem: "app.nidget", category: "keychain")

    /// Base query identifying one item: generic password, our service, account = key.
    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Insert-or-update. Add first (the common case for fresh installs); on
    /// errSecDuplicateItem fall back to updating the existing item's data.
    static func set(_ value: String, key: String) {
        let data = Data(value.utf8)

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                log.error("Keychain update failed with status \(updateStatus)")
            }
            return
        }
        log.error("Keychain add failed with status \(addStatus)")
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                log.error("Keychain read failed with status \(status)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Keychain delete failed with status \(status)")
        }
    }
}
