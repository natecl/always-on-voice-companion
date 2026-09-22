import AudioCapture
import Foundation
import TranscriptionEngine

public struct GrokEngineConfiguration: Sendable {
    public var apiKey: String
    public var url: URL
    public var makeTransport: @Sendable () -> any GrokTransport
    public var sleep: @Sendable (Duration) async -> Void
    public var nowMs: (@Sendable () -> Int)?
    public var handshakeTimeout: Duration
    public var chunkBytes: Int

    public init(
        apiKey: String,
        url: URL,
        makeTransport: @escaping @Sendable () -> any GrokTransport,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        nowMs: (@Sendable () -> Int)? = nil,
        handshakeTimeout: Duration = .seconds(5),
        chunkBytes: Int = AudioFormat.chunkBytes
    ) {
        self.apiKey = apiKey
        self.url = url
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.nowMs = nowMs
        self.handshakeTimeout = handshakeTimeout
        self.chunkBytes = chunkBytes
    }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> GrokEngineConfiguration {
        GrokEngineConfiguration(
            apiKey: environment["XAI_API_KEY"] ?? "",
            url: GrokWebSocket.url(),
            makeTransport: { URLSessionGrokTransport() }
        )
    }
}

public enum GrokEngineBootstrap {
    /// Registers the Grok builder. Call once at process start. The factory remains the switch.
    public static func install() {
        EngineFactory.register("grok") { track in
            GrokEngine(track: track)
        }
    }
}

/// Streaming STT against `wss://api.x.ai/v1/stt`. No audio leaves until
/// `transcript.created`. Word times are re-based onto session audio time.
public actor GrokEngine: TranscriptionEngine {
    public nonisolated let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let configuration: GrokEngineConfiguration
    private let startedHost: UInt64
    private var track: AudioTrack
    private var transport: (any GrokTransport)?
    private var pending = Data()
    private var bytesSent = 0
    private var socketOriginMs = 0
    private var ready = false
    private var hasBeenReady = false
    private var pumping = false
    private var finishRequested = false
    private var seq = 0
    private var emittedFinal = false
    private var backoff = BackoffSchedule()
    private var gap = GapAccount()
    private var handshakeFailure: EngineError?
    private var reader: Task<Void, Never>?

    public init(track: AudioTrack, configuration: GrokEngineConfiguration = .live()) {
        self.track = track
        self.configuration = configuration
        self.startedHost = HostClock.now()
        let pair = AsyncStream<EngineEvent>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func connect(track: AudioTrack) async throws {
        self.track = track
        continuation.yield(.state(.connecting))
        guard !configuration.apiKey.isEmpty else {
            continuation.yield(.state(.failed(reason: "missing XAI_API_KEY")))
            continuation.yield(.error(.missingAPIKey))
            throw EngineError.missingAPIKey
        }
        let transport = configuration.makeTransport()
        self.transport = transport
        do {
            try await transport.connect(url: configuration.url, authorizationBearer: configuration.apiKey)
        } catch {
            continuation.yield(.state(.failed(reason: String(describing: error))))
            continuation.yield(.error(.socket(String(describing: error))))
            throw EngineError.socket(String(describing: error))
        }
        reader = Task { await self.readLoop() }
        try await waitForReady()
        continuation.yield(.state(.ready))
        continuation.yield(.state(.streaming))
        await pump()
    }

    public func send(_ frame: PCMFrame) async throws {
        guard !finishRequested else { return }
        pending.append(frame.data)
        await pump()
    }

    public func finish() async {
        guard !finishRequested else { return }
        finishRequested = true
        await flushTail()
        reader?.cancel()
        await transport?.close()
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    private func waitForReady() async throws {
        let deadline = Date().addingTimeInterval(Self.seconds(configuration.handshakeTimeout))
        while !ready {
            if let handshakeFailure {
                reader?.cancel()
                throw handshakeFailure
            }
            if Date() >= deadline {
                reader?.cancel()
                continuation.yield(.state(.failed(reason: "no transcript.created")))
                continuation.yield(.error(.handshakeTimeout))
                throw EngineError.handshakeTimeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func readLoop() async {
        while !finishRequested {
            guard let transport else { return }
            do {
                let event = try await transport.receive()
                if finishRequested || Task.isCancelled { return }
                await handle(event)
            } catch is CancellationError {
                return
            } catch {
                if finishRequested || Task.isCancelled { return }
                await handle(.closed(code: 1006, reason: String(describing: error)))
            }
        }
    }

    private func handle(_ event: GrokSocketEvent) async {
        switch event {
        case .text(let text):
            apply(GrokMessages.decode(text))
        case .binary:
            break
        case .closed(let code, let reason):
            guard !finishRequested else { return }
            if !hasBeenReady {
                handshakeFailure = .socket("closed \(code) \(reason)")
                return
            }
            await reconnect(code: code, reason: reason)
        }
    }

    private func reconnect(code: Int, reason: String) async {
        while !finishRequested {
            ready = false
            gap.begin(atMs: currentMs())
            let delay = backoff.delay
            continuation.yield(.state(.degraded(
                reason: "ws closed (\(code)); reconnect #\(backoff.attempt + 1) in \(Int(Self.seconds(delay).rounded()))s"
            )))
            backoff = backoff.advanced()
            await configuration.sleep(delay)
            if finishRequested { return }
            let next = configuration.makeTransport()
            do {
                try await next.connect(url: configuration.url, authorizationBearer: configuration.apiKey)
                transport = next
                try await readUntilCreated(next)
                if let span = gap.end(atMs: currentMs()) {
                    continuation.yield(.gap(fromMs: span.fromMs, toMs: span.toMs))
                }
                continuation.yield(.state(.streaming))
                await pump()
                return
            } catch {
                continuation.yield(.error(.socket(String(describing: error))))
            }
        }
    }

    private func readUntilCreated(_ transport: any GrokTransport) async throws {
        let deadline = Date().addingTimeInterval(Self.seconds(configuration.handshakeTimeout))
        while !ready && !finishRequested {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw EngineError.handshakeTimeout
            }
            let event = try await receiveWithTimeout(transport, timeout: .milliseconds(max(1, Int(remaining * 1000))))
            switch event {
            case .text(let text):
                apply(GrokMessages.decode(text))
            case .binary:
                break
            case .closed(let code, let reason):
                throw EngineError.socket("closed \(code) \(reason)")
            }
        }
    }

    private func apply(_ message: GrokServerMessage) {
        switch message {
        case .created:
            socketOriginMs = PCMClock.milliseconds(bytesSent: bytesSent)
            ready = true
            hasBeenReady = true
        case .partial(let transcript):
            emit(transcript, forceFinal: false)
        case .done(let transcript):
            if !emittedFinal && !transcript.text.isEmpty {
                emit(transcript, forceFinal: true)
            }
        case .error(let message):
            continuation.yield(.error(.protocol(message)))
            continuation.yield(.state(.degraded(reason: message)))
        case .unknown:
            break
        }
    }

    private func emit(_ transcript: GrokTranscript, forceFinal: Bool) {
        let final = forceFinal || transcript.isFinal
        let rebase = TimestampRebase(originMs: socketOriginMs)
        let words = transcript.words.map { word in
            TranscriptWord(
                w: word.text,
                startMs: rebase.sessionMs(engineSeconds: word.start),
                endMs: rebase.sessionMs(engineSeconds: word.end),
                conf: word.confidence
            )
        }
        let startMs = rebase.sessionMs(engineSeconds: transcript.start)
        let durationEnd = rebase.sessionMs(engineSeconds: transcript.start + transcript.duration)
        let endMs = max(durationEnd, words.map(\.endMs).max() ?? durationEnd)
        let confidences = words.compactMap(\.conf)
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        seq += 1
        if final { emittedFinal = true }
        continuation.yield(.transcript(TranscriptEvent(
            track: track,
            kind: final ? .final : .partial,
            text: transcript.text,
            words: words,
            speaker: speaker(transcript),
            confidence: confidence,
            seq: seq,
            startMs: startMs,
            endMs: max(endMs, startMs)
        )))
    }

    private func speaker(_ transcript: GrokTranscript) -> String? {
        var counts: [Int: Int] = [:]
        for word in transcript.words {
            if let speaker = word.speaker {
                counts[speaker, default: 0] += 1
            }
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return "S\(top + 1)"
    }

    private func pump() async {
        guard !pumping, ready, let transport else { return }
        pumping = true
        defer { pumping = false }
        while pending.count >= configuration.chunkBytes {
            let size = configuration.chunkBytes
            let chunk = Data(pending.prefix(size))
            pending.removeFirst(size)
            do {
                try await transport.sendBinary(chunk)
                bytesSent += chunk.count
            } catch {
                pending.insert(contentsOf: chunk, at: 0)
                ready = false
                continuation.yield(.error(.socket(String(describing: error))))
                return
            }
        }
    }

    private func flushTail() async {
        guard ready, let transport else {
            if !pending.isEmpty {
                continuation.yield(.error(.protocol(
                    "finish before transcript.created; \(pending.count) bytes not sent"
                )))
            }
            return
        }
        if !pending.isEmpty {
            let tail = pending
            pending.removeAll(keepingCapacity: false)
            do {
                try await transport.sendBinary(tail)
                bytesSent += tail.count
            } catch {
                continuation.yield(.error(.socket(String(describing: error))))
            }
        }
        do {
            try await transport.sendText(GrokMessages.audioDone)
        } catch {
            continuation.yield(.error(.socket(String(describing: error))))
        }
    }

    private func currentMs() -> Int {
        if let nowMs = configuration.nowMs {
            return nowMs()
        }
        return HostClock.milliseconds(from: startedHost, to: HostClock.now())
    }

    private enum ReceiveRace: Sendable {
        case event(GrokSocketEvent)
        case timeout
    }

    private func receiveWithTimeout(_ transport: any GrokTransport, timeout: Duration) async throws -> GrokSocketEvent {
        let nanos = Self.nanoseconds(timeout)
        return try await withThrowingTaskGroup(of: ReceiveRace.self) { group in
            group.addTask {
                let event = try await transport.receive()
                return .event(event)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                return .timeout
            }
            let first = try await group.next() ?? .timeout
            group.cancelAll()
            switch first {
            case .event(let event):
                return event
            case .timeout:
                throw EngineError.handshakeTimeout
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        let seconds = UInt64(max(0, parts.seconds)) * 1_000_000_000
        let nanos = UInt64(max(0, parts.attoseconds / 1_000_000_000))
        return seconds &+ nanos
    }
}
