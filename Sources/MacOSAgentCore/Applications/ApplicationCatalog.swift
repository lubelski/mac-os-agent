import CoreServices
import Foundation
import Synchronization

/// The application bundles in the folders where macOS keeps apps. A folder is read again only
/// when its modification date changes, or the date of one of its bundles' Info.plist files, so a
/// search after the first one costs a `stat` call per folder and per bundle. An app updated in
/// place, with its files rewritten inside the old bundle, changes its Info.plist and not the
/// folder it sits in.
public final class ApplicationCatalog: Sendable {
    /// Where apps live, in the order results prefer them.
    public static let standardFolders: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Applications", directoryHint: .isDirectory),
        // Safari is updated outside the system volume and lives here.
        URL(filePath: "/System/Cryptexes/App/System/Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices/Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory),
    ]

    /// Folders of system components. Their subfolders are not searched, apps in them without a
    /// Dock icon are left out, and the rest rank below ordinary apps. Other folders are searched
    /// two levels down, for folders such as `/Applications/Utilities` and `/Applications/DaVinci Resolve`.
    private static let systemComponentFolders: Set<String> = ["/System/Library/CoreServices"]

    public let folders: [URL]
    private let cache = Mutex<[String: CachedFolder]>([:])

    private struct CachedFolder {
        var modified: Date
        var applications: [InstalledApplication]
        var subfolders: [URL]
        /// Each bundle's Info.plist and its date when the folder was read, including bundles
        /// left out of `applications`.
        var infoDates: [(path: String, date: FileModificationDate?)]

        var bundlesAreUnchanged: Bool {
            infoDates.allSatisfy { FileModificationDate.read($0.path) == $0.date }
        }
    }

    public init(folders: [URL] = ApplicationCatalog.standardFolders) {
        self.folders = folders
    }

    /// Every application in the folders, in folder order.
    public func applications() -> [InstalledApplication] {
        var result: [InstalledApplication] = []
        for folder in folders {
            let isSystem = Self.systemComponentFolders.contains(folder.plainPath)
            collect(folder, depth: isSystem ? 0 : 2, systemComponents: isSystem, into: &result)
        }
        return result
    }

    private func collect(_ folder: URL, depth: Int, systemComponents: Bool, into result: inout [InstalledApplication]) {
        let key = folder.plainPath
        // Read the date from the file system each time. URL resource values are cached per URL.
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        else { return }
        let entry: CachedFolder
        if let cached = cache.withLock({ $0[key] }), cached.modified == modified, cached.bundlesAreUnchanged {
            entry = cached
        } else {
            entry = Self.read(folder, modified: modified, systemComponents: systemComponents)
            cache.withLock { $0[key] = entry }
        }
        result.append(contentsOf: entry.applications)
        if depth > 0 {
            for subfolder in entry.subfolders {
                collect(subfolder, depth: depth - 1, systemComponents: systemComponents, into: &result)
            }
        }
    }

    private static func read(_ folder: URL, modified: Date, systemComponents: Bool) -> CachedFolder {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var applications: [InstalledApplication] = []
        var subfolders: [URL] = []
        var infoDates: [(path: String, date: FileModificationDate?)] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if url.pathExtension == "app" {
                // Read before the bundle, so a change while it is read shows next time.
                let infoPath = url.appending(path: "Contents/Info.plist").path(percentEncoded: false)
                infoDates.append((infoPath, FileModificationDate.read(infoPath)))
                guard var application = application(at: url) else { continue }
                if systemComponents {
                    if application.hasNoDockIcon { continue }
                    application.isSystemComponent = true
                }
                applications.append(application)
            } else if let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true
            {
                subfolders.append(url)
            }
        }
        return CachedFolder(modified: modified, applications: applications, subfolders: subfolders, infoDates: infoDates)
    }

    /// Reads an application bundle's name and bundle identifier from its Info.plist.
    /// Returns nil when the URL is not an application bundle.
    public static func application(at url: URL) -> InstalledApplication? {
        let url = url.standardizedFileURL
        guard url.pathExtension == "app" else { return nil }
        let plistURL = url.appending(path: "Contents/Info.plist")
        var info: [String: Any] = [:]
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            info = plist
        } else if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return nil
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        var alternates: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String, !value.isEmpty, value != fileName, !alternates.contains(value) {
                alternates.append(value)
            }
        }
        var application = InstalledApplication(
            name: fileName,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            url: url,
            alternateNames: alternates)
        application.hasNoDockIcon = isTrue(info["LSUIElement"]) || isTrue(info["LSBackgroundOnly"])
        return application
    }

    private static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: value == "1" || value.lowercased() == "true" || value.lowercased() == "yes"
        default: false
        }
    }

    /// Asks Spotlight for application bundles whose name contains the query, for apps outside
    /// the standard folders. Runs synchronously and returns at most `limit` apps.
    public static func spotlightApplications(matching query: String, limit: Int = 40) -> [InstalledApplication] {
        let cleaned = query.filter { !"\"\\*?'".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let text = "kMDItemContentType == \"com.apple.application-bundle\" && "
            + "(kMDItemDisplayName == \"*\(cleaned)*\"cd || kMDItemFSName == \"*\(cleaned)*\"cd)"
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return [] }
        MDQuerySetMaxCount(mdQuery, limit * 2)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var result: [InstalledApplication] = []
        for index in 0..<MDQueryGetResultCount(mdQuery) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            // Helper apps inside other bundles and apps in the Trash are not what anyone means.
            let parent = (path as NSString).deletingLastPathComponent
            if parent.contains(".app/") || parent.hasSuffix(".app") || path.contains("/.Trash/") { continue }
            if let application = application(at: URL(filePath: path)) { result.append(application) }
            if result.count >= limit { break }
        }
        return result
    }
}
