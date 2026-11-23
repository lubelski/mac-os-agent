import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The text field holds one icon at its left and the text, and nothing else: the icon is the
/// four-pointed sparkle at rest and the target's icon when the suggestions experiment offers
/// one, and Stop is on a working row at the end of the thread while a task runs. Checked on
/// pixels of the real window drawn offscreen, since its accessibility tree is not built there.
@MainActor
@Suite(.serialized) struct FieldMarkAndWorkingRowTests {
    init() { _ = NSApplication.shared }

    // MARK: - The field's mark

    @Test func theRestingMarkIsTheSingleFourPointedSparkle() {
        #expect(Mark.promptSymbol == "sparkle", "one star with four points, not `sparkles`")
        #expect(NSImage(systemSymbolName: Mark.promptSymbol, accessibilityDescription: nil) != nil,
                "the symbol name resolves on this macOS")
        #expect(Mark.call == "›", "the tool rows keep their mark")
    }

    /// The sparkle and an app's icon take the same slot, so the text never moves when one
    /// replaces the other.
    @Test func theSparkleAndAnIconTakeTheSameRoom() throws {
        let session = try #require(PanelPreview.session(named: "footer-typing"))
        let target = try #require(session.returnTarget)
        let resting = NSHostingView(rootView: InputMark(target: nil)).fittingSize
        let offered = NSHostingView(rootView: InputMark(target: target)).fittingSize
        #expect(resting == offered)
        #expect(resting == CGSize(width: InputMark.size, height: InputField.rowHeight))
    }

    @Test func theFieldShowsTheSparkleAtRestAndTheTargetsIconWhenOffered() throws {
        let sparkle = try Self.pixels(Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(width: InputMark.size, height: InputField.rowHeight))
        let chevron = try Self.pixels(Text(verbatim: "›").font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
            .frame(width: InputMark.size, height: InputField.rowHeight))
        let resting = try Self.pixels(InputMark(target: nil))
        #expect(resting == sparkle, "the field's mark at rest is the sparkle")
        #expect(resting != chevron, "and no longer the `›`")

        // The experiment offers an app: its icon takes the sparkle's place.
        let typing = try #require(PanelPreview.session(named: "footer-typing"))
        let target = try #require(typing.returnTarget)
        #expect(target.title == "Google Chrome")
        #expect(try Self.pixels(InputMark(target: target)) != resting)
        #expect(try Self.pixels(InputMark(target: typing.returnTarget)) == Self.pixels(InputMark(target: target)))

        // With an empty field, or with the experiment off, nothing takes its place.
        #expect(try #require(PanelPreview.session(named: "footer-idle")).returnTarget == nil)
        let off = try PanelBarDrawing.session("footer-typing", experiment: false)
        #expect(off.returnTarget == nil)
    }

    // MARK: - The working row

    /// The same thread drawn with a task running and without one. The band with the field is the
    /// same in both, so nothing is added to it while a task runs, and the thread above differs,
    /// because the working row is its last row.
    @Test(arguments: [false, true])
    func theWorkingRowShowsOnlyWhileATaskRuns(incognito: Bool) throws {
        for experiment in [false, true] {
            let running = try Self.drawn(running: true, experiment: experiment, incognito: incognito)
            let idle = try Self.drawn(running: false, experiment: experiment, incognito: incognito)
            let size = PanelBarDrawing.size
            let footer = experiment ? InputFooter.height : 0
            // The band with the field: the row of the field and its padding, above the footer.
            let bandTop = size.height - footer - InputField.rowHeight - 24
            let band = CGRect(x: 0, y: bandTop + 1, width: size.width, height: InputField.rowHeight + 22)
            #expect(Self.same(running, idle, in: band),
                    "the field is the same, full width, with a task running, experiment \(experiment) incognito \(incognito)")
            // Just above the band, where the thread's last row is.
            let lastRow = CGRect(x: 16, y: bandTop - HistoryView.bottomPadding - WorkingRow.height, width: 120, height: WorkingRow.height)
            #expect(!Self.same(running, idle, in: lastRow),
                    "the working row ends the thread while a task runs, experiment \(experiment) incognito \(incognito)")
        }
    }

    @Test func theWorkingRowKeepsItsHelpAndItsName() {
        #expect(WorkingRow.title == "Stop", "VoiceOver reads it as Stop")
        #expect(WorkingRow.help == "Stop the task (Command-Period)")
        #expect(WorkingRow.height <= 22, "about the height of a tool row")
    }

    // MARK: - Support

    private static func session(running: Bool, experiment: Bool, incognito: Bool) -> AgentSession {
        var thread = PanelPreview.StandInThread(now: Date())
        thread.user("change the wallpaper to a sunset", minutesAgo: 2)
        thread.tool("osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"Sunset.heic\"'",
                    output: "[exit status 0]")
        thread.reply("Done. Every desktop now shows the Sunset picture.")
        let session = AgentSession(previewEntries: thread.entries, isRunning: running, incognito: incognito)
        session.suggestionList.forcedOn = experiment
        session.syncInstantActionMode()
        return session
    }

    private static func drawn(running: Bool, experiment: Bool, incognito: Bool) throws -> NSBitmapImageRep {
        let session = session(running: running, experiment: experiment, incognito: incognito)
        return try PanelBarDrawing.draw(PanelBarDrawing.panel(session, model: try PanelBarDrawing.model("paper")), dark: false)
    }

    /// Whether two drawings match within a level everywhere in `rect`, in points from the
    /// panel's top left.
    private static func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Bool {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        let margin = PanelBarDrawing.margin
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                let px = Int(((x + margin) * scale).rounded()), py = Int(((y + margin) * scale).rounded())
                guard let one = a.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                      let two = b.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return false }
                let difference = [one.redComponent - two.redComponent, one.greenComponent - two.greenComponent,
                                  one.blueComponent - two.blueComponent].map(abs).max() ?? 0
                if difference > 2.0 / 255 { return false }
            }
        }
        return true
    }

    /// A small view drawn as PNG data, to compare two drawings of a mark.
    private static func pixels(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light).foregroundStyle(.black))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
