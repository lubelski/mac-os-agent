import Foundation
import MacOSAgentCore
import Observation

/// The skills the owner can invoke with a slash in the main panel, kept live.
///
/// It reads the skills folder again when a file or folder in it changes, when the app itself
/// changes a skill (Settings posts `SkillLibrary.didChangeNotification`), when a tool call
/// finishes, and when the panel is summoned. So a skill the agent writes, one made in Settings,
/// and one dropped in with Finder all show in the slash list without a relaunch.
@MainActor
@Observable
final class SkillCommandsModel {
    private(set) var menu: SlashCommandMenu
    @ObservationIgnored let library: SkillLibrary
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// True for a stand-in with a menu of its own, which never reads a folder.
    @ObservationIgnored private let isFixed: Bool

    /// - Parameter watches: False for a fixed stand-in, as in previews.
    init(library: SkillLibrary, watches: Bool = true) {
        self.library = library
        isFixed = false
        menu = SlashCommandMenu(skills: library.skills())
        guard watches else { return }
        watcher = FolderWatcher(folder: library.folder) { [weak self] in self?.reload() }
        observer = NotificationCenter.default.addObserver(
            forName: SkillLibrary.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// A fixed menu, for previews and tests.
    init(menu: SlashCommandMenu) {
        library = SkillLibrary(folder: URL(filePath: "/nonexistent"), settingsFile: URL(filePath: "/nonexistent"))
        self.menu = menu
        isFixed = true
    }

    /// Reads the skills again. The menu changes only when a command did, so the views that show
    /// it redraw only then.
    func reload() {
        guard !isFixed else { return }
        // The folder may have been made since the last look, by the agent or in Settings.
        if watcher?.isWatching == false { watcher?.rearm() }
        let fresh = SlashCommandMenu(skills: library.skills())
        if fresh != menu { menu = fresh }
    }
}
