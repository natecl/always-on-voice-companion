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
        var receives: [UUID: CheckedContinuation<GrokSocketEvent, Never>] = [:]
        var sends: [UUID: CheckedContinuation<Void, Error>] = [:]
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
        let stored = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.task = task
            return true
        }
        if stored {
            task.resume()
        } else {
            task.cancel()
        }
    }

    public func sendText(_ text: String) async throws {
        try await send(.string(text))
    }

    public func sendBinary(_ data: Data) async throws {
        try await send(.data(data))
    }

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let task = try current()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let parked = state.withLock { state -> Bool in
                    guard state.task != nil, !state.closed else { return false }
                    state.sends[id] = continuation
                    return true
                }
                if !parked {
                    continuation.resume(throwing: EngineError.socket("websocket is not connected"))
                    return
                }
                task.send(message) { [weak self] error in
                    if let error {
                        self?.completeSend(id, .failure(error))
                    } else {
                        self?.completeSend(id, .success(()))
                    }
                }
            }
        } onCancel: {
            self.abort()
        }
    }

    public func receive() async throws -> GrokSocketEvent {
        let task: URLSessionWebSocketTask
        do {
            task = try current()
        } catch {
            return .closed(code: 1006, reason: "websocket is not connected")
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<GrokSocketEvent, Never>) in
                let parked = state.withLock { state -> Bool in
                    guard state.task != nil, !state.closed else { return false }
                    state.receives[id] = continuation
                    return true
                }
                if !parked {
                    continuation.resume(returning: .closed(code: 1006, reason: "websocket is not connected"))
                    return
                }
                task.receive { [weak self] result in
                    guard let self else { return }
                    self.completeReceive(id, self.event(from: result))
                }
            }
        } onCancel: {
            self.abort()
        }
    }

    /// `URLSessionWebSocketTask.receive()` does not resume when `pf` drops the
    /// outbound SYN, and `invalidateAndCancel()` waits on that same parked
    /// task. `cancel()` on the calling thread can wait too: the Mac P3 run
    /// never got past teardown, so reconnect never yielded `gap`. Resume our
    /// continuations and cancel the task off this call stack, and return
    /// without waiting for either. Do not invalidate the session.
    public func close() async {
        abort()
    }

    private func abort() {
        let taken = state.withLock { state -> (URLSessionWebSocketTask?, [CheckedContinuation<GrokSocketEvent, Never>], [CheckedContinuation<Void, Error>]) in
            let task = state.task
            let receives = Array(state.receives.values)
            let sends = Array(state.sends.values)
            state.receives.removeAll()
            state.sends.removeAll()
            state.closed = true
            state.task = nil
            return (task, receives, sends)
        }
        // A custom session deallocated with a task still inside the dropped
        // handshake can crash. Keep it alive across the detached cancel.
        SessionHold.shared.keep(session)
        let teardown = SocketTeardown(task: taken.0, receives: taken.1, sends: taken.2)
        Task.detached {
            teardown.run()
        }
    }

    private func completeReceive(_ id: UUID, _ event: GrokSocketEvent) {
        let continuation = state.withLock { state -> CheckedContinuation<GrokSocketEvent, Never>? in
            state.receives.removeValue(forKey: id)
        }
        continuation?.resume(returning: event)
    }

    private func completeSend(_ id: UUID, _ result: Result<Void, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.sends.removeValue(forKey: id)
        }
        continuation?.resume(with: result)
    }

    private func event(from result: Result<URLSessionWebSocketTask.Message, Error>) -> GrokSocketEvent {
        switch result {
        case .success(let message):
            switch message {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .binary(data)
            @unknown default:
                StageMirror.note("websocket message type unknown")
                return .text("")
            }
        case .failure(let error):
            let task = state.withLock { $0.task }
            let code = task?.closeCode.rawValue ?? 0
            let ns = error as NSError
            var reason = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
            if let http = (task?.response as? HTTPURLResponse)?.statusCode {
                reason = "http=\(http) \(reason)"
            }
            return .closed(code: code == 0 ? 1006 : code, reason: reason)
        }
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

#if os(macOS)
/// Resumes parked `send`/`receive` continuations, then cancels the task.
/// Both steps run off the caller's stack: a synchronous resume re-enters the
/// engine, and `URLSessionWebSocketTask.cancel()` does not return while `pf`
/// has the receive parked.
private final class SocketTeardown: @unchecked Sendable {
    private let task: URLSessionWebSocketTask?
    private let receives: [CheckedContinuation<GrokSocketEvent, Never>]
    private let sends: [CheckedContinuation<Void, Error>]

    init(
        task: URLSessionWebSocketTask?,
        receives: [CheckedContinuation<GrokSocketEvent, Never>],
        sends: [CheckedContinuation<Void, Error>]
    ) {
        self.task = task
        self.receives = receives
        self.sends = sends
    }

    func run() {
        for continuation in receives {
            continuation.resume(returning: .closed(code: 1006, reason: "websocket is not connected"))
        }
        for continuation in sends {
            continuation.resume(throwing: EngineError.socket("websocket is not connected"))
        }
        task?.cancel()
    }
}

/// Failed handshakes must not deallocate their `URLSession` while a task is
/// still outstanding, and they must not call `invalidateAndCancel()` on the
/// reconnect path. That call waits for `receive` and wedges the next session.
private final class SessionHold: @unchecked Sendable {
    static let shared = SessionHold()

    private struct Held: @unchecked Sendable {
        var sessions: [URLSession] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: Held())

    func keep(_ session: URLSession) {
        state.withLock { held in
            if !held.sessions.contains(where: { $0 === session }) {
                held.sessions.append(session)
            }
        }
    }
}
#endif
