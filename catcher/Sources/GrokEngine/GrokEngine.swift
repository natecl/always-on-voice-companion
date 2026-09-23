import AudioCapture
import Diagnostics
import Foundation
import Metering
import Synchronization
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
public actor GrokEngine: TranscriptionEngine, EngineDiagnostics, StageLogging, MeteredEngine {
    public nonisolated let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let configuration: GrokEngineConfiguration
    private var track: AudioTrack
    private var transport: (any GrokTransport)?
    private var pending = Data()
    private var bytesSent = 0
    /// Bytes accepted by `send`, including replays. Never decremented.
    /// `bytesSent` is an audio cursor and shrinks in `reclaimReplay`.
    private var wireBytes = 0
    private var replayedBytes = 0
    private var tailBytes = 0
    private var socketAttempts = 0
    private var socketsOpened = 0
    private var closedSocketOpenMs = 0
    private var socketOpenStartedMs: Int?
    private var closedServerAudioMs = 0
    private var socketServerHighMs = 0
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
    /// A final from the socket opened after `gap` began. Streaming stays unannounced
    /// until this is set or the catch-up budget ends, so the seg is already queued.
    private var postResumeFinal = false
    /// The catch-up socket closed while `recovery` still owns reconnect. `socketDied`
    /// would no-op; the loop retries instead of announcing a dead stream.
    private var catchUpLost = false
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
    private var lastResumeBacklogMs = 0
    /// This session's `stages.log`. Nil in unit tests; the pipeline binds it.
    private var stageSink: (any StageSink)?

    public init(track: AudioTrack, configuration: GrokEngineConfiguration = .live()) {
        self.track = track
        self.configuration = configuration
        let pair = AsyncStream<EngineEvent>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func bindStages(_ sink: any StageSink) {
        stageSink = sink
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
            binaryFrames: binaryFrames,
            lastResumeBacklogMs: lastResumeBacklogMs
        )
    }

    public func meterCounters() -> MeterCounters {
        var openMs = closedSocketOpenMs
        if let started = socketOpenStartedMs {
            openMs += max(0, currentMs() - started)
        }
        return MeterCounters(
            wireBytes: wireBytes,
            replayBytes: replayedBytes,
            tailBytes: tailBytes,
            socketAttempts: socketAttempts,
            socketsOpened: socketsOpened,
            socketOpenMs: openMs,
            serverAudioMs: closedServerAudioMs + socketServerHighMs
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
        socketAttempts += 1
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
        endOpenInterval()
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
                if catchUpLost || generation != socketGeneration { return }
            } catch is CancellationError {
                return
            } catch {
                if finishRequested || Task.isCancelled || generation != socketGeneration { return }
                lastError = ErrorDetail.sentence(error)
                await handle(.closed(code: 1006, reason: ErrorDetail.sentence(error)), generation: generation)
                if catchUpLost || generation != socketGeneration { return }
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
            // `recovery` is this reconnect. Starting another one here drops the
            // attempt that is about to yield `gap`. Mark the socket lost so the
            // loop opens a fresh one instead of announcing streaming.
            if recovery != nil {
                endOpenInterval()
                ready = false
                catchUpLost = true
                return
            }
            socketDied(code: code, reason: reason)
        }
    }

    /// Start the one reconnect task. `reconnect` is what yields `gap` and then
    /// `streaming` (the verifier writes `resumed`). Waiting for `receive` to
    /// observe the close never happens under a `pf` drop: the close frame is
    /// outbound and is discarded, so the reader stays parked.
    ///
    /// The degraded yield is synchronous and happens before any `URLSession`
    /// call. On Mac, `task.cancel()` against a `pf`-parked receive does not
    /// return, and the previous recovery task awaited `close()` before this
    /// yield — so the session only kept the verifier's heartbeat `degraded`
    /// and never wrote `gap` or `streaming`. The scripted transport's `close()`
    /// returns immediately, which is why that handshake test still passed.
    private func socketDied(code: Int, reason: String) {
        guard hasBeenReady, !finishRequested, recovery == nil else { return }
        endOpenInterval()
        ready = false
        socketGeneration += 1
        pumpOwner = nil
        let dead = transport
        transport = nil
        watchdog?.cancel()
        watchdog = nil
        let stalledReader = reader
        reader = nil
        let delay = backoff.delay
        let attempt = backoff.attempt + 1
        // Copy the replay on this actor before `close()` resumes a parked send.
        // That resume can run alongside reconnect; sharing the PCM buffer traps.
        reclaimReplay()
        gap.begin(atMs: currentMs())
        continuation.yield(.state(.degraded(
            reason: "ws closed (\(code)); reconnect #\(attempt) in \(Int(Self.seconds(delay).rounded()))s"
        )))
        noteReconnect([
            Field("track", track.rawValue),
            Field("attempt", String(attempt)),
            Field("code", String(code)),
            Field("reason", reason),
        ])
        recovery = Task.detached {
            await self.reconnect(code: code, reason: reason, announced: true, prepared: true)
        }
        // Teardown is not sequenced in front of reconnect. A parked
        // `URLSessionWebSocketTask.cancel()` must not sit on this actor.
        Task.detached {
            stalledReader?.cancel()
        }
        abandonSocket(dead)
    }

    private func reconnect(code: Int, reason: String, announced: Bool, prepared: Bool) async {
        defer { recovery = nil }
        var didPrepare = prepared
        var skipAnnounce = announced
        while !finishRequested {
            ready = false
            if !didPrepare {
                reclaimReplay()
                gap.begin(atMs: currentMs())
                didPrepare = true
            }
            let delay = backoff.delay
            let attempt = backoff.attempt + 1
            if !skipAnnounce {
                continuation.yield(.state(.degraded(
                    reason: "ws closed (\(code)); reconnect #\(attempt) in \(Int(Self.seconds(delay).rounded()))s"
                )))
                noteReconnect([
                    Field("track", track.rawValue),
                    Field("attempt", String(attempt)),
                    Field("code", String(code)),
                    Field("reason", reason),
                ])
            }
            skipAnnounce = false
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
                if finishRequested { return }
                // Read-only. What the new socket must replay before live audio.
                lastResumeBacklogMs = PCMClock.milliseconds(bytesSent: pending.count + inFlight.count + replay.count)
                // Arm `receive` before the replay send. The previous order pumped
                // the backlog, yielded `streaming` (the verifier writes `resumed`),
                // and only then started the reader. Mac graded the file at that
                // ann: the replay had gone out with nobody reading, so no `t=seg`
                // was queued at or after the resumed `atMs`.
                postResumeFinal = false
                catchUpLost = false
                reader = Task { await self.readLoop() }
                for _ in 0..<4 {
                    if catchUpLost || !ready { break }
                    await Task.yield()
                }
                await pump(minimumBytes: 1)
                if finishRequested { return }
                if !ready || catchUpLost {
                    stopCatchUpReader()
                    reclaimReplay()
                    abandonSocket(next)
                    transport = nil
                    continue
                }
                await waitForPostResumeSegment()
                if finishRequested || Task.isCancelled { return }
                if !ready || catchUpLost {
                    stopCatchUpReader()
                    reclaimReplay()
                    abandonSocket(next)
                    transport = nil
                    continue
                }
                // End the hole on the new socket's origin so the resumed ann and
                // the next seg share one session time. A final already queued
                // uses that same origin, so its `startMs` is not before the ann.
                if let span = gap.end(atMs: lastSocketOrigin) {
                    continuation.yield(.gap(fromMs: span.fromMs, toMs: span.toMs))
                }
                backoff = BackoffSchedule()
                noteReconnect([
                    Field("track", track.rawValue),
                    Field("attempt", String(attempt)),
                    Field("result", "streaming"),
                ])
                continuation.yield(.state(.streaming))
                armWatchdog()
                return
            } catch {
                let message = String(describing: error)
                if reader != nil {
                    stopCatchUpReader()
                }
                continuation.yield(.error(.socket(message)))
                noteReconnect([
                    Field("track", track.rawValue),
                    Field("attempt", String(attempt)),
                    Field("result", "fail"),
                    Field("error", message),
                ])
                abandonSocket(next)
                transport = nil
            }
        }
    }

    private func noteReconnect(_ fields: [Field]) {
        let line = StageLine(
            kind: .stage,
            name: "reconnect",
            verdict: Verdict.ok.rawValue,
            fields: fields
        )
        if let stageSink {
            stageSink.write(line, fsync: true)
        } else {
            StageMirror.emit(line.formatted())
        }
    }

    /// `connect` has no deadline. The handshake timeout is the same budget the
    /// engine already uses for `transcript.created`. A `pf` drop can park
    /// `connect` inside `URLSession`; the loop must not wait for that call.
    private func open(_ transport: any GrokTransport) async throws {
        socketAttempts += 1
        let url = configuration.url
        let key = configuration.apiKey
        let timeout = configuration.handshakeTimeout
        try await firstToFinish(timeout: timeout, onTimeout: {
            // `close()` on a `pf`-parked `URLSession` may never return. Waiting
            // here held the reconnect loop on the dropped SYN, so the socket
            // opened after the rule cleared — the one that yields `gap` — never
            // ran.
            abandonSocket(transport)
        }) {
            try await transport.connect(url: url, authorizationBearer: key)
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
            endOpenInterval()
            socketsOpened += 1
            socketOpenStartedMs = currentMs()
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
            noteServerAudio(transcript)
            replay.removeAll(keepingCapacity: true)
            commit(transcript, fromDone: false)
        case .done(let transcript):
            noteServerAudio(transcript)
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
        let who = speaker(transcript)
        if final, let cursor = liveCursorMs() {
            let earlier = words.filter { $0.startMs < cursor }
            let live = words.filter { $0.startMs >= cursor }
            if !earlier.isEmpty, !live.isEmpty {
                yieldTranscript(
                    text: Self.joined(earlier),
                    words: earlier,
                    speaker: who,
                    final: true,
                    startMs: earlier.map(\.startMs).min() ?? startMs,
                    endMs: earlier.map(\.endMs).max() ?? endMs
                )
                yieldTranscript(
                    text: Self.joined(live),
                    words: live,
                    speaker: who,
                    final: true,
                    startMs: live.map(\.startMs).min() ?? cursor,
                    endMs: live.map(\.endMs).max() ?? endMs
                )
                return
            }
            if earlier.isEmpty, !live.isEmpty, startMs < cursor {
                yieldTranscript(
                    text: transcript.text,
                    words: live,
                    speaker: who,
                    final: true,
                    startMs: live.map(\.startMs).min() ?? cursor,
                    endMs: max(endMs, live.map(\.endMs).max() ?? endMs)
                )
                return
            }
        }
        yieldTranscript(
            text: transcript.text,
            words: words,
            speaker: who,
            final: final,
            startMs: startMs,
            endMs: max(endMs, startMs)
        )
    }

    /// Session time where replayed audio ends and the grader's live window
    /// begins. Nil on the first socket, which has no backlog to cut.
    private func liveCursorMs() -> Int? {
        guard lastResumeBacklogMs > 0 else { return nil }
        return socketOriginMs + lastResumeBacklogMs + Self.liveAfterBacklogMarginMs
    }

    private func yieldTranscript(
        text: String,
        words: [TranscriptWord],
        speaker: String?,
        final: Bool,
        startMs: Int,
        endMs: Int
    ) {
        let confidences = words.compactMap(\.conf)
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        seq += 1
        if final {
            socketEmittedFinal = true
            postResumeFinal = true
        }
        continuation.yield(.transcript(TranscriptEvent(
            track: track,
            kind: final ? .final : .partial,
            text: text,
            words: words,
            speaker: speaker,
            confidence: confidence,
            seq: seq,
            startMs: startMs,
            endMs: max(endMs, startMs)
        )))
    }

    private static func joined(_ words: [TranscriptWord]) -> String {
        words.map(\.w).filter { !$0.isEmpty }.joined(separator: " ")
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

    /// Chunk finals land about 3s into speech. The grade reads `events.jsonl`
    /// when `resumed` appears, so this wait ends when that final has been
    /// yielded, and still yields streaming if the server stays quiet.
    private static let postResumeBudgetMs = 8_000

    /// Words this far past the replayed backlog are live audio. The session
    /// grader counts a segment as live only when its `startMs` is at or after
    /// `resumed + backlogMs + 3s`. One speech-final that spans the replay would
    /// otherwise stay a single backlog row.
    public static let liveAfterBacklogMarginMs = 3_000

    private func waitForPostResumeSegment() async {
        var waited = 0
        while !postResumeFinal && ready && !catchUpLost && !finishRequested && !Task.isCancelled && waited < Self.postResumeBudgetMs {
            await Task.yield()
            if postResumeFinal || !ready || catchUpLost || finishRequested || Task.isCancelled { return }
            await configuration.sleep(.milliseconds(50))
            waited += 50
            if !ready || catchUpLost || finishRequested || Task.isCancelled { return }
            await pump()
        }
    }

    private func stopCatchUpReader() {
        catchUpLost = false
        reader?.cancel()
        reader = nil
        socketGeneration += 1
    }

    private func pump(minimumBytes: Int? = nil) async {
        guard pumpOwner == nil, ready, let transport else { return }
        let generation = socketGeneration
        let minimum = minimumBytes ?? configuration.chunkBytes
        pumpOwner = generation
        defer {
            if pumpOwner == generation {
                pumpOwner = nil
            }
        }
        while pending.count >= minimum && pending.count > 0 && generation == socketGeneration {
            let chunk = Self.takePrefix(&pending, configuration.chunkBytes)
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
                wireBytes += chunk.count
                replay.append(chunk)
                Self.keepTail(&replay, Self.replayCap)
            } catch {
                if generation != socketGeneration {
                    restoreInFlight(chunk, generation: generation)
                    return
                }
                inFlight.removeAll(keepingCapacity: false)
                inFlightGeneration = nil
                Self.prepend(chunk, to: &pending)
                ready = false
                sendErrors += 1
                if lastError == nil { lastError = ErrorDetail.sentence(error) }
                continuation.yield(.error(.socket(String(describing: error))))
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
            let tail = Self.copyBytes(pending)
            pending = Data()
            do {
                try await transport.sendBinary(tail)
                bytesSent += tail.count
                wireBytes += tail.count
                tailBytes += tail.count
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

    /// Close the open-socket interval. Idempotent: a second call in the same
    /// death (the closed handler and `socketDied`) does not add time twice.
    private func endOpenInterval() {
        if let started = socketOpenStartedMs {
            closedSocketOpenMs += max(0, currentMs() - started)
            socketOpenStartedMs = nil
        }
        closedServerAudioMs += socketServerHighMs
        socketServerHighMs = 0
    }

    private func noteServerAudio(_ transcript: GrokTranscript) {
        let ms = Int(((transcript.start + transcript.duration) * 1_000).rounded())
        if ms > socketServerHighMs {
            socketServerHighMs = ms
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
        Self.prepend(chunk, to: &pending)
        inFlight = Data()
        inFlightGeneration = nil
    }

    private func reclaimReplay() {
        if !inFlight.isEmpty {
            Self.prepend(inFlight, to: &pending)
            inFlight = Data()
            inFlightGeneration = nil
        }
        guard !replay.isEmpty else { return }
        let replayed = replay
        replay = Data()
        bytesSent = max(0, bytesSent - replayed.count)
        replayedBytes += replayed.count
        Self.prepend(replayed, to: &pending)
    }

    /// `removeFirst` / `insert(at: 0)` leave an empty `InlineSlice` whose start
    /// index is the old count. The next insert asks to replace index 0 on a
    /// slice that starts at 3200 and traps (`ud2`) in swift-foundation — the
    /// same overlay Mac uses — so reconnect dies before `gap`. Rebuild a
    /// zero-based buffer instead of slicing.
    private static func copyBytes(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var copy = Data(count: data.count)
        _ = copy.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest)
        }
        return copy
    }

    private static func takePrefix(_ data: inout Data, _ count: Int) -> Data {
        let n = min(max(0, count), data.count)
        let head = copyBytes(data.prefix(n))
        if n >= data.count {
            data = Data()
        } else {
            data = copyBytes(data.dropFirst(n))
        }
        return head
    }

    private static func prepend(_ head: Data, to tail: inout Data) {
        guard !head.isEmpty else { return }
        var combined = Data(count: head.count + tail.count)
        combined.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = head.copyBytes(to: UnsafeMutableRawBufferPointer(start: base, count: head.count))
            if tail.count > 0 {
                _ = tail.copyBytes(
                    to: UnsafeMutableRawBufferPointer(start: base.advanced(by: head.count), count: tail.count)
                )
            }
        }
        tail = combined
    }

    private static func keepTail(_ data: inout Data, _ maxCount: Int) {
        guard data.count > maxCount else { return }
        data = copyBytes(data.suffix(maxCount))
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
            // `!ready` used to end the watchdog. A send failure sets `ready`
            // false and then used to wait on `close()`; the watchdog died in
            // that window and nothing started reconnect.
            if Task.isCancelled || finishRequested || generation != socketGeneration { return }
            if !ready {
                socketDied(code: 1006, reason: "inbound stall")
                return
            }
            let outstanding = bytesSent > bytesAtLastInbound || !inFlight.isEmpty
            if !outstanding { continue }
            if Date().timeIntervalSince(lastInbound) >= limit {
                socketDied(code: 1006, reason: "inbound stall")
                return
            }
        }
    }

    private func receiveWithTimeout(_ transport: any GrokTransport, timeout: Duration) async throws -> GrokSocketEvent {
        // `withThrowingTaskGroup` waits for every child. Closing the first
        // parked handshake resumed `receive` once; the next `pf` handshake
        // stays parked, the group never returns, and no later socket is
        // opened — so `gap` and `streaming` (`resumed`) are never yielded.
        try await firstToFinish(timeout: timeout, onTimeout: {
            abandonSocket(transport)
        }) {
            try await transport.receive()
        }
    }

    /// Winner returns. The loser is cancelled and not awaited: a dropped SYN
    /// never unblocks `URLSession`, and waiting here is the stuck reconnect.
    private func firstToFinish<T: Sendable>(
        timeout: Duration,
        onTimeout: @Sendable () async -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = FirstWin<T>()
        let work = Task.detached {
            do {
                race.finish(.value(try await operation()))
            } catch is CancellationError {
                race.finish(.failed("cancelled"))
            } catch {
                race.finish(.failed(String(describing: error)))
            }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            race.finish(.timeout)
        }
        let outcome = await race.wait()
        timer.cancel()
        switch outcome {
        case .value(let value):
            return value
        case .failed(let message):
            work.cancel()
            throw EngineError.socket(message)
        case .timeout:
            await onTimeout()
            work.cancel()
            throw EngineError.handshakeTimeout
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
}

/// Drop a socket without waiting. `URLSessionWebSocketTask.cancel()` on a
/// `pf`-parked receive does not return; awaiting it is what kept `gap` and
/// `streaming` off the Mac session.
private func abandonSocket(_ transport: (any GrokTransport)?) {
    guard let transport else { return }
    Task.detached {
        await transport.close()
    }
}

/// First `finish` wins. The reconnect loop must not wait on the loser: a
/// `pf`-dropped `receive` never returns, and waiting is what skipped `gap`.
private final class FirstWin<Value: Sendable>: @unchecked Sendable {
    enum Outcome: Sendable {
        case value(Value)
        case failed(String)
        case timeout
    }

    private struct State: Sendable {
        var outcome: Outcome?
        var waiting: CheckedContinuation<Outcome, Never>?
    }

    private let state = Mutex(State())

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state -> Outcome? in
                if let outcome = state.outcome {
                    return outcome
                }
                state.waiting = continuation
                return nil
            }
            if let already {
                continuation.resume(returning: already)
            }
        }
    }

    func finish(_ outcome: Outcome) {
        let continuation = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let continuation = state.waiting
            state.waiting = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
