import Foundation
import Testing
@testable import MacOSAgentCore

/// The prompt cache with an image in the episode, in the bytes the OpenAI provider sends, as
/// `PromptCacheWireTests` checks it without one. The image is read from the images folder for
/// each request and must go out as the same bytes every time.
@Suite struct ImageWireTests {
    struct Run {
        var server: StubResponsesServer
        var image: PreparedImage
    }

    /// A message with an image that leads to a tool call and its answer, then a follow-up
    /// without one after a relaunch: three requests in one episode.
    static func run() async throws -> Run {
        let server = StubResponsesServer(replies: [
            [.reasoning, .call(name: "record", arguments: ["q": "disk"])],
            [.reasoning, .message("The backup disk is full.")],
            [.message("Delete the oldest backups first.")],
        ])
        let file = temporaryThreadFile()
        let folder = file.deletingLastPathComponent()
        let images = ImageFolder(folder: folder.appending(path: "images"))
        let usageLog = UsageLog(fileURL: folder.appending(path: "usage.jsonl"), device: { WireEpisode.device })
        let image = try ImagePreparation.prepare(drawnImage(width: 96, height: 60))

        var loop = try loop(server: server, thread: try ThreadStore(fileURL: file), usageLog: usageLog, images: images)
        try await loop.run(
            "what does this error mean", images: [image], now: WireEpisode.start, onEvent: { _ in }, confirm: { _ in true })
        // A relaunch: the thread and the image are read back from their files.
        loop = try self.loop(server: server, thread: try ThreadStore(fileURL: file), usageLog: usageLog, images: images)
        try await loop.run("what should I delete", now: WireEpisode.start.addingTimeInterval(60), onEvent: { _ in }, confirm: { _ in true })
        return Run(server: server, image: image)
    }

    static func loop(server: StubResponsesServer, thread: ThreadStore, usageLog: UsageLog, images: ImageFolder) throws -> AgentLoop {
        let base = try WireEpisode.loop(server: server, thread: thread, usageLog: usageLog)
        return AgentLoop(
            provider: base.provider, thread: thread, tools: base.tools,
            instructionsForEpisode: { _ in WireEpisode.instructions }, usageLog: usageLog, images: images)
    }

    @Test func eachRequestStartsWithTheOneBeforeItAndReadsItFromTheCache() async throws {
        let run = try await Self.run()
        let received = run.server.received
        let reported = run.server.reported
        #expect(received.count == 3)
        for index in received.indices.dropFirst() {
            let previous = received[index - 1]
            let difference = RequestDigest.firstDifference(
                previous: previous.input.map { $0.encodedString() }, current: received[index].input.map { $0.encodedString() })
            #expect(difference == nil, "request \(index + 1) differs from request \(index) at input item \(difference ?? -1)")
            let boundaries = StubResponsesServer.boundaries(tools: previous.body["tools"] ?? .array([]), input: previous.input)
            let expected = StubResponsesServer.tokens(boundaries.prompt.prefix(boundaries.ends.last ?? 0))
            #expect(reported[index].cachedTokens == expected)
            #expect(reported[index].cachedTokens > 0)
        }
        // Every request carries the image, as the same data URL.
        let url = "data:image/png;base64," + run.image.data.base64EncodedString()
        for request in received {
            let parts = request.input[1]["content"]?.arrayValue ?? []
            #expect(parts.count == 2)
            #expect(parts.last?["image_url"] == .string(url))
        }
    }

    /// The requests, compared with a file in the repository. The image's data URL is written
    /// as its length and digest, so the file stays readable and a change to the bytes still shows.
    @Test func theEpisodeSendsWhatTheGoldenFileHolds() async throws {
        let run = try await Self.run()
        let requests: [JSONValue] = run.server.received.map { request in
            let kept = request.headers.filter { WireEpisode.goldenHeaders.contains($0.key) }
            return ["headers": .object(kept.mapValues { .string($0) }), "body": Self.shortenImages(WireEpisode.shortenInstructions(request.body))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let actual = try encoder.encode(JSONValue.array(requests)) + Data("\n".utf8)
        let golden = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/openai-wire-image-episode.json")
        if ProcessInfo.processInfo.environment["MAC_OS_AGENT_UPDATE_GOLDEN"] == "1" {
            try actual.write(to: golden)
        }
        let expected = try Data(contentsOf: golden)
        #expect(actual == expected, "The requests differ from \(golden.lastPathComponent). If the change is meant, run with MAC_OS_AGENT_UPDATE_GOLDEN=1 and commit the file.")
    }

    static func shortenImages(_ body: JSONValue) -> JSONValue {
        guard case .object(var object) = body, let input = body["input"]?.arrayValue else { return body }
        object["input"] = .array(input.map { item in
            guard case .object(var fields) = item, let parts = item["content"]?.arrayValue else { return item }
            fields["content"] = .array(parts.map { part in
                guard case .object(var partFields) = part, let url = part["image_url"]?.stringValue else { return part }
                partFields["image_url"] = .string("<data URL: \(url.count) characters, \(RequestDigest.digest(.string(url)))>")
                return .object(partFields)
            })
            return .object(fields)
        })
        return .object(object)
    }
}
