import AppKit
import MacOSAgentCore
import Observation

/// The panel's themes as the app holds them: the list, the active theme, the Use Glass
/// switch, and the message layout. The panel and Settings both read the one shared model, so a choice in either, or
/// one the agent makes with its tools, shows everywhere at once.
///
/// It reads the themes folder again whenever a file in it changes, so a theme the owner or the
/// agent adds or edits shows without a relaunch.
@MainActor
@Observable
final class ThemeModel {
    /// The model the panel and Settings share. A preview sets its own before it shows anything.
    static var shared = ThemeModel()

    @ObservationIgnored let library: ThemeLibrary
    @ObservationIgnored let preferences: ThemePreferences
    private(set) var entries: [ThemeEntry] = []
    private(set) var activeID: String
    private(set) var storedUsesGlass: Bool
    /// The Use Glass switch, or a preview's choice in place of it.
    var usesGlass: Bool { previewUsesGlass ?? storedUsesGlass }
    /// Use Glass for a preview, never saved.
    var previewUsesGlass: Bool?
    private(set) var storedMessageLayout: MessageLayout
    /// How the panel lays out messages, or a preview's choice in place of it.
    var messageLayout: MessageLayout { previewMessageLayout ?? storedMessageLayout }
    /// The message layout for a preview, never saved.
    var previewMessageLayout: MessageLayout?
    /// A part of Settings, Appearance to scroll to when it appears, such as "messages". Used by
    /// previews.
    @ObservationIgnored var previewScrollTarget: String?
    var errorMessage: String?
    /// A theme to show in place of the active one, for a preview. Never saved.
    var previewOverride: Theme?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(library: ThemeLibrary = ThemeLibrary(), preferences: ThemePreferences = ThemePreferences()) {
        self.library = library
        self.preferences = preferences
        activeID = preferences.themeID
        storedUsesGlass = preferences.usesGlass
        storedMessageLayout = preferences.messageLayout
        reload()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ThemeLibrary.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Any preference change in the app posts this, such as the panel's frame, so it only
        // reads the theme preferences again, not the folder.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPreferences() }
        })
        watchFolder()
    }

    /// The theme the panel draws with. A file that went missing or broke falls back to Glass.
    var activeTheme: Theme {
        if let previewOverride { return previewOverride }
        return entries.first { $0.id == activeID }?.theme ?? BuiltInThemes.glass
    }

    var activeEntry: ThemeEntry? { entries.first { $0.id == activeID } }
    var builtInEntries: [ThemeEntry] { entries.filter(\.isBuiltIn) }
    var ownEntries: [ThemeEntry] { entries.filter { !$0.isBuiltIn } }

    func reload() {
        let fresh = library.entries()
        if fresh != entries { entries = fresh }
        reloadPreferences()
        if watcher == nil { watchFolder() }
    }

    func reloadPreferences() {
        let id = preferences.themeID
        if id != activeID { activeID = id }
        let glass = preferences.usesGlass
        if glass != storedUsesGlass { storedUsesGlass = glass }
        let layout = preferences.messageLayout
        if layout != storedMessageLayout { storedMessageLayout = layout }
    }

    func select(_ id: String) {
        guard entries.first(where: { $0.id == id })?.theme != nil else { return }
        preferences.setThemeID(id)
        reload()
    }

    func setUsesGlass(_ value: Bool) {
        preferences.setUsesGlass(value)
        reload()
    }

    func setMessageLayout(_ layout: MessageLayout) {
        preferences.setMessageLayout(layout)
        reloadPreferences()
    }

    /// Copies a theme into a new file and makes the copy the active theme.
    func duplicate(_ id: String) {
        do {
            let copy = try library.duplicate(id: id)
            errorMessage = nil
            reload()
            select(copy)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Deletes one of the owner's themes. The panel goes back to Glass when it was the active one.
    func delete(_ id: String) {
        do {
            try library.delete(id: id)
            if activeID == id { preferences.setThemeID(BuiltInThemes.defaultID) }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        watchFolder()
        NSWorkspace.shared.open(library.folder)
    }

    func revealFile(_ entry: ThemeEntry) {
        guard let url = entry.fileURL else { return revealFolder() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reads the folder again when a file is added, removed, or replaced in it. Editors and the
    /// agent write files by replacing them, which changes the folder.
    private func watchFolder() {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(library.folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = source.data
                if event.contains(.delete) || event.contains(.rename) {
                    // The folder itself went away. Watch again once it is back.
                    self.watcher?.cancel()
                    self.watcher = nil
                }
                self.reload()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
