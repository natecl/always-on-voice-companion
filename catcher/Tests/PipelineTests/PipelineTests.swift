import AudioCapture
import Diagnostics
import Foundation
import Metering
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

@Test func stubSessionWritesCostJSONLWithoutTouchingEventShape() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-cost-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let clock = ManualSessionClock()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in StubEngine(track: track, framesPerFinal: 1) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        recordPCM: true,
        engineLabel: "stub",
        clock: clock,
        meterIntervalMs: 50
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    let frame = Data(repeating: 1, count: 3_200)
    capture.emit(PCMFrame(track: .system, data: frame, hostTime: clock.now()))
    capture.emit(PCMFrame(track: .microphone, data: Data(repeating: 2, count: 3_200), hostTime: clock.now()))
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"track\":\"microphone\"") && text.contains("\"track\":\"system\"")
    }
    clock.set(50)
    try await waitLong {
        await minuteEnds(in: directory).contains(50)
    }
    let live = try #require(await pipeline.costSnapshot())
    #expect(live.calibrated == false)
    #expect(live.billingModel == "uncalibrated")
    #expect(live.rateCardID == "xai-stt-2026-09-18")
    #expect(live.usd == 0)
    clock.set(100)
    try await waitLong {
        await minuteEnds(in: directory).contains(100)
    }
    await pipeline.stop()

    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    try expectEventShapeUnchanged(events)
    #expect(!events.contains("cost."))
    #expect(!events.contains("wireBytes"))
    let pcm = try Data(contentsOf: SessionPaths.pcmFile(track: "system", in: directory))
    #expect(pcm == frame)

    let read = try CostLog.read(url: CostLog.fileURL(in: directory))
    #expect(read.droppedTruncatedTail == false)
    let rows = read.rows
    guard case .session(let session) = rows.first else {
        Issue.record("missing cost.session")
        return
    }
    #expect(session.v == 1)
    #expect(session.engine == "stub")
    #expect(session.billingModel == "uncalibrated")
    #expect(session.rateCard == "xai-stt-2026-09-18")
    guard case .rollup(let rollup) = rows.last else {
        Issue.record("missing cost.rollup")
        return
    }
    #expect(rollup.clean == true)
    #expect(rollup.recovered == false)
    #expect(rollup.usd == 0)
    let endAt = try endAtMs(events)
    #expect(rollup.wallMs == endAt)

    let minutes = rows.compactMap { row -> CostMinuteRow? in
        if case .minute(let minute) = row { return minute }
        return nil
    }
    let ordinals = Set(minutes.map(\.m)).sorted()
    #expect(ordinals == Array(0..<ordinals.count))
    #expect(ordinals.count >= 2)
    for ordinal in ordinals {
        let slice = minutes.filter { $0.m == ordinal }
        #expect(Set(slice.map(\.track)) == ["system", "microphone"])
        #expect(Set(slice.map(\.component)) == ["stt.stub"])
        #expect(Set(slice.map(\.fromMs)).count == 1)
        #expect(Set(slice.map(\.toMs)).count == 1)
    }
    for index in ordinals.dropFirst() {
        let previous = try #require(minutes.first { $0.m == index - 1 })
        let current = try #require(minutes.first { $0.m == index })
        #expect(previous.toMs == current.fromMs)
    }
    for track in ["system", "microphone"] {
        let summed = minutes.filter { $0.track == track }.reduce(0) { $0 + $1.wireBytes }
        #expect(rollup.units[track]?.wireBytes == summed)
    }
}

@Test func stopWritesEndWhenEngineCloseNeverReturns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-hang-\(UUID().uuidString)", isDirectory: true)
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { FakeCapture() },
        makeEngine: { _ in HungFinishEngine() },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    let started = ContinuousClock.now
    await pipeline.stop()
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2))
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(events.contains("\"t\":\"end\""))
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

@Test func resumedRowCarriesTrackAndEngineBacklog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-resume-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let engines = LockedEngines()
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in engines.make(track) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub"
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    engines.engine(.system)?.dropAndResume(backlogMs: 21_000)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("\"kind\":\"resumed\"")
    }
    await pipeline.stop()
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(events.contains("ws closed (1006) track=system"))
    #expect(events.contains("\"track\":\"system\""))
    #expect(events.contains("transport resumed track=system backlogMs=21000"))
    try expectEventShapeUnchanged(events)
}

@Test func harnessStopKeepsRecordingUntilTheLiveTailFloor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-tail-\(UUID().uuidString)", isDirectory: true)
    let capture = FakeCapture()
    let engines = LockedEngines()
    // Gap toMs is 2000 in the fake. Floor = 2000 + 100 + 800 = 2900, a short hold.
    let pipeline = Pipeline(
        sessionRoot: root,
        makeCapture: { capture },
        makeEngine: { track in engines.make(track) },
        launchProbe: { .granted },
        recheckProbe: { .granted },
        engineLabel: "stub",
        liveTailFloor: LiveTailFloor(marginMs: 0, tailMs: 800, slackMs: 0)
    )
    await pipeline.start()
    let directory = try #require(await pipeline.sessionDirectory)
    engines.engine(.system)?.dropAndResume(backlogMs: 100)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("backlogMs=100")
    }
    let stopping = Task { await pipeline.stopAfterLiveTail() }
    try await Task.sleep(for: .milliseconds(200))
    // Still recording inside the hold: capture reaches the engine and a live
    // final is stored, so the tail window has speech and not an idle clock.
    #expect(await pipeline.isRunning)
    let system = try #require(engines.engine(.system))
    let sentBefore = system.sentFrames
    capture.emit(PCMFrame(track: .system, data: Data(repeating: 1, count: 3_200), hostTime: HostClock.now()))
    try await waitUntil { system.sentFrames > sentBefore }
    system.speakFinal("live words after the backlog", startMs: 2_500)
    try await waitUntil {
        let text = (try? String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)) ?? ""
        return text.contains("live words after the backlog")
    }
    await stopping.value
    let events = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    let endAt = try endAtMs(events)
    #expect(endAt >= 2_900)
    #expect(await pipeline.isRunning == false)
    #expect(events.contains("transport resumed track=system backlogMs=100"))
    // Holding must not open another degrade after the resume.
    let resumed = events.range(of: "backlogMs=100")
    let after = resumed.map { events[$0.upperBound...] } ?? ""
    #expect(!after.contains("\"kind\":\"degraded\""))
    #expect(!after.contains("\"kind\":\"gap\""))
}

@Test func liveTailFloorMatchesTheGraderThresholds() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("harness/thresholds.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let thresholds = try #require(object)
    #expect(thresholds["p3LiveMarginMs"] as? Int == LiveTailFloor.grader.marginMs)
    #expect(thresholds["p3MinTailMs"] as? Int == LiveTailFloor.grader.tailMs)
    #expect(LiveTailFloor.grader.slackMs == 5_000)
    // 859205c board: resumed 52742, backlog 18020, liveFrom 73762, tail need 88762.
    #expect(LiveTailFloor.grader.endMs(resumedAtMs: 52_742, backlogMs: 18_020) == 88_762)
}

private final class LockedEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [AudioTrack: ReconnectingEngine] = [:]

    func make(_ track: AudioTrack) -> ReconnectingEngine {
        let engine = ReconnectingEngine()
        lock.lock()
        made[track] = engine
        lock.unlock()
        return engine
    }

    func engine(_ track: AudioTrack) -> ReconnectingEngine? {
        lock.lock()
        defer { lock.unlock() }
        return made[track]
    }
}

private final class ReconnectingEngine: TranscriptionEngine, EngineDiagnostics, @unchecked Sendable {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let lock = NSLock()
    private var backlog = 0
    private var sent = 0
    private var track = AudioTrack.system
    private var seq = 0

    init() {
        let pair = AsyncStream<EngineEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    var sentFrames: Int { lock.withLock { sent } }

    func connect(track: AudioTrack) async throws {
        lock.withLock { self.track = track }
        continuation.yield(.state(.connecting))
        continuation.yield(.state(.ready))
        continuation.yield(.state(.streaming))
    }

    func send(_ frame: PCMFrame) async throws {
        lock.withLock { sent += 1 }
    }

    func speakFinal(_ text: String, startMs: Int) {
        let (track, seq) = lock.withLock { () -> (AudioTrack, Int) in
            self.seq += 1
            return (self.track, self.seq)
        }
        continuation.yield(.transcript(TranscriptEvent(
            track: track,
            kind: .final,
            text: text,
            words: [],
            seq: seq,
            startMs: startMs,
            endMs: startMs + 1_000
        )))
    }

    func finish() async {
        continuation.yield(.state(.closed))
        continuation.finish()
    }

    func dropAndResume(backlogMs: Int) {
        lock.lock()
        backlog = backlogMs
        lock.unlock()
        continuation.yield(.state(.degraded(reason: "ws closed (1006)")))
        continuation.yield(.gap(fromMs: 1_000, toMs: 2_000))
        continuation.yield(.state(.streaming))
    }

    func snapshot() async -> EngineDiagnosticsSnapshot {
        EngineDiagnosticsSnapshot(lastResumeBacklogMs: lock.withLock { backlog })
    }
}

private func stageLines(in directory: URL) throws -> [StageLine] {
    let text = try String(contentsOf: directory.appendingPathComponent("stages.log"), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { StageLine.parse(String($0)) }
}

private func endAtMs(_ events: String) throws -> Int {
    for line in events.split(separator: "\n", omittingEmptySubsequences: true) {
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        if object["t"] as? String == "end" {
            return try #require(object["atMs"] as? Int)
        }
    }
    Issue.record("missing end row")
    return -1
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

private func waitLong(_ predicate: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<200 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out")
}

private func minuteEnds(in directory: URL) async -> Set<Int> {
    guard let read = try? CostLog.read(url: CostLog.fileURL(in: directory)) else { return [] }
    var ends: Set<Int> = []
    for case .minute(let row) in read.rows {
        ends.insert(row.toMs)
    }
    return ends
}

/// Session time the test moves by hand. `now` is milliseconds × 1_000_000 so
/// `milliseconds(from:to:)` is a plain difference.
private final class ManualSessionClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds = 0

    func now() -> UInt64 {
        lock.lock()
        let milliseconds = milliseconds
        lock.unlock()
        return UInt64(milliseconds) * 1_000_000
    }

    func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        Int(end / 1_000_000) - Int(start / 1_000_000)
    }

    func set(_ milliseconds: Int) {
        lock.lock()
        self.milliseconds = milliseconds
        lock.unlock()
    }
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

private final class HungFinishEngine: TranscriptionEngine, @unchecked Sendable {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    init() {
        let pair = AsyncStream<EngineEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect(track: AudioTrack) async throws {
        continuation.yield(.state(.ready))
        continuation.yield(.state(.streaming))
    }

    func send(_ frame: PCMFrame) async throws {}

    func finish() async {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            return
        }
        continuation.finish()
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
