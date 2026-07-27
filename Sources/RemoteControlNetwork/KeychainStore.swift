import Foundation
import Security

final class KeychainStore {
    private let service: String
    private let useDataProtectionKeychain: Bool

    init(useDataProtectionKeychain: Bool = false, service: String? = nil) {
        self.useDataProtectionKeychain = useDataProtectionKeychain
        // Retain the established service names so upgrades keep their
        // Keychain access and do not prompt merely because of the rebrand.
        self.service = service ?? (useDataProtectionKeychain
            ? "com.local.RemoteControlNetwork.data-protection"
            : "com.local.RemoteControlNetwork.secure-v2")
    }

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        var attributes: [String: Any] = [kSecValueData as String: data]
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw KeychainError.status(operation: "update", code: status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        if useDataProtectionKeychain {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.status(operation: "add", code: addStatus)
        }
    }

    func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw KeychainError.status(operation: "read", code: status)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

}

enum KeychainError: Error, LocalizedError {
    case status(operation: String, code: OSStatus)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .status(let operation, let code):
            return "Keychain \(operation) error: \(code)"
        case .verificationFailed:
            return "Keychain did not return the value that was just saved"
        }
    }
}
