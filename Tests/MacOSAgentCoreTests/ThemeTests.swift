import Foundation
import Testing
@testable import MacOSAgentCore

/// A folder of its own and a preferences suite of its own, removed when the test ends. Nothing
/// touches the real themes folder or the app's preferences.
private final class ThemeSandbox {
    let folder: URL
    let suiteName: String
    let library: ThemeLibrary
    let preferences: ThemePreferences

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "mac-os-agent-theme-tests-\(UUID().uuidString)"
        library = ThemeLibrary(folder: folder)
        preferences = ThemePreferences(suiteName: suiteName)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func write(_ name: String, _ text: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: folder.appending(path: name))
    }

    var read: ReadThemesTool { ReadThemesTool(library: library, preferences: preferences) }
    var change: ChangeThemeTool { ChangeThemeTool(library: library, preferences: preferences) }
}

private func context(approving: Bool = true, asked: AskedLog? = nil) -> ToolRunContext {
    ToolRunContext(callID: "call", confirm: { request in
        asked?.append(request)
        return approving
    })
}

private final class AskedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ConfirmationRequest] = []
    func append(_ request: ConfirmationRequest) { lock.withLock { requests.append(request) } }
    var all: [ConfirmationRequest] { lock.withLock { requests } }
}

/// A readable dark theme with one appearance, as a file, with a few values open to change.
private func darkThemeFile(name: String = "Night Swim", primary: String = "#F2F4F8", secondary: String = "#B8C0CC", tint: String = "#101828F0", extra: String = "") -> String {
    """
    {
      "format": 1,
      "name": "\(name)",\(extra)
      "dark": {
        "surface": { "kind": "blur", "tint": "\(tint)", "fill": "#111827" },
        "text": { "primary": "\(primary)", "secondary": "\(secondary)", "tertiary": "#7B8494" },
        "accent": "#7FB2FF",
        "ownerMessage": { "fill": "#7FB2FF2E", "edge": "#7FB2FF4D" },
        "agentReply": { "fill": "#FFFFFF12", "edge": "#FFFFFF1F" },
        "divider": "#FFFFFF26",
        "code": "#7B8494",
        "goAhead": { "fill": "#FFFFFF10", "edge": "#FFFFFF2E" },
        "incognito": { "tint": "#7A66E02E", "badge": "#FFFFFF14" }
      }
    }
    """
}

@Suite struct ThemeColorTests {
    @Test func hexColorsReadAndWriteTheSame() {
        #expect(ThemeColor("#0B3D45") == .hex(red: 0x0B, green: 0x3D, blue: 0x45, alpha: 255))
        #expect(ThemeColor("#0b3d45e6") == .hex(red: 0x0B, green: 0x3D, blue: 0x45, alpha: 0xE6))
        #expect(ThemeColor("#0b3d45e6")?.description == "#0B3D45E6")
        #expect(ThemeColor("#0B3D45FF")?.description == "#0B3D45")
        for text in ["#000000", "#FFFFFF00", "#12345678", "system-label", "system-accent 30%", "system-tertiary-label 0%"] {
            #expect(ThemeColor(text)?.description == text)
        }
    }

    @Test func systemColorsTakeAnOptionalOpacity() {
        #expect(ThemeColor("system-accent") == .system(.accent, percent: 100))
        #expect(ThemeColor("system-label 13%") == .system(.label, percent: 13))
        #expect(ThemeColor("system-label 13%")?.isSystem == true)
    }

    @Test func malformedColorsAreRefused() {
        for text in ["", "#", "#12", "#12345", "#1234567", "#GG0000", "red", "0B3D45", "system-label 130%", "system-label 30", "system-blue", "system-label 30% extra", "#123456789"] {
            #expect(ThemeColor(text) == nil, "\(text)")
        }
    }

    @Test func contrastMatchesTheWCAGFigures() {
        #expect(abs(RGBA.contrast(.black, .white) - 21) < 0.001)
        #expect(abs(RGBA.contrast(.white, .white) - 1) < 0.001)
        // #777777 on white is the well known 4.48:1.
        let gray = ThemeColor("#777777")!.resolved(dark: false)
        #expect(abs(gray.contrast(over: .white) - 4.48) < 0.01)
        // Half-transparent black over white is the same as #808080 over white.
        let half = RGBA(red: 0, green: 0, blue: 0, alpha: 0.5).over(.white)
        #expect(abs(half.red - 0.5) < 0.001 && half.alpha == 1)
    }
}

@Suite struct ThemeFormatTests {
    @Test func everyBuiltInThemeParsesAndRoundTrips() throws {
        #expect(BuiltInThemes.ids == ["glass", "tidewater", "graphite", "paper", "high-contrast", "ember"])
        for entry in BuiltInThemes.all {
            #expect(entry.problem == nil, "\(entry.id): \(entry.problem ?? "")")
            let theme = try #require(entry.theme)
            #expect(try Theme.parse(theme.fileText) == theme)
            #expect(theme.fileText == (try Theme.parse(theme.fileText)).fileText)
        }
    }

    @Test func glassIsTheDefaultAndKeepsTheLookFromBeforeThemes() {
        #expect(BuiltInThemes.defaultID == "glass")
        let glass = BuiltInThemes.glass
        #expect(glass.name == "Glass")
        #expect(glass.fixedAppearance == nil)
        for kind in ThemeAppearanceKind.allCases {
            let appearance = glass.appearance(dark: kind.isDark)
            #expect(appearance.surface.kind == .glass)
            #expect(appearance.surface.tint == nil)
            #expect(appearance.text == ThemeText(primary: .system(.label, percent: 100), secondary: .system(.secondaryLabel, percent: 100), tertiary: .system(.tertiaryLabel, percent: 100)))
            #expect(appearance.ownerMessage.fill == .system(.accent, percent: 30))
            #expect(appearance.agentReply == ThemeBox(fill: .system(.label, percent: 13), edge: .system(.label, percent: 10)))
            #expect(appearance.divider == .system(.label, percent: 14))
            #expect(appearance.goAhead == ThemeBox(fill: .system(.label, percent: 8), edge: .system(.label, percent: 16)))
            #expect(appearance.incognito.badge == .system(.label, percent: 7))
        }
    }

    @Test func aThemeWithOneAppearanceAlwaysDrawsInIt() throws {
        let theme = try Theme.parse(darkThemeFile())
        #expect(theme.light == nil)
        #expect(theme.fixedAppearance == .dark)
        #expect(theme.appearance(dark: false) == theme.dark)
        #expect(theme.appearanceSummary == "dark only")
        #expect(!theme.fileText.contains("\"light\""))
    }

    @Test func aFileWithNeitherAppearanceIsRefused() {
        #expect(throws: ThemeFormatError("The theme defines neither light nor dark. It needs at least one of them.")) {
            try Theme.parse(#"{ "format": 1, "name": "Empty" }"#)
        }
        #expect(throws: ThemeFormatError.self) { try Theme.parse(#"{ "format": 1, "name": "Empty", "light": null }"#) }
    }

    @Test func malformedFilesSayWhereTheProblemIs() {
        func problem(_ text: String) -> String? {
            do { _ = try Theme.parse(text); return nil } catch { return error.description }
        }
        #expect(problem("not json") == "The file is not valid JSON.")
        #expect(problem("[1]") == "the file should be an object.")
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"format\": 1", with: "\"format\": 2"))?.contains("newer version") == true)
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"format\": 1", with: "\"format\": \"1\""))?.contains("format should be the number 1") == true)
        #expect(problem(darkThemeFile(extra: "\n  \"author\": \"me\",")) == "The file has a key it does not use, \"author\". It takes format, name, light, dark.")
        #expect(problem(darkThemeFile(name: "")) == "name is empty.")
        #expect(problem(darkThemeFile(name: String(repeating: "a", count: 41))) == "name is longer than 40 characters.")
        #expect(problem(darkThemeFile(secondary: "#B8C0")) == "dark.text.secondary is \"#B8C0\", which is not a color. Use #RRGGBB or #RRGGBBAA, or a system color: system-label, system-secondary-label, system-tertiary-label, system-accent, optionally followed by an opacity such as 30%.")
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"fill\": \"#111827\"", with: "\"fill\": \"#11182780\""))?.hasPrefix("dark.surface.fill is \"#11182780\". It has to be an opaque hex color") == true)
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"kind\": \"blur\"", with: "\"kind\": \"frosted\"")) == "dark.surface.kind should be one of glass, blur, solid.")
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"divider\": \"#FFFFFF26\",", with: "")) == "dark has no divider.")
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"edge\": \"#7FB2FF4D\"", with: "\"edge\": \"#7FB2FF4D\", \"glow\": \"#FFFFFF\"")) == "dark.ownerMessage has a key it does not use, \"glow\". It takes fill, edge.")
        #expect(problem(darkThemeFile().replacingOccurrences(of: "\"accent\": \"#7FB2FF\"", with: "\"accent\": 7")) == "dark.accent should be a color as text, such as \"#1C1E21\".")
    }

    /// A file written before the bars' fill existed reads as before, writes the same bytes,
    /// and takes the derived fill: the primary text at 3 percent.
    @Test func theBarIsOptionalAndDerivedFromThePrimaryText() throws {
        let text = darkThemeFile()
        let theme = try Theme.parse(text)
        let dark = try #require(theme.dark)
        #expect(dark.bar == nil)
        #expect(!theme.fileText.contains("\"bar\""))
        #expect(theme.fileText == (try Theme.parse(theme.fileText)).fileText)
        #expect(dark.barFill == .hex(red: 0xF2, green: 0xF4, blue: 0xF8, alpha: 8))
        #expect(BuiltInThemes.glass.appearance(dark: false).barFill == .system(.label, percent: 3))
        for entry in BuiltInThemes.all {
            for (_, appearance) in try #require(entry.theme).appearances {
                #expect(appearance.bar == nil, "\(entry.id) derives its bars' fill")
                #expect(appearance.barFill == appearance.text.primary.scaled(toOpacity: appearance.text.primary.opacity * 0.03))
                #expect(appearance.barFill.opacity > 0 && appearance.barFill.opacity < 0.05)
            }
        }
    }

    /// A theme may set the bars' fill. It reads, writes after the incognito colors, and reads
    /// back as itself, and a malformed one says where it is.
    @Test func aThemeCanSetTheBar() throws {
        let text = darkThemeFile().replacingOccurrences(
            of: "\"badge\": \"#FFFFFF14\" }", with: "\"badge\": \"#FFFFFF14\" },\n    \"bar\": \"#FFFFFF0D\"")
        let theme = try Theme.parse(text)
        #expect(theme.dark?.bar == .hex(red: 255, green: 255, blue: 255, alpha: 0x0D))
        #expect(theme.dark?.barFill == .hex(red: 255, green: 255, blue: 255, alpha: 0x0D))
        #expect(theme.fileText.contains("\"incognito\": { \"tint\": \"#7A66E02E\", \"badge\": \"#FFFFFF14\" },\n    \"bar\": \"#FFFFFF0D\"\n  }"))
        #expect(try Theme.parse(theme.fileText) == theme)
        do {
            _ = try Theme.parse(text.replacingOccurrences(of: "\"#FFFFFF0D\"", with: "\"pale\""))
            Issue.record("A malformed bar should be refused.")
        } catch {
            #expect(error.description.hasPrefix("dark.bar is \"pale\", which is not a color."))
        }
    }

    /// A file written before the field color existed reads as before, writes the same bytes,
    /// and takes the derived pill: the primary text at 6 percent, with an edge at 12.
    @Test func theFieldIsOptionalAndDerivedFromThePrimaryText() throws {
        let text = darkThemeFile()
        let theme = try Theme.parse(text)
        let dark = try #require(theme.dark)
        #expect(dark.field == nil)
        #expect(!theme.fileText.contains("\"field\""))
        #expect(theme.fileText == (try Theme.parse(theme.fileText)).fileText)
        #expect(dark.fieldBox == ThemeBox(
            fill: .hex(red: 0xF2, green: 0xF4, blue: 0xF8, alpha: 15),
            edge: .hex(red: 0xF2, green: 0xF4, blue: 0xF8, alpha: 31)))
        let system = ThemeAppearance(
            surface: dark.surface, text: ThemeText(primary: .system(.label, percent: 100), secondary: dark.text.secondary, tertiary: dark.text.tertiary),
            accent: dark.accent, ownerMessage: dark.ownerMessage, agentReply: dark.agentReply, divider: dark.divider,
            code: dark.code, goAhead: dark.goAhead, incognito: dark.incognito)
        #expect(system.fieldBox == ThemeBox(fill: .system(.label, percent: 6), edge: .system(.label, percent: 12)))
    }

    /// A theme may set the field. It reads, writes after the incognito colors and the bar, and
    /// reads back as itself, and a malformed one says where it is.
    @Test func aThemeCanSetTheField() throws {
        let field = "\"field\": { \"fill\": \"#FFFFFF14\", \"edge\": \"#FFFFFF33\" }"
        let text = darkThemeFile().replacingOccurrences(
            of: "\"badge\": \"#FFFFFF14\" }", with: "\"badge\": \"#FFFFFF14\" },\n    \(field)")
        let theme = try Theme.parse(text)
        let expected = ThemeBox(fill: .hex(red: 255, green: 255, blue: 255, alpha: 0x14), edge: .hex(red: 255, green: 255, blue: 255, alpha: 0x33))
        #expect(theme.dark?.field == expected)
        #expect(theme.dark?.fieldBox == expected)
        #expect(theme.fileText.contains("\"badge\": \"#FFFFFF14\" },\n    \(field)\n  }"))
        #expect(try Theme.parse(theme.fileText) == theme)

        // With the bar too, the bar comes first and both read back.
        let both = try Theme.parse(darkThemeFile().replacingOccurrences(
            of: "\"badge\": \"#FFFFFF14\" }", with: "\"badge\": \"#FFFFFF14\" },\n    \(field),\n    \"bar\": \"#FFFFFF0D\""))
        #expect(both.fileText.contains("\"bar\": \"#FFFFFF0D\",\n    \(field)\n  }"))
        #expect(try Theme.parse(both.fileText) == both)

        func problem(_ replacement: String) -> String? {
            do {
                _ = try Theme.parse(darkThemeFile().replacingOccurrences(
                    of: "\"badge\": \"#FFFFFF14\" }", with: "\"badge\": \"#FFFFFF14\" },\n    \(replacement)"))
                return nil
            } catch { return error.description }
        }
        #expect(problem("\"field\": \"#FFFFFF14\"") == "dark.field should be an object.")
        #expect(problem("\"field\": { \"fill\": \"#FFFFFF14\" }") == "dark.field has no edge.")
        #expect(problem("\"field\": { \"fill\": \"pale\", \"edge\": \"#FFFFFF33\" }")?.hasPrefix("dark.field.fill is \"pale\", which is not a color.") == true)
    }

    /// Every built-in theme sets its own pill, so it is plain on the dark themes, where the
    /// derived one is too faint.
    @Test func everyBuiltInThemeSetsTheField() throws {
        for entry in BuiltInThemes.all {
            for (kind, appearance) in try #require(entry.theme).appearances {
                let field = try #require(appearance.field, "\(entry.id) \(kind)")
                #expect(field.edge.opacity > 0, "\(entry.id) \(kind)")
            }
        }
    }

    @Test func theTintIsOptional() throws {
        let text = darkThemeFile().replacingOccurrences(of: "\"tint\": \"#101828F0\", ", with: "")
        let theme = try Theme.parse(text)
        #expect(theme.dark?.surface.tint == nil)
        #expect(try Theme.parse(theme.fileText) == theme)
    }
}

@Suite struct ThemeContrastTests {
    /// Every built-in theme reaches WCAG AA, 4.5:1, for primary and secondary text in every
    /// appearance it defines, everywhere that text sits. Glass uses the system's label colors,
    /// which are held to 3:1, the bar the system's own secondary label meets.
    @Test func everyBuiltInThemeIsReadable() throws {
        for entry in BuiltInThemes.all {
            let theme = try #require(entry.theme)
            let failures = ThemeContrast.failures(theme)
            #expect(failures.isEmpty, "\(entry.id): \(failures.map(\.failureText).joined(separator: " | "))")
            for (kind, level, check) in ThemeContrast.worst(theme) {
                let bar = check.text.isSystem ? ThemeContrast.requiredForSystemText : ThemeContrast.required
                #expect(check.ratio >= bar, "\(entry.id) \(kind) \(level)")
                print("contrast \(entry.id) \(kind.rawValue) \(level.rawValue) \(ThemeContrast.Check.ratioText(check.ratio)) \(check.place) \(check.backdrop)")
            }
        }
    }

    /// Text on the bars is checked over the bars' fill laid on the surface, in every theme.
    @Test func textOnTheBarsIsChecked() throws {
        for entry in BuiltInThemes.all {
            let theme = try #require(entry.theme)
            let onBars = ThemeContrast.checks(theme).filter { $0.place == "on the bars" }
            #expect(Set(onBars.map(\.level)) == [.primary, .secondary], "\(entry.id)")
            #expect(onBars.allSatisfy { $0.passes }, "\(entry.id)")
        }
        let hard = try Theme.parse(darkThemeFile().replacingOccurrences(
            of: "\"badge\": \"#FFFFFF14\" }", with: "\"badge\": \"#FFFFFF14\" },\n    \"bar\": \"#E0E4EA\""))
        #expect(ThemeContrast.failures(hard).contains { $0.place == "on the bars" })
    }

    /// Text in the pill is checked over the field's fill laid on the bars' fill, in every theme.
    @Test func textInTheFieldIsChecked() throws {
        for entry in BuiltInThemes.all {
            let theme = try #require(entry.theme)
            let inField = ThemeContrast.checks(theme).filter { $0.place == "in the text field" }
            #expect(Set(inField.map(\.level)) == [.primary, .secondary], "\(entry.id)")
            #expect(inField.allSatisfy { $0.passes }, "\(entry.id)")
        }
        let hard = try Theme.parse(darkThemeFile().replacingOccurrences(
            of: "\"badge\": \"#FFFFFF14\" }",
            with: "\"badge\": \"#FFFFFF14\" },\n    \"field\": { \"fill\": \"#E0E4EA\", \"edge\": \"#FFFFFF\" }"))
        #expect(ThemeContrast.failures(hard).contains { $0.place == "in the text field" })
        #expect(!ThemeContrast.failures(hard).contains { $0.place == "on the bars" })
    }

    @Test func everyHexBuiltInThemeMeetsAAWithoutTheSystemAllowance() throws {
        for entry in BuiltInThemes.all where entry.id != "glass" {
            let theme = try #require(entry.theme)
            for check in ThemeContrast.checks(theme) {
                #expect(!check.text.isSystem)
                #expect(check.ratio >= 4.5, "\(entry.id): \(check.failureText)")
            }
        }
    }

    @Test func glassAndBlurAreCheckedOverBlackAndWhite() throws {
        let theme = try Theme.parse(darkThemeFile())
        let backdrops = Set(ThemeContrast.checks(theme).map(\.backdrop))
        #expect(backdrops == ["over the fallback fill", "with the tint over a black backdrop", "with the tint over a white backdrop"])
        let solid = try #require(BuiltInThemes.all.first { $0.id == "graphite" }?.theme)
        #expect(Set(ThemeContrast.checks(solid).map(\.backdrop)) == ["on the solid fill"])
    }

    @Test func aWeakTintFailsWithLightTextAndSaysByHowMuch() throws {
        let theme = try Theme.parse(darkThemeFile(tint: "#10182840"))
        let failures = ThemeContrast.failures(theme)
        #expect(!failures.isEmpty)
        #expect(failures.allSatisfy { $0.backdrop == "with the tint over a white backdrop" })
        let first = try #require(failures.first)
        #expect(first.failureText.hasPrefix("dark: primary text #F2F4F8 on the surface with the tint over a white backdrop is "))
        #expect(first.failureText.contains("It needs 4.50:1, so it is "))
        #expect(first.failureText.hasSuffix(" short."))
    }

    @Test func textTooCloseToItsBoxFails() throws {
        let theme = try Theme.parse(darkThemeFile(secondary: "#4A5160"))
        let places = Set(ThemeContrast.failures(theme).filter { $0.level == .secondary }.map(\.place))
        #expect(places.contains("in the agent's reply box"))
        #expect(places.contains("on the incognito line"))
    }

    @Test func systemLabelsOnGlassAreCheckedOverTheFallbackOnly() throws {
        let checks = ThemeContrast.checks(BuiltInThemes.glass)
        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.backdrop == "over the fallback fill" && $0.required == 3 })
    }
}

@Suite struct ThemeLibraryTests {
    @Test func builtInThemesComeFirstThenFilesByName() {
        let sandbox = ThemeSandbox()
        sandbox.write("zebra.json", darkThemeFile(name: "Aurora"))
        sandbox.write("night-swim.json", darkThemeFile())
        sandbox.write("notes.txt", "not a theme")
        let ids = sandbox.library.entries().map(\.id)
        #expect(ids == BuiltInThemes.ids + ["zebra", "night-swim"])
        #expect(sandbox.library.entry(id: "zebra")?.name == "Aurora")
        #expect(sandbox.library.entry(id: "zebra")?.isBuiltIn == false)
    }

    @Test func brokenFilesAreListedWithTheirProblem() {
        let sandbox = ThemeSandbox()
        sandbox.write("half-done.json", "{ \"format\": 1 ")
        sandbox.write("Bad Name.json", darkThemeFile())
        sandbox.write("glass.json", darkThemeFile())
        let entries = sandbox.library.fileEntries()
        #expect(entries.first { $0.id == "half-done" }?.problem == "The file is not valid JSON.")
        #expect(entries.first { $0.id == "Bad Name" }?.problem?.contains("lowercase letters") == true)
        #expect(entries.first { $0.id == "glass" }?.problem == "A built-in theme already has the id glass. Rename the file.")
        #expect(entries.allSatisfy { $0.theme == nil })
        // A broken or missing theme draws as Glass.
        #expect(sandbox.library.theme(id: "half-done") == BuiltInThemes.glass)
        #expect(sandbox.library.theme(id: "missing") == BuiltInThemes.glass)
    }

    @Test func saveWritesTheFileAndBuiltInsCannotBeWritten() throws {
        let sandbox = ThemeSandbox()
        let theme = try Theme.parse(darkThemeFile())
        let id = try sandbox.library.save(theme)
        #expect(id == "night-swim")
        let text = try String(contentsOf: sandbox.folder.appending(path: "night-swim.json"), encoding: .utf8)
        #expect(text == theme.fileText)
        #expect(sandbox.library.entry(id: id)?.theme == theme)
        var renamed = theme
        renamed.name = "Glass"
        #expect(throws: ThemeLibraryError.self) { try sandbox.library.save(renamed) }
        #expect(throws: ThemeLibraryError.self) { try sandbox.library.delete(id: "glass") }
    }

    @Test func duplicateMakesANewNameAndDeleteRemovesTheFile() throws {
        let sandbox = ThemeSandbox()
        let first = try sandbox.library.duplicate(id: "tidewater")
        let second = try sandbox.library.duplicate(id: "tidewater")
        #expect(first == "tidewater-copy")
        #expect(second == "tidewater-copy-2")
        #expect(sandbox.library.entry(id: first)?.name == "Tidewater Copy")
        #expect(sandbox.library.entry(id: first)?.theme?.dark == BuiltInThemes.all[1].theme?.dark)
        try sandbox.library.delete(id: first)
        #expect(sandbox.library.entry(id: first) == nil)
        #expect(throws: ThemeLibraryError.self) { try sandbox.library.delete(id: first) }
    }

    @Test func preferencesDefaultToGlassWithGlassOn() {
        let sandbox = ThemeSandbox()
        #expect(sandbox.preferences.themeID == "glass")
        #expect(sandbox.preferences.usesGlass)
        sandbox.preferences.setThemeID("paper")
        sandbox.preferences.setUsesGlass(false)
        #expect(ThemePreferences(suiteName: sandbox.suiteName).themeID == "paper")
        #expect(ThemePreferences(suiteName: sandbox.suiteName).usesGlass == false)
    }
}

@Suite struct ThemeToolTests {
    @Test func readListsTheThemesAndTheFormat() async {
        let sandbox = ThemeSandbox()
        sandbox.write("broken.json", "{}")
        let text = await sandbox.read.run(arguments: ["theme_id": nil], context: context())
        #expect(text.hasPrefix("The panel uses Glass (glass). Use glass is on in Settings."))
        #expect(text.contains("- tidewater: Tidewater, built in, dark only"))
        #expect(text.contains("- glass: Glass, built in, light and dark"))
        #expect(text.contains("- broken: cannot be read. The file has no format."))
        #expect(text.contains("Colors are #RRGGBB or #RRGGBBAA"))
    }

    @Test func readOneThemeGivesItsWholeFile() async throws {
        let sandbox = ThemeSandbox()
        let text = await sandbox.read.run(arguments: ["theme_id": "Paper"], context: context())
        let file = try #require(text.components(separatedBy: "Its file:\n").last)
        #expect(try Theme.parse(file) == BuiltInThemes.all[3].theme)
        #expect(text.hasPrefix("paper is a built-in theme, which cannot be changed."))
        #expect(await sandbox.read.run(arguments: ["theme_id": "nope"], context: context()).hasPrefix("Error: there is no theme nope."))
    }

    @Test func saveAndApplyWritesAValidFileAndPicksIt() async throws {
        let sandbox = ThemeSandbox()
        let result = await sandbox.change.run(arguments: ["action": "save_and_apply", "theme_id": nil, "file": .string(darkThemeFile())], context: context())
        #expect(result == "Saved Night Swim as night-swim and applied it to the panel.")
        #expect(sandbox.preferences.themeID == "night-swim")
        let written = try String(contentsOf: sandbox.folder.appending(path: "night-swim.json"), encoding: .utf8)
        #expect(try Theme.parse(written) == Theme.parse(darkThemeFile()))
    }

    @Test func saveReplacesAnExistingThemeByID() async throws {
        let sandbox = ThemeSandbox()
        _ = await sandbox.change.run(arguments: ["action": "save", "theme_id": nil, "file": .string(darkThemeFile())], context: context())
        let result = await sandbox.change.run(arguments: ["action": "save", "theme_id": "night-swim", "file": .string(darkThemeFile(name: "Night Swim Two"))], context: context())
        #expect(result == "Saved Night Swim Two as night-swim.")
        #expect(sandbox.library.entry(id: "night-swim")?.name == "Night Swim Two")
        #expect(sandbox.preferences.themeID == "glass")
        let missing = await sandbox.change.run(arguments: ["action": "save", "theme_id": "nothing-here", "file": .string(darkThemeFile())], context: context())
        #expect(missing.hasPrefix("Error: there is no theme nothing-here to replace."))
    }

    @Test func malformedOrUnreadableThemesAreNeverWritten() async {
        let sandbox = ThemeSandbox()
        let malformed = await sandbox.change.run(arguments: ["action": "save", "theme_id": nil, "file": "{ \"format\": 1, \"name\": \"X\" }"], context: context())
        #expect(malformed.hasPrefix("Error: the theme was not saved. The theme defines neither light nor dark."))
        let unreadable = await sandbox.change.run(arguments: ["action": "save", "theme_id": nil, "file": .string(darkThemeFile(secondary: "#3A404C"))], context: context())
        #expect(unreadable.hasPrefix("Error: the theme was not saved."))
        #expect(unreadable.contains("too hard to read:"))
        #expect(unreadable.contains("- dark: secondary text #3A404C on the surface over the fallback fill is "))
        #expect(unreadable.hasSuffix("Change those colors and save again."))
        let empty = await sandbox.change.run(arguments: ["action": "save", "theme_id": nil, "file": nil], context: context())
        #expect(empty == "Error: a save needs the whole theme file in file.")
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder.plainPath))
    }

    @Test func builtInThemesCannotBeOverwrittenOrDeleted() async throws {
        let sandbox = ThemeSandbox()
        let overwrite = await sandbox.change.run(arguments: ["action": "save", "theme_id": nil, "file": .string(darkThemeFile(name: "Tidewater"))], context: context())
        #expect(overwrite.hasPrefix("Error: Tidewater is a built-in theme, which cannot be changed."))
        let byID = await sandbox.change.run(arguments: ["action": "save", "theme_id": "glass", "file": .string(darkThemeFile())], context: context())
        #expect(byID.hasPrefix("Error: Glass is a built-in theme"))
        let asked = AskedLog()
        let delete = await sandbox.change.run(arguments: ["action": "delete", "theme_id": "paper", "file": nil], context: context(asked: asked))
        #expect(delete == "Error: Paper is a built-in theme, which cannot be deleted.")
        #expect(asked.all.isEmpty)
    }

    @Test func applyPicksAThemeByIDOrName() async {
        let sandbox = ThemeSandbox()
        #expect(await sandbox.change.run(arguments: ["action": "apply", "theme_id": "High Contrast", "file": nil], context: context()) == "Applied High Contrast to the panel.")
        #expect(sandbox.preferences.themeID == "high-contrast")
        #expect(await sandbox.change.run(arguments: ["action": "apply", "theme_id": "none", "file": nil], context: context()).hasPrefix("Error: there is no theme none."))
        sandbox.write("broken.json", "{}")
        #expect(await sandbox.change.run(arguments: ["action": "apply", "theme_id": "broken", "file": nil], context: context()).hasPrefix("Error: the file for broken cannot be read"))
        #expect(sandbox.preferences.themeID == "high-contrast")
    }

    @Test func deleteAsksFirstAndFallsBackToGlass() async {
        let sandbox = ThemeSandbox()
        _ = await sandbox.change.run(arguments: ["action": "save_and_apply", "theme_id": nil, "file": .string(darkThemeFile())], context: context())
        let asked = AskedLog()
        let declined = await sandbox.change.run(arguments: ["action": "delete", "theme_id": "night-swim", "file": nil], context: context(approving: false, asked: asked))
        #expect(declined == "The owner declined. Night Swim is still there.")
        #expect(asked.all.map(\.kind) == [.deleteTheme])
        #expect(asked.all.map(\.body) == [.item(name: "Night Swim", detail: "themes/night-swim.json")])
        #expect(asked.all.first?.prompt == "Delete this theme? It removes its file from the themes folder.")
        #expect(asked.all.first?.approveTitle == "Delete")
        #expect(asked.all.first?.declineTitle == "Don’t Delete")
        #expect(asked.all.first?.waitingText == "waiting for your go-ahead to delete the theme Night Swim")
        #expect(sandbox.library.entry(id: "night-swim") != nil)
        let deleted = await sandbox.change.run(arguments: ["action": "delete", "theme_id": "night-swim", "file": nil], context: context())
        #expect(deleted == "Deleted Night Swim. It was the panel's theme, so the panel is back on Glass.")
        #expect(sandbox.preferences.themeID == "glass")
        #expect(sandbox.library.entry(id: "night-swim") == nil)
    }

    @Test func theToolsAreLastInTheirOwnGroupWithSmallStrictSchemas() {
        let sandbox = ThemeSandbox()
        let tools = BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: []), system: FakeSystemControl(), themes: sandbox.library, themePreferences: sandbox.preferences)
        // The appearance tools come just before the action and memory tools, which were added after them.
        let appearance = Array(tools.dropLast(4).suffix(2))
        #expect(appearance.map(\.definition.name) == [ReadThemesTool.name, ChangeThemeTool.name])
        #expect(appearance.allSatisfy { $0.source == .appearance })
        var characters = 0
        for tool in appearance {
            let definition = tool.definition
            #expect(definition.parameters["additionalProperties"] == false)
            let encoded: JSONValue = ["type": "function", "name": .string(definition.name), "description": .string(definition.description), "parameters": definition.parameters, "strict": true]
            characters += encoded.encodedString().count
        }
        print("appearance tools add \(characters) characters to each request")
        #expect(characters < 1200)
    }

    @Test func theFixedInstructionsMentionTheThemeTools() {
        let text = AgentInstructions.fixed(skills: [], skillsFolder: URL(filePath: "/tmp/skills"))
        #expect(text.contains("When the person asks to change how the panel looks, make and apply a theme with read_themes and change_theme."))
    }
}
