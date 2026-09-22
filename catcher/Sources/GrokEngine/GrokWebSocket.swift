import Diagnostics
import Foundation
import TranscriptionEngine
#if os(macOS)
import Synchronization
import os
#endif

public enum GrokSocketEvent: Sendable, Equatable {
    case text(String)
    case binary(Data)
    case closed(code: Int, reason: String)
}

public protocol GrokTransport: Sendable {
    func connect(url: URL, authorizationBearer: String) async throws
    func sendText(_ text: String) async throws
    func sendBinary(_ data: Data) async throws
    func receive() async throws -> GrokSocketEvent
    func close() async
}

public enum GrokWebSocket {
    public static let endpoint = URL(string: "wss://api.x.ai/v1/stt")!
    /// xAI's default endpointing chops sentences. 800 ms is locked for v0.
    public static let endpointingMs = 800

    public static func url(model: String = EngineFactory.grokModelName) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointingMs)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "diarize", value: "true"),
        ]
        return components.url!
    }

    public static func query(_ url: URL) -> [String: String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value ?? "" } ?? [:]
    }
}

public final class URLSessionGrokTransport: GrokTransport, @unchecked Sendable {
    #if os(macOS)
    private struct State: @unchecked Sendable {
        var task: URLSessionWebSocketTask?
        var closed = false
    }

    private let session: URLSession
    /// `NSLock.lock`/`unlock` are unavailable in `close()`, which is `async`.
    /// Task and closed live in this lock. `withLock` is synchronous, so the
    /// critical section cannot span an `await`.
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func connect(url: URL, authorizationBearer: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authorizationBearer)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        store(task)
        task.resume()
    }

    private func store(_ task: URLSessionWebSocketTask) {
        state.withLock { $0.task = task }
    }

    public func sendText(_ text: String) async throws {
        let task = try current()
        try await withTaskCancellationHandler {
            try await task.send(.string(text))
        } onCancel: {
            task.cancel()
        }
    }

    public func sendBinary(_ data: Data) async throws {
        let task = try current()
        try await withTaskCancellationHandler {
            try await task.send(.data(data))
        } onCancel: {
            task.cancel()
        }
    }

    public func receive() async throws -> GrokSocketEvent {
        let task: URLSessionWebSocketTask
        do {
            task = try current()
        } catch {
            return .closed(code: 1006, reason: "websocket is not connected")
        }
        return await withTaskCancellationHandler {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    return .text(text)
                case .data(let data):
                    return .binary(data)
                @unknown default:
                    StageMirror.note("websocket message type unknown")
                    return .text("")
                }
            } catch {
                let code = task.closeCode.rawValue
                let ns = error as NSError
                var reason = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
                if let http = (task.response as? HTTPURLResponse)?.statusCode {
                    reason = "http=\(http) \(reason)"
                }
                return .closed(code: code == 0 ? 1006 : code, reason: reason)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// `cancel(with: .normalClosure)` waits to write a close frame. Under a `pf`
    /// drop that frame never leaves, and `receive`/`send` stay parked. Cancel
    /// the task locally and invalidate this socket's session so those calls fail
    /// without a network round trip.
    public func close() async {
        let handoff: (task: URLSessionWebSocketTask?, alreadyClosed: Bool) = state.withLock { state in
            if state.closed {
                return (nil, true)
            }
            state.closed = true
            let task = state.task
            state.task = nil
            return (task, false)
        }
        if handoff.alreadyClosed { return }
        handoff.task?.cancel()
        session.invalidateAndCancel()
    }

    private func current() throws -> URLSessionWebSocketTask {
        try state.withLock { state in
            guard let task = state.task, !state.closed else {
                throw EngineError.socket("websocket is not connected")
            }
            return task
        }
    }
    #else
    public init() {}

    public func connect(url: URL, authorizationBearer: String) async throws {
        throw EngineError.socket("URLSession WebSocket STT transport requires macOS")
    }

    public func sendText(_ text: String) async throws {
        throw EngineError.socket("URLSession WebSocket STT transport requires macOS")
    }

    public func sendBinary(_ data: Data) async throws {
        throw EngineError.socket("URLSession WebSocket STT transport requires macOS")
    }

    public func receive() async throws -> GrokSocketEvent {
        throw EngineError.socket("URLSession WebSocket STT transport requires macOS")
    }

    public func close() async {}
    #endif
}
