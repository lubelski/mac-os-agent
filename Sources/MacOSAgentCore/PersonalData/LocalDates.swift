import Foundation

/// A day on the calendar with no time, such as a reminder due on a day or an all-day event.
public struct CalendarDay: Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day a moment falls on in a time zone.
    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// Midnight at the start of the day in the calendar's time zone.
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public func adding(days: Int, in calendar: Calendar) -> CalendarDay {
        CalendarDay(calendar.date(byAdding: .day, value: days, to: start(in: calendar)) ?? start(in: calendar), in: calendar)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// A date the model passed: a day with no time, or a moment.
public enum DateInput: Sendable, Equatable {
    case day(CalendarDay)
    /// A moment. `floating` is true when the text had no offset and was read in the Mac's time zone.
    case moment(Date, floating: Bool)
}

/// Reads ISO 8601 dates from the model and writes dates back in one form it reads without
/// doubt. Everything is in the Mac's current time zone unless the text gives an offset.
public struct LocalDates: Sendable {
    public let timeZone: TimeZone
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    /// Reads `2026-11-21`, `2026-11-21T14:30`, `2026-11-21T14:30:00`, and any of those with a
    /// `Z` or an offset such as `-08:00`. A space may stand for the `T`. Returns nil for
    /// anything else, or a day that does not exist.
    public func parse(_ text: String) -> DateInput? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?)?$/
        guard let match = text.wholeMatch(of: pattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3)
        else { return nil }
        let calendarDay = CalendarDay(year: year, month: month, day: day)
        // Rejects days such as February 30, which the calendar would roll into March.
        guard (1...12).contains(month), CalendarDay(calendarDay.start(in: calendar), in: calendar) == calendarDay else { return nil }
        guard let hourText = match.4, let hour = Int(hourText), let minute = match.5.flatMap({ Int($0) }) else {
            return .day(calendarDay)
        }
        let second = match.6.flatMap { Int($0) } ?? 0
        guard hour < 24, minute < 60, second < 60 else { return nil }
        var zone = timeZone
        var floating = true
        if let offsetText = match.7 {
            floating = false
            guard let offset = Self.offsetSeconds(String(offsetText)), let fixed = TimeZone(secondsFromGMT: offset) else { return nil }
            zone = fixed
        }
        var parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        parts.timeZone = zone
        guard let date = calendar.date(from: parts) else { return nil }
        return .moment(date, floating: floating)
    }

    private static func offsetSeconds(_ text: String) -> Int? {
        if text.uppercased() == "Z" { return 0 }
        let sign = text.hasPrefix("-") ? -1 : 1
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == 2 || digits.count == 4,
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.count == 4 ? digits.suffix(2) : "00"),
              hours <= 14, minutes < 60
        else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// The first moment a date covers: a day's midnight, or the moment itself.
    public func start(of input: DateInput) -> Date {
        switch input {
        case .day(let day): day.start(in: calendar)
        case .moment(let date, _): date
        }
    }

    /// The end of a range that reaches a date: the midnight after a day, so the whole day is
    /// included, or the moment itself.
    public func endOfRange(reaching input: DateInput) -> Date {
        switch input {
        case .day(let day): day.adding(days: 1, in: calendar).start(in: calendar)
        case .moment(let date, _): date
        }
    }

    public func day(of date: Date) -> CalendarDay { CalendarDay(date, in: calendar) }

    // MARK: Writing

    /// `Sat 2026-11-21`.
    public func text(_ day: CalendarDay) -> String {
        let weekday = calendar.component(.weekday, from: day.start(in: calendar))
        return "\(Self.weekdays[weekday - 1]) \(String(format: "%04d-%02d-%02d", day.year, day.month, day.day))"
    }

    /// `Sat 2026-11-21 14:30`, in the Mac's time zone.
    public func text(_ date: Date) -> String {
        "\(text(day(of: date))) \(timeText(date))"
    }

    /// `14:30`.
    public func timeText(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// One line that says which time zone the times are in, for the top of a result.
    public var timeZoneNote: String {
        let abbreviation = timeZone.abbreviation() ?? ""
        return "Times are local to the Mac (\(timeZone.identifier)\(abbreviation.isEmpty ? "" : ", \(abbreviation)"))."
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}
