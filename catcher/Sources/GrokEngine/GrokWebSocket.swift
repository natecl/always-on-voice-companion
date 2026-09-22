import Foundation
import TranscriptionEngine

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
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

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
        lock.lock()
        self.task = task
        lock.unlock()
    }

    public func sendText(_ text: String) async throws {
        try await current().send(.string(text))
    }

    public func sendBinary(_ data: Data) async throws {
        try await current().send(.data(data))
    }

    public func receive() async throws -> GrokSocketEvent {
        do {
            let message = try await current().receive()
            switch message {
            case .string(let text):
                return .text(text)
            case .data(let data):
                return .binary(data)
            @unknown default:
                return .text("")
            }
        } catch {
            let task = currentOptional()
            let code = task?.closeCode.rawValue ?? 1006
            return .closed(code: code, reason: String(describing: error))
        }
    }

    public func close() async {
        takeTask()?.cancel(with: .normalClosure, reason: nil)
    }

    private func takeTask() -> URLSessionWebSocketTask? {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        return task
    }

    private func current() throws -> URLSessionWebSocketTask {
        lock.lock()
        defer { lock.unlock() }
        guard let task else {
            throw EngineError.socket("websocket is not connected")
        }
        return task
    }

    private func currentOptional() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
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
