import Foundation

/// Which store a run keeps its secrets in, and moving them from the file to the Keychain.
///
/// - A release build, the one `scripts/release.sh` makes, keeps them in the Keychain. It is
///   the build whose Info.plist has the update feed, and it is signed with a Developer ID, so
///   it has a team identifier and macOS keeps its Keychain access from one update to the next.
/// - A development build keeps them in `secrets.json` in the data folder, because for an app
///   with no team identifier the Keychain asks again after every rebuild.
/// - A run with `--data-folder` keeps them in that folder's file in any build, and never
///   touches the Keychain. Previews, captures, and manual checks use one.
public enum SecretStorage {
    public enum Location: Equatable, Sendable {
        case keychain
        case file
    }

    public enum Reason: Equatable, Sendable {
        case releaseBuild
        case developmentBuild
        case anotherDataFolder
    }

    /// The store a run would use before any migration.
    public static func location(hasFeed: Bool, usesAnotherDataFolder: Bool) -> (Location, Reason) {
        if usesAnotherDataFolder { return (.file, .anotherDataFolder) }
        return hasFeed ? (.keychain, .releaseBuild) : (.file, .developmentBuild)
    }

    /// What a release build does at launch with the secrets in the file.
    public enum Decision: Equatable, Sendable {
        /// The file has no secrets.
        case nothingToMove
        /// The Keychain already has the app's secrets, so the file is left alone. A
        /// development build may have signed in to it since.
        case alreadyInKeychain
        case move
    }

    public static func decide(keychainHasSecrets: Bool, fileHasSecrets: Bool) -> Decision {
        if keychainHasSecrets { return .alreadyInKeychain }
        return fileHasSecrets ? .move : .nothingToMove
    }

    public enum Migration: Equatable, Sendable {
        case nothingToMove
        /// `fileHasSecrets` is true when `secrets.json` also has a sign-in, which this build
        /// does not use.
        case alreadyInKeychain(fileHasSecrets: Bool)
        /// `count` secrets went to the Keychain. `fileProblem` is set when they could not be
        /// removed from the file afterwards.
        case moved(count: Int, fileProblem: String?)
        /// The Keychain could not be read or written. The file is unchanged and this launch
        /// uses it.
        case failed(String)
    }

    /// Moves every secret in `file` to `keychain` when the Keychain has none, then removes
    /// them from the file. Nothing goes the other way. If a write fails, whatever was written
    /// is taken out of the Keychain again and the file is left alone, so the next launch tries
    /// again from the same place.
    public static func migrate(from file: FileSecrets, to keychain: KeychainSecrets) -> Migration {
        let values = file.all()
        let keychainHasSecrets: Bool
        do {
            keychainHasSecrets = try keychain.hasSecrets()
        } catch {
            return .failed("The Keychain could not be read: \(error.localizedDescription)")
        }
        switch decide(keychainHasSecrets: keychainHasSecrets, fileHasSecrets: !values.isEmpty) {
        case .nothingToMove:
            return .nothingToMove
        case .alreadyInKeychain:
            return .alreadyInKeychain(fileHasSecrets: !values.isEmpty)
        case .move:
            break
        }
        var written: [String] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            do {
                try keychain.write(value, for: key)
                written.append(key)
                guard keychain.read(key) == value else {
                    throw MigrationError.readBackDiffered
                }
            } catch {
                for key in written { keychain.delete(key) }
                return .failed("Moving the sign-in to the Keychain failed: \(error.localizedDescription)")
            }
        }
        do {
            try file.remove(values)
            return .moved(count: values.count, fileProblem: nil)
        } catch {
            return .moved(count: values.count, fileProblem: error.localizedDescription)
        }
    }

    private enum MigrationError: Error, LocalizedError {
        case readBackDiffered
        var errorDescription: String? { "the Keychain did not return what was written" }
    }

    /// Picks the store for a run and, in a release build, moves the file's secrets to the
    /// Keychain first. `keychain` is called only when the run may use the Keychain.
    public static func resolve(
        hasFeed: Bool, usesAnotherDataFolder: Bool, file: FileSecrets, keychain: () -> KeychainSecrets
    ) -> (store: any SecretStore, status: Status) {
        let (location, reason) = location(hasFeed: hasFeed, usesAnotherDataFolder: usesAnotherDataFolder)
        guard location == .keychain else {
            return (file, Status(location: .file, reason: reason, migration: nil))
        }
        let keychain = keychain()
        let migration = migrate(from: file, to: keychain)
        if case .failed = migration {
            return (file, Status(location: .file, reason: reason, migration: migration))
        }
        return (keychain, Status(location: .keychain, reason: reason, migration: migration))
    }

    /// The store for this run of the app, from its Info.plist and its launch arguments.
    public static func forThisRun(bundle: Bundle = .main) -> (store: any SecretStore, status: Status) {
        resolve(
            hasFeed: AppUpdates.hasFeed(bundle.infoDictionary),
            usesAnotherDataFolder: AgentPaths.usesAnotherDataFolder,
            file: FileSecrets(fileURL: AgentPaths.secretsFile),
            keychain: { KeychainSecrets() })
    }

    /// Where this run keeps the sign-in and why, for Debugging and the log. It never holds a
    /// secret or a key's value.
    public struct Status: Equatable, Sendable {
        public var location: Location
        public var reason: Reason
        /// Set for a release build only.
        public var migration: Migration?

        public init(location: Location, reason: Reason, migration: Migration?) {
            self.location = location
            self.reason = reason
            self.migration = migration
        }

        /// Where, in a few words.
        public var place: String {
            switch location {
            case .keychain: "Keychain"
            case .file: "secrets.json in the data folder"
            }
        }

        /// Why, in a sentence or two.
        public var explanation: String {
            switch reason {
            case .anotherDataFolder:
                return "This run was given --data-folder, so it keeps its sign-in in that folder and never uses the Keychain."
            case .developmentBuild:
                return "This is a development build, with no update feed. It keeps the sign-in in a file, so a rebuild does not make macOS ask for Keychain access."
            case .releaseBuild:
                let base = "This is a release build, so it keeps the sign-in in the login Keychain."
                switch migration {
                case nil, .nothingToMove:
                    return base
                case .alreadyInKeychain(let fileHasSecrets):
                    return fileHasSecrets
                        ? base + " secrets.json also has a sign-in, from a development build, which this build does not use."
                        : base
                case .moved(let count, let fileProblem):
                    let items = count == 1 ? "1 item" : "\(count) items"
                    let moved = base + " It was moved there from secrets.json at this launch, \(items)."
                    return fileProblem.map { moved + " They could not be removed from the file: \($0)" } ?? moved
                case .failed(let message):
                    return "This is a release build, which keeps the sign-in in the Keychain, but this launch uses secrets.json. \(message)"
                }
            }
        }
    }
}
