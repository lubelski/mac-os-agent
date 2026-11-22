import Foundation
import Security

/// Where secrets are kept. Tests substitute an in-memory store.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Stores `value`, replacing any earlier value.
    func write(_ value: String, for key: String) throws
    func delete(_ key: String)
}

/// The Keychain calls `KeychainSecrets` makes, one item per account. `LoginKeychain` is the
/// real one. Tests use a stand-in, so they never read or write the owner's Keychain.
public protocol KeychainItems: Sendable {
    /// The value of the app's item for `account`, or nil when there is none.
    func value(for account: String) throws -> String?
    /// Stores `value`, replacing any earlier value.
    func setValue(_ value: String, for account: String) throws
    /// Removes the item for `account`. Removing an item that does not exist succeeds.
    func removeValue(for account: String) throws
    /// The account of every item the app keeps.
    func accounts() throws -> [String]
}

/// Secrets in the Keychain, one item per key. A release build keeps its sign-in here. See
/// `SecretStorage` for which runs use it.
public struct KeychainSecrets: SecretStore {
    public static let service = "dev.lubelski.mac-os-agent"

    let items: any KeychainItems

    public init(items: any KeychainItems = LoginKeychain()) {
        self.items = items
    }

    /// A Keychain that cannot be read reads as no value, as a missing file does in `FileSecrets`.
    public func read(_ key: String) -> String? { (try? items.value(for: key)) ?? nil }

    public func write(_ value: String, for key: String) throws { try items.setValue(value, for: key) }

    public func delete(_ key: String) { try? items.removeValue(for: key) }

    /// Whether the Keychain holds any of the app's secrets.
    public func hasSecrets() throws -> Bool { try !items.accounts().isEmpty }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Generic password items in the login Keychain, under the service `dev.lubelski.mac-os-agent`
/// with the key as the account.
///
/// - It is the file-based keychain that `SecItem` uses on macOS by default, not the data
///   protection keychain, which would need a provisioning profile and a keychain access group.
///   Access is the item's access control list, which trusts the app that made the item, as
///   its designated requirement says.
/// - `kSecAttrAccessible` does not apply to this keychain. An item can be read while the login
///   keychain is unlocked, which is while the owner is logged in.
/// - Items are never synchronizable, so iCloud Keychain does not copy them.
/// - Each item carries `marker` in its generic attribute. Items under the same service from
///   before the sign-in moved to a file have no marker. They belong to an old development
///   build, so reading them would make macOS ask the owner, and their sign-in is stale. They
///   are left out of reads and lists, and replaced when the same key is written.
public struct LoginKeychain: KeychainItems {
    public static let marker = Data("mac-os-agent secret 1".utf8)

    public init() {}

    private func query(_ account: String? = nil, markedOnly: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecrets.service,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if markedOnly { query[kSecAttrGeneric as String] = Self.marker }
        return query
    }

    public func value(for account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setValue(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            // An old item without the marker would block the add, so it goes first.
            let removed = SecItemDelete(query(account, markedOnly: false) as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw KeychainError(status: removed) }
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "mac-os-agent: \(account)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Removes the item with or without the marker, so signing out also clears an old one.
    public func removeValue(for account: String) throws {
        let status = SecItemDelete(query(account, markedOnly: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Reads attributes only, never a value.
    public func accounts() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw KeychainError(status: status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Secrets in `secrets.json` in the data folder, readable only by the owner. A development
/// build and any run with `--data-folder` keep their sign-in here. The Keychain ties "Always
/// Allow" to the exact build for an app with no Apple team identifier, so it asked the owner
/// twice after every rebuild. The cost of the file is that any process running as the owner
/// can read it.
public final class FileSecrets: SecretStore, @unchecked Sendable {
    public let fileURL: URL
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

    /// Every key and value in the file, for moving them to the Keychain.
    public func all() -> [String: String] { lock.withLock { load() } }

    /// Removes these keys where each still has the value given, and removes the file when
    /// nothing is left in it.
    func remove(_ moved: [String: String]) throws {
        try lock.withLock {
            var values = load()
            for (key, value) in moved where values[key] == value { values.removeValue(forKey: key) }
            if values.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try save(values)
            }
        }
    }
}

extension AgentPaths {
    public static var secretsFile: URL { applicationSupport.appending(path: "secrets.json") }

    /// Whether this run was pointed at another data folder with `--data-folder`.
    public static var usesAnotherDataFolder: Bool { dataFolder(from: CommandLine.arguments) != nil }
}
