import AudioCapture
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

    public init(
        sessionRoot: URL = SessionPaths.root(),
        makeCapture: @escaping @Sendable () -> any AudioCapturing = { AudioCaptureBackend.make() },
        makeEngine: @escaping @Sendable (AudioTrack) throws -> any TranscriptionEngine = { try EngineFactory.make(track: $0) },
        launchProbe: @escaping @Sendable () async -> PermissionState = { await PermissionGate.startCaptureProbe() },
        recheckProbe: @escaping @Sendable () async -> PermissionState = { PermissionGate.recheck() },
        recordPCM: Bool = false,
        engineLabel: String = EngineFactory.sessionEngineName(),
        clock: any SessionClock = HostSessionClock()
    ) {
        self.sessionRoot = sessionRoot
        self.makeCapture = makeCapture
        self.makeEngine = makeEngine
        self.launchProbe = launchProbe
        self.recheckProbe = recheckProbe
        self.recordPCM = recordPCM
        self.engineLabel = engineLabel
        self.clock = clock
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
        origin = clock.now()
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
                app: CatcherMetadata.appVersion
            ))
        } catch {
            await failClosed("store create failed: \(error)")
            return
        }

        await emit(await verifier.beginSession(atMs: 0))
        let permission = await launchProbe()
        await emit(await verifier.observePermission(permission, atMs: 0))
        if case .blocked = permission {
            await closeSession(clean: false)
            return
        }

        var created: [AudioTrack: any TranscriptionEngine] = [:]
        do {
            for track in AudioTrack.allCases {
                created[track] = try makeEngine(track)
            }
        } catch {
            await failClosed("engine unavailable: \(error)")
            return
        }

        let capture = makeCapture()
        self.capture = capture
        do {
            try await capture.start()
        } catch {
            let captureError = error as? CaptureError ?? .unavailable(String(describing: error))
            await emit(await verifier.observeCapture(captureError, atMs: nowMs()))
            await closeSession(clean: false)
            return
        }

        let router = TrackRouter(engines: created)
        do {
            for track in AudioTrack.allCases {
                let engine = router.engine(for: track)
                engines[track] = engine
                try await engine.connect(track: track)
            }
        } catch {
            await capture.stop()
            await failClosed("engine connect failed: \(error)")
            return
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
            let at = nowMs()
            if case .transcript(let transcript) = stamped, transcript.kind == .final {
                guard sessionOpen, !ended else {
                    let stored = await store?.syncedFinalCount ?? 0
                    await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: stored))
                    continue
                }
                let before = await store?.syncedFinalCount ?? 0
                // Blank and restated finals are not written. Crash-safety must not
                // treat that skip as a segment that failed to fsync.
                guard await storeFinal(transcript) else { continue }
                let after = await store?.syncedFinalCount ?? before
                await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: before))
                await emit(await verifier.observeStored(count: after, atMs: at))
                uiContinuation.yield(.transcript(transcript))
                continue
            }
            let stored = await store?.syncedFinalCount ?? 0
            await emit(await verifier.observeEngine(stamped, track: track, atMs: at, storedCount: stored))
            if case .transcript(let transcript) = stamped {
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
                try await Task.sleep(for: .seconds(1))
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
        guard let engine = engines[frame.track] else { return }
        do {
            try await engine.send(frame)
        } catch {
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
            await failClosed("store write failed: \(error)")
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
                await failClosed("store write failed: \(error)")
                return
            }
        }
    }

    private func appendPCM(_ frame: PCMFrame) {
        guard recordPCM, let directory else { return }
        let key = frame.track.rawValue
        if pcmHandles[key] == nil {
            let url = SessionPaths.pcmFile(track: key, in: directory)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            pcmHandles[key] = try? FileHandle(forWritingTo: url)
        }
        do {
            try pcmHandles[key]?.write(contentsOf: frame.data)
        } catch {
            pcmHandles[key] = nil
        }
    }

    private func closePCM() {
        for handle in pcmHandles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        pcmHandles = [:]
    }

    private func closeSession(clean: Bool) async {
        guard !ended else { return }
        closePCM()
        let at = nowMs()
        try? await store?.end(atMs: at, clean: clean)
        try? await store?.assemble(recovered: false)
        ended = true
        sessionOpen = false
        await emit(await verifier.endSession())
    }

    private func failClosed(_ message: String) async {
        guard !failing else { return }
        failing = true
        let effect = await verifier.observeStoreFailure(message, atMs: nowMs())
        uiContinuation.yield(.snapshot(effect.snapshot))
        await capture?.stop()
        for engine in engines.values {
            await engine.finish()
        }
        await closeSession(clean: false)
    }

    private func nowMs() -> Int {
        max(0, clock.milliseconds(from: origin, to: clock.now()))
    }
}
