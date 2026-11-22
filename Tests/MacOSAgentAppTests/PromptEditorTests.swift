import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

@MainActor
struct PromptEditorTests {
    private func editor(width: CGFloat = 400) throws -> (NSScrollView, NSTextView) {
        let scrollView = PromptEditor.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, try #require(scrollView.documentView as? NSTextView))
    }

    @Test func theTextIsMonospaced() throws {
        let (_, textView) = try editor()
        PromptEditor.setText("You are an agent.\nBe brief.", in: textView)
        let font = try #require(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
        #expect(font.pointSize == PromptText.fontSize)
        #expect((textView.typingAttributes[.font] as? NSFont)?.isFixedPitch == true)
        let paragraph = try #require(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.lineSpacing == PromptText.lineSpacing)
    }

    /// A prompt is saved as typed.
    @Test func nothingRewritesWhatIsTyped() throws {
        let (_, textView) = try editor()
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isRichText)
        #expect(textView.allowsUndo)
        #expect(textView.usesFindBar)
    }

    @Test func aLongLineWrapsAndDoesNotWidenTheEditor() throws {
        let (scrollView, textView) = try editor(width: 400)
        PromptEditor.setText("short line", in: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let oneLine = textView.layoutManager!.usedRect(for: textView.textContainer!).height
        PromptEditor.setText(String(repeating: "a long line of prose that goes on ", count: 40), in: textView)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager!.usedRect(for: textView.textContainer!)
        #expect(used.height > oneLine * 3)
        #expect(used.width <= scrollView.contentSize.width)
        #expect(textView.frame.width <= scrollView.contentSize.width)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(textView.textContainer?.widthTracksTextView == true)
    }

    /// The section takes the width it is offered, whatever the text is.
    @Test func theSectionFitsTheWidthItIsGiven() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "prompt-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md")),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")))
        let model = InstructionsSettingsModel(prompt: prompt)
        model.draft = String(repeating: "one very long line without a break ", count: 200)
        let host = NSHostingView(rootView: InstructionsSettingsView(model: model).frame(minWidth: 0, maxWidth: .infinity))
        #expect(host.fittingSize.width < 1000)
    }
}

/// Renders the Instructions section and the full prompt offscreen, for a pull request when
/// screen capture is not available. Run with MAC_OS_AGENT_RENDER_INSTRUCTIONS set to a folder.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_INSTRUCTIONS"] != nil))
struct InstructionsRenders {
    private func write(_ view: some View, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func rendersTheSectionAndTheFullPrompt() throws {
        let out = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_INSTRUCTIONS"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "prompt-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md")),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")))
        let model = InstructionsSettingsModel(prompt: prompt)
        try write(InstructionsSettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                  size: NSSize(width: 620, height: 520), to: out.appending(path: "instructions.png"))
        try write(FullPromptView(text: model.fullPrompt).background(Color(nsColor: .windowBackgroundColor)),
                  size: NSSize(width: 640, height: 480), to: out.appending(path: "full-prompt.png"))
    }
}
