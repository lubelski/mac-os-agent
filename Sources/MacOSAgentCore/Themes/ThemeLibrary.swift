import Foundation

/// A theme as Settings and the agent list it: built in, or a file in the themes folder.
public struct ThemeEntry: Sendable, Equatable, Identifiable {
    /// The file's name without `.json`, or the built-in theme's id. The preference stores it.
    public var id: String
    /// The name from the file, or the id when the file could not be read.
    public var name: String
    /// Nil when the file could not be read.
    public var theme: Theme?
    /// Why the file could not be read. Nil when it is fine.
    public var problem: String?
    public var isBuiltIn: Bool
    /// The file, for a theme in the themes folder.
    public var fileURL: URL?

    public init(id: String, name: String, theme: Theme?, problem: String?, isBuiltIn: Bool, fileURL: URL?) {
        self.id = id
        self.name = name
        self.theme = theme
        self.problem = problem
        self.isBuiltIn = isBuiltIn
        self.fileURL = fileURL
    }
}

/// Why a theme could not be saved or deleted.
public struct ThemeLibraryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// The built-in themes and the theme files in `themes/` in Application Support, one file per
/// theme, named by its id, such as `themes/night-swim.json`. The folder is read each time, so a
/// file the owner or the agent adds is picked up without a relaunch.
public struct ThemeLibrary: Sendable {
    public let folder: URL

    public static let fileExtension = "json"
    /// Posted after the library or the theme preferences change in this process, so the panel
    /// and Settings can redraw.
    public static let didChangeNotification = Notification.Name("dev.lubelski.mac-os-agent.themesDidChange")

    public init(folder: URL = AgentPaths.themesFolder) {
        self.folder = folder
    }

    /// The built-in themes first, in their fixed order, then the files in the folder by name.
    /// A file that cannot be read is listed with its problem.
    public func entries() -> [ThemeEntry] {
        BuiltInThemes.all + fileEntries()
    }

    func fileEntries() -> [ThemeEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.plainPath) else { return [] }
        let builtIn = Set(BuiltInThemes.ids)
        return names
            .filter { $0.hasSuffix("." + Self.fileExtension) && !$0.hasPrefix(".") }
            .map { fileName -> ThemeEntry in
                let id = String(fileName.dropLast(Self.fileExtension.count + 1))
                let url = folder.appending(path: fileName)
                var entry = ThemeEntry(id: id, name: id, theme: nil, problem: nil, isBuiltIn: false, fileURL: url)
                if !Self.isValidIdentifier(id) {
                    entry.problem = "The file name should be lowercase letters, digits, and hyphens, then .json."
                } else if builtIn.contains(id) {
                    entry.problem = "A built-in theme already has the id \(id). Rename the file."
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    do {
                        let theme = try Theme.parse(text)
                        entry.theme = theme
                        entry.name = theme.name
                    } catch {
                        entry.problem = String(describing: error)
                    }
                } else {
                    entry.problem = "The file could not be read as text."
                }
                return entry
            }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    public func entry(id: String) -> ThemeEntry? {
        entries().first { $0.id == id }
    }

    /// The theme with the id, or Glass when there is none or its file cannot be read.
    public func theme(id: String) -> Theme {
        entry(id: id)?.theme ?? BuiltInThemes.glass
    }

    /// Finds a theme by its id or, ignoring case, its name.
    public func find(_ idOrName: String) -> ThemeEntry? {
        let wanted = idOrName.trimmingCharacters(in: .whitespaces)
        let all = entries()
        return all.first { $0.id == wanted } ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Writes a theme to its file and returns its id. With no id, the id comes from the name.
    /// A built-in theme can never be written over.
    @discardableResult
    public func save(_ theme: Theme, id: String? = nil) throws(ThemeLibraryError) -> String {
        let id = id ?? Self.identifier(for: theme.name)
        guard Self.isValidIdentifier(id) else {
            throw ThemeLibraryError("The id \"\(id)\" should be lowercase letters, digits, and hyphens.")
        }
        if BuiltInThemes.ids.contains(id) {
            throw ThemeLibraryError("\(id) is a built-in theme, which cannot be changed. Give the theme another name.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(theme.fileText.utf8).write(to: fileURL(id: id), options: .atomic)
        } catch {
            throw ThemeLibraryError("Could not write the theme file: \(error.localizedDescription)")
        }
        Self.postChange()
        return id
    }

    /// Removes a theme's file. Built-in themes cannot be deleted.
    public func delete(id: String) throws(ThemeLibraryError) {
        if BuiltInThemes.ids.contains(id) {
            throw ThemeLibraryError("\(id) is a built-in theme, which cannot be deleted.")
        }
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.plainPath) else {
            throw ThemeLibraryError("There is no theme file \(url.lastPathComponent).")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ThemeLibraryError("Could not delete the theme file: \(error.localizedDescription)")
        }
        Self.postChange()
    }

    /// Copies a theme into a new file named after it, such as "Tidewater Copy", and returns the
    /// new id.
    public func duplicate(id: String) throws(ThemeLibraryError) -> String {
        guard var theme = entry(id: id)?.theme else {
            throw ThemeLibraryError("The theme \(id) cannot be read, so it cannot be copied.")
        }
        let taken = Set(entries().map(\.id))
        let base = String(theme.name.prefix(Theme.maximumNameLength - 8))
        var number = 1
        var name = "\(base) Copy"
        while taken.contains(Self.identifier(for: name)) {
            number += 1
            name = "\(base) Copy \(number)"
        }
        theme.name = name
        return try save(theme)
    }

    public func fileURL(id: String) -> URL {
        folder.appending(path: "\(id).\(Self.fileExtension)")
    }

    /// The id for a name: lowercase letters and digits, with hyphens between the words.
    public static func identifier(for name: String) -> String {
        let id = SkillLibrary.suggestedName(from: name)
        return id.isEmpty ? "theme" : id
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.first != "-" && id.last != "-"
            && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

/// The active theme, the Use Glass switch, and the message layout, kept in the app's
/// preferences.
public struct ThemePreferences: Sendable {
    public static let themeKey = "panelTheme"
    public static let usesGlassKey = "panelUsesGlass"
    public static let messageLayoutKey = "panelMessageLayout"

    /// The preferences suite, or nil for the app's standard preferences. Previews and tests use
    /// a suite of their own.
    public let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    public var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The active theme's id. Glass until the owner or the agent picks another.
    public var themeID: String {
        defaults.string(forKey: Self.themeKey) ?? BuiltInThemes.defaultID
    }

    public func setThemeID(_ id: String) {
        defaults.set(id, forKey: Self.themeKey)
        ThemeLibrary.postChange()
    }

    /// When off, every theme draws its fallback fill instead of glass or blur. On by default.
    public var usesGlass: Bool {
        defaults.object(forKey: Self.usesGlassKey) as? Bool ?? true
    }

    public func setUsesGlass(_ value: Bool) {
        defaults.set(value, forKey: Self.usesGlassKey)
        ThemeLibrary.postChange()
    }

    /// How the panel lays out messages. On opposite sides until the owner picks full width. A
    /// value this build does not know reads as the default.
    public var messageLayout: MessageLayout {
        defaults.string(forKey: Self.messageLayoutKey).flatMap(MessageLayout.init(rawValue:)) ?? .sides
    }

    public func setMessageLayout(_ layout: MessageLayout) {
        defaults.set(layout.rawValue, forKey: Self.messageLayoutKey)
        ThemeLibrary.postChange()
    }
}
