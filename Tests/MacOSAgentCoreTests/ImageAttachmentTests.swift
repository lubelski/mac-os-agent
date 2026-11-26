import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacOSAgentCore

/// A made-up picture drawn in code: stripes of color with a square in a corner, so reducing it
/// keeps something to compare. Never a real screenshot.
func drawnImage(width: Int, height: Int, type: UTType = .png, shade: CGFloat = 0.2) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for stripe in 0..<8 {
        context.setFillColor(CGColor(srgbRed: CGFloat(stripe) / 8, green: shade, blue: 1 - CGFloat(stripe) / 8, alpha: 1))
        context.fill(CGRect(x: width * stripe / 8, y: 0, width: width / 8 + 1, height: height))
    }
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 5, height: height / 5))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

@Suite struct ImagePreparationTests {
    @Test func aLargeScreenshotIsReducedToTheLongEdgeAndKeptAsPNG() throws {
        let prepared = try ImagePreparation.prepare(drawnImage(width: 4096, height: 1024))
        #expect(prepared.attachment.width == 2048)
        #expect(prepared.attachment.height == 512)
        #expect(prepared.attachment.type == ImageAttachment.png)
        #expect(prepared.attachment.bytes == prepared.data.count)
        #expect(prepared.attachment.id == ImageAttachment.contentID(of: prepared.data))
        #expect(prepared.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aTallImageIsReducedByItsHeight() throws {
        let prepared = try ImagePreparation.prepare(drawnImage(width: 1000, height: 3000))
        #expect(prepared.attachment.height == 2048)
        #expect(prepared.attachment.width == 683)
    }

    @Test func aSmallImageIsNeverScaledUp() throws {
        let prepared = try ImagePreparation.prepare(drawnImage(width: 300, height: 200))
        #expect(prepared.attachment.width == 300)
        #expect(prepared.attachment.height == 200)
    }

    @Test func aPhotoStaysAJPEG() throws {
        let prepared = try ImagePreparation.prepare(drawnImage(width: 3000, height: 2000, type: .jpeg))
        #expect(prepared.attachment.type == ImageAttachment.jpeg)
        #expect(prepared.attachment.width == 2048)
        #expect(prepared.attachment.fileName.hasSuffix(".jpg"))
        #expect(prepared.data.starts(with: [0xFF, 0xD8]))
    }

    @Test func clipboardTIFFBecomesPNG() throws {
        let prepared = try ImagePreparation.prepare(drawnImage(width: 800, height: 600, type: .tiff))
        #expect(prepared.attachment.type == ImageAttachment.png)
    }

    /// The bytes are made once, when the image is attached. Making them again from the same
    /// source, as a second paste of it does, gives the same bytes and the same file.
    @Test func reducingAndEncodingGivesTheSameBytesEachTime() throws {
        let source = drawnImage(width: 3000, height: 1800)
        let first = try ImagePreparation.prepare(source)
        let second = try ImagePreparation.prepare(source)
        #expect(first == second)
        let photo = drawnImage(width: 3000, height: 1800, type: .jpeg)
        #expect(try ImagePreparation.prepare(photo) == ImagePreparation.prepare(photo))
    }

    @Test func somethingThatIsNotAnImageIsRefused() {
        #expect(throws: ImagePreparation.PreparationError.notAnImage) {
            try ImagePreparation.prepare(Data("not a picture".utf8))
        }
    }
}

@Suite struct ImageThreadTests {
    static let image = ImageAttachment(id: String(repeating: "ab", count: 32), type: ImageAttachment.png, bytes: 1234, width: 640, height: 400)

    /// A line written before images existed, exactly as an older build wrote it.
    @Test func anOldLineWithoutImagesLoads() throws {
        let line = #"{"date":"2026-11-20T10:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","item":{"type":"user_message","value":{"text":"hello"}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ThreadEntry.self, from: Data(line.utf8))
        #expect(entry.item == .userMessage(text: "hello"))
        #expect(entry.item.images.isEmpty)
    }

    /// A message without images is written exactly as before: no `images` key.
    @Test func aPlainMessageIsWrittenAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ThreadItem.userMessage(text: "hello"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"type":"user_message","value":{"text":"hello"}}"#)
    }

    @Test func aMessageWithImagesRoundTripsThroughTheThreadFile() async throws {
        let file = temporaryThreadFile()
        let store = try ThreadStore(fileURL: file)
        try await store.append(.userMessage(text: "what is this", images: [Self.image]))
        try await store.append(.userMessage(text: "", images: [Self.image, Self.image]))
        let reloaded = try ThreadStore(fileURL: file)
        #expect(await reloaded.entries.map(\.item) == [
            .userMessage(text: "what is this", images: [Self.image]),
            .userMessage(text: "", images: [Self.image, Self.image]),
        ])
        // The line points to the image and holds no bytes.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#""images":[{"bytes":1234,"height":400,"id":"abab"#))
        #expect(!text.contains("base64"))
    }
}

@Suite struct ImageStorageTests {
    @Test func theFolderKeepsEachImageOnceByItsHash() throws {
        let folder = temporaryThreadFile().deletingLastPathComponent().appending(path: "images")
        let store = ImageFolder(folder: folder)
        let image = try ImagePreparation.prepare(drawnImage(width: 200, height: 100))
        try store.keep(image)
        try store.keep(image)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == [image.attachment.fileName])
        #expect(store.data(for: image.attachment) == image.data)
    }

    @Test func aChangedFileReadsAsGone() throws {
        let folder = temporaryThreadFile().deletingLastPathComponent().appending(path: "images")
        let store = ImageFolder(folder: folder)
        let image = try ImagePreparation.prepare(drawnImage(width: 200, height: 100))
        try store.keep(image)
        try Data("other bytes".utf8).write(to: store.url(for: image.attachment))
        #expect(store.data(for: image.attachment) == nil)
    }
}

@Suite struct ImageRequestTests {
    static let date = Date(timeIntervalSince1970: 1_795_000_000)

    @Test func anImageGoesAfterTheTextAsADataURL() throws {
        let image = try ImagePreparation.prepare(drawnImage(width: 64, height: 32))
        let request = ModelRequest(
            instructions: "x", entries: [ThreadEntry(date: Self.date, item: .userMessage(text: "what is this", images: [image.attachment]))],
            tools: [], images: [image.id: image.data])
        let input = OpenAIResponses.input(for: request, model: "m", timeZone: TimeZone(identifier: "UTC")!)
        let content = try #require(input[1]["content"]?.arrayValue)
        #expect(content.count == 2)
        #expect(content[0] == ["type": "input_text", "text": "[2026-11-18 11:06 GMT] what is this"])
        #expect(content[1] == [
            "type": "input_image", "detail": "auto",
            "image_url": .string("data:image/png;base64," + image.data.base64EncodedString()),
        ])
    }

    @Test func anImageWhoseBytesAreGoneIsAFixedNote() throws {
        let image = ImageThreadTests.image
        let request = ModelRequest(
            instructions: "x", entries: [ThreadEntry(date: Self.date, item: .userMessage(text: "", images: [image]))],
            tools: [], images: [:])
        let input = OpenAIResponses.input(for: request, model: "m", timeZone: TimeZone(identifier: "UTC")!)
        let content = try #require(input[1]["content"]?.arrayValue)
        #expect(content == [
            ["type": "input_text", "text": "[2026-11-18 11:06 GMT] "],
            ["type": "input_text", "text": .string(ImageAttachment.missingNote)],
        ])
    }

    /// The loop reads an image once per episode. A file that disappears partway through, or
    /// one that was gone from the start and comes back, does not change the next request.
    @Test func aMissingFileDoesNotChangeTheRequestPartwayThroughAnEpisode() async throws {
        let folder = temporaryThreadFile().deletingLastPathComponent()
        let images = ImageFolder(folder: folder.appending(path: "images"))
        let provider = FakeProvider(replies: [[.item(assistant("one"))], [.item(assistant("two"))], [.item(assistant("three"))]])
        let loop = AgentLoop(
            provider: provider, thread: try ThreadStore(fileURL: folder.appending(path: "thread.jsonl")), tools: [],
            instructionsForEpisode: { _ in "x" }, images: images)
        let image = try ImagePreparation.prepare(drawnImage(width: 100, height: 60))
        try await loop.run("look", images: [image], now: Self.date, onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests[0].images == [image.id: image.data])

        try FileManager.default.removeItem(at: images.url(for: image.attachment))
        try await loop.run("again", now: Self.date.addingTimeInterval(60), onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests[1].images == [image.id: image.data])

        // A new loop, as after a relaunch, finds the file gone, and says so from then on.
        let relaunched = AgentLoop(
            provider: provider, thread: try ThreadStore(fileURL: folder.appending(path: "thread.jsonl")), tools: [],
            instructionsForEpisode: { _ in "x" }, images: images)
        try await relaunched.run("and now", now: Self.date.addingTimeInterval(120), onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests[2].images.isEmpty)
        let input = OpenAIResponses.input(for: provider.requests[2], model: "m")
        #expect(input[1]["content"]?.arrayValue?.last == ["type": "input_text", "text": .string(ImageAttachment.missingNote)])
    }

    @Test func theImageIsKeptBeforeTheMessageThatPointsToIt() async throws {
        let folder = temporaryThreadFile().deletingLastPathComponent()
        let images = ImageFolder(folder: folder.appending(path: "images"))
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let loop = AgentLoop(
            provider: FakeProvider(replies: [[.item(assistant("ok"))]]), thread: thread, tools: [],
            instructionsForEpisode: { _ in "x" }, images: images)
        let image = try ImagePreparation.prepare(drawnImage(width: 100, height: 60))
        try await loop.run("", images: [image], onEvent: { _ in }, confirm: { _ in true })
        #expect(images.data(for: image.attachment) == image.data)
        #expect(await thread.entries.first?.item == .userMessage(text: "", images: [image.attachment]))
    }

    @Test func aDigestCoversTheImageAndHoldsNoneOfIt() throws {
        let image = try ImagePreparation.prepare(drawnImage(width: 64, height: 32))
        let other = try ImagePreparation.prepare(drawnImage(width: 64, height: 32, shade: 0.8))
        func digests(_ prepared: PreparedImage) -> [String] {
            let request = ModelRequest(
                instructions: "x", entries: [ThreadEntry(date: Self.date, item: .userMessage(text: "hi", images: [prepared.attachment]))],
                tools: [], images: [prepared.id: prepared.data])
            return RequestDigest.make(tools: nil, input: OpenAIResponses.input(for: request, model: "m"))
        }
        #expect(digests(image) != digests(other))
        #expect(digests(image).allSatisfy { $0.count == 6 })
    }

    @Test func anErrorNeverCarriesImageDataAndSaysWhatWentWrong() {
        let error = OpenAIResponsesProvider.ProviderError.http(
            status: 400, body: #"{"error":{"message":"Invalid image in data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="}}"#)
        let text = error.errorDescription ?? ""
        #expect(!text.contains("iVBOR"))
        #expect(text.contains("data:image/png;base64,…"))
        #expect(text.hasSuffix(OpenAIResponsesProvider.imageErrorHint))
        let plain = OpenAIResponsesProvider.ProviderError.http(status: 400, body: "bad request").errorDescription ?? ""
        #expect(!plain.contains(OpenAIResponsesProvider.imageErrorHint))
    }
}

@Suite struct ImageHistoryTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aMessageWithImagesSaysSoInHistorySearchAndTheAgentsTools() async throws {
        let image = ImageThreadTests.image
        let entries = [
            ThreadEntry(date: Self.start, item: .userMessage(text: "what does this error mean", images: [image])),
            ThreadEntry(date: Self.start.addingTimeInterval(10), item: assistant("The disk is full.")),
            ThreadEntry(date: Self.start.addingTimeInterval(20), item: .userMessage(text: "", images: [image, image])),
            ThreadEntry(date: Self.start.addingTimeInterval(9_000), item: .episodeStart(.init(reason: .requested))),
            ThreadEntry(date: Self.start.addingTimeInterval(9_000), item: .userMessage(text: "now")),
        ]
        let contents = ThreadContents(entries: entries)
        let first = try #require(contents.episode(numbered: 1))
        let lines = EpisodeLine.lines(of: first, in: contents)
        #expect(lines.map(\.text) == ["what does this error mean [with 1 image]", "The disk is full.", "[with 2 images]"])
        #expect(lines[0].images == [image])
        #expect(lines[2].images.count == 2)
        #expect(first.messagePreview == "what does this error mean [with 1 image]")
        #expect(first.messageCount == 3)

        let file = temporaryThreadFile()
        let store = try ThreadStore(fileURL: file)
        for entry in entries { try await store.append(entry.item, date: entry.date, id: entry.id) }
        let current = try #require(await store.currentEpisode)
        let context = ToolRunContext(callID: "c", episodeID: current.id, confirm: { _ in true })
        let gmt = try #require(TimeZone(identifier: "GMT"))
        let read = await ReadEpisodeTool(history: store, timeZone: gmt).run(arguments: ["episode": 1, "from_line": .null], context: context)
        #expect(read.contains("person: what does this error mean [with 1 image]"))
        #expect(read.contains("person: [with 2 images]"))
        // Found by the words typed, and by the note on its images. The image itself is not read.
        #expect(await store.search("error").map(\.position) == [0])
        #expect(Set(await store.search("image").map(\.position)) == [0, 2])
    }
}

@Suite struct ImagePasteTests {
    static let screenshot = Data([0x89, 0x50])
    static let isImage: @Sendable (URL) -> Bool = { $0.pathExtension == "png" }

    @Test func aScreenshotOnTheClipboardIsAttached() {
        #expect(ImagePaste.choose(files: [], imageData: Self.screenshot, text: nil, isImageFile: Self.isImage)
            == .images([.data(Self.screenshot)]))
    }

    @Test func textIsStillPastedAsText() {
        #expect(ImagePaste.choose(files: [], imageData: nil, text: "hello", isImageFile: Self.isImage) == .text)
        // A document copied with a picture in it pastes its words.
        #expect(ImagePaste.choose(files: [], imageData: Self.screenshot, text: "a paragraph with a picture", isImageFile: Self.isImage) == .text)
        #expect(ImagePaste.choose(files: [], imageData: nil, text: nil, isImageFile: Self.isImage) == .text)
    }

    @Test func imageFilesFromFinderAreAttachedAndOtherFilesAreNot() {
        let png = URL(filePath: "/tmp/a.png")
        let pdf = URL(filePath: "/tmp/b.pdf")
        #expect(ImagePaste.choose(files: [png, pdf], imageData: nil, text: "a.png", isImageFile: Self.isImage) == .images([.file(png)]))
        #expect(ImagePaste.choose(files: [pdf], imageData: nil, text: "b.pdf", isImageFile: Self.isImage) == .text)
    }

    @Test func aBrowsersCopyImageWithItsAddressIsAttached() {
        #expect(ImagePaste.choose(files: [], imageData: Self.screenshot, text: "https://example.com/a.png", isImageFile: Self.isImage)
            == .images([.data(Self.screenshot)]))
    }

    @Test func atMostSixGoWithAMessage() {
        #expect(ImagePaste.room(attached: 0, adding: 2) == 2)
        #expect(ImagePaste.room(attached: 5, adding: 3) == 1)
        #expect(ImagePaste.room(attached: 6, adding: 1) == 0)
        #expect(ImagePaste.limitNotice(leftOut: 2) == "A message can have 6 images. 2 images left out.")
    }
}

@Suite struct ImageInputTests {
    @Test func openAIModelsReadImagesAndALocalModelSaysWhetherItDoes() {
        let capabilities = Ollama.capabilities(fromTags: [
            "models": [
                ["name": "seeing:latest", "capabilities": ["completion", "vision", "tools"]],
                ["name": "text-only:latest", "capabilities": ["completion", "tools"]],
                ["name": "old:latest"],
            ],
        ])
        #expect(ImageInput.isSupported(modelID: "gpt-6-luna", localCapabilities: capabilities) == true)
        #expect(ImageInput.isSupported(modelID: Ollama.modelID("seeing:latest"), localCapabilities: capabilities) == true)
        #expect(ImageInput.isSupported(modelID: Ollama.modelID("text-only:latest"), localCapabilities: capabilities) == false)
        // Not known either way: sent, and a provider error reads plainly.
        #expect(ImageInput.isSupported(modelID: Ollama.modelID("old:latest"), localCapabilities: capabilities) == nil)
        #expect(ImageInput.isSupported(modelID: Ollama.modelID("unlisted"), localCapabilities: [:]) == nil)
        #expect(ImageInput.unsupportedMessage(modelID: Ollama.modelID("text-only:latest"))
            == "text-only (Ollama) cannot read images. Remove them, or choose another model.")
    }
}

@Suite struct ImageQueueTests {
    @Test func aQueuedMessageKeepsItsImages() throws {
        let image = try ImagePreparation.prepare(drawnImage(width: 40, height: 40))
        var queue = MessageQueue()
        queue.append("look", images: [image])
        queue.append("and this")
        #expect(queue.next()?.images == [image])
        let pulled = queue.pullBackItem()
        let back = try #require(pulled)
        #expect(back.text == "and this")
        #expect(back.images.isEmpty)
    }
}
