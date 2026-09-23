import AudioCapture
import Diagnostics
import Foundation
import SessionStore
import TranscriptionEngine
import Verifier

public enum PipelineUIEvent: Sendable {
    case transcript(TranscriptEvent)
    case snapshot(VerifierSnapshot)
}

public protocol SessionClock: Sendable {
    func now() -> UInt64
    func milliseconds(from start: UInt64, to end: UInt64) -> Int
}

public struct HostSessionClock: SessionClock {
    public init() {}

    public func now() -> UInt64 { HostClock.now() }

    public func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        HostClock.milliseconds(from: start, to: end)
    }
}

/// Capture → one engine stream per track → JSONL. The verifier only observes.
public actor Pipeline {
    public nonisolated let ui: AsyncStream<PipelineUIEvent>
    private let uiContinuation: AsyncStream<PipelineUIEvent>.Continuation
    private let sessionRoot: URL
    private let makeCapture: @Sendable () -> any AudioCapturing
    private let makeEngine: @Sendable (AudioTrack) throws -> any TranscriptionEngine
    private let launchProbe: @Sendable () async -> PermissionState
    private let recheckProbe: @Sendable () async -> PermissionState
    private let recordPCM: Bool
    private let engineLabel: String
    private let probeInterval: Duration
    private let clock: any SessionClock
    private let verifier = Verifier()

    private var capture: (any AudioCapturing)?
    private var store: SessionStore?
    private var directory: URL?
    private var engines: [AudioTrack: any TranscriptionEngine] = [:]
    private var eventTasks: [Task<Void, Never>] = []
    private var frameTask: Task<Void, Never>?
    private var failureTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var sessionOpen = false
    private var ended = false
    private var halting = false
    private var failing = false
    private var origin: UInt64 = 0
    private var pcmHandles: [String: FileHandle] = [:]
    /// Gap `toMs` is the engine session clock. The following `resumed` ann uses
    /// it so a post-reconnect seg (same clock) is not stuck before the ann.
    private var resumeAtMs: [AudioTrack: Int] = [:]
    private let stageFactory: @Sendable (URL?) -> any StageSink
    private var sink: (any StageSink)?
    private let ledger = StageLedger()
    private var checkpointTask: Task<Void, Never>?
    private var gatingFailed = false
    private var closing = false
    private var pcmError: String?

    public init(
        sessionRoot: URL = SessionPaths.root(),
        makeCapture: @escaping @Sendable () -> any AudioCapturing = { AudioCaptureBackend.make() },
        makeEngine: @escaping @Sendable (AudioTrack) throws -> any TranscriptionEngine = { try EngineFactory.make(track: $0) },
        launchProbe: @escaping @Sendable () async -> PermissionState = { await PermissionGate.startCaptureProbe() },
        recheckProbe: @escaping @Sendable () async -> PermissionState = { PermissionGate.recheck() },
        recordPCM: Bool = false,
        engineLabel: String = EngineFactory.sessionEngineName(),
        probeInterval: Duration = .seconds(1),
        clock: any SessionClock = HostSessionClock(),
        stages: (@Sendable (URL?) -> any StageSink)? = nil
    ) {
        self.sessionRoot = sessionRoot
        self.makeCapture = makeCapture
        self.makeEngine = makeEngine
        self.launchProbe = launchProbe
        self.recheckProbe = recheckProbe
        self.recordPCM = recordPCM
        self.engineLabel = engineLabel
        self.probeInterval = probeInterval
        self.clock = clock
        if let stages {
            self.stageFactory = stages
        } else {
            let root = sessionRoot
            self.stageFactory = { directory in
                if let directory {
                    return FileStageSink(directory: directory, fileName: "stages.log")
                }
                return FileStageSink(directory: root, fileName: "launch-stages.log")
            }
        }
        let pair = AsyncStream<PipelineUIEvent>.makeStream()
        self.ui = pair.stream
        self.uiContinuation = pair.continuation
    }

    public var isRunning: Bool { sessionOpen }
    public var sessionDirectory: URL? { directory }

    public func start() async {
        if sessionOpen || halting { return }
        ended = false
        failing = false
        halting = false
        resumeAtMs = [:]
        gatingFailed = false
        closing = false
        pcmError = nil
        sink = nil
        await ledger.reset()
        origin = clock.now()
        SessionClockAnchor.reset(to: origin)
        let id = UUID()
        let directory = SessionPaths.directory(id: id, root: sessionRoot)
        do {
            let store = try SessionStore(directory: directory)
            self.store = store
            self.directory = directory
            try await store.begin(SessionHeader(
                id: id.uuidString,
                startedAt: ISO8601.string(from: Date()),
                engine: engineLabel,
                tracks: AudioTrack.allCases.map(\.rawValue),
                app: CatcherMetadata.headerApp
            ))
        } catch {
            let sentence = ErrorDetail.sentence(error)
            StageMirror.note("store create \(sentence)")
            gatingFailed = true
            await failClosed("store create failed: \(error)", traceError: sentence)
            return
        }

        await emit(await verifier.beginSession(atMs: 0))
        let permission = await launchProbe()
        await emit(await verifier.observePermission(permission, atMs: 0))
        let blockedReason: String?
        switch permission {
        case .blocked(let reason):
            blockedReason = reason
        case .granted:
            blockedReason = nil
        }
        let authority = PermissionGate.readMicrophoneAuthority()
        await persist([
            StageBuilders.tcc(
                probeGranted: blockedReason == nil,
                blockReason: blockedReason,
                micStatus: authority.authorizationStatus,
                owns: authority.ownsTCCIdentity,
                entitlement: authority.audioInputEntitlement,
                responsible: authority.responsibleName ?? "unknown"
            ),
        ])
        if case .blocked = permission {
            gatingFailed = true
            await closeSession(clean: false)
            return
        }

        var created: [AudioTrack: any TranscriptionEngine] = [:]
        do {
            let stages = ensureSink()
            for track in AudioTrack.allCases {
                let engine = try makeEngine(track)
                if let logging = engine as? any StageLogging {
                    await logging.bindStages(stages)
                }
                created[track] = engine
            }
        } catch {
            let sentence = ErrorDetail.sentence(error)
            StageMirror.note("engine create \(sentence)")
            gatingFailed = true
            await failClosed("engine unavailable: \(error)", traceError: sentence)
            return
        }

        let capture = makeCapture()
        self.capture = capture
        do {
            try await capture.start()
            await persist([StageBuilders.captureStart(display: displayID(of: capture), error: nil)])
        } catch {
            await persist([StageBuilders.captureStart(display: displayID(of: capture), error: error)])
            gatingFailed = true
            let captureError = error as? CaptureError ?? .unavailable(String(describing: error))
            await emit(await verifier.observeCapture(captureError, atMs: nowMs()))
            await closeSession(clean: false)
            return
        }

        let router = TrackRouter(engines: created)
        for track in AudioTrack.allCases {
            let engine = router.engine(for: track)
            engines[track] = engine
            let started = ContinuousClock.now
            do {
                try await engine.connect(track: track)
                var milliseconds = Self.elapsedMilliseconds(since: started)
                if let diagnostics = engine as? EngineDiagnostics {
                    let snap = await diagnostics.snapshot()
                    if let handshake = snap.handshakeMs {
                        milliseconds = handshake
                    }
                }
                await persist([
                    StageBuilders.apiConnectOK(track: track.rawValue, engine: engineLabel, milliseconds: milliseconds),
                ])
            } catch {
                let sentence = ErrorDetail.sentence(error)
                await persist([
                    StageBuilders.apiConnectFAIL(
                        track: track.rawValue,
                        engine: engineLabel,
                        fields: await connectFailureFields(engine: engine, error: error)
                    ),
                ])
                gatingFailed = true
                await capture.stop()
                await failClosed("engine connect failed: \(error)", traceError: sentence)
                return
            }
        }

        sessionOpen = true
        for track in AudioTrack.allCases {
            guard let engine = engines[track] else { continue }
            let events = engine.events
            eventTasks.append(Task { await self.consumeEvents(events, track: track) })
        }
        let frames = capture.frames
        frameTask = Task { await self.consumeFrames(frames) }
        let failures = capture.failures
        failureTask = Task { await self.consumeFailures(failures) }
        tickTask = Task { await self.tickLoop() }
        probeTask = Task { await self.probeLoop() }
        checkpointTask = Task { await self.checkpointLoop() }
    }

    public func stop() async {
        await halt(clean: true)
    }

    private func halt(clean: Bool) async {
        if halting {
            while !ended {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return
        }
        halting = true
        tickTask?.cancel()
        probeTask?.cancel()
        let wasOpen = sessionOpen
        sessionOpen = false
        await capture?.stop()
        for engine in engines.values {
            await engine.finish()
        }
        await frameTask?.value
        for task in eventTasks {
            await task.value
        }
        if !ended {
            await closeSession(clean: clean && wasOpen)
        }
        frameTask = nil
        failureTask = nil
        tickTask = nil
        probeTask = nil
        eventTasks = []
        engines = [:]
        capture = nil
        halting = false
    }

    private func consumeFrames(_ frames: AsyncStream<PCMFrame>) async {
        for await frame in frames {
            if Task.isCancelled || !sessionOpen { continue }
            await ingest(frame)
        }
    }

    private func consumeEvents(_ events: AsyncStream<EngineEvent>, track: AudioTrack) async {
        for await event in events {
            if Task.isCancelled { break }
            let stamped = TrackRouter.stamp(event, track: track)
            let at = stampedAt(stamped, track: track)
            if case .error(let engineError) = stamped {
                await ledger.noteAPIError(Self.engineErrorText(engineError))
            }
            if case .transcript(let transcript) = stamped, transcript.kind == .final {
                guard sessionOpen, !ended else {
                    let stored = await store?.syncedFinalCount ?? 0
                    await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: stored))
                    continue
                }
                let before = await store?.syncedFinalCount ?? 0
                // Blank and restated finals are not written. Crash-safety must not
                // treat that skip as a segment that failed to fsync.
                let blank = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard await storeFinal(transcript) else {
                    if !failing {
                        if blank {
                            await ledger.noteBlankDropped()
                        } else {
                            await ledger.noteRestated()
                        }
                    }
                    continue
                }
                await ledger.noteStoredFinal(track: track.rawValue)
                let after = await store?.syncedFinalCount ?? before
                await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: before))
                await emit(await verifier.observeStored(count: after, atMs: at))
                uiContinuation.yield(.transcript(transcript))
                continue
            }
            let stored = await store?.syncedFinalCount ?? 0
            await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: stored))
            if case .transcript(let transcript) = stamped {
                if transcript.kind != .final {
                    await ledger.notePartial()
                }
                uiContinuation.yield(.transcript(transcript))
            }
        }
    }

    private func consumeFailures(_ failures: AsyncStream<CaptureError>) async {
        for await error in failures {
            let at = nowMs()
            await emit(await verifier.observeCapture(error, atMs: at))
            if case .tccRevokedMidSession = error {
                Task { await self.halt(clean: false) }
                return
            }
            if case .streamStopped = error {
                let reprobe = await recheckProbe()
                await emit(await verifier.observeReprobe(reprobe, atMs: at))
                if case .blocked = reprobe {
                    Task { await self.halt(clean: false) }
                    return
                }
            }
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                break
            }
            if Task.isCancelled || ended { break }
            guard sessionOpen else { continue }
            await emit(await verifier.tick(atMs: nowMs()))
        }
    }

    private func probeLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: probeInterval)
            } catch {
                break
            }
            if Task.isCancelled || ended || !sessionOpen { continue }
            let state = await recheckProbe()
            await emit(await verifier.observeReprobe(state, atMs: nowMs()))
            if case .blocked = state {
                Task { await self.halt(clean: false) }
                return
            }
        }
    }

    private func ingest(_ frame: PCMFrame) async {
        let at = max(0, clock.milliseconds(from: origin, to: frame.hostTime))
        await emit(await verifier.observeFrame(frame, atMs: at))
        appendPCM(frame)
        await ledger.frameExtracted(track: frame.track.rawValue, energy: StageLedger.hasEnergy(frame.data))
        guard let engine = engines[frame.track] else { return }
        do {
            try await engine.send(frame)
            await ledger.noteSent(track: frame.track.rawValue, bytes: frame.data.count)
        } catch {
            let sentence = ErrorDetail.sentence(error)
            await ledger.noteSendError(sentence)
            StageMirror.note("engine send \(sentence)")
            await emit(await verifier.observeEngine(.error(.socket(String(describing: error))), track: frame.track, atMs: at, storedCount: 0))
        }
    }

    /// `conf` stays off the segment row. Grok usually has no segment score, and a
    /// stub `conf` makes P5's key set differ. Word scores still live on `words[].c`.
    private func storeFinal(_ transcript: TranscriptEvent) async -> Bool {
        do {
            return try await store?.appendSegment(SegmentRow(
                seq: transcript.seq,
                track: transcript.track.rawValue,
                startMs: transcript.startMs,
                endMs: transcript.endMs,
                final: true,
                text: transcript.text,
                speaker: transcript.speaker,
                conf: nil,
                words: transcript.words.map { WordStamp(w: $0.w, s: $0.startMs, e: $0.endMs, c: $0.conf) }
            )) ?? false
        } catch {
            let sentence = ErrorDetail.sentence(error)
            StageMirror.note("store segment \(sentence)")
            await failClosed("store write failed: \(error)", traceError: sentence)
            return false
        }
    }

    private func emit(_ effect: VerifierEffect) async {
        uiContinuation.yield(.snapshot(effect.snapshot))
        if failing { return }
        for annotation in effect.annotations {
            let detail: AnnotationDetail?
            switch annotation.detail {
            case .none:
                detail = nil
            case .text(let text):
                detail = .text(text)
            case .gap(let fromMs, let toMs, let track):
                detail = .gap(fromMs: fromMs, toMs: toMs, track: track)
            }
            do {
                try await store?.appendAnnotation(AnnotationRow(atMs: annotation.atMs, kind: annotation.kind, detail: detail))
            } catch {
                let sentence = ErrorDetail.sentence(error)
                StageMirror.note("store annotation \(sentence)")
                await failClosed("store write failed: \(error)", traceError: sentence)
                return
            }
        }
    }

    private func appendPCM(_ frame: PCMFrame) {
        guard recordPCM, let directory else { return }
        let key = frame.track.rawValue
        if pcmHandles[key] == nil {
            let url = SessionPaths.pcmFile(track: key, in: directory)
            if !FileManager.default.createFile(atPath: url.path, contents: nil) {
                rememberPCM("createFile failed \(url.path)")
            } else {
                do {
                    pcmHandles[key] = try FileHandle(forWritingTo: url)
                } catch {
                    rememberPCM(ErrorDetail.sentence(error))
                }
            }
        }
        guard let handle = pcmHandles[key] else { return }
        do {
            try handle.write(contentsOf: frame.data)
        } catch {
            rememberPCM(ErrorDetail.sentence(error))
            pcmHandles[key] = nil
        }
    }

    private func rememberPCM(_ text: String) {
        StageMirror.note("pcm \(text)")
        if pcmError == nil { pcmError = text }
    }

    private func closePCM() {
        for handle in pcmHandles.values {
            do {
                try handle.synchronize()
            } catch {
                rememberPCM(ErrorDetail.sentence(error))
            }
            do {
                try handle.close()
            } catch {
                rememberPCM(ErrorDetail.sentence(error))
            }
        }
        pcmHandles = [:]
    }

    private func closeSession(clean: Bool, traceError: String? = nil) async {
        guard !ended else { return }
        closing = true
        checkpointTask?.cancel()
        closePCM()
        if let pcmError {
            await ledger.notePCMError(pcmError)
        }
        let at = nowMs()
        var endError: String?
        do {
            try await store?.end(atMs: at, clean: clean)
        } catch {
            endError = ErrorDetail.sentence(error)
            StageMirror.note("session end \(endError ?? "")")
        }
        var assembleError: String?
        do {
            try await store?.assemble(recovered: false)
        } catch {
            assembleError = ErrorDetail.sentence(error)
            StageMirror.note("session assemble \(assembleError ?? "")")
        }
        if !gatingFailed {
            await writeCountStages()
            await writeTranscript(error: assembleError ?? endError)
        }
        ended = true
        sessionOpen = false
        await emit(await verifier.endSession())
        await emitTraceIfNeeded(fallback: traceError)
    }

    private func failClosed(_ message: String, traceError: String? = nil) async {
        guard !failing else { return }
        failing = true
        let effect = await verifier.observeStoreFailure(message, atMs: nowMs())
        uiContinuation.yield(.snapshot(effect.snapshot))
        await capture?.stop()
        for engine in engines.values {
            await engine.finish()
        }
        await closeSession(clean: false, traceError: traceError ?? message)
    }

    private func stampedAt(_ event: EngineEvent, track: AudioTrack) -> Int {
        switch event {
        case .gap(fromMs: _, toMs: let to):
            resumeAtMs[track] = to
            return nowMs()
        case .state(.streaming):
            if let stamp = resumeAtMs.removeValue(forKey: track) {
                return stamp
            }
            return nowMs()
        default:
            return nowMs()
        }
    }

    private func nowMs() -> Int {
        max(0, clock.milliseconds(from: origin, to: clock.now()))
    }

    private func checkpointLoop() async {
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            return
        }
        if Task.isCancelled || ended || closing || !sessionOpen { return }
        let lines = await makeCountLines()
        if Task.isCancelled || ended || closing || !sessionOpen { return }
        await persist(lines, checkpoint: true)
        let segmentsFailed = lines.contains { $0.stage == .segmentsReceived && $0.verdict == Verdict.fail.rawValue }
        if segmentsFailed, !closing, !ended {
            await emitTraceIfNeeded(fallback: nil)
        }
    }

    private func writeCountStages() async {
        await persist(await makeCountLines(), checkpoint: true)
    }

    private func makeCountLines() async -> [StageLine] {
        await ledger.countLines(capture: await captureSnapshot(), stream: await streamSnapshot())
    }

    private func captureSnapshot() async -> CaptureCounterSnapshot {
        if let diagnostics = capture as? CaptureDiagnostics {
            let counters = diagnostics.counters()
            return CaptureCounterSnapshot(
                system: counters.system,
                microphone: counters.microphone,
                invalid: counters.invalid,
                empty: counters.empty,
                extractFailed: counters.extractFailed,
                firstOSStatus: counters.firstOSStatus,
                firstFailureDetail: counters.firstFailureDetail,
                displayID: counters.displayID
            )
        }
        let extracted = await ledger.extractedCounts()
        return CaptureCounterSnapshot(system: extracted.system, microphone: extracted.microphone)
    }

    private func streamSnapshot() async -> StreamSnapshot {
        var systemBytes = 0
        var microphoneBytes = 0
        var pending = 0
        var sendErrors = 0
        var firstSendError = ""
        var fromEngine = false
        for track in AudioTrack.allCases {
            guard let engine = engines[track], let diagnostics = engine as? EngineDiagnostics else { continue }
            fromEngine = true
            let snap = await diagnostics.snapshot()
            switch track {
            case .system:
                systemBytes = snap.bytesSent
            case .microphone:
                microphoneBytes = snap.bytesSent
            }
            pending += snap.pendingCount
            sendErrors += snap.sendErrors
            if firstSendError.isEmpty, snap.sendErrors > 0, let error = snap.lastError {
                firstSendError = error
            }
        }
        guard fromEngine else { return StreamSnapshot() }
        return StreamSnapshot(
            systemBytes: systemBytes,
            microphoneBytes: microphoneBytes,
            pending: pending,
            sendErrors: sendErrors,
            firstSendError: firstSendError,
            fromEngine: true
        )
    }

    private func writeTranscript(error: String?) async {
        var bytes = 0
        if let directory {
            let url = SessionPaths.transcriptFile(in: directory)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    bytes = try Data(contentsOf: url).count
                } catch {
                    StageMirror.note("transcript read \(ErrorDetail.sentence(error))")
                }
            }
        }
        let segments = await ledger.storedFinals()
        let line = await ledger.transcriptLine(bytes: bytes, segments: segments, recovered: false, error: error)
        await persist([line], checkpoint: true)
    }

    private func emitTraceIfNeeded(fallback: String?) async {
        let recorded = sink?.recorded() ?? []
        let failed = FailureTrace.verdictLines(recorded).contains { $0.verdict == Verdict.fail.rawValue }
        let segments = await ledger.storedFinals()
        guard failed || segments == 0 || fallback != nil else { return }
        let report = FailureTrace.report(lines: recorded, fallbackError: fallback)
        await persist(report.lines, checkpoint: true)
        if !report.cause.isEmpty, report.lines.count > 1 {
            Loud.defaultLog(report.lines[1].formatted())
        }
    }

    private func persist(_ lines: [StageLine], checkpoint: Bool = false) async {
        let sink = ensureSink()
        await Task.detached(priority: .utility) {
            for line in lines {
                let durable = checkpoint || line.verdict == Verdict.fail.rawValue || line.kind == .trace
                sink.write(line, fsync: durable)
            }
        }.value
    }

    private func ensureSink() -> any StageSink {
        if let sink { return sink }
        let created = stageFactory(directory)
        sink = created
        return created
    }

    private func displayID(of capture: any AudioCapturing) -> String {
        guard let diagnostics = capture as? CaptureDiagnostics else { return "unknown" }
        let id = diagnostics.counters().displayID
        return id == 0 ? "unknown" : String(id)
    }

    private func connectFailureFields(engine: any TranscriptionEngine, error: Error) async -> [Field] {
        var fields: [Field] = []
        let detail = ErrorDetail.describe(error)
        if let domain = detail["domain"], !domain.isEmpty { fields.append(Field("domain", domain)) }
        if let code = detail["code"], !code.isEmpty { fields.append(Field("code", code)) }
        var errorText = String(describing: error)
        if let diagnostics = engine as? EngineDiagnostics {
            let snap = await diagnostics.snapshot()
            if let http = snap.httpStatus { fields.append(Field("http", String(http))) }
            if let closeCode = snap.lastCloseCode {
                var close = String(closeCode)
                if let reason = snap.lastCloseReason, !reason.isEmpty {
                    close += " \(reason)"
                }
                fields.append(Field("close", close))
            }
            if let body = snap.httpBody, !body.isEmpty { fields.append(Field("body", body)) }
            if let last = snap.lastError, !last.isEmpty { errorText = last }
        }
        fields.append(Field("error", errorText))
        return fields
    }

    private static func engineErrorText(_ error: EngineError) -> String {
        switch error {
        case .missingAPIKey:
            "missing XAI_API_KEY"
        case .handshakeTimeout:
            "handshakeTimeout"
        case .socket(let text):
            text
        case .protocol(let text):
            text
        case .closed:
            "closed"
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
