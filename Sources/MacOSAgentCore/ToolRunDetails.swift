import Foundation

/// What the app noted about one tool run, stored beside its result in the thread for the tool
/// call inspector. It is never sent to the model, so it cannot change a request or the prompt
/// cache. Every field is optional: a result written before a field existed simply lacks it,
/// and the inspector shows less for it.
public struct ToolRunDetails: Sendable, Equatable, Codable {
    /// The go-ahead a call asked for, and the owner's answer.
    public enum GoAhead: String, Sendable, Equatable, Codable {
        case approved
        case declined
        /// A step of a quick action that would have asked if the agent had made the call. The
        /// owner chose the action from a list, which is the go-ahead, so it did not ask.
        case preapproved
    }

    /// When the tool began, after the model had finished writing the call.
    public var started: Date?
    /// How long the tool took from start to result, in seconds, including any wait for a go-ahead.
    public var seconds: Double?
    /// How long of that was spent waiting for the owner's go-ahead.
    public var waitedSeconds: Double?
    /// Set when the call asked for a go-ahead.
    public var goAhead: GoAhead?
    /// The title of the group the tool belongs to, such as Built In.
    public var source: String?
    /// The exit status of a shell command.
    public var exitStatus: Int32?
    /// True when the command was stopped at its time limit.
    public var timedOut: Bool?
    /// True when the task was stopped while the tool ran.
    public var stopped: Bool?
    /// How many characters the tool produced before its output was shortened for the model.
    /// Nil when it was not shortened.
    public var fullCharacters: Int?

    public init(
        started: Date? = nil, seconds: Double? = nil, waitedSeconds: Double? = nil, goAhead: GoAhead? = nil,
        source: String? = nil, exitStatus: Int32? = nil, timedOut: Bool? = nil, stopped: Bool? = nil,
        fullCharacters: Int? = nil
    ) {
        self.started = started
        self.seconds = seconds
        self.waitedSeconds = waitedSeconds
        self.goAhead = goAhead
        self.source = source
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.stopped = stopped
        self.fullCharacters = fullCharacters
    }
}

/// Where a running tool notes what it knows about its run, such as a command's exit status.
/// The loop adds the timing and the go-ahead and stores the whole with the result.
public final class ToolRunReport: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ToolRunDetails()

    public init() {}

    /// Changes the noted details.
    public func note(_ change: (inout ToolRunDetails) -> Void) {
        lock.withLock { change(&value) }
    }

    public var details: ToolRunDetails { lock.withLock { value } }
}
