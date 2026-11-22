import Foundation
import Security

/// Where secrets are kept. Tests substitute an in-memory store.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Stores `value`, replacing any earlier value.
    func write(_ value: String, for key: String) throws
    func delete(_ key: String)
}

/// Generic password items under mac-os-agent's own service name, in the login Keychain.
public struct KeychainSecrets: SecretStore {
    public static let service = "dev.lubelski.mac-os-agent"

    public struct KeychainError: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    public init() {}

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "mac-os-agent: \(key)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
