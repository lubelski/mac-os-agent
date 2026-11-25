import Foundation
@testable import MacOSAgentCore
import Testing

/// Stands in for the login Keychain, so no test reads or writes the owner's.
final class MemoryKeychain: KeychainItems, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Keychain error -25308: User interaction is not allowed." }
    }

    private let lock = NSLock()
    private var items: [String: String]
    /// Writes after this many succeed fail. Nil never fails.
    var writesBeforeFailure: Int?
    var listingFails = false
    private var writes = 0

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    var contents: [String: String] { lock.withLock { items } }

    func value(for account: String) throws -> String? { lock.withLock { items[account] } }

    func setValue(_ value: String, for account: String) throws {
        try lock.withLock {
            if let limit = writesBeforeFailure, writes >= limit { throw Failure() }
            writes += 1
            items[account] = value
        }
    }

    func removeValue(for account: String) throws { _ = lock.withLock { items.removeValue(forKey: account) } }

    func accounts() throws -> [String] {
        try lock.withLock {
            if listingFails { throw Failure() }
            return Array(items.keys)
        }
    }
}

private func temporarySecretsFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-secrets-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "secrets.json")
}

private func fileWith(_ values: [String: String]) throws -> FileSecrets {
    let file = FileSecrets(fileURL: temporarySecretsFile())
    for (key, value) in values { try file.write(value, for: key) }
    return file
}

/// Keys the app does not know about yet stand for whatever a later change adds.
private let signIn = [
    "chatgpt-refresh-token": "refresh-secret-1",
    "chatgpt-client-id": "oaiapp_client_2",
    "some-later-key": "later-secret-3",
]

@Suite struct SecretStorageChoiceTests {
    @Test func aReleaseBuildUsesTheKeychain() {
        let choice = SecretStorage.location(hasFeed: true, usesAnotherDataFolder: false)
        #expect(choice.0 == .keychain)
        #expect(choice.1 == .releaseBuild)
    }

    @Test func aDevelopmentBuildUsesTheFile() {
        let choice = SecretStorage.location(hasFeed: false, usesAnotherDataFolder: false)
        #expect(choice.0 == .file)
        #expect(choice.1 == .developmentBuild)
    }

    @Test func anotherDataFolderUsesItsFileInAnyBuild() {
        for hasFeed in [true, false] {
            let choice = SecretStorage.location(hasFeed: hasFeed, usesAnotherDataFolder: true)
            #expect(choice.0 == .file)
            #expect(choice.1 == .anotherDataFolder)
        }
    }

    @Test func onlyAReleaseBuildWithTheDefaultFolderOpensTheKeychain() throws {
        for (hasFeed, another) in [(false, false), (false, true), (true, true)] {
            let file = try fileWith(signIn)
            defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
            var opened = false
            let (store, status) = SecretStorage.resolve(
                hasFeed: hasFeed, usesAnotherDataFolder: another, file: file,
                keychain: {
                    opened = true
                    return KeychainSecrets(items: MemoryKeychain())
                })
            #expect(!opened)
            #expect(store is FileSecrets)
            #expect(status.location == .file)
            #expect(status.migration == nil)
            #expect(file.all() == signIn)
        }
    }
}

@Suite struct SecretMigrationTests {
    @Test func theDecisionFollowsTheKeychainFirst() {
        #expect(SecretStorage.decide(keychainHasSignIn: false, fileHasSecrets: false) == .nothingToMove)
        #expect(SecretStorage.decide(keychainHasSignIn: false, fileHasSecrets: true) == .move)
        #expect(SecretStorage.decide(keychainHasSignIn: true, fileHasSecrets: false) == .alreadyInKeychain)
        #expect(SecretStorage.decide(keychainHasSignIn: true, fileHasSecrets: true) == .alreadyInKeychain)
    }

    @Test func withNothingInTheFileNothingMoves() throws {
        let file = FileSecrets(fileURL: temporarySecretsFile())
        let keychain = MemoryKeychain()
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(status.migration == .nothingToMove)
        #expect(status.location == .keychain)
        #expect(store is KeychainSecrets)
        #expect(keychain.contents.isEmpty)
    }

    @Test func everySecretInTheFileMovesToTheKeychainAndLeavesTheFile() throws {
        let file = try fileWith(signIn)
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        let keychain = MemoryKeychain()
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(status.migration == .moved(count: 3, fileProblem: nil))
        #expect(status.location == .keychain)
        #expect(keychain.contents == signIn)
        #expect(file.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(store.read("chatgpt-refresh-token") == "refresh-secret-1")
    }

    @Test func aFailedKeychainWriteLeavesTheFileAndUsesItForThisLaunch() throws {
        let file = try fileWith(signIn)
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        let keychain = MemoryKeychain()
        keychain.writesBeforeFailure = 1
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        guard case .failed(let message) = status.migration else {
            Issue.record("Expected a failed migration, got \(String(describing: status.migration))")
            return
        }
        #expect(message.contains("-25308"))
        #expect(status.location == .file)
        #expect(store is FileSecrets)
        #expect(file.all() == signIn)
        // What was written before the failure is taken out again, so the next launch starts over.
        #expect(keychain.contents.isEmpty)
        #expect(status.explanation.contains("this launch uses secrets.json"))
    }

    @Test func aKeychainThatCannotBeListedLeavesTheFile() throws {
        let file = try fileWith(signIn)
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        let keychain = MemoryKeychain()
        keychain.listingFails = true
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(store is FileSecrets)
        #expect(status.location == .file)
        #expect(file.all() == signIn)
    }

    @Test func onceMovedTheKeychainWinsAndALaterFileIsLeftAlone() throws {
        let file = try fileWith(signIn)
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        let keychain = MemoryKeychain()
        _ = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })

        // The next launch finds nothing in the file.
        let second = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(second.status.migration == .alreadyInKeychain(fileHasSecrets: false))

        // A development build signs in to the file afterwards. The release build keeps its own.
        try file.write("dev-refresh", for: "chatgpt-refresh-token")
        let third = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(third.status.migration == .alreadyInKeychain(fileHasSecrets: true))
        #expect(third.store.read("chatgpt-refresh-token") == "refresh-secret-1")
        #expect(file.read("chatgpt-refresh-token") == "dev-refresh")
        #expect(keychain.contents == signIn)
    }

    @Test func theStatusNamesThePlaceAndNeverASecret() throws {
        let file = try fileWith(signIn)
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        let (_, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: MemoryKeychain()) })
        #expect(status.place == "Keychain")
        #expect(status.explanation.contains("moved there from secrets.json at this launch, 3 items"))
        let text = "\(status) \(status.place) \(status.explanation)"
        for value in signIn.values { #expect(!text.contains(value)) }
    }

    @Test func theDiagnosticsSayWhereTheSignInIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = DiagnosticsReport(
            build: BuildInfo(version: "0.1", build: "1", commit: "abc", signing: "Signed"),
            dataFolder: root, model: "gpt-6-luna", signIn: nil, instructions: "", tools: [], skills: [],
            threadFile: root.appending(path: "thread.jsonl"), usageLog: UsageLog(fileURL: root.appending(path: "usage.jsonl")),
            problems: [],
            secretStorage: SecretStorage.Status(location: .file, reason: .developmentBuild, migration: nil))
        #expect(report.plainText().contains("- Kept in: secrets.json in the data folder. This is a development build"))
    }
}

/// Every secret operation the app uses behaves the same in the file and in the Keychain.
@Suite struct SecretStoreContractTests {
    static func stores() -> [(String, any SecretStore)] {
        [
            ("file", FileSecrets(fileURL: temporarySecretsFile())),
            ("keychain", KeychainSecrets(items: MemoryKeychain())),
        ]
    }

    @Test(arguments: [0, 1]) func writesReadsReplacesAndDeletes(_ index: Int) throws {
        let (_, secrets) = Self.stores()[index]
        #expect(secrets.read("token") == nil)
        try secrets.write("one", for: "token")
        try secrets.write("two", for: "other")
        #expect(secrets.read("token") == "one")
        try secrets.write("three", for: "token")
        #expect(secrets.read("token") == "three")
        secrets.delete("token")
        #expect(secrets.read("token") == nil)
        #expect(secrets.read("other") == "two")
        // Deleting a key that is not there does nothing.
        secrets.delete("token")
        secrets.delete("never-written")
        #expect(secrets.read("other") == "two")
    }

    @Test(arguments: [0, 1]) func signingOutThroughEitherStoreForgetsTheTokens(_ index: Int) async throws {
        let (_, secrets) = Self.stores()[index]
        try secrets.write("r", for: ChatGPTAuthenticator.refreshTokenKey)
        try secrets.write("c", for: ChatGPTAuthenticator.clientIDKey)
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: UUID(), transport: FakeTransport(body: [:]))
        #expect(await authenticator.isSignedIn())
        await authenticator.signOut()
        #expect(await !authenticator.isSignedIn())
        #expect(secrets.read(ChatGPTAuthenticator.refreshTokenKey) == nil)
    }

    @Test(arguments: [0, 1]) func aRefreshThroughEitherStoreKeepsTheNewToken(_ index: Int) async throws {
        let (_, secrets) = Self.stores()[index]
        try secrets.write("old-refresh", for: ChatGPTAuthenticator.refreshTokenKey)
        try secrets.write("oaiapp_existing", for: ChatGPTAuthenticator.clientIDKey)
        let transport = FakeTransport(body: [
            "access_token": "a", "refresh_token": "new-refresh", "expires_in": 3600, "scope": .string(ChatGPTSignIn.scope),
        ])
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: UUID(), transport: transport)
        _ = try await authenticator.accessToken()
        #expect(secrets.read(ChatGPTAuthenticator.refreshTokenKey) == "new-refresh")
        #expect(secrets.read(ChatGPTAuthenticator.clientIDKey) == "oaiapp_existing")
    }
}
