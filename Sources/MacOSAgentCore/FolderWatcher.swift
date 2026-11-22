import Foundation

/// Watches a folder and the folders directly inside it, and calls `onChange` shortly after
/// anything in them is added, removed, renamed, or replaced. It is how the skills folder is
/// kept live: making a skill folder changes the skills folder, and writing its `SKILL.md`
/// changes the skill's own folder. Editors and the agent usually write a file by replacing it,
/// which changes the folder it is in. An edit in place to a file that leaves its folder as it
/// was is not seen here, so the app also reads the folder again at other moments.
///
/// It uses a dispatch source per folder, as the themes folder's watch does. When the folder
/// does not exist yet, it watches nothing until `rearm()` finds it.
@MainActor
public final class FolderWatcher {
    public let folder: URL
    private let delay: Duration
    private let onChange: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: Task<Void, Never>?

    /// - Parameter delay: How long to wait after a change before calling `onChange`, so a burst
    ///   of writes, such as a folder and its file, is one call.
    public init(folder: URL, delay: Duration = .milliseconds(100), onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.delay = delay
        self.onChange = onChange
        rearm()
    }

    isolated deinit {
        pending?.cancel()
        for source in sources.values { source.cancel() }
    }

    /// True while the folder itself is watched.
    public var isWatching: Bool { sources[folder.plainPath] != nil }

    /// Watches the folder and each folder inside it as they are now. Called after every change,
    /// so a new skill folder is watched from then on and a removed one lets go.
    public func rearm() {
        var wanted = [folder]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        {
            wanted += contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        let paths = Set(wanted.map(\.plainPath))
        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        for url in wanted where sources[url.plainPath] == nil {
            watch(url)
        }
    }

    private func watch(_ url: URL) {
        let path = url.plainPath
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    // The folder itself went away or moved. Watch it again if it comes back.
                    source.cancel()
                    if self.sources[path] === source { self.sources[path] = nil }
                }
                self.scheduleChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[path] = source
    }

    private func scheduleChange() {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.rearm()
            self.onChange()
        }
    }
}
