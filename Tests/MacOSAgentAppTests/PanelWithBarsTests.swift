import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The panel with bars and an input pill, first slice: the switch, the status line, the pill's
/// measures, the mark, and the radii. See `PanelFrame`.
@MainActor
@Suite struct PanelWithBarsTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "mac-os-agent-panel-with-bars-\(UUID().uuidString)"))
    }

    /// Off by default, and with it off nothing about the window changes: the suggestions
    /// experiment follows its own switch, and the panel keeps its radius.
    @Test func itIsOffByDefaultAndOffChangesNothing() throws {
        let session = AgentSession(previewEntries: [])
        session.preferences = try suite()
        #expect(!session.panelWithBars)
        #expect(!session.suggestionsInFooter)
        #expect(PanelFrame.cornerRadius(panelWithBars: false) == PanelShape.cornerRadius)
        Experiment.suggestionsInFieldAndFooter.set(true, session.preferences)
        #expect(session.suggestionsInFooter)
        #expect(!session.panelWithBars)
    }

    /// On, it turns on the gray completion and the status line whatever the suggestions
    /// experiment's own switch says.
    @Test func onItUsesTheSuggestionsMachineryWhateverThatSwitchSays() throws {
        let session = AgentSession(previewEntries: [])
        session.preferences = try suite()
        Experiment.panelWithBarsAndInputPill.set(true, session.preferences)
        #expect(session.panelWithBars)
        #expect(session.suggestionsInFooter)
        session.suggestionList.forcedOn = false
        #expect(session.suggestionsInFooter)

        let preview = try #require(PanelWithBarsPreview.session(named: "bars-typing"))
        #expect(preview.panelWithBars)
        #expect(!Experiment.suggestionsInFieldAndFooter.isOn(preview.preferences))
        preview.draft = "chr"
        #expect(preview.returnTarget?.title == "Google Chrome")
        #expect(preview.inlineCompletion != nil)
    }

    /// The status line leaves out the model's name, which is in the title bar, and Return while
    /// typing a message reads "↵ send". The footer of the suggestions experiment is as it was.
    @Test func theStatusLineSaysSendAndLeavesOutTheModel() {
        func make(_ state: InputFooterContent.State, statusLine: Bool) -> InputFooterContent {
            .make(state, modelName: "GPT-6 Luna", recallsMessages: true, queuesWhileRunning: false,
                  statusLine: statusLine)
        }
        let typing = make(.typing, statusLine: true)
        #expect(typing.leading.map(\.text) == ["↵ send", "⇧↵ new line"])
        #expect(typing.trailing == nil)
        #expect(make(.idle, statusLine: true).leading.map(\.text) == ["↑ earlier messages", "/ commands"])
        #expect(make(.idle, statusLine: true).trailing == nil)
        #expect(make(.running(queuedCount: 0), statusLine: true).leading.map(\.text) == ["⌘. stop"])
        #expect(make(.running(queuedCount: 0), statusLine: true).trailing == nil)
        #expect(make(.list(nil), statusLine: true).trailing?.text == "⌘↵ ask the agent")

        let footer = make(.typing, statusLine: false)
        #expect(footer.leading.map(\.text) == ["↵ ask the agent", "⇧↵ new line"])
        #expect(footer.trailing?.text == "GPT-6 Luna")
    }

    /// The pill is 38 points tall for one line with 14 point text. More lines make it taller
    /// a line at a time, up to eight, and then it stops growing.
    @Test func thePillIsThirtyEightPointsForOneLineAndGrowsToEight() {
        let metrics = InputFieldMetrics.pill
        #expect(metrics.font.pointSize == 14)
        #expect(metrics.rowHeight == 38)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 38))
        textView.font = metrics.font
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = "one line"
        #expect(metrics.height(of: textView, width: 400) == 38)
        textView.string = "one\ntwo\nthree"
        let three = metrics.height(of: textView, width: 400)
        #expect(abs(three - (metrics.lineHeight * 3 + metrics.verticalInset * 2)) <= 1)
        textView.string = (1...20).map(String.init).joined(separator: "\n")
        let most = metrics.height(of: textView, width: 400)
        #expect(abs(most - (metrics.lineHeight * CGFloat(InputField.maximumLines) + metrics.verticalInset * 2)) <= 1)
        // The standard field is as it was.
        #expect(InputFieldMetrics.standard.font.pointSize == 15)
        #expect(InputFieldMetrics.standard.rowHeight == InputField.rowHeight)
    }

    /// An inner radius is the outer radius less the gap: the panel 16, the inset 8, the pill 8,
    /// and a message 6.
    @Test func theRadiiFollowTheRule() {
        #expect(PanelFrame.cornerRadius(panelWithBars: true) == 16)
        #expect(PanelFrame.inset == 8)
        #expect(PanelFrame.pillCornerRadius == PanelFrame.panelCornerRadius - PanelFrame.inset)
        #expect(PanelFrame.pillCornerRadius == 8)
        #expect(PanelShape.messageCornerRadius == 6)
        #expect(PanelShape.surface(squareEdges: [], radius: 16).cornerRadii.topLeading == 16)
        let layer = CALayer()
        PanelShape.clipToSurface(layer, squareEdges: [.left], radius: 16)
        #expect(layer.cornerRadius == 16)
        #expect(layer.maskedCorners == PanelShape.roundedCorners(squareEdges: [.left]))
    }

    /// The logo is a triangle pointing right, close to equilateral, centered in its rect.
    @Test func theLogoIsATrianglePointingRight() {
        let rect = CGRect(x: 0, y: 0, width: 12, height: 12)
        let bounds = LogoTriangle().path(in: rect).boundingRect
        // Rounded tips trim a little from each extent.
        #expect(bounds.height > 8.5 && bounds.height <= 12, "\(bounds.height)")
        let ratio = bounds.width / bounds.height
        #expect(ratio > 0.8 && ratio < 0.92, "\(ratio)")
        #expect(abs(bounds.midY - rect.midY) < 0.5)
        #expect(LogoTriangle().path(in: rect).contains(CGPoint(x: bounds.maxX - 1.5, y: rect.midY)))
        #expect(!LogoTriangle().path(in: rect).contains(CGPoint(x: bounds.maxX - 1.5, y: bounds.minY + 1)))
    }

    /// The pill is plain on every built-in theme: its fill differs from the band's, drawn on the
    /// real window offscreen. On High Contrast, where both are near black or white, its edge is.
    @Test(arguments: [("graphite", true), ("tidewater", true), ("ember", true), ("glass", true), ("paper", false), ("high-contrast", true)])
    func thePillStandsApartFromTheBand(theme: String, dark: Bool) throws {
        let model = try PanelBarDrawing.model(theme)
        let session = try #require(PanelWithBarsPreview.session(named: "bars-rest"))
        let bitmap = try PanelBarDrawing.draw(PanelBarDrawing.panel(session, model: model), dark: dark)
        let margin = PanelBarDrawing.margin
        let size = PanelBarDrawing.size
        // The status line is at the bottom, the pill above it, and the band's top inset above that.
        let pillTop = size.height - InputFooter.height - PanelFrame.pillHeight
        let inPill = pixel(bitmap, margin + size.width / 2, margin + pillTop + PanelFrame.pillHeight / 2 + 8)
        let band = pixel(bitmap, margin + size.width / 2, margin + pillTop - PanelFrame.inset / 2)
        let edge = pixel(bitmap, margin + size.width / 2, margin + pillTop + 0.5)
        let apart = distance(inPill, band) > 6 || distance(edge, band) > 40
        #expect(apart, "\(theme): pill \(inPill), edge \(edge), band \(band)")
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> [Double] {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let color = bitmap.colorAt(x: Int((x * scale).rounded()), y: Int((y * scale).rounded()))!
        let rgb = color.usingColorSpace(.sRGB)!
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { ($0 * 255).rounded() }
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +)
    }
}

/// The panel with bars, the working row slice: the marks, the status line while a task runs,
/// and where queued messages are drawn. See `PanelWorkingRow`.
@MainActor
@Suite struct PanelWorkingRowTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "mac-os-agent-working-row-\(UUID().uuidString)"))
    }

    /// The bright mark steps left to right and wraps around, three steps a second.
    @Test func theBrightMarkStepsLeftToRightAndWraps() {
        #expect((0..<7).map(WorkingMarks.brightIndex(step:)) == [0, 1, 2, 0, 1, 2, 0])
        #expect(WorkingMarks.brightIndex(step: -1) == 2)
        #expect(WorkingMarks.strengths(step: 0, reduceMotion: false) == [1, WorkingMarks.dimStrength, WorkingMarks.dimStrength])
        #expect(WorkingMarks.strengths(step: 4, reduceMotion: false) == [WorkingMarks.dimStrength, 1, WorkingMarks.dimStrength])
        #expect(WorkingMarks.strengths(step: 5, reduceMotion: false) == [WorkingMarks.dimStrength, WorkingMarks.dimStrength, 1])
        #expect(WorkingMarks.stepsPerSecond == 3)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(WorkingMarks.step(at: start.addingTimeInterval(1)) == WorkingMarks.step(at: start) + 3)
        #expect(WorkingMarks.step(at: start.addingTimeInterval(0.3)) == WorkingMarks.step(at: start))
    }

    /// With Reduce Motion on the three marks stand still, whatever the step.
    @Test func reduceMotionHoldsTheMarksStill() {
        let still = (0..<6).map { WorkingMarks.strengths(step: $0, reduceMotion: true) }
        #expect(Set(still).count == 1)
        #expect(still[0] == [1, 1, 1])
        #expect(PanelWorkingRow.title == "Working…")
        #expect(PanelWorkingRow.spokenTitle == "Working")
        #expect(PanelWorkingRow.stopTitle == "Stop")
    }

    /// While a task runs the status line says how to stop at the left, and how to queue at the
    /// right when the queue experiment is on. There is no hint for steering.
    @Test func theStatusLineWhileATaskRuns() {
        func make(queued: Int, queues: Bool, statusLine: Bool = true) -> InputFooterContent {
            .make(.running(queuedCount: queued), modelName: "GPT-6 Luna", recallsMessages: true,
                  queuesWhileRunning: queues, statusLine: statusLine)
        }
        #expect(make(queued: 0, queues: false).leading.map(\.text) == ["⌘. stop"])
        #expect(make(queued: 0, queues: false).trailing == nil)
        #expect(make(queued: 0, queues: true).leading.map(\.text) == ["⌘. stop"])
        #expect(make(queued: 0, queues: true).trailing?.text == "↵ queue")
        #expect(make(queued: 2, queues: true).leading.map(\.text) == ["⌘. stop", "↑ edit queued"])
        #expect(make(queued: 2, queues: true).trailing?.text == "↵ queue")
        #expect(make(queued: 2, queues: true).spoken == "Command-Period, stop. Up Arrow, edit queued. Return, queue")
        for queued in [0, 2] {
            for content in [make(queued: queued, queues: true), make(queued: queued, queues: false)] {
                #expect(!(content.leading + [content.trailing].compactMap { $0 }).contains { $0.text.contains("steer") })
            }
        }
        // The suggestions experiment's footer, with the switch off, is as it was.
        let footer = make(queued: 2, queues: true, statusLine: false)
        #expect(footer.leading.map(\.text) == ["⌘. stop", "↵ queue", "↑ edit queued"])
        #expect(footer.trailing?.text == "GPT-6 Luna")
    }

    /// Queued messages are drawn in the conversation with the panel with bars on, and above the
    /// field with it off, as before. With the queue experiment off nothing is queued, so nothing
    /// is drawn with either.
    @Test(arguments: [false, true], [false, true])
    func whereQueuedMessagesAreDrawn(panelWithBars: Bool, queues: Bool) throws {
        let session = AgentSession(previewEntries: PanelWithBarsPreview.thread(), isRunning: true)
        session.preferences = try suite()
        Experiment.panelWithBarsAndInputPill.set(panelWithBars, session.preferences)
        Experiment.queueMessagesWhileRunning.set(queues, session.preferences)
        #expect(session.queuedMessagePlacement == .none)
        session.draft = "and the menu bar too"
        session.submitToAgent()
        switch (panelWithBars, queues) {
        case (_, false):
            #expect(session.queue.isEmpty)
            #expect(session.queuedMessagePlacement == .none)
        case (true, true):
            #expect(session.queuedMessagePlacement == .inConversation)
        case (false, true):
            #expect(session.queuedMessagePlacement == .aboveField)
        }
    }

    /// Edit and Remove on a queued message in the conversation do what they do above the field.
    @Test func editAndRemoveStillWork() throws {
        let session = try #require(PanelWithBarsPreview.session(named: "bars-queued"))
        #expect(session.queuedMessagePlacement == .inConversation)
        #expect(session.queue.items.map(\.text) == ["and the menu bar too", "then set an alarm for 7"])
        session.editQueued(session.queue.items[0].id)
        #expect(session.draft == "and the menu bar too")
        #expect(session.queue.items.map(\.text) == ["then set an alarm for 7"])
        session.draft = ""
        session.removeQueued(session.queue.items[0].id)
        #expect(session.queue.isEmpty)
        #expect(session.queuedMessagePlacement == .none)
    }

    /// The previews draw what they say: running, Stop under the pointer, and queued messages.
    @Test func thePreviewsRun() throws {
        for name in ["bars-running", "bars-working-hover", "bars-queued"] {
            let session = try #require(PanelWithBarsPreview.session(named: name))
            #expect(session.isRunning)
            #expect(session.panelWithBars)
        }
        #expect(try #require(PanelWithBarsPreview.session(named: "bars-working-hover")).previewHoversWorkingRow)
    }

    /// The message layout preview has what a comparison of the layouts needs: a time label,
    /// a long reply and a short one, and the lines for an app opened and quick actions run.
    @Test func theLayoutPreviewHasEveryKindOfRowTheLayoutMoves() throws {
        let rows = try #require(PanelWithBarsPreview.session(named: "bars-layout")).transcript.rows
        #expect(rows.contains { if case .user(_, _, true) = $0.kind { true } else { false } })
        #expect(rows.filter { if case .assistant = $0.kind { true } else { false } }.count == 2)
        #expect(rows.filter { if case .line = $0.kind { true } else { false } }.count == 3)
        #expect(try #require(PanelWithBarsPreview.session(named: "bars-layout-copy")).previewRevealsControls)
    }

    /// The theme model reads the message layout, keeps a change, and lets a preview show the
    /// other layout without saving it.
    @Test func theThemeModelKeepsTheMessageLayout() throws {
        let themes = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-message-layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suiteName = "mac-os-agent-message-layout-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: themes)
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let model = ThemeModel(library: ThemeLibrary(folder: themes), preferences: ThemePreferences(suiteName: suiteName))
        #expect(model.messageLayout == .sides)
        model.setMessageLayout(.fullWidth)
        #expect(model.messageLayout == .fullWidth)
        #expect(ThemePreferences(suiteName: suiteName).messageLayout == .fullWidth)
        model.previewMessageLayout = .sides
        #expect(model.messageLayout == .sides)
        #expect(ThemePreferences(suiteName: suiteName).messageLayout == .fullWidth)
    }
}

/// Renders the panel with bars offscreen, for a pull request when screen capture is not
/// available: each state in a light theme, and at rest and with a long message in each dark
/// theme. Run with MAC_OS_AGENT_RENDER_BARS set to a folder. Glass and blur are not drawn
/// offscreen, so every theme draws on its fallback fill. See `PanelBarDrawing`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] != nil))
struct PanelWithBarsRenders {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] ?? "/tmp", directoryHint: .isDirectory)

    private func render(_ name: String, theme: String, dark: Bool, placement: PanelPlacement? = nil) throws {
        let session = try #require(PanelPreview.session(named: name))
        let placement = placement ?? PanelPlacement()
        placement.cornerRadius = PanelFrame.cornerRadius(panelWithBars: session.panelWithBars)
        let bitmap = try PanelBarDrawing.draw(
            PanelBarDrawing.panel(session, model: try PanelBarDrawing.model(theme), placement: placement), dark: dark)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: "\(name)-\(theme)-\(dark ? "dark" : "light").png"))
    }

    @Test func rendersEachStateAndTheDarkThemes() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in PanelWithBarsPreview.names {
            try render(name, theme: "glass", dark: false)
        }
        for (theme, dark) in [("glass", true), ("tidewater", true), ("graphite", true), ("ember", true), ("high-contrast", true), ("high-contrast", false), ("paper", false)] {
            try render("bars-rest", theme: theme, dark: dark)
            try render("bars-long", theme: theme, dark: dark)
            try render("bars-lines", theme: theme, dark: dark)
        }
        for name in ["bars-running", "bars-working-hover", "bars-queued"] {
            try render(name, theme: "graphite", dark: true)
        }
        // Before: the same conversation with the switch off, at rest and while a task runs.
        for (theme, dark) in [("glass", false), ("graphite", true)] {
            let running = AgentSession(previewEntries: PanelWithBarsPreview.thread(), isRunning: true)
            let runningBitmap = try PanelBarDrawing.draw(
                PanelBarDrawing.panel(running, model: try PanelBarDrawing.model(theme)), dark: dark)
            try #require(runningBitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appending(path: "before-running-\(theme)-\(dark ? "dark" : "light").png"))
            let session = AgentSession(previewEntries: PanelWithBarsPreview.thread())
            let bitmap = try PanelBarDrawing.draw(
                PanelBarDrawing.panel(session, model: try PanelBarDrawing.model(theme)), dark: dark)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appending(path: "before-rest-\(theme)-\(dark ? "dark" : "light").png"))
        }
    }
}
