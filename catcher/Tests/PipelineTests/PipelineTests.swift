import AudioCapture
import Foundation
import Pipeline
import SessionStore
import Testing
import TranscriptionEngine

@Test func routerKeepsOneEnginePerTrackAndStampsEvents() {
    let router = TrackRouter { track in StubEngine(track: track) }
    let systemA = router.engine(for: .system) as! StubEngine
    let systemB = router.engine(for: .system) as! StubEngine
    let mic = router.engine(for: .microphone) as! StubEngine
    #expect(systemA === systemB)
    #expect(systemA !== mic)
    let stamped = TrackRouter.stamp(
        .transcript(TranscriptEvent(
            track: .microphone,
            kind: .final,
            text: "x",
            words: [],
            seq: 1,
            startMs: 0,
            endMs: 1
        )),
        track: .system
    )
    guard case .transcript(let event) = stamped else {
        Issue.record("expected transcript")
        return
    }
    #expect(event.track == .system)
}

@Test func pipelineSourceDoesNotBranchOnEngines() throws {
    let root = packageRoot()
    for name in ["Pipeline.swift", "TrackRouter.swift"] {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Pipeline/\(name)"), encoding: .utf8)
        #expect(!source.contains("GrokEngine"))
        #expect(!source.contains("StubEngine"))
        #expect(!source.contains("CATCHER_ENGINE"))
    }
}

@Test func pipelineRecordsBothTracksAndDropsPartials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-pipe-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in StubEngine(track: track, framesPerFinal: 1) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        recordPCM: true,
        engineLabel: "stub"
    )
    await pipeline.start()
    let host = HostClock.now()
    capture.emit(PCMFrame(track: .system, data: Data(repeating: 1, count: 3_200), hostTime: host))
    capture.emit(PCMFrame(track: .microphone, data: Data(repeating: 2, count: 3_200), hostTime: host))
    let directory = try #require(await pipeline.sessionDirectory)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"track\":\"microphone\"") && text.contains("\"track\":\"system\"")
    }
    await pipeline.stop()
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(!events.contains("\"text\":\"partial\""))
    #expect(!events.contains("\"conf\""))
    #expect(events.contains("\"t\":\"end\""))
    let transcript = try String(contentsOf: SessionPaths.transcriptFile(in: directory), encoding: .utf8)
    #expect(transcript.contains("[them] S1"))
    #expect(transcript.contains("[me]"))
    let pcm = try Data(contentsOf: SessionPaths.pcmFile(track: "system", in: directory))
    #expect(pcm.count == 3_200)
    #expect(await pipeline.isRunning == false)
}

@Test func blockedProbeDoesNotStartAFakeRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-block-\(UUID().uuidString)", isDirectory: true)
    let started = LockedFlag()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: {
            started.value = true
            return FakeCapture()
        },
        makeEngine: { track in StubEngine(track: track) },
        launchProbe: { .blocked(reason: "screen recording access denied") },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    #expect(started.value == false)
    #expect(await pipeline.isRunning == false)
    let directory = try #require(await pipeline.sessionDirectory)
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(events.contains("\"kind\":\"blocked\""))
    #expect(events.contains("\"t\":\"end\""))
    #expect(!events.contains("\"t\":\"seg\""))
}

@Test func midSessionRecheckWritesBlockedOnTheLiveSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-revoke-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let gate = RevokeGate()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in StubEngine(track: track) },
        launchProbe: { .granted },
        recheckProbe: { gate.state() },
        engineLabel: "stub",
        probeInterval: .milliseconds(20)
    )
    await pipeline.start()
    #expect(await pipeline.isRunning)
    capture.emit(PCMFrame(track: .system, data: Data(repeating: 1, count: 3_200), hostTime: HostClock.now()))
    gate.block()
    let directory = try #require(await pipeline.sessionDirectory)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"kind\":\"blocked\"")
    }
    try await waitUntil { await pipeline.isRunning == false }
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(events.contains("\"kind\":\"blocked\""))
    #expect(!events.contains("\"clean\":true"))
}

@Test func streamRevokeWritesBlockedAndStops() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-stop-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in StubEngine(track: track) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    capture.fail(.tccRevokedMidSession)
    let directory = try #require(await pipeline.sessionDirectory)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"kind\":\"blocked\"") && text.contains("\"t\":\"end\"")
    }
    #expect(await pipeline.isRunning == false)
}

private func packageRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

private func waitUntil(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<50 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out")
}

private final class LockedFlag: @unchecked Sendable {
    var value = false
}

private final class RevokeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false

    func block() {
        lock.lock()
        blocked = true
        lock.unlock()
    }

    func state() -> PermissionState {
        lock.lock()
        let blocked = blocked
        lock.unlock()
        return blocked ? .blocked(reason: "screen recording access denied") : .granted
    }
}

private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let frames: AsyncStream<PCMFrame>
    let failures: AsyncStream<CaptureError>
    private let frameContinuation: AsyncStream<PCMFrame>.Continuation
    private let failureContinuation: AsyncStream<CaptureError>.Continuation

    init() {
        let frames = AsyncStream<PCMFrame>.makeStream()
        let failures = AsyncStream<CaptureError>.makeStream()
        self.frames = frames.stream
        self.frameContinuation = frames.continuation
        self.failures = failures.stream
        self.failureContinuation = failures.continuation
    }

    func start() async throws {}

    func stop() async {
        frameContinuation.finish()
        failureContinuation.finish()
    }

    func emit(_ frame: PCMFrame) {
        frameContinuation.yield(frame)
    }

    func fail(_ error: CaptureError) {
        failureContinuation.yield(error)
    }
}
