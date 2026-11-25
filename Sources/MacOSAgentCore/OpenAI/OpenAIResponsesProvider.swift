import Foundation

/// The OpenAI provider: the Responses API at api.openai.com, streamed, authorized with the
/// access token from Sign in with ChatGPT.
public struct OpenAIResponsesProvider: ModelProvider {
    public static let baseURL = URL(string: "https://api.openai.com/v1")!

    public enum ProviderError: Error, LocalizedError {
        case http(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                OpenAIResponsesProvider.explain("OpenAI API error (\(status)): \(body)")
            }
        }
    }

    private let authenticator: ChatGPTAuthenticator
    private let model: @Sendable () -> String
    private let reasoningEffort: String
    private let promptCacheKey: String
    private let session: URLSession

    /// - Parameters:
    ///   - model: Read at the start of each reply, so a change in settings applies to the next one.
    ///   - promptCacheKey: The same for every request in the thread, so OpenAI routes them to the same cache.
    public init(
        authenticator: ChatGPTAuthenticator,
        model: @escaping @Sendable () -> String,
        reasoningEffort: String = OpenAIModel.defaultReasoningEffort,
        promptCacheKey: String,
        session: URLSession = .shared
    ) {
        self.authenticator = authenticator
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptCacheKey = promptCacheKey
        self.session = session
    }

    public func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelStreamEvent, Error>.makeStream()
        let task = Task {
            do {
                try await run(request, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(_ request: ModelRequest, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        let model = model()
        let body = OpenAIResponses.body(
            for: request, model: model, reasoningEffort: reasoningEffort, promptCacheKey: promptCacheKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bodyData = try encoder.encode(body)

        var bytes: URLSession.AsyncBytes
        var attempt = 0
        while true {
            attempt += 1
            var urlRequest = URLRequest(url: Self.baseURL.appending(path: "responses"))
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = bodyData
            urlRequest.timeoutInterval = 300
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            urlRequest.setValue("mac-os-agent", forHTTPHeaderField: "User-Agent")
            urlRequest.setValue("Bearer \(try await authenticator.accessToken())", forHTTPHeaderField: "Authorization")
            for (field, value) in Self.sessionHeaders(promptCacheKey: promptCacheKey) {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }

            let (responseBytes, response) = try await session.bytes(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                bytes = responseBytes
                break
            }
            var errorBody = Data()
            for try await byte in responseBytes where errorBody.count < 16_384 { errorBody.append(byte) }
            if status == 401, attempt == 1 {
                // The token may have been revoked or expired early. Refresh once and retry.
                await authenticator.discardAccessToken()
                continue
            }
            throw ProviderError.http(status: status, body: String(decoding: errorBody, as: UTF8.self))
        }

        var parser = OpenAIResponses.StreamParser(model: model)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = JSONValue.parse(payload) else { continue }
            for output in try parser.consume(event) {
                continuation.yield(output)
            }
        }
        try Task.checkCancellation()
        try parser.finish()
    }

    /// Headers that tie every request in the thread to one session, so OpenAI routes them to the
    /// machine that holds their prompt cache. pi sends the same two to api.openai.com, with the
    /// same value as `prompt_cache_key`, and gets most of each prompt from the cache.
    static func sessionHeaders(promptCacheKey: String) -> [(String, String)] {
        let key = String(promptCacheKey.prefix(64))
        return [("session-id", key), ("x-client-request-id", key)]
    }

    /// Adds a hint to errors that mean the ChatGPT plan's shared usage limit was reached.
    static func explain(_ message: String) -> String {
        if message.contains("subscription_sharing_workplace_individual_usage_limit_exceeded") {
            return message + "\nYou have reached your ChatGPT workspace's usage limit. Ask the workspace admin to raise it."
        }
        if message.contains("subscription_sharing_usage_limit_exceeded") {
            return message + "\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage"
        }
        return message
    }
}
