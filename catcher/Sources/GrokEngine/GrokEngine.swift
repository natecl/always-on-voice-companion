import AudioCapture
import Diagnostics
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
    /// No server message for this long, while a send is still in flight or bytes
    /// have been written since the last message, means the socket is black-holed.
    /// A `pf` drop does not FIN/RST the WebSocket.
    public var inboundStall: Duration
    public var authProbe: @Sendable (String) async -> AuthProbeResult

    public init(
        apiKey: String,
        url: URL,
        makeTransport: @escaping @Sendable () -> any GrokTransport,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        nowMs: (@Sendable () -> Int)? = nil,
        handshakeTimeout: Duration = .seconds(5),
        chunkBytes: Int = AudioFormat.chunkBytes,
        inboundStall: Duration = .seconds(5),
        authProbe: @escaping @Sendable (String) async -> AuthProbeResult = { key in
            await GrokProbe.fetchAuthStatus(apiKey: key)
        }
    ) {
        self.apiKey = apiKey
        self.url = url
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.nowMs = nowMs
        self.handshakeTimeout = handshakeTimeout
        self.chunkBytes = chunkBytes
        self.inboundStall = inboundStall
        self.authProbe = authProbe
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
public actor GrokEngine: TranscriptionEngine, EngineDiagnostics {
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
    /// Owns reconnect. Independent of the reader: a dropped close frame never wakes `receive`.
    private var recovery: Task<Void, Never>?
    private var socketGeneration = 0
    /// Socket generation that currently owns `pump`. A hung send keeps its task; a new socket must still pump.
    private var pumpOwner: Int?
    /// Chunk removed from `pending` and not yet accepted by `send`. A blocked send is not in `replay`.
    private var inFlight = Data()
    private var inFlightGeneration: Int?
    /// Bytes sent on this socket since the last server message. Replayed after a stall.
    private var replay = Data()
    private var bytesAtLastInbound = 0
    private var lastInbound = Date()
    private var lastSocketOrigin = 0
    private var handshakeStarted: ContinuousClock.Instant?
    private var handshakeMs: Int?
    private var lastCloseCode: Int?
    private var lastCloseReason: String?
    private var lastError: String?
    private var httpStatus: Int?
    private var httpBody: String?
    private var unknownMessages: [String] = []
    private var sendErrors = 0
    private var binaryFrames = 0
    private var authProbed = false

    public init(track: AudioTrack, configuration: GrokEngineConfiguration = .live()) {
        self.track = track
        self.configuration = configuration
        let pair = AsyncStream<EngineEvent>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func snapshot() async -> EngineDiagnosticsSnapshot {
        EngineDiagnosticsSnapshot(
            bytesSent: bytesSent,
            pendingCount: pending.count,
            handshakeMs: handshakeMs,
            lastCloseCode: lastCloseCode,
            lastCloseReason: lastCloseReason,
            lastError: lastError,
            httpStatus: httpStatus,
            httpBody: httpBody,
            unknownMessages: unknownMessages,
            sendErrors: sendErrors,
            binaryFrames: binaryFrames
        )
    }

    public func connect(track: AudioTrack) async throws {
        self.track = track
        continuation.yield(.state(.connecting))
        guard !configuration.apiKey.isEmpty else {
            lastError = "missing XAI_API_KEY"
            continuation.yield(.state(.failed(reason: "missing XAI_API_KEY")))
            continuation.yield(.error(.missingAPIKey))
            throw EngineError.missingAPIKey
        }
        let transport = configuration.makeTransport()
        self.transport = transport
        handshakeStarted = ContinuousClock.now
        do {
            try await transport.connect(url: configuration.url, authorizationBearer: configuration.apiKey)
        } catch {
            lastError = ErrorDetail.sentence(error)
            continuation.yield(.state(.failed(reason: String(describing: error))))
            continuation.yield(.error(.socket(String(describing: error))))
            await attachAuthProbe()
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
        recovery?.cancel()
        let pendingRecovery = recovery
        await transport?.close()
        await pendingRecovery?.value
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    private func waitForReady() async throws {
        let deadline = Date().addingTimeInterval(Self.seconds(configuration.handshakeTimeout))
        while !ready {
            if let handshakeFailure {
                reader?.cancel()
                if lastError == nil { lastError = String(describing: handshakeFailure) }
                await attachAuthProbe()
                throw handshakeFailure
            }
            if Date() >= deadline {
                reader?.cancel()
                lastError = "handshakeTimeout"
                continuation.yield(.state(.failed(reason: "no transcript.created")))
                continuation.yield(.error(.handshakeTimeout))
                await attachAuthProbe()
                throw EngineError.handshakeTimeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func readLoop() async {
        let generation = socketGeneration
        while !finishRequested && !Task.isCancelled && generation == socketGeneration {
            guard let transport else { return }
            do {
                let event = try await transport.receive()
                if finishRequested || Task.isCancelled || generation != socketGeneration { return }
                await handle(event, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                if finishRequested || Task.isCancelled || generation != socketGeneration { return }
                lastError = ErrorDetail.sentence(error)
                await handle(.closed(code: 1006, reason: ErrorDetail.sentence(error)), generation: generation)
            }
        }
    }

    private func handle(_ event: GrokSocketEvent, generation: Int) async {
        guard generation == socketGeneration else { return }
        switch event {
        case .text(let text):
            bytesAtLastInbound = bytesSent
            lastInbound = Date()
            apply(GrokMessages.decode(text))
        case .binary:
            binaryFrames += 1
            break
        case .closed(let code, let reason):
            guard !finishRequested else { return }
            lastCloseCode = code
            lastCloseReason = reason
            if !hasBeenReady {
                handshakeFailure = .socket("closed \(code) \(reason)")
                if lastError == nil { lastError = "closed \(code) \(reason)" }
                return
            }
            socketDied(code: code, reason: reason)
        }
    }

    /// Start the one reconnect task. `reconnect` is what yields `gap` and then
    /// `streaming` (the verifier writes `resumed`). Waiting for `receive` to
    /// observe the close never happens under a `pf` drop: the close frame is
    /// outbound and is discarded, so the reader stays parked.
    private func socketDied(code: Int, reason: String) {
        guard hasBeenReady, !finishRequested, recovery == nil else { return }
        ready = false
        socketGeneration += 1
        pumpOwner = nil
        let dead = transport
        transport = nil
        // Detached so cancelling the stalled reader or the watchdog does not
        // cancel the reconnect that those two tasks just asked for.
        recovery = Task.detached {
            await dead?.close()
            await self.reconnect(code: code, reason: reason)
        }
        watchdog?.cancel()
        watchdog = nil
        reader?.cancel()
        reader = nil
    }

    private func reconnect(code: Int, reason: String) async {
        defer { recovery = nil }
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
                // A connect started while `pf` is still dropping SYNs will not
                // fail on its own until TCP gives up. Bound it so the backoff
                // loop can open a fresh socket after the rule clears.
                try await open(next)
                transport = next
                try await readUntilCreated(next)
                await pump()
                if finishRequested { return }
                if !ready {
                    reader?.cancel()
                    reader = nil
                    await next.close()
                    transport = nil
                    continue
                }
                // End the hole on the new socket's origin so the resumed ann and
                // the next seg share one session time.
                if let span = gap.end(atMs: lastSocketOrigin) {
                    continuation.yield(.gap(fromMs: span.fromMs, toMs: span.toMs))
                }
                backoff = BackoffSchedule()
                continuation.yield(.state(.streaming))
                reader = Task { await self.readLoop() }
                armWatchdog()
                return
            } catch {
                continuation.yield(.error(.socket(String(describing: error))))
                await next.close()
                transport = nil
            }
        }
    }

    /// `connect` has no deadline. The handshake timeout is the same budget the
    /// engine already uses for `transcript.created`.
    private func open(_ transport: any GrokTransport) async throws {
        let url = configuration.url
        let key = configuration.apiKey
        let timeout = configuration.handshakeTimeout
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await transport.connect(url: url, authorizationBearer: key)
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            guard try await group.next() ?? false else {
                throw EngineError.handshakeTimeout
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
            if handshakeMs == nil, let handshakeStarted {
                handshakeMs = Self.elapsedMilliseconds(since: handshakeStarted)
            }
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
            if lastError == nil { lastError = message }
            continuation.yield(.error(.protocol(message)))
            continuation.yield(.state(.degraded(reason: message)))
        case .unknown(let text):
            if unknownMessages.count < 3 {
                unknownMessages.append(String(text.prefix(512)))
            }
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
        guard pumpOwner == nil, ready, let transport else { return }
        let generation = socketGeneration
        pumpOwner = generation
        defer {
            if pumpOwner == generation {
                pumpOwner = nil
            }
        }
        while pending.count >= configuration.chunkBytes && generation == socketGeneration {
            let size = configuration.chunkBytes
            let chunk = Data(pending.prefix(size))
            pending.removeFirst(size)
            inFlight = chunk
            inFlightGeneration = generation
            do {
                try await transport.sendBinary(chunk)
                if generation != socketGeneration {
                    restoreInFlight(chunk, generation: generation)
                    return
                }
                inFlight.removeAll(keepingCapacity: false)
                inFlightGeneration = nil
                bytesSent += chunk.count
                replay.append(chunk)
                if replay.count > Self.replayCap {
                    replay.removeFirst(replay.count - Self.replayCap)
                }
            } catch {
                if generation != socketGeneration {
                    restoreInFlight(chunk, generation: generation)
                    return
                }
                inFlight.removeAll(keepingCapacity: false)
                inFlightGeneration = nil
                pending.insert(contentsOf: chunk, at: 0)
                ready = false
                sendErrors += 1
                if lastError == nil { lastError = ErrorDetail.sentence(error) }
                continuation.yield(.error(.socket(String(describing: error))))
                await transport.close()
                socketDied(code: 1006, reason: ErrorDetail.sentence(error))
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
                sendErrors += 1
                if lastError == nil { lastError = ErrorDetail.sentence(error) }
                continuation.yield(.error(.socket(String(describing: error))))
            }
        }
        do {
            try await transport.sendText(GrokMessages.audioDone)
        } catch {
            sendErrors += 1
            if lastError == nil { lastError = ErrorDetail.sentence(error) }
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

    private func restoreInFlight(_ chunk: Data, generation: Int) {
        guard inFlightGeneration == generation, inFlight == chunk else { return }
        pending.insert(contentsOf: chunk, at: 0)
        inFlight.removeAll(keepingCapacity: false)
        inFlightGeneration = nil
    }

    private func reclaimReplay() {
        if !inFlight.isEmpty {
            pending.insert(contentsOf: inFlight, at: 0)
            inFlight.removeAll(keepingCapacity: false)
            inFlightGeneration = nil
        }
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

    /// `send` can return while the packets sit in the kernel, or it can sit
    /// forever on the one in-flight chunk. Either way `receive` does not return.
    /// A server message sets the watermark to every byte `send` has already
    /// accepted, so a blocked next send has `bytesSent == bytesAtLastInbound`
    /// and must still count. The timer resets on every server message.
    private func watchInbound(_ stall: Duration) async {
        let limit = Self.seconds(stall)
        let generation = socketGeneration
        while !Task.isCancelled && !finishRequested && generation == socketGeneration {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            if Task.isCancelled || finishRequested || !ready || generation != socketGeneration { return }
            let outstanding = bytesSent > bytesAtLastInbound || !inFlight.isEmpty
            if !outstanding { continue }
            if Date().timeIntervalSince(lastInbound) >= limit {
                socketDied(code: 1006, reason: "inbound stall")
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

    private func attachAuthProbe() async {
        guard !authProbed, !hasBeenReady else { return }
        authProbed = true
        let result = await configuration.authProbe(configuration.apiKey)
        httpStatus = result.http
        if !result.body.isEmpty {
            httpBody = result.body
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
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
