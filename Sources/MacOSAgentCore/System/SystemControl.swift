import AppKit
import Foundation
import UniformTypeIdentifiers

/// A file or folder as the system tools see it.
public struct FileInfo: Sendable, Equatable {
    public var path: String
    public var isFolder: Bool
    /// The uniform type identifier, such as public.jpeg, when the system knows it.
    public var contentType: String?
    public var modified: Date?
    /// Bytes, for a file.
    public var size: Int?

    public init(path: String, isFolder: Bool = false, contentType: String? = nil, modified: Date? = nil, size: Int? = nil) {
        self.path = path
        self.isFolder = isFolder
        self.contentType = contentType
        self.modified = modified
        self.size = size
    }
}

/// What is on the clipboard.
public struct ClipboardContents: Sendable, Equatable {
    public var text: String?
    /// Files and folders copied in Finder.
    public var filePaths: [String]
    /// Every type on the clipboard, such as public.png, for when there is no text.
    public var types: [String]

    public init(text: String? = nil, filePaths: [String] = [], types: [String] = []) {
        self.text = text
        self.filePaths = filePaths
        self.types = types
    }
}

/// What quitting an app came to.
public enum QuitOutcome: Sendable, Equatable {
    case quit
    /// It was asked to quit and is still running, usually because it is asking about unsaved work.
    case stillRunning
}

/// Everything the system tools need from macOS, so the tools can be tested without opening,
/// changing, or quitting anything real.
public protocol SystemControl: Sendable {
    /// The file or folder at a path, or nil when there is none.
    func fileInfo(atPath path: String) async -> FileInfo?
    /// Opens URLs or files, with the default app or with the app at `application`.
    func open(_ urls: [URL], withApplicationAt application: URL?) async throws
    /// Shows the item selected in a Finder window.
    func revealInFinder(_ url: URL) async
    /// Runs a Spotlight query and returns up to `limit` items, in no particular order.
    func spotlight(query: String, scope: [String], limit: Int) async -> [FileInfo]
    func readClipboard() async -> ClipboardContents
    func writeClipboard(_ text: String) async
    /// Sets the desktop picture on every screen. Returns how many screens.
    func setDesktopPicture(_ url: URL) async throws -> Int
    /// Asks the running app to quit, as choosing Quit in its menu would, and waits a moment.
    func quit(_ application: RunningApplication) async -> QuitOutcome
    func hide(_ application: RunningApplication) async -> Bool
}

/// The real system, through NSWorkspace, Spotlight, and NSPasteboard.
public struct SystemControlOnMac: SystemControl {
    /// How long to wait for an app to quit before saying it is still running.
    public var quitWait: Duration

    public init(quitWait: Duration = .seconds(3)) {
        self.quitWait = quitWait
    }

    public func fileInfo(atPath path: String) async -> FileInfo? {
        let url = URL(filePath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .contentModificationDateKey, .fileSizeKey])
        else { return nil }
        return FileInfo(
            path: url.plainPath, isFolder: values.isDirectory ?? false, contentType: values.contentType?.identifier,
            modified: values.contentModificationDate, size: values.fileSize)
    }

    @MainActor
    public func open(_ urls: [URL], withApplicationAt application: URL?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let application {
            NSApp?.yieldActivation(toApplicationWithBundleIdentifier: Bundle(url: application)?.bundleIdentifier ?? "")
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration)
        } else {
            for url in urls {
                if let handler = NSWorkspace.shared.urlForApplication(toOpen: url), let identifier = Bundle(url: handler)?.bundleIdentifier {
                    NSApp?.yieldActivation(toApplicationWithBundleIdentifier: identifier)
                }
                guard NSWorkspace.shared.open(url) else { throw SystemControlError.couldNotOpen(url) }
            }
        }
    }

    @MainActor
    public func revealInFinder(_ url: URL) async {
        NSApp?.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func spotlight(query: String, scope: [String], limit: Int) async -> [FileInfo] {
        await Task.detached { Self.runSpotlight(query: query, scope: scope, limit: limit) }.value
    }

    static func runSpotlight(query: String, scope: [String], limit: Int) -> [FileInfo] {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        if !scope.isEmpty {
            MDQuerySetSearchScope(mdQuery, scope as CFArray, 0)
        }
        MDQuerySetMaxCount(mdQuery, limit)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var result: [FileInfo] = []
        for index in 0..<MDQueryGetResultCount(mdQuery) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let type = MDItemCopyAttribute(item, kMDItemContentType) as? String
            let tree = MDItemCopyAttribute(item, kMDItemContentTypeTree) as? [String] ?? []
            result.append(FileInfo(
                path: path,
                isFolder: tree.contains("public.folder") && !tree.contains("com.apple.package"),
                contentType: type,
                modified: MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date,
                size: (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.intValue))
        }
        return result
    }

    @MainActor
    public func readClipboard() async -> ClipboardContents {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return ClipboardContents(
            text: pasteboard.string(forType: .string),
            filePaths: urls.map(\.plainPath),
            types: (pasteboard.types ?? []).map(\.rawValue))
    }

    @MainActor
    public func writeClipboard(_ text: String) async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    public func setDesktopPicture(_ url: URL) async throws -> Int {
        let screens = NSScreen.screens
        for screen in screens {
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
        return screens.count
    }

    @MainActor
    public func quit(_ application: RunningApplication) async -> QuitOutcome {
        let matches = Self.running(application)
        guard !matches.isEmpty else { return .quit }
        for app in matches { app.terminate() }
        let deadline = ContinuousClock.now + quitWait
        while ContinuousClock.now < deadline {
            if matches.allSatisfy(\.isTerminated) { return .quit }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return matches.allSatisfy(\.isTerminated) ? .quit : .stillRunning
    }

    @MainActor
    public func hide(_ application: RunningApplication) async -> Bool {
        let matches = Self.running(application)
        return !matches.isEmpty && matches.map { $0.hide() }.allSatisfy { $0 }
    }

    @MainActor
    private static func running(_ application: RunningApplication) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            if let url = application.url { return app.bundleURL?.standardizedFileURL == url.standardizedFileURL }
            return app.bundleIdentifier == application.bundleIdentifier
        }
    }
}

enum SystemControlError: LocalizedError {
    case couldNotOpen(URL)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url): "macOS could not open \(url.isFileURL ? url.plainPath : url.absoluteString)."
        }
    }
}

extension ToolSource {
    public static let system = ToolSource(id: "system", title: "System")
}
