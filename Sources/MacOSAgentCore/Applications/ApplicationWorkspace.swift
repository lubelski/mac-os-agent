import AppKit
import Foundation

/// A running application, as the application tools report it.
public struct RunningApplication: Sendable, Equatable {
    public var name: String
    public var bundleIdentifier: String?
    public var url: URL?
    public var isFrontmost: Bool
    public var isHidden: Bool

    public init(name: String, bundleIdentifier: String?, url: URL?, isFrontmost: Bool = false, isHidden: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
    }
}

/// What opening an application did.
public enum OpenApplicationOutcome: Sendable, Equatable {
    /// It was not running and has been launched.
    case launched
    /// It was already running and has been brought to the front.
    case broughtToFront
}

/// Everything the application tools need from the system, so the tools can be tested with a
/// made-up list of apps.
public protocol ApplicationWorkspace: Sendable {
    /// Apps in the standard folders.
    func installedApplications() async -> [InstalledApplication]
    /// Apps anywhere on the Mac whose name contains the query, for when the standard folders
    /// have no good match.
    func otherApplications(matching query: String) async -> [InstalledApplication]
    /// Apps with a Dock icon that are running now.
    func runningApplications() async -> [RunningApplication]
    /// The copy of an app Launch Services would open for a bundle identifier.
    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL?
    /// Reads the app bundle at a URL, or returns nil when there is none.
    func application(at url: URL) async -> InstalledApplication?
    /// Opens the app and brings it to the front.
    func openApplication(at url: URL) async throws -> OpenApplicationOutcome
}

/// The real system, through Launch Services, NSWorkspace, and Spotlight.
public final class SystemApplicationWorkspace: ApplicationWorkspace {
    private let catalog: ApplicationCatalog

    public init(catalog: ApplicationCatalog = ApplicationCatalog()) {
        self.catalog = catalog
    }

    public func installedApplications() async -> [InstalledApplication] {
        let catalog = catalog
        return await Task.detached { catalog.applications() }.value
    }

    public func otherApplications(matching query: String) async -> [InstalledApplication] {
        await Task.detached { ApplicationCatalog.spotlightApplications(matching: query) }.value
    }

    @MainActor
    public func runningApplications() async -> [RunningApplication] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                RunningApplication(
                    name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "(unnamed)",
                    bundleIdentifier: app.bundleIdentifier,
                    url: app.bundleURL?.standardizedFileURL,
                    isFrontmost: app.processIdentifier == frontmost,
                    isHidden: app.isHidden)
            }
    }

    @MainActor
    public func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.standardizedFileURL
    }

    public func application(at url: URL) async -> InstalledApplication? {
        ApplicationCatalog.application(at: url)
    }

    @MainActor
    public func openApplication(at url: URL) async throws -> OpenApplicationOutcome {
        let url = url.standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url }
        if let running {
            // Since macOS 14 an app can only bring another to the front if it gives up being
            // active first.
            NSApp?.yieldActivation(to: running)
            if running.isHidden { running.unhide() }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        if running != nil {
            opened.activate()
            return .broughtToFront
        }
        return .launched
    }
}
