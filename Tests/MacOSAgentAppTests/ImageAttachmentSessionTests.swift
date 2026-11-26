import AppKit
import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// A pasteboard that is not the clipboard, so a test never reads or writes the owner's.
struct StandInPasteboard: ImagePasteboard {
    var fileURLs: [URL] = []
    var imageData: Data?
    var plainText: String?
}

/// Attaching images in the main panel, against a kept thread and an images folder in a
/// temporary folder. The images are drawn in code.
@MainActor
@Suite(.serialized) struct ImageAttachmentSessionTests {
    init() { _ = NSApplication.shared }

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-image-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let provider = EchoProvider()

    private func makeSession(preferences: StandInPreferences? = nil) throws -> (AgentSession, ThreadStore, ImageFolder) {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let images = ImageFolder(folder: folder.appending(path: "images"))
        let loop = AgentLoop(
            provider: provider, thread: thread, tools: [], instructionsForEpisode: { _ in "x" }, images: images)
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.instantActions = InstantActions(applications: InstantActionPreview.applications, learns: false)
        if let preferences { session.preferences = preferences.defaults }
        return (session, thread, images)
    }

    static func image(_ shade: Double = 0.3) -> PreparedImage {
        StandInImages.prepared(shade < 0.5 ? .errorDialog : .chart)
    }

    @Test func pasteAttachesAnImageAndLeavesTextToTheField() throws {
        let textView = InputTextView()
        var attached: [ImagePaste.Source] = []
        textView.onAttachImages = { sources in
            attached = sources
            return true
        }
        let screenshot = StandInImages.png(.chart, width: 200, height: 120)
        #expect(textView.attachImages(from: StandInPasteboard(imageData: screenshot)))
        #expect(attached == [.data(screenshot)])
        attached = []
        #expect(!textView.attachImages(from: StandInPasteboard(plainText: "just words")))
        #expect(attached.isEmpty)
        // Paste reads the pasteboard it is given, never the clipboard, here.
        textView.pasteboardForPaste = { StandInPasteboard(imageData: screenshot) }
        textView.paste(nil)
        #expect(attached == [.data(screenshot)])
        #expect(textView.string.isEmpty)
    }

    @Test func returnWithAnImageSendsToTheAgentInsteadOfOpeningAnApp() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, thread, images) = try makeSession()
        let image = Self.image()
        session.attach(prepared: [image])
        // Alone, "safari" opens Safari. With an image attached it is a message.
        session.draft = "safari"
        #expect(session.instantActions.suggestion == nil)
        session.submit()
        await session.waitUntilIdle()
        #expect(await thread.entries.first?.item == .userMessage(text: "safari", images: [image.attachment]))
        #expect(provider.requests.last?.images == [image.id: image.data])
        #expect(images.data(for: image.attachment) == image.data)
        #expect(session.attachments.isEmpty)
        #expect(session.draft.isEmpty)
        #expect(session.transcript.rows.last(where: \.isUser)?.images == [image.attachment])
    }

    @Test func aMessageOfImagesAloneCanBeSent() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, thread, _) = try makeSession()
        let image = Self.image()
        session.attach(prepared: [image, image])
        #expect(session.attachments.count == 1)
        session.submit()
        await session.waitUntilIdle()
        #expect(await thread.entries.first?.item == .userMessage(text: "", images: [image.attachment]))
    }

    @Test func atMostSixAreAttachedAndTheRestAreNamed() throws {
        let (session, _, _) = try makeSession()
        let many = (0..<8).map { index in
            try! ImagePreparation.prepare(StandInImages.png(.chart, width: 100 + index, height: 80))
        }
        session.attach(prepared: many)
        #expect(session.attachments.count == ImageAttachment.limit)
        #expect(session.attachmentNotice == "A message can have 6 images. 2 images left out.")
        session.removeAttachment(many[0].id)
        #expect(session.attachments.count == 5)
        #expect(session.attachmentNotice == nil)
    }

    @Test func aModelThatCannotReadImagesIsNotSentThem() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (session, thread, _) = try makeSession()
        session.imageInputSupported = { false }
        session.attach(prepared: [Self.image()])
        session.draft = "what is this"
        session.submit()
        await session.waitUntilIdle()
        #expect(provider.requests.isEmpty)
        #expect(await thread.entries.isEmpty)
        #expect(session.draft == "what is this")
        #expect(session.attachments.count == 1)
        #expect(session.attachmentNotice?.hasSuffix("cannot read images. Remove them, or choose another model.") == true)
        // Text alone still goes.
        session.removeAttachment(session.attachments[0].id)
        session.submit()
        await session.waitUntilIdle()
        #expect(provider.requests.count == 1)
    }

    @Test func aQueuedMessageKeepsItsImagesAndRecallBringsBackTextOnly() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = StandInPreferences(recall: true, queue: true)
        defer { preferences.forget() }
        let (session, thread, _) = try makeSession(preferences: preferences)
        provider.holds = true
        session.draft = "first"
        session.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.isRunning)
        let image = Self.image()
        session.attach(prepared: [image])
        session.draft = "and this picture"
        session.submit()
        #expect(session.queue.items.map(\.images) == [[image]])
        #expect(session.attachments.isEmpty)
        // Up in an empty field takes the queued message back whole, and it can be queued again.
        #expect(session.recallMessage(by: -1))
        #expect(session.draft == "and this picture")
        #expect(session.attachments == [image])
        session.submit()
        provider.holds = false
        session.stop()
        await session.waitUntilIdle()
        session.resumeQueue()
        await session.waitUntilIdle()
        #expect(await thread.entries.contains { $0.item == .userMessage(text: "and this picture", images: [image.attachment]) })

        // Recalling a sent message brings back its text, without its images.
        #expect(session.recallMessage(by: -1))
        #expect(session.draft == "and this picture")
        #expect(session.attachments.isEmpty)
    }

    @Test func aKeptThumbnailIsDrawnWithoutReadingTheFileAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let images = ImageFolder(folder: folder.appending(path: "images"))
        // A size no other test draws, so the shared cache cannot already hold it.
        let image = try ImagePreparation.prepare(StandInImages.png(.landscape, width: 333, height: 211))
        let points: CGFloat = 37
        try images.keep(image)
        var reads = 0
        let read = { () -> Data? in
            reads += 1
            return images.data(for: image.attachment)
        }
        #expect(ImageThumbnails.image(for: image.attachment, points: points, data: read) != nil)
        #expect(ImageThumbnails.image(for: image.attachment, points: points, data: read) != nil)
        #expect(reads == 1)

        // A missing image is asked for each time, so it shows once its file is back.
        let other = try ImagePreparation.prepare(StandInImages.png(.chart, width: 317, height: 203))
        let readOther = { () -> Data? in
            reads += 1
            return images.data(for: other.attachment)
        }
        #expect(ImageThumbnails.image(for: other.attachment, points: points, data: readOther) == nil)
        #expect(ImageThumbnails.image(for: other.attachment, points: points, data: readOther) == nil)
        #expect(reads == 3)
        try images.keep(other)
        #expect(ImageThumbnails.image(for: other.attachment, points: points, data: readOther) != nil)
        #expect(reads == 4)
    }
}
