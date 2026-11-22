import Foundation

/// Tells two presses of Delete in an empty text field, close together, from everything else.
/// With `HarnessBehavior.doubleDeleteStartsNewEpisode` on, the second press does what `/new`
/// does.
///
/// Only two distinct presses count, both made while the field is already empty:
/// - A press that empties the field, such as deleting the last character, is not one of them.
///   So "delete the last character, then press again" is one press on empty, not two.
/// - A key repeat from holding Delete never counts and starts the count over, so holding Delete
///   to erase a long draft never starts a new episode when the field runs empty.
/// - The second press has to come within `interval` of the first. The text field uses the
///   system's double-click interval, the Mac's own setting for how close two presses are.
///
/// The field starts the count over, with `reset()`, on any other key, a click, its text
/// changing, and losing focus or the window hiding.
public struct DoubleDelete: Sendable, Equatable {
    public var interval: TimeInterval
    /// When the first press on an empty field was made, while waiting for a second.
    public private(set) var firstPress: TimeInterval?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Whether a first press is waiting for a second.
    public var isWaiting: Bool { firstPress != nil }

    /// One key-down of Delete. Returns true when it is the second of two in an empty field.
    /// - Parameters:
    ///   - fieldIsEmpty: whether the field was empty before this press was handled.
    ///   - isRepeat: whether the press is a key repeat from holding the key down.
    ///   - time: when the press was made, as an event's timestamp.
    public mutating func press(fieldIsEmpty: Bool, isRepeat: Bool, at time: TimeInterval) -> Bool {
        guard fieldIsEmpty, !isRepeat else {
            firstPress = nil
            return false
        }
        if let first = firstPress, time >= first, time - first <= interval {
            firstPress = nil
            return true
        }
        // Too slow, or the first press: this one may be the first of two.
        firstPress = time
        return false
    }

    public mutating func reset() {
        firstPress = nil
    }
}
