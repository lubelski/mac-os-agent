import Foundation

// Task links, with the panel with bars and an input pill experiment on: a short row of
// clickable links above the pill for the task at hand, such as a ticket, a pull request, or a
// mock page. The model keeps the list with `set_links`, which replaces it whole. A port of the
// links mod in `agent-customizations`. See `planning/panel-with-input-pill.md`.
//
// The list belongs to the episode it was set in. It is kept in `task-links.json` in the data
// folder with that episode's id, so it comes back after a relaunch while the episode lasts, and
// a new episode starts with none. The incognito window has no `set_links` and writes nothing.

/// One link in the row: a short label and an http or https URL.
public struct TaskLink: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String { url }
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// The rules for a list of links, after the links mod.
public enum TaskLinks {
    public static let maximumCount = 8
    public static let maximumLabelLength = 32
    public static let maximumURLLength = 2048
    /// How many links the row shows before the rest go into its overflow menu.
    public static let visibleCount = 3

    /// Why a list was refused, in a sentence the model reads.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// The list checked, cleaned, and without repeated URLs, or the reason it was refused.
    /// Labels have control characters and runs of spaces folded to one space. An empty list is
    /// valid and clears the row.
    public static func normalize(_ value: JSONValue?) throws(Problem) -> [TaskLink] {
        guard let items = value?.arrayValue else { throw Problem("links must be an array") }
        guard items.count <= maximumCount else { throw Problem("links are limited to \(maximumCount) items") }
        var links: [TaskLink] = []
        var seen = Set<String>()
        for item in items {
            guard let rawLabel = item["label"]?.stringValue, let rawURL = item["url"]?.stringValue else {
                throw Problem("each link must have a string label and url")
            }
            let label = cleanLabel(rawLabel)
            guard !label.isEmpty else { throw Problem("a link label cannot be empty") }
            guard label.count <= maximumLabelLength else {
                throw Problem("link labels are limited to \(maximumLabelLength) characters: \(label)")
            }
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.count <= maximumURLLength else {
                throw Problem("link urls are limited to \(maximumURLLength) characters: \(label)")
            }
            guard !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw Problem("a link url cannot hold whitespace or control characters: \(label)")
            }
            guard isWebURL(url) else { throw Problem("links must be http or https URLs: \(url)") }
            guard seen.insert(url).inserted else { continue }
            links.append(TaskLink(label: label, url: url))
        }
        return links
    }

    /// True for an absolute http or https URL with a host.
    public static func isWebURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty
        else { return false }
        return URL(string: text) != nil
    }

    static func cleanLabel(_ text: String) -> String {
        let folded = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The tool's result: what the row now shows.
    static func describe(_ links: [TaskLink]) -> String {
        links.isEmpty ? "No links set." : "Links: " + links.map(\.label).joined(separator: ", ")
    }
}

/// Where the list is kept: `task-links.json` in the data folder, with the id of the episode it
/// belongs to. Read each time, since it is a few lines.
public struct TaskLinkStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AgentPaths.taskLinksFile) {
        self.fileURL = fileURL
    }

    private struct File: Codable {
        var format = 1
        var episode: UUID?
        var links: [TaskLink]
    }

    /// The links set in this episode, or none when the file holds another episode's.
    public func links(inEpisode episode: UUID?) -> [TaskLink] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.episode == episode
        else { return [] }
        return file.links
    }

    /// Replaces the list. An empty list removes the file.
    public func set(_ links: [TaskLink], episode: UUID?) throws {
        guard !links.isEmpty else { return try clear() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(File(episode: episode, links: links)).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.plainPath) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

extension ToolSource {
    public static let taskLinks = ToolSource(id: "task-links", title: "Task Links")
}

/// Replaces the task links shown above the text field. Only in the tool list when the panel
/// with bars experiment was on at launch. Needs no go-ahead: it changes only the row.
public struct SetLinksTool: AgentTool {
    public static let name = "set_links"

    public let store: TaskLinkStore
    /// Whether the experiment is on now. Turned off since launch, the tool is still in this
    /// run's list, and a call sets nothing.
    public let isOn: @Sendable () -> Bool

    public init(store: TaskLinkStore = TaskLinkStore(), isOn: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.isOn = isOn
    }

    public var source: ToolSource { .taskLinks }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Replace the clickable links shown above the text field for the current task. Send the \
                complete current list each time, with short labels, for the task's tickets, pull \
                requests, mock pages, and similar pages. Pass an empty list to clear stale links. At \
                most \(TaskLinks.maximumCount) links, labels up to \(TaskLinks.maximumLabelLength) \
                characters, and http or https URLs only. Three show in the row and the rest go in a menu.
                """,
            parameters: Schema.object([
                "links": [
                    "type": "array",
                    "description": "The complete list, in the order to show it. Empty clears the row.",
                    "items": Schema.object([
                        "label": Schema.string("A short label, such as \"PR #12\" or \"LIN-123\"."),
                        "url": Schema.string("An http or https URL."),
                    ]),
                ],
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let count = arguments["links"]?.arrayValue?.count ?? 0
        return count == 0 ? "Clear the task links" : "Set \(count) task link\(count == 1 ? "" : "s")"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard isOn() else {
            return "Error: the links row is turned off in Settings, so nothing was set."
        }
        let links: [TaskLink]
        do {
            links = try TaskLinks.normalize(arguments["links"])
        } catch {
            return "Error: \(error.description)."
        }
        do {
            try store.set(links, episode: context.episodeID)
        } catch {
            return "Error: could not keep the links: \(error.localizedDescription)"
        }
        return TaskLinks.describe(links)
    }
}
