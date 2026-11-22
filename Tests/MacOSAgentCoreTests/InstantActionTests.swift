import Foundation
import Testing
@testable import MacOSAgentCore

private func app(_ name: String, _ identifier: String?, _ folder: String = "/Applications", alternates: [String] = [], system: Bool = false) -> InstalledApplication {
    InstalledApplication(
        name: name, bundleIdentifier: identifier,
        url: URL(filePath: "\(folder)/\(name).app", directoryHint: .isDirectory), alternateNames: alternates,
        isSystemComponent: system)
}

/// A Mac with the apps macOS ships and a typical set of others, in the catalog's folder order.
let standInApplications: [InstalledApplication] = [
    app("1Password", "com.1password.1password"),
    app("Affinity Photo 2", "com.seriflabs.affinityphoto2"),
    app("Arc", "company.thebrowser.Browser"),
    app("ChatGPT", "com.openai.chat"),
    app("Claude", "com.anthropic.claudefordesktop"),
    app("Cursor", "com.todesktop.230313mzl4w4u92"),
    app("Discord", "com.hnc.Discord"),
    app("Docker", "com.docker.docker"),
    app("Fantastical", "com.flexibits.fantastical2.mac"),
    app("Figma", "com.figma.Desktop"),
    app("Firefox", "org.mozilla.firefox"),
    app("GarageBand", "com.apple.garageband10"),
    app("Ghostty", "com.mitchellh.ghostty"),
    app("Google Chrome", "com.google.Chrome"),
    app("Google Chrome Canary", "com.google.Chrome.canary"),
    app("Google Drive", "com.google.drivefs"),
    app("iMovie", "com.apple.iMovieApp"),
    app("iTerm", "com.googlecode.iterm2", alternates: ["iTerm2"]),
    app("Keynote", "com.apple.iWork.Keynote"),
    app("Linear", "com.linear"),
    app("Microsoft Excel", "com.microsoft.Excel"),
    app("Microsoft Outlook", "com.microsoft.Outlook"),
    app("Microsoft PowerPoint", "com.microsoft.Powerpoint"),
    app("Microsoft Teams", "com.microsoft.teams2"),
    app("Microsoft Word", "com.microsoft.Word"),
    app("Notion", "notion.id"),
    app("Notion Calendar", "com.cron.electron"),
    app("Numbers", "com.apple.iWork.Numbers"),
    app("Obsidian", "md.obsidian"),
    app("Pages", "com.apple.iWork.Pages"),
    app("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x"),
    app("Raycast", "com.raycast.macos"),
    app("Safari Technology Preview", "com.apple.SafariTechnologyPreview"),
    app("Signal", "org.whispersystems.signal-desktop"),
    app("Slack", "com.tinyspeck.slackmacgap"),
    app("Spotify", "com.spotify.client"),
    app("Telegram", "ru.keepcoder.Telegram"),
    app("Things 3", "com.culturedcode.ThingsMac"),
    app("Visual Studio Code", "com.microsoft.VSCode", alternates: ["Code"]),
    app("WhatsApp", "net.whatsapp.WhatsApp"),
    app("Xcode", "com.apple.dt.Xcode"),
    app("zoom.us", "us.zoom.xos"),
    app("App Store", "com.apple.AppStore", "/System/Applications"),
    app("Automator", "com.apple.Automator", "/System/Applications"),
    app("Books", "com.apple.iBooksX", "/System/Applications"),
    app("Calculator", "com.apple.calculator", "/System/Applications"),
    app("Calendar", "com.apple.iCal", "/System/Applications"),
    app("Chess", "com.apple.Chess", "/System/Applications"),
    app("Clock", "com.apple.clock", "/System/Applications"),
    app("Contacts", "com.apple.AddressBook", "/System/Applications"),
    app("Dictionary", "com.apple.Dictionary", "/System/Applications"),
    app("FaceTime", "com.apple.FaceTime", "/System/Applications"),
    app("Find My", "com.apple.findmy", "/System/Applications"),
    app("Font Book", "com.apple.FontBook", "/System/Applications"),
    app("Freeform", "com.apple.freeform", "/System/Applications"),
    app("Games", "com.apple.games", "/System/Applications"),
    app("Home", "com.apple.Home", "/System/Applications"),
    app("Image Capture", "com.apple.Image_Capture", "/System/Applications"),
    app("Image Playground", "com.apple.GenerativePlaygroundApp", "/System/Applications"),
    app("iPhone Mirroring", "com.apple.ScreenContinuity", "/System/Applications"),
    app("Journal", "com.apple.journal", "/System/Applications"),
    app("Launchpad", "com.apple.launchpad.launcher", "/System/Applications"),
    app("Mail", "com.apple.mail", "/System/Applications"),
    app("Maps", "com.apple.Maps", "/System/Applications"),
    app("Messages", "com.apple.MobileSMS", "/System/Applications"),
    app("Mission Control", "com.apple.exposelauncher", "/System/Applications"),
    app("Music", "com.apple.Music", "/System/Applications"),
    app("News", "com.apple.news", "/System/Applications"),
    app("Notes", "com.apple.Notes", "/System/Applications"),
    app("Passwords", "com.apple.Passwords", "/System/Applications"),
    app("Phone", "com.apple.mobilephone", "/System/Applications"),
    app("Photo Booth", "com.apple.PhotoBooth", "/System/Applications"),
    app("Photos", "com.apple.Photos", "/System/Applications"),
    app("Podcasts", "com.apple.podcasts", "/System/Applications"),
    app("Preview", "com.apple.Preview", "/System/Applications"),
    app("QuickTime Player", "com.apple.QuickTimePlayerX", "/System/Applications"),
    app("Reminders", "com.apple.reminders", "/System/Applications"),
    app("Shortcuts", "com.apple.shortcuts", "/System/Applications"),
    app("Siri", "com.apple.siri.launcher", "/System/Applications"),
    app("Stickies", "com.apple.Stickies", "/System/Applications"),
    app("Stocks", "com.apple.stocks", "/System/Applications"),
    app("System Settings", "com.apple.systempreferences", "/System/Applications"),
    app("TextEdit", "com.apple.TextEdit", "/System/Applications"),
    app("Time Machine", "com.apple.backup.launcher", "/System/Applications"),
    app("Tips", "com.apple.tips", "/System/Applications"),
    app("TV", "com.apple.TV", "/System/Applications"),
    app("Voice Memos", "com.apple.VoiceMemos", "/System/Applications"),
    app("Weather", "com.apple.weather", "/System/Applications"),
    app("Activity Monitor", "com.apple.ActivityMonitor", "/System/Applications/Utilities"),
    app("Console", "com.apple.Console", "/System/Applications/Utilities"),
    app("Disk Utility", "com.apple.DiskUtility", "/System/Applications/Utilities"),
    app("Keychain Access", "com.apple.keychainaccess", "/System/Applications/Utilities"),
    app("Screen Sharing", "com.apple.ScreenSharing", "/System/Applications/Utilities"),
    app("Screenshot", "com.apple.screenshot.launcher", "/System/Applications/Utilities"),
    app("Script Editor", "com.apple.ScriptEditor2", "/System/Applications/Utilities"),
    app("Terminal", "com.apple.Terminal", "/System/Applications/Utilities"),
    app("Safari", "com.apple.Safari", "/System/Cryptexes/App/System/Applications"),
    app("Finder", "com.apple.finder", "/System/Library/CoreServices", system: true),
]

private let engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: standInApplications)])

private func offered(_ input: String, history: InstantActionHistory = InstantActionHistory(), now: Date = Date()) -> [String] {
    engine.suggestion(for: input, history: history, now: now)?.choices.map(\.title) ?? []
}

@Suite struct InstantActionPhraseTests {
    let verbs = ApplicationInstantActions.launchVerbs

    @Test func readsAVerbAndASubject() throws {
        let phrase = try #require(InstantPhrase.parse("  Open   Safari ", verbs: verbs))
        #expect(phrase.verb == "open")
        #expect(phrase.subject == "Safari")
        #expect(phrase.text == "Open Safari")
        #expect(phrase.key == "safari")
    }

    @Test func readsATwoWordVerbBeforeAOneWordOne() throws {
        let phrase = try #require(InstantPhrase.parse("switch to slack", verbs: verbs))
        #expect(phrase.verb == "switch to")
        #expect(phrase.subject == "slack")
        let goTo = try #require(InstantPhrase.parse("go to messages", verbs: verbs))
        #expect(goTo.verb == "go to")
    }

    @Test func aVerbAloneIsABareWord() throws {
        let phrase = try #require(InstantPhrase.parse("open", verbs: verbs))
        #expect(phrase.verb == nil)
        #expect(phrase.subject == "open")
    }

    @Test func sentencesAndLongInputHaveNoShape() {
        for input in [
            "", "   ", "what is safari?", "open safari, then mail", "safari.", "xcode!", "/new", "/usr/bin is slow",
            "open \"safari\"", "what's up", "open safari\nplease", "one two three four five",
            "open one two three four five", String(repeating: "a", count: 60), "...", "100%", "x = 1",
        ] {
            #expect(InstantPhrase.parse(input, verbs: verbs) == nil, "\(input)")
        }
    }

    @Test func aFullStopInsideANameIsFine() throws {
        let phrase = try #require(InstantPhrase.parse("zoom.us", verbs: verbs))
        #expect(phrase.subject == "zoom.us")
    }
}

@Suite struct InstantActionRuleTests {
    /// Launch requests, each with the app the row offers first.
    static let launches: [(String, String)] = [
        ("safari", "Safari"), ("Safari", "Safari"), ("SAFARI", "Safari"), ("open safari", "Safari"),
        ("Open Safari", "Safari"), ("saf", "Safari"), ("safa", "Safari"), ("launch xcode", "Xcode"),
        ("xcode", "Xcode"), ("xc", "Xcode"), ("start spotify", "Spotify"), ("spot", "Spotify"),
        ("switch to slack", "Slack"), ("slack", "Slack"), ("go to messages", "Messages"),
        ("bring up notes", "Notes"), ("notes", "Notes"), ("calc", "Calculator"), ("calculator", "Calculator"),
        ("cal", "Calendar"), ("calendar", "Calendar"), ("term", "Terminal"), ("terminal", "Terminal"),
        ("chrome", "Google Chrome"), ("open chrome", "Google Chrome"), ("google chrome", "Google Chrome"),
        ("vs code", "Visual Studio Code"), ("vscode", "Visual Studio Code"), ("vsc", "Visual Studio Code"),
        ("visual studio", "Visual Studio Code"), ("open code", "Visual Studio Code"), ("open word", "Microsoft Word"),
        ("excel", "Microsoft Excel"), ("powerpoint", "Microsoft PowerPoint"), ("outlook", "Microsoft Outlook"),
        ("zoom", "zoom.us"), ("open zoom", "zoom.us"), ("1password", "1Password"), ("1pass", "1Password"),
        ("system settings", "System Settings"), ("settings", "System Settings"), ("open settings", "System Settings"),
        ("activity monitor", "Activity Monitor"), ("finder", "Finder"), ("open finder", "Finder"),
        ("mail", "Mail"), ("music", "Music"), ("photos", "Photos"), ("maps", "Maps"), ("weather", "Weather"),
        ("news", "News"), ("home", "Home"), ("preview", "Preview"), ("pages", "Pages"), ("numbers", "Numbers"),
        ("photo booth", "Photo Booth"), ("find my", "Find My"), ("open find my", "Find My"),
        ("figma", "Figma"), ("notion", "Notion"), ("obsidian", "Obsidian"), ("discord", "Discord"),
        ("whatsapp", "WhatsApp"), ("chatgpt", "ChatGPT"), ("keyn", "Keynote"), ("garage", "GarageBand"),
        ("garageband", "GarageBand"), ("keychain", "Keychain Access"), ("disk utility", "Disk Utility"),
        ("textedit", "TextEdit"), ("quicktime", "QuickTime Player"), ("iterm", "iTerm"), ("iterm2", "iTerm"),
        ("ghostty", "Ghostty"), ("things", "Things 3"), ("teams", "Microsoft Teams"), ("open teams", "Microsoft Teams"),
        ("launch firefox", "Firefox"), ("start docker", "Docker"), ("app store", "App Store"),
        ("open app store", "App Store"), ("facetime", "FaceTime"), ("reminders", "Reminders"),
        ("open s", "Siri"), ("screenshot", "Screenshot"), ("dict", "Dictionary"), ("pixelmator", "Pixelmator Pro"), ("time machine", "Time Machine"),
    ]

    @Test func everyLaunchRequestOffersTheApp() {
        for (input, expected) in Self.launches {
            let choices = offered(input)
            #expect(choices.first == expected, "\(input) offered \(choices)")
            #expect(choices.count <= InstantActionRule.maximumChoices)
        }
    }

    /// Messages a person sends an agent. None of them may offer anything.
    static let messages: [String] = [
        // Questions and requests that mention an app.
        "what is safari", "is xcode running", "open safari and go to hacker news", "open safari, then hacker news",
        "quit slack", "close safari", "delete zoom", "hide spotify", "update xcode", "uninstall chrome",
        "safari is slow", "xcode?", "safari.", "why is mail slow", "make chrome the default",
        "use chrome", "use chrome instead", "what about chrome", "open chrome to github", "open zoom and mute",
        "open a new safari window", "open safari please", "please open safari",
        // Requests that start with a launch verb but are not about an app.
        "open the door", "open it", "open this", "open that file", "open my email", "open downloads",
        "open the downloads folder", "open a new window", "open new tab", "start a timer", "start over",
        "start again", "launch the rocket", "switch to dark mode", "switch to light mode", "go to bed",
        "go to sleep", "go to the desktop", "bring up the volume", "start now", "open up", "open all",
        // Ordinary requests to the agent.
        "change the wallpaper to a sunset", "find the screenshot I took this morning", "what time is it",
        "make a folder on the desktop called Receipts", "how much disk space do I have", "empty the trash",
        "turn on do not disturb", "lock the screen", "remind me to call mom", "play some music", "play music",
        "set volume to 50", "dark mode", "set a timer", "summarize this page", "translate hello",
        "call mom", "email bob", "text sarah", "maps to the airport", "show my calendar", "show notes",
        "new note", "new reminder", "list my reminders", "do it", "try again", "never mind", "go ahead",
        "sounds good", "looks good", "good job", "nice work", "no thanks", "not now", "maybe later",
        "thank you", "keep going", "carry on", "what happened", "undo that", "and then", "that one",
        // One word replies and everyday words that start an app's name.
        "help", "find", "search", "thanks", "thx", "ok", "okay", "y", "n", "k", "no", "yes", "sure", "go",
        "stop", "what", "hi", "hey", "hello", "test", "status", "pass", "password", "short", "shortcut",
        "photo", "screen", "time", "image", "message", "text", "note", "system", "activity",
        "chat", "code", "word", "desktop", "game", "font", "key", "voice", "monitor", "sleep", "restart",
        "mute", "open", "launch", "start", "switch", "continue", "cancel", "retry", "next", "more", "again",
        "it", "is", "the", "a", "i", "s", "x", "q", "1", "42", "pic", "remind", "phone call",
        // Commands and code.
        "/new", "/incognito", "/usr/bin is slow", "ls -la", "rm -rf ~/Downloads", "~/Desktop",
        "open ~/Desktop", "open https://example.com", "brew install wget",
    ]

    @Test func noMessageOffersAnything() {
        for input in Self.messages {
            let choices = offered(input)
            #expect(choices.isEmpty, "\(input) offered \(choices)")
        }
    }

    @Test func aBareExactNameIsOfferedAlone() {
        #expect(offered("notion") == ["Notion"])
        #expect(offered("calendar") == ["Calendar"])
        #expect(offered("safari") == ["Safari"])
    }

    @Test func closeMatchesAreOfferedToChooseBetweenWithTheBestFirst() {
        #expect(offered("saf") == ["Safari", "Safari Technology Preview"])
        #expect(offered("cal") == ["Calendar", "Calculator"], "Notion Calendar only has the word, a weaker match")
        // The shorter name first when the matches are equal.
        #expect(offered("google") == ["Google Drive", "Google Chrome", "Google Chrome Canary"])
        #expect(offered("open s").count == InstantActionRule.maximumChoices)
    }

    @Test func aShortBareInputWithNoClearLeaderOffersNothing() {
        // Safari and Safari Technology Preview start the same way.
        #expect(offered("sa").isEmpty)
        // Phone, Photos, and Photo Booth.
        #expect(offered("ph").isEmpty)
    }

    @Test func aShortBareInputWithOneMatchIsOffered() {
        #expect(offered("xc") == ["Xcode"])
        #expect(offered("1p") == ["1Password"])
    }

    @Test func initialsNeedThreeLettersWithoutAVerb() {
        #expect(offered("vsc") == ["Visual Studio Code"])
        #expect(offered("gc").isEmpty)
        #expect(offered("open gc").first == "Google Chrome")
    }

    @Test func aTypoIsLeftToTheAgent() {
        // The agent's search tolerates these. The instant path does not guess.
        #expect(offered("safar").first == "Safari") // still a prefix
        #expect(offered("crome").isEmpty)
        #expect(offered("open crome").isEmpty)
        #expect(offered("sfari").isEmpty)
    }

    @Test func aSecondCopyWithTheSameNameIsLeftOut() {
        let copies = standInApplications + [app("Safari", "com.apple.Safari", "/Users/someone/Applications")]
        let engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: copies)])
        let choices = engine.suggestion(for: "safari")?.choices ?? []
        #expect(choices.map(\.title) == ["Safari"])
        #expect(choices.first?.id == "application:/System/Cryptexes/App/System/Applications/Safari.app")
    }

    @Test func aRunningAppWinsATie() {
        let slack = "/Applications/Slack.app"
        let provider = ApplicationInstantActions(applications: standInApplications, runningPaths: [slack])
        let engine = InstantActionEngine(providers: [provider])
        #expect(engine.suggestion(for: "open s")?.top.title == "Slack")
    }

    @Test func theSuggestionNamesTheInputItAnswers() throws {
        let suggestion = try #require(engine.suggestion(for: "open safari"))
        #expect(suggestion.input == "open safari")
        #expect(suggestion.phrase.key == "safari")
        #expect(suggestion.top.target.actionLabel == "opens")
        guard case .application(let application) = suggestion.top.target else { Issue.record(); return }
        #expect(application.bundleIdentifier == "com.apple.Safari")
    }

    @Test func aVerbOnlyAddressesProvidersThatTakeIt() {
        struct Other: InstantActionProvider {
            var verbs: Set<String> { ["visit"] }
            func candidates(for phrase: InstantPhrase) -> [InstantActionCandidate] {
                [InstantActionCandidate(id: "other:x", title: "Other", strength: .exact, score: 100,
                                        target: .application(standInApplications[0]))]
            }
        }
        let engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: standInApplications), Other()])
        #expect(engine.verbs.contains("visit"))
        #expect(engine.suggestion(for: "open safari")?.choices.map(\.title) == ["Safari"])
        #expect(engine.suggestion(for: "visit anything")?.choices.map(\.title) == ["Other"])
    }
}

@Suite struct InstantActionLearningTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let safari = "application:/System/Cryptexes/App/System/Applications/Safari.app"
    let slack = "application:/Applications/Slack.app"
    let spotify = "application:/Applications/Spotify.app"

    @Test func aSingleLetterOpensWhatTheOwnerTookForItBefore() {
        #expect(offered("s").isEmpty)
        var safariOwner = InstantActionHistory()
        safariOwner.record(safari, subject: "s", at: now)
        #expect(offered("s", history: safariOwner, now: now) == ["Safari"])
        var slackOwner = InstantActionHistory()
        slackOwner.record(slack, subject: "s", at: now)
        #expect(offered("s", history: slackOwner, now: now) == ["Slack"])
    }

    @Test func aPickForOneSubjectDoesNotUnlockAnother() {
        var history = InstantActionHistory()
        history.record(safari, subject: "s", at: now)
        #expect(offered("x", history: history, now: now).isEmpty)
        #expect(offered("sa", history: history, now: now).isEmpty, "two letters with two close matches stay ambiguous")
    }

    @Test func aPickMakesItTheOnlyChoiceNextTime() {
        #expect(offered("saf").count == 2)
        var history = InstantActionHistory()
        history.record("application:/Applications/Safari Technology Preview.app", subject: "saf", at: now)
        #expect(offered("saf", history: history, now: now) == ["Safari Technology Preview"])
    }

    @Test func frequentUseReordersTheChoices() {
        #expect(offered("open s").first == "Siri")
        var history = InstantActionHistory()
        for day in 0..<4 { history.record(spotify, subject: "spotify", at: now.addingTimeInterval(-Double(day) * 3600)) }
        #expect(offered("open s", history: history, now: now).first == "Spotify")
    }

    @Test func useAloneNeverPutsAPrefixAheadOfAnExactName() {
        var history = InstantActionHistory()
        for _ in 0..<10 { history.record("application:/Applications/Notion Calendar.app", subject: "notion calendar", at: now) }
        #expect(offered("notion", history: history, now: now) == ["Notion"])
    }

    @Test func aPickCanPutAPrefixAheadOfAnExactName() {
        var history = InstantActionHistory()
        history.record("application:/Applications/Notion Calendar.app", subject: "notion", at: now)
        #expect(offered("notion", history: history, now: now).first == "Notion Calendar")
    }

    @Test func aPickLiftsTheEverydayWordLimitButNotTheFunctionWordRule() {
        #expect(offered("code").isEmpty)
        var history = InstantActionHistory()
        history.record("application:/Applications/Visual Studio Code.app", subject: "code", at: now)
        #expect(offered("code", history: history, now: now) == ["Visual Studio Code"])
        history.record(safari, subject: "the", at: now)
        #expect(offered("the", history: history, now: now).isEmpty)
    }

    @Test func useCountsLessAsItAges() {
        var history = InstantActionHistory()
        for _ in 0..<4 { history.record(slack, subject: "slack", at: now) }
        #expect(history.useBoost(for: slack, now: now) == InstantActionHistory.maximumUseBoost)
        #expect(history.useBoost(for: slack, now: now.addingTimeInterval(3 * 24 * 3600)) == 5)
        #expect(history.useBoost(for: slack, now: now.addingTimeInterval(60 * 24 * 3600)) == 1)
        #expect(history.useBoost(for: spotify, now: now) == 0)
    }

    @Test func picksGrowWithUseAndFadeWithTime() {
        var history = InstantActionHistory()
        history.record(slack, subject: "s", at: now)
        #expect(history.pickBoost(for: slack, subject: "s", now: now) == InstantActionHistory.firstPickBoost)
        for _ in 0..<10 { history.record(slack, subject: "s", at: now) }
        #expect(history.pickBoost(for: slack, subject: "s", now: now) == InstantActionHistory.maximumPickBoost)
        #expect(history.pickBoost(for: slack, subject: "s", now: now.addingTimeInterval(100 * 24 * 3600)) == InstantActionHistory.maximumPickBoost / 2)
    }

    @Test func keepsOnlyTheRecentUsesAndTheMostRecentSubjects() {
        var history = InstantActionHistory()
        for index in 0..<(InstantActionHistory.subjectLimit + 20) {
            history.record("application:/Applications/App\(index).app", subject: "subject \(index)", at: now.addingTimeInterval(Double(index)))
        }
        #expect(history.picks.count == InstantActionHistory.subjectLimit)
        #expect(history.picks["subject 0"] == nil)
        #expect(history.picks["subject \(InstantActionHistory.subjectLimit + 19)"] != nil)
        #expect(history.uses.count == InstantActionHistory.useLimit)
        for _ in 0..<20 { history.record(slack, subject: "slack", at: now.addingTimeInterval(10_000)) }
        #expect(history.uses[slack]?.recent.count == InstantActionHistory.recentLimit)
        #expect(history.uses[slack]?.count == 20)
    }

    @Test func theStoreSavesAndReadsBack() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "instant-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "instant-actions.json")
        let store = InstantActionHistoryStore(fileURL: file)
        #expect(store.history == InstantActionHistory())
        store.record(safari, subject: "s", at: now)
        store.record(safari, subject: "saf", at: now)
        await store.waitForWrites()
        let reread = InstantActionHistoryStore(fileURL: file)
        #expect(reread.history.uses[safari]?.count == 2)
        #expect(reread.history.wasPicked(safari, for: "s"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("Safari.app"))
    }

    @Test func aDamagedFileStartsEmpty() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "instant-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "instant-actions.json")
        try Data("not json".utf8).write(to: file)
        #expect(InstantActionHistoryStore(fileURL: file).history == InstantActionHistory())
    }
}

/// Timings on this Mac's real list of installed apps. Run with MAC_OS_AGENT_MEASURE=1 set.
/// Nothing is opened.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_MEASURE"] == "1"))
struct InstantActionMeasurements {
    @Test func timesMatchingOnTheInstalledApps() {
        let catalog = ApplicationCatalog()
        let coldStart = ContinuousClock.now
        let applications = catalog.applications()
        let cold = ContinuousClock.now - coldStart
        let warmStart = ContinuousClock.now
        _ = catalog.applications()
        let warm = ContinuousClock.now - warmStart
        let prepareStart = ContinuousClock.now
        let engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: applications)])
        let prepare = ContinuousClock.now - prepareStart
        let inputs = ["s", "sa", "saf", "safa", "safari", "open safari", "calc", "vs code", "chrome",
                      "change the wallpaper to a sunset", "what is safari", "help", "find", "o", "op", "ope", "open", "open x", "open xc"]
        var worst = Duration.zero
        var total = Duration.zero
        let rounds = 50
        for _ in 0..<rounds {
            for input in inputs {
                let start = ContinuousClock.now
                _ = engine.suggestion(for: input)
                let elapsed = ContinuousClock.now - start
                total += elapsed
                worst = max(worst, elapsed)
            }
        }
        print("instant-actions: \(applications.count) apps. Catalog cold \(cold), warm \(warm). Prepare \(prepare).")
        print("instant-actions: match mean \(total / (rounds * inputs.count)), worst \(worst).")
        for input in inputs {
            print("instant-actions: \(input) -> \(engine.suggestion(for: input)?.choices.map(\.title) ?? [])")
        }
        let triggered = InstantActionRuleTests.messages.filter { engine.suggestion(for: $0) != nil }
        print("instant-actions: messages that would open an app on this Mac: \(triggered.map { "\($0) -> \(engine.suggestion(for: $0)!.choices.map(\.title))" })")
    }
}
