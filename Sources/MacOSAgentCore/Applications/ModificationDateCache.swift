import Darwin

/// When a file or folder last changed, to the nanosecond, read with one `stat` call. That costs
/// about a microsecond, cheap enough to check on every keystroke. `FileManager.attributesOfItem`
/// reads the same date in about 25.
public struct FileModificationDate: Hashable, Sendable {
    public let seconds: Int
    public let nanoseconds: Int

    public init(seconds: Int, nanoseconds: Int) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    /// The date of the file at `path`, following a symbolic link, or nil when there is nothing
    /// there.
    public static func read(_ path: String) -> FileModificationDate? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileModificationDate(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// A value made from a file, kept by the file's path and made again when the file's modification
/// date is no longer the one it was made at. A file that is missing counts as a date of its own,
/// so a value made while it was gone is made again when it comes back.
///
/// The suggestion list keeps app icons here. An app updated by putting a new bundle in place of
/// the old one has a new bundle folder date, which is also what tells Launch Services to give
/// out the new icon.
public struct ModificationDateCache<Value> {
    private var entries: [String: (date: FileModificationDate?, value: Value)] = [:]
    private let limit: Int
    private let readDate: (String) -> FileModificationDate?

    /// - Parameters:
    ///   - limit: Past this many paths the cache starts over, so it never grows without end.
    ///   - readDate: How a path's date is read. Tests pass a stand-in.
    public init(limit: Int = 200, readDate: @escaping (String) -> FileModificationDate? = FileModificationDate.read) {
        self.limit = limit
        self.readDate = readDate
    }

    public var count: Int { entries.count }

    /// The value kept for `path` while its date is unchanged, or a new one from `make`.
    public mutating func value(for path: String, make: () -> Value) -> Value {
        let date = readDate(path)
        if let entry = entries[path], entry.date == date { return entry.value }
        let value = make()
        if entries[path] == nil, entries.count >= limit { entries.removeAll() }
        entries[path] = (date, value)
        return value
    }
}
