import Foundation
import Security

/// Where secrets are kept. Tests substitute an in-memory store.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Stores `value`, replacing any earlier value.
    func write(_ value: String, for key: String) throws
    func delete(_ key: String)
}

/// Generic password items under mac-os-agent's own service name, in the login Keychain. The
/// app no longer uses it. See `FileSecrets`.
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

/// Secrets in `secrets.json` in the data folder, readable only by the owner. This is where the
/// app keeps its sign-in. The Keychain ties "Always Allow" to the exact build for an app with
/// no Apple team identifier, so it asked the owner twice after every rebuild. The cost of the
/// file is that any process running as the owner can read it.
public final class FileSecrets: SecretStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func read(_ key: String) -> String? { lock.withLock { load()[key] } }

    public func write(_ value: String, for key: String) throws {
        try lock.withLock {
            var values = load()
            values[key] = value
            try save(values)
        }
    }

    public func delete(_ key: String) {
        lock.withLock {
            var values = load()
            guard values.removeValue(forKey: key) != nil else { return }
            try? save(values)
        }
    }
}

extension AgentPaths {
    public static var secretsFile: URL { applicationSupport.appending(path: "secrets.json") }

    /// Where this run keeps secrets: a file in its data folder, never the Keychain.
    public static func secretStore() -> any SecretStore { FileSecrets(fileURL: secretsFile) }
}
