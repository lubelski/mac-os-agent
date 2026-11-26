import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct ModificationDateCacheTests {
    /// A stand-in file system: a date per path, and nil for a path with nothing there.
    final class Dates: @unchecked Sendable {
        var byPath: [String: FileModificationDate] = [:]
        func set(_ path: String, _ seconds: Int?) {
            byPath[path] = seconds.map { FileModificationDate(seconds: $0, nanoseconds: 0) }
        }
    }

    @Test func aValueIsKeptWhileItsFileIsUnchanged() {
        let dates = Dates()
        dates.set("/Applications/Placeholder.app", 100)
        var cache = ModificationDateCache<String>(readDate: { dates.byPath[$0] })
        var made = 0
        func icon() -> String { cache.value(for: "/Applications/Placeholder.app") { made += 1; return "icon \(made)" } }

        #expect(icon() == "icon 1")
        #expect(icon() == "icon 1")
        #expect(made == 1)
    }

    @Test func aValueIsMadeAgainWhenItsFileChanges() {
        let dates = Dates()
        dates.set("/Applications/Placeholder.app", 100)
        var cache = ModificationDateCache<String>(readDate: { dates.byPath[$0] })
        var made = 0
        func icon() -> String { cache.value(for: "/Applications/Placeholder.app") { made += 1; return "icon \(made)" } }

        #expect(icon() == "icon 1")
        // An update puts a new bundle in place of the old one.
        dates.set("/Applications/Placeholder.app", 200)
        #expect(icon() == "icon 2")
        #expect(icon() == "icon 2")
    }

    @Test func aFileThatComesBackIsReadAgain() {
        let dates = Dates()
        var cache = ModificationDateCache<String>(readDate: { dates.byPath[$0] })
        var made = 0
        func icon() -> String { cache.value(for: "/Applications/Placeholder.app") { made += 1; return "icon \(made)" } }

        // Gone while an updater swaps it: the stand-in is kept until the bundle is back.
        #expect(icon() == "icon 1")
        #expect(icon() == "icon 1")
        dates.set("/Applications/Placeholder.app", 300)
        #expect(icon() == "icon 2")
    }

    @Test func pastItsLimitItStartsOver() {
        var cache = ModificationDateCache<Int>(limit: 2, readDate: { _ in FileModificationDate(seconds: 1, nanoseconds: 0) })
        _ = cache.value(for: "/a") { 1 }
        _ = cache.value(for: "/b") { 2 }
        #expect(cache.count == 2)
        // A path already kept never empties it.
        _ = cache.value(for: "/b") { 2 }
        #expect(cache.count == 2)
        _ = cache.value(for: "/c") { 3 }
        #expect(cache.count == 1)
    }

    @Test func readsTheDateOfARealFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-dates-\(UUID().uuidString).app", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileModificationDate.read(folder.path) == nil)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000.5)], ofItemAtPath: folder.path)
        let first = try #require(FileModificationDate.read(folder.path))
        #expect(first.seconds == 1_000_000)
        #expect(first.nanoseconds == 500_000_000)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: folder.path)
        #expect(FileModificationDate.read(folder.path) != first)
    }
}
