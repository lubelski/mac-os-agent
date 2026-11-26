import Foundation
import Synchronization

/// The OpenAI provider: the Responses API at api.openai.com, streamed, authorized with the
/// access token from Sign in with ChatGPT. A local model goes to Ollama on this Mac instead,
/// which takes the same requests. See `Ollama`. A development build sends both through
/// inference-gateway instead, with no sign-in of its own. See `Access`.
public struct OpenAIResponsesProvider: ModelProvider {
    public static let baseURL = URL(string: "https://api.openai.com/v1")!

    public enum ProviderError: Error, LocalizedError {
        case http(status: Int, body: String)
        case ollamaNotRunning(URL)
        /// Nothing answered at inference-gateway's address.
        case gatewayNotRunning(URL)
        /// inference-gateway answered 503 because it has no sign-in. The message says what to run.
        case gatewayNotSignedIn(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body):
                OpenAIResponsesProvider.explain(
                    "OpenAI API error (\(status)): \(OpenAIResponsesProvider.withoutImageData(body))", status: status)
            case .ollamaNotRunning(let url):
                "Ollama is not running at \(url.host() ?? "localhost"):\(url.port ?? 11434). Open Ollama, or choose an OpenAI model."
            case .gatewayNotRunning(let url):
                InferenceGateway.notRunningMessage(url)
            case .gatewayNotSignedIn(let message):
                "inference-gateway: \(message)"
            }
        }
    }

    /// How requests reach the models.
    public enum Access: Sendable {
        /// Straight to api.openai.com with this app's own sign-in, and to Ollama on this Mac.
        case signIn(ChatGPTAuthenticator)
        /// Through inference-gateway at this address, which adds the sign-in itself. Requests
        /// carry no credentials and name the app in `X-Client-App`.
        case gateway(URL)
    }

    private let access: Access
    private let model: @Sendable () -> String
    private let reasoningEffort: String
    private let promptCacheKey: String
    private let session: URLSession
    private let timeZone: TimeZone
    private let ollamaBaseURL: URL
    /// The last prefix `prepare` warmed, shared by copies of the provider.
    private let lastWarmed = LastWarmed()

    final class LastWarmed: Sendable {
        private let value = Mutex<(digest: String, date: Date)?>(nil)

        /// True, and remembered, when this digest was not warmed in the last minute.
        func claim(_ digest: String, at now: Date) -> Bool {
            value.withLock { last in
                if let last, last.digest == digest, now.timeIntervalSince(last.date) < 60 { return false }
                last = (digest, now)
                return true
            }
        }
    }

    /// - Parameters:
    ///   - model: Read at the start of each reply, so a change in settings applies to the next one.
    ///   - promptCacheKey: The same for every request in the thread, so OpenAI routes them to the same cache.
    ///   - ollamaBaseURL: Used with `.signIn` access only. Through the gateway, Ollama is behind it.
    public init(
        access: Access,
        model: @escaping @Sendable () -> String,
        reasoningEffort: String = OpenAIModel.defaultReasoningEffort,
        promptCacheKey: String,
        session: URLSession = .shared,
        timeZone: TimeZone = .current,
        ollamaBaseURL: URL = Ollama.baseURL
    ) {
        self.access = access
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptCacheKey = promptCacheKey
        self.session = session
        self.timeZone = timeZone
        self.ollamaBaseURL = ollamaBaseURL
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

    /// Where a request goes and as what: OpenAI with the ChatGPT sign-in, or Ollama on this Mac
    /// for a model setting such as `ollama/inkling-2-mini`, with no sign-in. Through the gateway,
    /// both go to it with no sign-in, on the same paths after its prefix.
    struct Route {
        var url: URL
        var model: String
        var provider: String
        /// Sends this app's ChatGPT access token. Only for OpenAI reached directly.
        var signsIn: Bool
        /// The gateway's address, when the request goes through it.
        var gateway: URL?
    }

    func route(for modelID: String) -> Route {
        var gateway: URL?
        var openAIBaseURL = Self.baseURL
        var ollamaBaseURL = ollamaBaseURL
        if case .gateway(let base) = access {
            gateway = base
            openAIBaseURL = InferenceGateway.openAIBaseURL(base)
            ollamaBaseURL = InferenceGateway.ollamaBaseURL(base)
        }
        if let name = Ollama.modelName(fromID: modelID) {
            return Route(
                url: ollamaBaseURL.appending(path: "v1/responses"), model: name, provider: Ollama.providerName,
                signsIn: false, gateway: gateway)
        }
        return Route(
            url: openAIBaseURL.appending(path: "responses"), model: modelID, provider: OpenAIResponses.providerName,
            signsIn: gateway == nil, gateway: gateway)
    }

    private func run(_ request: ModelRequest, continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation) async throws {
        let route = route(for: model())
        let body = OpenAIResponses.body(
            for: request, model: route.model, reasoningEffort: reasoningEffort, promptCacheKey: promptCacheKey,
            timeZone: timeZone, provider: route.provider)
        continuation.yield(.requestSent(items: RequestDigest.make(tools: body["tools"], input: body["input"]?.arrayValue ?? [])))
        let bytes = try await send(body, to: route, accept: "text/event-stream")

        var parser = OpenAIResponses.StreamParser(model: route.model, provider: route.provider)
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

    /// Reads the request's prefix into a local model's cache ahead of the owner's message, so
    /// the first reply of an episode does not wait for it. A cold read of the instructions and
    /// tools takes Ollama about 40 seconds on the owner's Mac, and a warm one about 3. It asks
    /// for one token and keeps nothing of the reply. OpenAI models are left alone: there a
    /// refresh costs plan usage, and their cache already lasts 30 minutes.
    ///
    /// The same prefix is warmed at most once a minute, so opening the panel again and again
    /// sends nothing new.
    public func prepare(_ request: ModelRequest) async {
        let route = route(for: model())
        guard route.provider == Ollama.providerName else { return }
        var body = OpenAIResponses.body(
            for: request, model: route.model, reasoningEffort: reasoningEffort, promptCacheKey: promptCacheKey,
            timeZone: timeZone, provider: route.provider)
        let digest = RequestDigest.digest(body)
        guard lastWarmed.claim(digest, at: Date()), case .object(var object) = body else { return }
        object["stream"] = false
        object["max_output_tokens"] = 1
        body = .object(object)
        guard let bytes = try? await send(body, to: route, accept: "application/json") else { return }
        do { for try await _ in bytes {} } catch {}
    }

    private func send(_ body: JSONValue, to route: Route, accept: String) async throws -> URLSession.AsyncBytes {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bodyData = try encoder.encode(body)
        var attempt = 0
        while true {
            attempt += 1
            var urlRequest = URLRequest(url: route.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = bodyData
            urlRequest.timeoutInterval = 300
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
            urlRequest.setValue("mac-os-agent", forHTTPHeaderField: "User-Agent")
            if route.gateway != nil {
                urlRequest.setValue(InferenceGateway.clientName, forHTTPHeaderField: InferenceGateway.clientHeader)
            }
            if route.signsIn, case .signIn(let authenticator) = access {
                urlRequest.setValue("Bearer \(try await authenticator.accessToken())", forHTTPHeaderField: "Authorization")
            }
            // OpenAI gets the session headers either way. The gateway passes them on.
            if route.provider == OpenAIResponses.providerName {
                for (field, value) in Self.sessionHeaders(promptCacheKey: promptCacheKey) {
                    urlRequest.setValue(value, forHTTPHeaderField: field)
                }
            }

            let responseBytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (responseBytes, response) = try await session.bytes(for: urlRequest)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                if let gateway = route.gateway { throw ProviderError.gatewayNotRunning(gateway) }
                if !route.signsIn { throw ProviderError.ollamaNotRunning(route.url) }
                throw error
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return responseBytes }
            var errorBody = Data()
            for try await byte in responseBytes where errorBody.count < 16_384 { errorBody.append(byte) }
            if status == 401, attempt == 1, route.signsIn, case .signIn(let authenticator) = access {
                // The token may have been revoked or expired early. Refresh once and retry.
                await authenticator.discardAccessToken()
                continue
            }
            let text = String(decoding: errorBody, as: UTF8.self)
            if route.gateway != nil, let message = InferenceGateway.notSignedInMessage(status: status, body: text) {
                throw ProviderError.gatewayNotSignedIn(message)
            }
            throw ProviderError.http(status: status, body: text)
        }
    }

    /// Headers that tie every request in the thread to one session, so OpenAI routes them to the
    /// machine that holds their prompt cache. pi sends the same two to api.openai.com, with the
    /// same value as `prompt_cache_key`, and gets most of each prompt from the cache.
    static func sessionHeaders(promptCacheKey: String) -> [(String, String)] {
        let key = String(promptCacheKey.prefix(64))
        return [("session-id", key), ("x-client-request-id", key)]
    }

    /// Adds a hint to errors that mean the ChatGPT plan's shared usage limit was reached.
    /// The hint after an error about an attached image, such as from a local model that cannot
    /// read one.
    public static let imageErrorHint = "The model could not take the attached image. Choose a model that reads images, or send the message without it."

    /// An error body with any image data in it cut down to its type, so an image the owner
    /// attached never reaches the problem log or the panel's error line, whatever a provider
    /// echoes back.
    static func withoutImageData(_ text: String) -> String {
        text.replacing(/data:image\/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+\/=]+/) { match in
            let prefix = match.output.prefix { $0 != "," }
            return "\(prefix),…"
        }
    }

    /// Adds a hint to errors that mean the ChatGPT plan's shared usage limit was reached, and to
    /// a refused request that names an image.
    static func explain(_ message: String, status: Int) -> String {
        let explained = explain(message)
        if explained == message, (400..<500).contains(status), message.lowercased().contains("image") {
            return message + "\n" + imageErrorHint
        }
        return explained
    }

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
