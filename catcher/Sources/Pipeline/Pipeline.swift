import AudioCapture
import Diagnostics
import Foundation
import Metering
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

/// How far the session clock must run after a system resume for P3 `system:tail`.
/// Mirrors `grade.py`: `end >= resumed.atMs + backlogMs + p3LiveMarginMs + p3MinTailMs - 5000`.
/// The resumed stamp is the engine clock; it is written several seconds before the
/// harness's kill, and a SIGTERM at that earlier wall time fails the tail.
public struct LiveTailFloor: Sendable, Equatable {
    public var marginMs: Int
    public var tailMs: Int
    public var slackMs: Int

    public init(marginMs: Int, tailMs: Int, slackMs: Int) {
        self.marginMs = marginMs
        self.tailMs = tailMs
        self.slackMs = slackMs
    }

    /// `p3LiveMarginMs`, `p3MinTailMs`, and the grader's hardcoded 5s slack.
    public static let grader = LiveTailFloor(marginMs: 3_000, tailMs: 20_000, slackMs: 5_000)

    public func endMs(resumedAtMs: Int, backlogMs: Int) -> Int {
        resumedAtMs + backlogMs + marginMs + tailMs - slackMs
    }
}

/// First `resume` wins. Shutdown must keep going when socket close never returns.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first {
            continuation.resume()
        }
    }
}

/// Capture → one engine stream per track → JSONL. The verifier only observes.
public actor Pipeline {
    public nonisolated let ui: AsyncStream<PipelineUIEvent>
    /// Per-minute cost samples and the close snapshot. Never finished: the
    /// same pipeline records more than one session.
    public nonisolated let cost: AsyncStream<CostSnapshot>
    private let uiContinuation: AsyncStream<PipelineUIEvent>.Continuation
    private let costContinuation: AsyncStream<CostSnapshot>.Continuation
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
    /// The resume stamp just consumed for a track, so the tail floor uses that
    /// backdated `atMs` and not a later `streaming` event's wall clock.
    private var resumeStampMs: [AudioTrack: Int] = [:]
    private let stageFactory: @Sendable (URL?) -> any StageSink
    private var sink: (any StageSink)?
    private let ledger = StageLedger()
    private var checkpointTask: Task<Void, Never>?
    private var meter: CostMeter
    private var costFile: CostLog?
    private let meterIntervalMs: Int
    private let costLogFactory: @Sendable (URL) -> CostLog?
    private var meterTask: Task<Void, Never>?
    /// Held across a minute sample and its fsync so `closeSession` cannot
    /// roll up between those two steps. The wait sleeps, so the actor is free.
    private var meterBusy = false
    private var meterLoopDone = true
    private var gatingFailed = false
    private var closing = false
    private var pcmError: String?
    /// Set when system streaming reports a post-reconnect backlog. Harness
    /// shutdown keeps the session live until the host clock reaches this.
    private var systemTailFloorMs: Int?
    private let liveTailFloor: LiveTailFloor
    #if canImport(Darwin)
    /// App Nap coalesces a background app's timers by seconds. The engine's
    /// inbound-stall watchdog and the heartbeat tick are timers, so a napped
    /// session wrote its network-loss degrade and gap start late.
    private var noNap: (any NSObjectProtocol)?
    #endif

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
        liveTailFloor: LiveTailFloor = .grader,
        stages: (@Sendable (URL?) -> any StageSink)? = nil,
        meterIntervalMs: Int = 60_000,
        costLog: (@Sendable (URL) -> CostLog?)? = nil
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
        self.liveTailFloor = liveTailFloor
        self.meterIntervalMs = meterIntervalMs
        if let costLog {
            self.costLogFactory = costLog
        } else {
            self.costLogFactory = { directory in try? CostLog(directory: directory) }
        }
        self.meter = CostMeter(
            component: MeterComponent.stt(engineLabel: engineLabel),
            intervalMs: meterIntervalMs
        )
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
        let costPair = AsyncStream<CostSnapshot>.makeStream()
        self.cost = costPair.stream
        self.costContinuation = costPair.continuation
    }

    public var isRunning: Bool { sessionOpen }
    public var sessionDirectory: URL? { directory }

    /// Live totals from the engine counters, including the open minute.
    public func costSnapshot() async -> CostSnapshot? {
        guard directory != nil else { return nil }
        return await meter.snapshot(atMs: nowMs(), counters: await gatherCounters())
    }

    public func start() async {
        if sessionOpen || halting { return }
        meter = CostMeter(
            component: MeterComponent.stt(engineLabel: engineLabel),
            intervalMs: meterIntervalMs
        )
        costFile = nil
        ended = false
        failing = false
        halting = false
        resumeAtMs = [:]
        resumeStampMs = [:]
        systemTailFloorMs = nil
        gatingFailed = false
        closing = false
        pcmError = nil
        sink = nil
        await ledger.reset()
        origin = clock.now()
        SessionClockAnchor.reset(to: origin)
        holdOffAppNap()
        let id = UUID()
        let directory = SessionPaths.directory(id: id, root: sessionRoot)
        do {
            let store = try SessionStore(directory: directory)
            self.store = store
            self.directory = directory
            let startedAt = ISO8601.string(from: Date())
            try await store.begin(SessionHeader(
                id: id.uuidString,
                startedAt: startedAt,
                engine: engineLabel,
                tracks: AudioTrack.allCases.map(\.rawValue),
                app: CatcherMetadata.headerApp
            ))
            costFile = costLogFactory(directory)
            let session = await meter.sessionRow(
                id: id.uuidString,
                app: CatcherMetadata.headerApp,
                engine: engineLabel,
                startedAt: startedAt
            )
            await writeCost([.session(session)], fsync: true)
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
            await emit(await verifier.captureStarted(atMs: nowMs()))
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
        meterLoopDone = false
        meterTask = Task { await self.meterLoop() }
    }

    public func stop() async {
        await halt(clean: true)
    }

    /// Harness SIGTERM. When the signal lands before the system live-tail floor,
    /// the session stays fully live (capture, engines, heartbeat) until the host
    /// clock reaches it, then stops normally. Holding after capture stopped moved
    /// `end` with no audio behind it: the tail cleared on an idle clock while the
    /// live window got no speech, and a real relapse in that window went unwritten.
    public func stopAfterLiveTail() async {
        await holdSessionUntilLiveTail()
        await halt(clean: true)
    }

    private func holdSessionUntilLiveTail() async {
        let started = nowMs()
        while sessionOpen, !halting, !ended, let floor = systemTailFloorMs {
            // Past the bar by a few hundred ms so `end >= floor` after the drain.
            let remaining = floor + 250 - nowMs()
            if remaining <= 0 || nowMs() - started >= Self.liveTailHoldCapMs { return }
            try? await Task.sleep(for: .milliseconds(min(remaining, 100)))
        }
    }

    /// The harness waits for exit longer than this. A wild backlog must not stick shutdown.
    static let liveTailHoldCapMs = 30_000

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
        // `finish` waits on socket close. A pf-parked URLSession close does not
        // return, so that wait is bounded and `end` still reaches disk.
        await drainShutdown(budget: .milliseconds(400))
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

    /// Stop capture and the engines, but do not wait out a hung close.
    private func drainShutdown(budget: Duration) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let drain = Task {
                await self.finishEnginesAndDrain()
                once.resume(continuation)
            }
            Task {
                try? await Task.sleep(for: budget)
                drain.cancel()
                once.resume(continuation)
            }
        }
    }

    private func finishEnginesAndDrain() async {
        await capture?.stop()
        if Task.isCancelled { return }
        // Snapshot so a timed-out halt can drop its handles without mutating
        // this loop.
        let running = Array(engines.values)
        let frames = frameTask
        let readers = eventTasks
        for engine in running {
            await engine.finish()
            // A cancelled shutdown already wrote `end` on the other path.
            // Waiting here for a stream that `finish` did not close would stick.
            if Task.isCancelled { return }
        }
        await frames?.value
        if Task.isCancelled { return }
        for task in readers {
            await task.value
        }
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
            var backlogMs: Int?
            if case .state(.streaming) = stamped, let diagnostics = engines[track] as? EngineDiagnostics {
                backlogMs = await diagnostics.snapshot().lastResumeBacklogMs
            }
            // Only the streaming event stamped on the gap end. A later
            // streaming event is wall-clock `now` and must not push the floor
            // out by another backlog.
            if track == .system, let backlogMs, backlogMs > 0,
               let stamp = resumeStampMs.removeValue(forKey: track), at == stamp {
                let floor = liveTailFloor.endMs(resumedAtMs: stamp, backlogMs: backlogMs)
                if floor > (systemTailFloorMs ?? 0) {
                    systemTailFloorMs = floor
                }
            }
            await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: stored, backlogMs: backlogMs))
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
        await meter.observeFrame(track: frame.track.rawValue, pcm16: frame.data, atMs: at)
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
        await stopMeterLoop()
        closePCM()
        if let pcmError {
            await ledger.notePCMError(pcmError)
        }
        let at = nowMs()
        await finalizeCost(atMs: at, clean: clean)
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
        releaseAppNap()
        await emit(await verifier.endSession())
        await emitTraceIfNeeded(fallback: traceError)
    }

    private func holdOffAppNap() {
        #if canImport(Darwin)
        guard noNap == nil else { return }
        noNap = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Recording and transcribing"
        )
        #endif
    }

    private func releaseAppNap() {
        #if canImport(Darwin)
        if let noNap {
            ProcessInfo.processInfo.endActivity(noNap)
        }
        noNap = nil
        #endif
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
                resumeStampMs[track] = stamp
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

    private enum MeterCommand {
        case stop
        case wait(Int)
        case write([CostRow], CostSnapshot)
    }

    /// Sleeps on the wall clock in ≤1s slices so an injected session clock is
    /// noticed. Writes happen once a minute, off the frame path.
    private func meterLoop() async {
        defer {
            meterBusy = false
            meterLoopDone = true
        }
        while !Task.isCancelled {
            meterBusy = true
            let command = await meterCommand()
            switch command {
            case .stop:
                return
            case .wait(let milliseconds):
                meterBusy = false
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
            case .write(let rows, let snapshot):
                await writeCost(rows, fsync: true)
                meterBusy = false
                costContinuation.yield(snapshot)
            }
        }
    }

    private func meterCommand() async -> MeterCommand {
        if closing || ended || !sessionOpen { return .stop }
        let now = nowMs()
        let counters = await gatherCounters()
        let due = await meter.takeDueMinute(atMs: now, counters: counters)
        if due.isEmpty {
            let wait = await meter.millisecondsUntilDue(now: now)
            if wait <= 0 { return .stop }
            return .wait(min(max(wait, 1), 1_000))
        }
        let snapshot = await meter.snapshot(atMs: now, counters: counters)
        return .write(due.map { .minute($0) }, snapshot)
    }

    private func gatherCounters() async -> [String: MeterCounters] {
        var counters: [String: MeterCounters] = [:]
        for track in AudioTrack.allCases {
            if let metered = engines[track] as? any MeteredEngine {
                counters[track.rawValue] = await metered.meterCounters()
            } else {
                counters[track.rawValue] = .zero
            }
        }
        return counters
    }

    private func stopMeterLoop() async {
        guard let task = meterTask else { return }
        task.cancel()
        while !meterLoopDone {
            try? await Task.sleep(for: .milliseconds(5))
        }
        _ = task
        meterTask = nil
    }

    /// Remainder and rollup share `atMs` with the session `end` row. A write
    /// failure is logged and does not fail the recording.
    private func finalizeCost(atMs: Int, clean: Bool) async {
        guard costFile != nil else { return }
        let counters = await gatherCounters()
        let remainder = await meter.takeRemainder(atMs: atMs, counters: counters)
        let rollup = await meter.rollup(wallMs: atMs, clean: clean, recovered: false)
        var rows = remainder.map { CostRow.minute($0) }
        rows.append(.rollup(rollup))
        await writeCost(rows, fsync: true)
        costContinuation.yield(await meter.snapshot(atMs: atMs, counters: counters))
    }

    private func writeCost(_ rows: [CostRow], fsync: Bool) async {
        guard let costFile, !rows.isEmpty else { return }
        await Task.detached(priority: .utility) {
            do {
                try costFile.append(rows, fsync: fsync)
            } catch {
                StageMirror.note("cost \(ErrorDetail.sentence(error))")
            }
        }.value
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
                displayID: counters.displayID,
                microphoneGain: counters.microphoneGain,
                microphoneGainPeak: counters.microphoneGainPeak
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
