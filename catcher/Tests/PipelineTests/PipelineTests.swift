import AudioCapture
import Diagnostics
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
    // SwiftPM has no Info.plist CatcherGitSHA. The grader rejects `unknown`.
    #expect(events.contains("\"app\":\"0.0.1+unknown\""))
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

@Test func stubSessionWritesEightOKStagesAndKeepsEventShape() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-stages-\(UUID().uuidString)", isDirectory: true)
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
    let lines = try stageLines(in: directory)
    let names = FailureTrace.verdictLines(lines).map { $0.name ?? "" }
    #expect(names == [
        "tcc-check",
        "capture-start",
        "api-connect",
        "api-connect",
        "frames-received",
        "pcm-extract",
        "api-stream",
        "segments-received",
        "transcript-write",
    ])
    let verdicts = FailureTrace.verdictLines(lines)
    #expect(verdicts.allSatisfy { $0.verdict == "OK" })
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    try expectEventShapeUnchanged(events)
}

@Test func declinedCaptureFailsAtCaptureStartAfterTCC() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-sc-\(UUID().uuidString)", isDirectory: true)
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { ThrowingCapture() },
        makeEngine: { track in StubEngine(track: track) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    let lines = try stageLines(in: directory)
    let capture = try #require(lines.first { $0.name == "capture-start" })
    #expect(capture.verdict == "FAIL")
    #expect(capture.field("code") == "-3801")
    #expect(capture.field("domain") == "SCStreamErrorDomain")
    let trace = try #require(lines.first { $0.kind == .trace && $0.field("first-fail") != nil })
    #expect(trace.field("last-ok") == "tcc-check")
    #expect(trace.field("first-fail") == "capture-start")
    #expect(!lines.contains { $0.name == "frames-received" })
}

@Test func failedConnectCarriesTheEngineError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-conn-\(UUID().uuidString)", isDirectory: true)
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { FakeCapture() },
        makeEngine: { _ in BoomEngine() },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    let lines = try stageLines(in: directory)
    let connect = try #require(lines.first { $0.name == "api-connect" })
    #expect(connect.verdict == "FAIL")
    #expect(connect.field("error")?.contains("connect refused 401") == true)
    let trace = try #require(lines.first { $0.kind == .trace && $0.field("first-fail") != nil })
    #expect(trace.field("first-fail") == "api-connect")
    #expect(trace.field("error")?.contains("connect refused 401") == true)
}

@Test func assembleFailureIsATranscriptWriteFail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-asm-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in StubEngine(track: track, framesPerFinal: 1) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    let host = HostClock.now()
    capture.emit(PCMFrame(track: .system, data: Data(repeating: 1, count: 3_200), hostTime: host))
    capture.emit(PCMFrame(track: .microphone, data: Data(repeating: 1, count: 3_200), hostTime: host))
    let directory = try #require(await pipeline.sessionDirectory)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"t\":\"seg\"")
    }
    try FileManager.default.createDirectory(
        at: SessionPaths.transcriptFile(in: directory),
        withIntermediateDirectories: true
    )
    await pipeline.stop()
    let lines = try stageLines(in: directory)
    let transcript = try #require(FailureTrace.verdictLines(lines).last { $0.name == "transcript-write" })
    #expect(transcript.verdict == "FAIL")
    #expect(transcript.field("error")?.isEmpty == false)
}

private func stageLines(in directory: URL) throws -> [StageLine] {
    let text = try String(contentsOf: directory.appendingPathComponent("stages.log"), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { StageLine.parse(String($0)) }
}

private func expectEventShapeUnchanged(_ events: String) throws {
    let allowed: [String: Set<String>] = [
        "session": ["t", "id", "startedAt", "engine", "tracks", "app"],
        "seg": ["t", "seq", "track", "startMs", "endMs", "final", "text", "speaker", "conf", "words"],
        "ann": ["t", "atMs", "kind", "detail"],
        "end": ["t", "atMs", "clean", "recovered"],
    ]
    let lines = events.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(!lines.isEmpty)
    for line in lines {
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let kind = try #require(object["t"] as? String)
        let keys = Set(object.keys)
        #expect(keys.isSubset(of: allowed[kind] ?? []))
        if let words = object["words"] as? [[String: Any]] {
            for word in words {
                #expect(Set(word.keys).isSubset(of: ["w", "s", "e", "c"]))
            }
        }
    }
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

private final class ThrowingCapture: AudioCapturing, @unchecked Sendable {
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

    func start() async throws {
        throw NSError(domain: "SCStreamErrorDomain", code: -3801, userInfo: [
            NSLocalizedDescriptionKey: "declined",
        ])
    }

    func stop() async {
        frameContinuation.finish()
        failureContinuation.finish()
    }
}

private actor BoomEngine: TranscriptionEngine {
    nonisolated let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    init() {
        let pair = AsyncStream<EngineEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect(track: AudioTrack) async throws {
        throw EngineError.socket("connect refused 401")
    }

    func send(_ frame: PCMFrame) async throws {}

    func finish() async {
        continuation.finish()
    }
}
