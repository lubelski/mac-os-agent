import Foundation

/// The rules for updating the app, kept apart from Sparkle so they can be tested.
///
/// Only a release build updates itself. `scripts/release.sh` has `scripts/bundle.sh` write the
/// feed address and the public signing key into Info.plist. A build without them never
/// updates itself, so a development copy is never replaced by a release.
public enum AppUpdates {
    /// Whether a bundle with this Info.plist has a feed to update from.
    public static func hasFeed(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String, let key = info?["SUPublicEDKey"] as? String else {
            return false
        }
        return !feed.isEmpty && !key.isEmpty
    }

    /// What the app is doing that a relaunch would cut off.
    public struct Activity: Equatable, Sendable {
        /// A task is running in the main panel or the incognito window.
        public var taskRunning: Bool
        /// A task is waiting for the owner's go-ahead in either window.
        public var waitingForGoAhead: Bool
        /// Messages are waiting in either window's queue. The queue is kept only in memory.
        public var queuedMessages: Bool
        /// The incognito window holds a conversation. It is kept only in memory.
        public var incognitoConversation: Bool

        public init(
            taskRunning: Bool = false, waitingForGoAhead: Bool = false,
            queuedMessages: Bool = false, incognitoConversation: Bool = false
        ) {
            self.taskRunning = taskRunning
            self.waitingForGoAhead = waitingForGoAhead
            self.queuedMessages = queuedMessages
            self.incognitoConversation = incognitoConversation
        }
    }

    /// Why an update that is ready waits instead of relaunching the app now.
    public enum Wait: Equatable, Sendable {
        case goAhead
        case task
        case queuedMessages
        case incognitoConversation
    }

    /// Nil when the app may quit and relaunch into an update now. Otherwise the first thing
    /// that holds it back.
    public static func wait(for activity: Activity) -> Wait? {
        if activity.waitingForGoAhead { return .goAhead }
        if activity.taskRunning { return .task }
        if activity.queuedMessages { return .queuedMessages }
        if activity.incognitoConversation { return .incognitoConversation }
        return nil
    }

    public static func mayRelaunch(_ activity: Activity) -> Bool {
        wait(for: activity) == nil
    }

    /// The version Settings shows, with the build number, such as "0.2.0 (512)".
    public static func version(_ info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String
        return version + (build.map { " (\($0))" } ?? "")
    }
}
