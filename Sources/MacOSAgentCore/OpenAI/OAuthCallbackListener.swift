import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1:1455 that receives the browser's redirect at
/// `/auth/callback` and checks it against the state this sign-in sent.
final class OAuthCallbackListener: @unchecked Sendable {
    private let expectedState: String
    private let savedClientID: String?
    private let queue = DispatchQueue(label: "mac-os-agent.oauth-callback")
    private let listener: NWListener
    private let results = AsyncThrowingStream<ChatGPTSignIn.AuthorizationResult, Error>.makeStream()
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    /// - Parameter savedClientID: The issued client id a reauthorization sent, if it is one.
    init(expectedState: String, savedClientID: String? = nil) throws {
        self.expectedState = expectedState
        self.savedClientID = savedClientID
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(ChatGPTSignIn.callbackHost),
            port: NWEndpoint.Port(rawValue: ChatGPTSignIn.callbackPort)!)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }

    /// Starts listening. Throws `portInUse` when something else holds the port. Without this
    /// check the browser's redirect would reach that other listener, which would reject it.
    func start() async throws {
        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        listener.stateUpdateHandler = { [results] state in
            switch state {
            case .ready:
                ready.continuation.yield()
                ready.continuation.finish()
            case .failed(let error), .waiting(let error):
                let mapped: Error = if case .posix(let code) = error, code == .EADDRINUSE {
                    ChatGPTSignIn.SignInError.portInUse
                } else {
                    error
                }
                ready.continuation.finish(throwing: mapped)
                results.continuation.finish(throwing: mapped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for try await _ in ready.stream { return }
    }

    /// Waits for a valid redirect. Invalid redirects get an error page and are ignored, as in pi.
    func result() async throws -> ChatGPTSignIn.AuthorizationResult {
        for try await result in results.stream { return result }
        throw ChatGPTSignIn.SignInError.cancelled
    }

    func stop() {
        results.continuation.finish(throwing: ChatGPTSignIn.SignInError.cancelled)
        listener.cancel()
        // Close every connection too, including spare ones the browser opened ahead of time,
        // so a later sign-in never receives its redirect on a connection left over from this one.
        let open = lock.withLock {
            defer { connections.removeAll() }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if error != nil || isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let url = URL(string: "http://\(ChatGPTSignIn.callbackHost):\(ChatGPTSignIn.callbackPort)\(parts[1])") else {
            respond(on: connection, status: 400, body: Self.page("The request could not be read."))
            return
        }
        guard url.path == ChatGPTSignIn.callbackPath else {
            respond(on: connection, status: 404, body: Self.page("Callback route not found."))
            return
        }
        do {
            let result = try ChatGPTSignIn.authorizationResult(
                callback: url, expectedState: expectedState, savedClientID: savedClientID)
            respond(on: connection, status: 200, body: Self.page("ChatGPT is connected to mac-os-agent. You can close this window."))
            results.continuation.yield(result)
            results.continuation.finish()
        } catch ChatGPTSignIn.SignInError.authorizationFailed(let error) {
            respond(on: connection, status: 400, body: Self.page("ChatGPT was not connected. Error: \(error)"))
            results.continuation.finish(throwing: ChatGPTSignIn.SignInError.authorizationFailed(error))
        } catch {
            respond(on: connection, status: 400, body: Self.page(error.localizedDescription))
        }
    }

    private func respond(on connection: NWConnection, status: Int, body: String) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html><html><head><meta charset="utf-8"><title>mac-os-agent</title>
            <style>body{font:15px -apple-system,system-ui,sans-serif;margin:4em auto;max-width:32em;padding:0 1em;color:#222}
            @media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}</style></head>
            <body><p>\(escaped)</p></body></html>
            """
    }
}
