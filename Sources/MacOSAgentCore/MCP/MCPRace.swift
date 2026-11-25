import Foundation
import Synchronization

/// Runs operations side by side and returns the first one's result, or throws its error. The
/// others are cancelled and never waited for, so a call to a server that ignores cancellation
/// cannot hold up a timeout or the owner stopping the task.
enum MCPRace {
    static func first<T: Sendable>(_ operations: [@Sendable () async throws -> T]) async throws -> T {
        let state = RaceState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.attach(continuation) else { return }
                let tasks = operations.map { operation in
                    Task {
                        do { state.finish(.success(try await operation())) } catch { state.finish(.failure(error)) }
                    }
                }
                state.hold(tasks)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    /// The operation, or `MCPConnectionError.timedOut` after the timeout.
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await first([
            operation,
            {
                try await Task.sleep(for: timeout)
                throw MCPConnectionError.timedOut(seconds: Int(timeout.components.seconds))
            },
        ])
    }
}

private final class RaceState<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var result: Result<T, Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// False when it already finished, as when the task was cancelled before it began.
    func attach(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let early = state.withLock { state -> Result<T, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
            return false
        }
        return true
    }

    func hold(_ tasks: [Task<Void, Never>]) {
        let finished = state.withLock { state -> Bool in
            state.tasks = tasks
            return state.result != nil
        }
        if finished { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            defer { state.continuation = nil }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
