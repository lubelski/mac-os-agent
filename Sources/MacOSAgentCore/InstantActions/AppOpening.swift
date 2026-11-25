import Foundation

extension ThreadItem {
    /// An app the owner opened from the instant row, logged with the panel with bars
    /// experiment on. Nothing is sent to the model when it happens. The entry sits in the thread
    /// where it was logged, and joins what the model sees with the next request of its episode,
    /// which is built after it, so the request's earlier prefix is unchanged.
    ///
    /// It is a kind of entry of its own, `app_opened`. A build from before it existed cannot
    /// read the line, so it skips it as it skips any line it cannot read, and the opening is
    /// invisible to it and never sent.
    public struct AppOpening: Sendable, Equatable, Codable {
        /// The name Finder shows, without `.app`.
        public var name: String
        public var bundleIdentifier: String?
        /// Where the app is, for its icon on the line.
        public var path: String
        /// What the model is sent for this entry. Stored whole, like a quick action's note, so
        /// a later request in the episode sends exactly the same text.
        public var message: String

        public init(name: String, bundleIdentifier: String?, path: String, message: String) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.path = path
            self.message = message
        }

        public init(_ application: InstalledApplication) {
            self.init(
                name: application.name, bundleIdentifier: application.bundleIdentifier, path: application.path,
                message: Self.message(name: application.name, bundleIdentifier: application.bundleIdentifier))
        }

        /// The note the model reads for an opening, between `<app_opened>` tags.
        public static func message(name: String, bundleIdentifier: String?) -> String {
            let id = bundleIdentifier.map { " (\($0))" } ?? ""
            return [
                "<app_opened>",
                "The person opened \(name)\(id) from the instant row. The app opened it without you, and nothing was sent to you at the time.",
                "No reply was asked for. This is a record, so you know it happened if they refer to it.",
                "</app_opened>",
            ].joined(separator: "\n")
        }
    }
}

extension AgentLoop {
    /// Logs an app the owner opened from the instant row. No model request is made: the entry
    /// waits in the thread for the next request of its episode.
    ///
    /// It goes in as an entry from the owner does, after an episode marker when the episode has
    /// timed out or a fresh start was asked for, and after answers to any unanswered calls, so the
    /// next request is valid and the opening belongs to the episode the panel shows.
    @discardableResult
    public func logAppOpening(
        _ opening: ThreadItem.AppOpening,
        startsNewEpisode: Bool = false,
        now: Date = Date(),
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> ThreadEntry {
        try await prepareForOwnerEntry(startsNewEpisode: startsNewEpisode, now: now, onEvent: onEvent)
        let entry = try await thread.append(.appOpened(opening), date: now)
        await onEvent(.entryAdded(entry))
        return entry
    }
}
