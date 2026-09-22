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
    /// No server message for this long while audio is still being written means
    /// the socket is black-holed. `pf` drop does not close a WebSocket.
    public var inboundStall: Duration

    public init(
        apiKey: String,
        url: URL,
        makeTransport: @escaping @Sendable () -> any GrokTransport,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        nowMs: (@Sendable () -> Int)? = nil,
        handshakeTimeout: Duration = .seconds(5),
        chunkBytes: Int = AudioFormat.chunkBytes,
        inboundStall: Duration = .seconds(5)
    ) {
        self.apiKey = apiKey
        self.url = url
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.nowMs = nowMs
        self.handshakeTimeout = handshakeTimeout
        self.chunkBytes = chunkBytes
        self.inboundStall = inboundStall
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
    /// Chunk finals (`is_final && !speech_final`) for the current utterance were stored.
    /// The following `speech_final` is that same utterance stitched again — not new text.
    private var utteranceHadChunk = false
    /// This socket already stored a final. `transcript.done` repeats the whole socket.
    private var socketEmittedFinal = false
    private var backoff = BackoffSchedule()
    private var gap = GapAccount()
    private var handshakeFailure: EngineError?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Bytes sent on this socket since the last server message. Replayed after a stall.
    private var replay = Data()
    private var bytesAtLastInbound = 0
    private var lastInbound = Date()
    private var lastSocketOrigin = 0

    public init(track: AudioTrack, configuration: GrokEngineConfiguration = .live()) {
        self.track = track
        self.configuration = configuration
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
        armWatchdog()
    }

    public func send(_ frame: PCMFrame) async throws {
        guard !finishRequested else { return }
        pending.append(frame.data)
        await pump()
    }

    public func finish() async {
        guard !finishRequested else { return }
        finishRequested = true
        watchdog?.cancel()
        watchdog = nil
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
            bytesAtLastInbound = bytesSent
            lastInbound = Date()
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
        watchdog?.cancel()
        watchdog = nil
        var prepared = false
        while !finishRequested {
            ready = false
            if !prepared {
                reclaimReplay()
                gap.begin(atMs: currentMs())
                prepared = true
            }
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
                // End the hole on the new socket's origin so the resumed ann and
                // the next seg share one session time.
                if let span = gap.end(atMs: lastSocketOrigin) {
                    continuation.yield(.gap(fromMs: span.fromMs, toMs: span.toMs))
                }
                backoff = BackoffSchedule()
                continuation.yield(.state(.streaming))
                await pump()
                armWatchdog()
                return
            } catch {
                continuation.yield(.error(.socket(String(describing: error))))
                await next.close()
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
                // Same as the reader. `created` on a new socket must start the
                // stall clock; leaving the pre-drop timestamp in place made the
                // replay look already stalled and the socket was closed again
                // before a seg could come back.
                bytesAtLastInbound = bytesSent
                lastInbound = Date()
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
            let audioMs = PCMClock.milliseconds(bytesSent: bytesSent)
            if hasBeenReady {
                // Wall time moved during the stall; the byte cursor did not.
                // Landing here keeps the resumed seg at or after the resumed ann.
                socketOriginMs = max(audioMs, currentMs())
            } else {
                socketOriginMs = audioMs
            }
            lastSocketOrigin = socketOriginMs
            ready = true
            hasBeenReady = true
            utteranceHadChunk = false
            socketEmittedFinal = false
        case .partial(let transcript):
            replay.removeAll(keepingCapacity: true)
            commit(transcript, fromDone: false)
        case .done(let transcript):
            replay.removeAll(keepingCapacity: true)
            commit(transcript, fromDone: true)
        case .error(let message):
            continuation.yield(.error(.protocol(message)))
            continuation.yield(.state(.degraded(reason: message)))
        case .unknown:
            break
        }
    }

    /// xAI sends three transcript states. Interim (`is_final=false`) is UI-only.
    /// A chunk final locks ~3s and must be stored. `speech_final` is the chunks
    /// stitched into one utterance — storing it again doubles the passage.
    /// `transcript.done` is the same text for the whole socket after `audio.done`.
    /// Empty finals are silence endpoint spam, not speech, and are not stored.
    private func commit(_ transcript: GrokTranscript, fromDone: Bool) {
        let spoken = !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if fromDone {
            guard spoken, !socketEmittedFinal else { return }
            emit(transcript, forceFinal: true)
            return
        }
        if !transcript.isFinal {
            guard spoken else { return }
            emit(transcript, forceFinal: false)
            return
        }
        if transcript.speechFinal {
            let hadChunk = utteranceHadChunk
            utteranceHadChunk = false
            guard spoken, !hadChunk else { return }
            emit(transcript, forceFinal: true)
            return
        }
        guard spoken else { return }
        utteranceHadChunk = true
        emit(transcript, forceFinal: true)
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
        if final { socketEmittedFinal = true }
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
                replay.append(chunk)
                if replay.count > Self.replayCap {
                    replay.removeFirst(replay.count - Self.replayCap)
                }
            } catch {
                pending.insert(contentsOf: chunk, at: 0)
                ready = false
                continuation.yield(.error(.socket(String(describing: error))))
                await transport.close()
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
        return SessionClockAnchor.milliseconds()
    }

    /// 30s of PCM16 mono at 16 kHz. Older than that is outside one network kill.
    private static let replayCap = 16_000 * 2 * 30

    private func reclaimReplay() {
        guard !replay.isEmpty else { return }
        pending.insert(contentsOf: replay, at: 0)
        bytesSent = max(0, bytesSent - replay.count)
        replay.removeAll(keepingCapacity: false)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        // The replay send can take longer than the stall budget. Start the
        // window after those bytes are written, and do not treat them as acked.
        lastInbound = Date()
        let stall = configuration.inboundStall
        watchdog = Task { await self.watchInbound(stall) }
    }

    /// `send` succeeds while packets are dropped: the bytes sit in the kernel
    /// and `receive` never returns. Close the socket so the reader reconnects.
    /// The timer resets on every server message, so a live transcript does not
    /// look like a stall.
    private func watchInbound(_ stall: Duration) async {
        let limit = Self.seconds(stall)
        while !Task.isCancelled && !finishRequested {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            if Task.isCancelled || finishRequested || !ready { return }
            guard bytesSent > bytesAtLastInbound else { continue }
            if Date().timeIntervalSince(lastInbound) >= limit {
                ready = false
                let dead = transport
                await dead?.close()
                return
            }
        }
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
