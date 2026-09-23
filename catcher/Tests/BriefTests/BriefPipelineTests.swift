import Foundation
import SessionStore
import Testing
@testable import Brief

@Test func grokRequestUsesStructuredChatCompletions() async throws {
    let transport = ScriptTransport()
    transport.response = try chatEnvelope(model: "grok-4.20-0309-non-reasoning")
    let input = try readyInput(words(25))
    let engine = GrokNotesEngine(model: "grok-4.20-0309-non-reasoning", apiKey: "test-key", transport: transport)
    let draft = try await engine.write(input, timeout: .seconds(1))
    #expect(draft.usage == BriefUsage(inputTokens: 12, outputTokens: 4))
    #expect(draft.model == "grok-4.20-0309-non-reasoning")
    #expect(transport.authorizations == ["test-key"])
    let body = try #require(transport.requests.first)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "grok-4.20-0309-non-reasoning")
    #expect(json["temperature"] as? Double == 0.2)
    #expect(json["max_tokens"] as? Int == 1_200)
    #expect(json["stream"] as? Bool == false)
    let format = try #require(json["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let text = String(decoding: body, as: UTF8.self)
    #expect(!text.contains("test-key"))
    #expect(BriefPrompt.schema()["additionalProperties"] as? Bool == false)
}

@Test func grokRejectsInvalidJSONAndHTTPErrors() async throws {
    let transport = ScriptTransport()
    transport.response = Data("not-json".utf8)
    let engine = GrokNotesEngine(model: "m", apiKey: "k", transport: transport)
    let input = try readyInput(words(25))
    await #expect(throws: NotesEngineError.invalidJSON) {
        try await engine.write(input, timeout: .seconds(1))
    }
    transport.status = 400
    transport.response = Data("no such model".utf8)
    do {
        _ = try await engine.write(input, timeout: .seconds(1))
        Issue.record("expected http")
    } catch let error as NotesEngineError {
        guard case .http(400, let body) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(body.contains("no such model"))
    }
}

@Test func factoryNamesEnginesInOnePlace() throws {
    let stub = try NotesEngineFactory.make(environment: ["CATCHER_NOTES_ENGINE": "stub"])
    #expect(stub.label == BriefEngineInfo(name: "stub", model: "stub"))
    #expect(throws: NotesEngineFactory.Failure.missingAPIKey) {
        try NotesEngineFactory.make(environment: ["CATCHER_NOTES_ENGINE": "grok"])
    }
    #expect(throws: NotesEngineFactory.Failure.unknownEngine("other")) {
        try NotesEngineFactory.make(environment: ["CATCHER_NOTES_ENGINE": "other"])
    }
    let transport = ScriptTransport()
    let grok = try NotesEngineFactory.make(
        environment: ["CATCHER_NOTES_ENGINE": "grok", "XAI_API_KEY": "k", "CATCHER_BRIEF_MODEL": "override"],
        transport: transport
    )
    #expect(grok.label == BriefEngineInfo(name: "grok-notes", model: "override"))
    let pinned = try NotesEngineFactory.make(
        environment: ["XAI_API_KEY": "k"],
        transport: transport
    )
    #expect(pinned.label.model == NotesService.briefModel)
}

@Test func runnerWritesCopyableNotesAndLeavesEventsAlone() async throws {
    let fixture = try makeSession(spokenRows())
    let engine = GateEngine()
    let report = await BriefRunner().run(
        ended(fixture.dir, id: "s"),
        engine: engine,
        environment: [:],
        createdAt: "2026-09-23T11:02:07.412Z",
        stopwatch: ManualStopwatch(0)
    )
    #expect(report.outcome == .ready)
    #expect(report.attempts == 1)
    #expect(engine.calls == 1)
    let markdown = try String(contentsOf: SessionPaths.briefMarkdownFile(in: fixture.dir), encoding: .utf8)
    let brief = try JSONDecoder().decode(Brief.self, from: Data(contentsOf: SessionPaths.briefFile(in: fixture.dir)))
    #expect(markdown == BriefRenderer.markdown(brief))
    #expect(markdown.contains(BriefContract.footer))
    #expect(!markdown.contains("Transcript gap"))
    #expect(brief.caveats == ["Transcript gap 00:41\u{2013}00:47 (system)."])
    #expect(brief.cost == nil)
    #expect(try Data(contentsOf: fixture.events) == fixture.before)
    #expect(try String(contentsOf: SessionPaths.transcriptFile(in: fixture.dir), encoding: .utf8) == "transcript")
    #expect(try String(contentsOf: SessionPaths.summaryFile(in: fixture.dir), encoding: .utf8) == "summary")
}

@Test func runnerRetriesOnceAndNotAfterTheCutoff() async throws {
    let retry = try makeSession(spokenRows())
    let clock = ManualStopwatch(0)
    let engine = GateEngine()
    engine.failTimes = 1
    engine.advanceOnCall = 1_000
    engine.clock = clock
    let retried = await BriefRunner().run(
        ended(retry.dir, id: "retry"),
        engine: engine,
        environment: [:],
        stopwatch: clock
    )
    #expect(retried.outcome == .ready)
    #expect(retried.attempts == 2)
    #expect(engine.calls == 2)

    let late = try makeSession(spokenRows())
    let lateClock = ManualStopwatch(0)
    let lateEngine = GateEngine()
    lateEngine.failTimes = 1
    lateEngine.advanceOnCall = 11_000
    lateEngine.clock = lateClock
    let failed = await BriefRunner().run(
        ended(late.dir, id: "late"),
        engine: lateEngine,
        environment: [:],
        stopwatch: lateClock
    )
    #expect(failed.attempts == 1)
    #expect(lateEngine.calls == 1)
    guard case .failed(let reason) = failed.outcome else {
        Issue.record("expected failure")
        return
    }
    #expect(reason.contains("transport"))
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.briefMarkdownFile(in: late.dir).path))
    #expect(FileManager.default.fileExists(atPath: SessionPaths.briefErrorFile(in: late.dir).path))
    #expect(try Data(contentsOf: late.events) == late.before)
}

@Test func runnerTimesOutWithoutASecondAttempt() async throws {
    let fixture = try makeSession(spokenRows())
    let clock = ManualStopwatch(0)
    let engine = GateEngine()
    engine.hang = true
    engine.advanceOnCall = 11_000
    engine.clock = clock
    let budget = BriefBudget(
        requestTimeout: .milliseconds(40),
        retryCutoffMs: 10_000,
        singleCallTokenCap: 60_000,
        chunkTokenCap: 30_000
    )
    let report = await BriefRunner().run(
        ended(fixture.dir, id: "timeout"),
        engine: engine,
        environment: [:],
        budget: budget,
        stopwatch: clock
    )
    #expect(report.attempts == 1)
    #expect(engine.calls == 1)
    guard case .failed(let reason) = report.outcome else {
        Issue.record("expected timeout")
        return
    }
    #expect(reason.contains("timed out"))
}

@Test func runnerSkipsShortSessionsAndStaysOffInTheHarness() async throws {
    let short = try makeSession([
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: words(10))),
    ])
    let shortEngine = GateEngine()
    let skipped = await BriefRunner().run(ended(short.dir, id: "short"), engine: shortEngine, environment: [:])
    #expect(skipped.outcome == .skipped(.tooShort))
    #expect(shortEngine.calls == 0)

    let harness = try makeSession(spokenRows())
    let harnessEngine = GateEngine()
    let suppressed = await BriefRunner().run(
        ended(harness.dir, id: "harness"),
        engine: harnessEngine,
        environment: ["CATCHER_HARNESS": "1"]
    )
    #expect(suppressed.outcome == .suppressed)
    #expect(harnessEngine.calls == 0)
}

@Test func recoveredSessionsRunOnlyWhenAsked() async throws {
    let auto = try makeSession(spokenRows())
    let autoEngine = GateEngine()
    let blocked = await BriefRunner().run(
        ended(auto.dir, id: "recovered", recovered: true),
        engine: autoEngine,
        intent: .automatic,
        environment: [:]
    )
    #expect(blocked.outcome == .needsManualNotes)
    #expect(autoEngine.calls == 0)

    let manual = try makeSession(spokenRows())
    let manualEngine = GateEngine()
    let made = await BriefRunner().run(
        ended(manual.dir, id: "make", recovered: true),
        engine: manualEngine,
        intent: .manual,
        environment: [:],
        stopwatch: ManualStopwatch(0)
    )
    #expect(made.outcome == .ready)
    #expect(manualEngine.calls == 1)
}

@Test func runnerIsSingleFlightPerSession() async throws {
    let fixture = try makeSession(spokenRows())
    let engine = GateEngine()
    engine.pauseMs = 80
    let runner = BriefRunner()
    let first = Task { await runner.run(ended(fixture.dir, id: "same"), engine: engine, environment: [:]) }
    let second = Task { await runner.run(ended(fixture.dir, id: "same"), engine: engine, environment: [:]) }
    let reports = await [first.value, second.value]
    #expect(reports.allSatisfy { $0.outcome == .ready })
    #expect(engine.calls == 1)
}

@Test func longTranscriptUsesMapAndReduce() async throws {
    var rows: [SessionRow] = []
    for seq in 1...4 {
        rows.append(.seg(segment(seq: seq, track: "microphone", startMs: seq * 1_000, text: words(40))))
    }
    let fixture = try makeSession(rows)
    let engine = GateEngine()
    let budget = BriefBudget(
        requestTimeout: .seconds(2),
        retryCutoffMs: 10_000,
        singleCallTokenCap: 40,
        chunkTokenCap: 20
    )
    let report = await BriefRunner().run(
        ended(fixture.dir, id: "chunks"),
        engine: engine,
        environment: [:],
        budget: budget,
        stopwatch: ManualStopwatch(0)
    )
    #expect(report.outcome == .ready)
    #expect(engine.calls == 5)
    #expect(try Data(contentsOf: fixture.events) == fixture.before)
}

@Test func bakeOffPicksTheFastestCleanModel() async throws {
    let results = [
        BriefBakeModelResult(model: "slow", passes: 5, runs: 5, medianRequestMs: 100),
        BriefBakeModelResult(model: "fast", passes: 5, runs: 5, medianRequestMs: 40),
        BriefBakeModelResult(model: "flaky", passes: 4, runs: 5, medianRequestMs: 10),
    ]
    #expect(BriefBakeOff.winner(results) == "fast")
    #expect(BriefBakeOff.disqualified("grok-4.3") == true)
    #expect(BriefBakeOff.disqualified("grok-4.20-0309-non-reasoning") == false)

    let input = try readyInput(words(25))
    let clock = ManualStopwatch(0)
    let transport = ScriptTransport()
    transport.clock = clock
    transport.responseForModel = { model in
        let name = model == "alias" ? "grok-4.3" : model
        return try chatEnvelope(model: name)
    }
    let context = BriefContext(
        sessionID: "bake",
        createdAt: "2026-09-23T00:00:00.000Z",
        source: BriefSource(eventsSha256: input.eventsSha256, segmentCount: 1, wordCount: 25, durationMs: 1_000, clean: true, recovered: false),
        engine: BriefEngineInfo(name: "grok-notes", model: "fast"),
        latency: BriefLatency(),
        usage: BriefUsage(inputTokens: 0, outputTokens: 0),
        caveats: [],
        validSeqs: input.segmentSeqs,
        segmentTexts: input.segmentTexts
    )
    let trials = await BriefBakeOff.measure(
        input: input,
        models: ["alias", "fast"],
        runs: 5,
        apiKey: "k",
        transport: transport,
        context: context,
        stopwatch: clock
    )
    let summary = BriefBakeOff.summarize(trials)
    #expect(summary.first { $0.model == "alias" }?.passes == 0)
    #expect(summary.first { $0.model == "fast" }?.passes == 5)
    #expect(BriefBakeOff.winner(summary) == "fast")
}

@Test func benchReadsTheFixtureAndWritesElsewhere() async throws {
    let fixture = try makeSession(spokenRows())
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("brief-bench-\(UUID().uuidString)", isDirectory: true)
    let reports = await BriefBench.sessions(
        eventsFile: fixture.events,
        outputDirectory: output,
        runs: 1,
        engine: GateEngine(),
        environment: ["CATCHER_BRIEF": "1"]
    )
    #expect(reports.count == 1)
    #expect(reports[0].outcome == .ready)
    let markdown = output.appendingPathComponent("run-1").appendingPathComponent("brief.md")
    #expect(FileManager.default.fileExists(atPath: markdown.path))
    #expect(try Data(contentsOf: fixture.events) == fixture.before)
    #expect(!FileManager.default.fileExists(atPath: fixture.dir.appendingPathComponent("brief.md").path))
}

private final class ManualStopwatch: BriefStopwatch, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int

    init(_ ms: Int) { self.ms = ms }

    func nowMs() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ms
    }

    func advance(_ delta: Int) {
        lock.lock()
        ms += delta
        lock.unlock()
    }
}

private final class GateEngine: NotesEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var failTimes = 0
    var advanceOnCall = 0
    var hang = false
    var pauseMs = 0
    var clock: ManualStopwatch?
    let label = BriefEngineInfo(name: "stub", model: "stub")

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft {
        _ = timeout
        let snapshot = beginCall()
        clock?.advance(snapshot.advance)
        if snapshot.n <= snapshot.failTimes {
            throw NotesEngineError.transport("reset")
        }
        if snapshot.pause > 0 {
            try await Task.sleep(for: .milliseconds(snapshot.pause))
        }
        if snapshot.hang {
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NotesEngineError.transport("hang was not cancelled")
        }
        let seq = input.segments.first?.seq ?? 1
        return NotesDraft(
            title: "Session notes",
            blocks: [
                BriefBlock(id: "summary", kind: .summary, heading: "Summary", items: [
                    BriefItem(text: "A short note.", cites: [seq]),
                ]),
            ]
        )
    }

    private func beginCall() -> (n: Int, failTimes: Int, advance: Int, hang: Bool, pause: Int) {
        lock.lock()
        defer { lock.unlock() }
        _calls += 1
        return (_calls, failTimes, advanceOnCall, hang, pauseMs)
    }
}

private final class ScriptTransport: NotesHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var status = 200
    var response = Data()
    var responseForModel: ((String) throws -> Data)?
    var clock: ManualStopwatch?
    private var _requests: [Data] = []
    private var _authorizations: [String] = []

    var requests: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var authorizations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _authorizations
    }

    func post(url: URL, body: Data, authorization: String, timeout: Duration) async throws -> NotesHTTPResponse {
        _ = url
        _ = timeout
        let model = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String ?? ""
        if model == "fast" {
            clock?.advance(20)
        } else if !model.isEmpty {
            clock?.advance(80)
        }
        let payload: Data
        if let responseForModel {
            payload = try responseForModel(model)
        } else {
            payload = response
        }
        let status = record(body: body, authorization: authorization)
        return NotesHTTPResponse(status: status, body: payload)
    }

    private func record(body: Data, authorization: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(body)
        _authorizations.append(authorization)
        return status
    }
}

private func words(_ count: Int) -> String {
    (1...count).map { "w\($0)" }.joined(separator: " ")
}

private func readyInput(_ text: String) throws -> BriefInput {
    let built = BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: text)),
    ], eventsSHA256: "hash")
    guard case .ready(let input) = built else {
        Issue.record("expected input")
        throw BriefValidationError.missingSummary
    }
    return input
}

private func spokenRows() -> [SessionRow] {
    [
        .session(SessionHeader(id: "s", startedAt: "t", engine: "stub", tracks: ["microphone"], app: "0.0.1")),
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: words(25))),
        .ann(AnnotationRow(atMs: 41_000, kind: "gap", detail: .gap(fromMs: 41_000, toMs: 47_210, track: "system"))),
        .end(EndRow(atMs: 60_000, clean: true)),
    ]
}

private func segment(seq: Int, track: String, startMs: Int, text: String) -> SegmentRow {
    SegmentRow(seq: seq, track: track, startMs: startMs, endMs: startMs + 1_000, final: true, text: text, words: [])
}

private func makeSession(_ rows: [SessionRow]) throws -> (dir: URL, events: URL, before: Data) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var body = Data()
    let encoder = JSONEncoder()
    for row in rows {
        body.append(try encoder.encode(row))
        body.append(0x0A)
    }
    let events = SessionPaths.eventsFile(in: dir)
    try body.write(to: events)
    try "transcript".write(to: SessionPaths.transcriptFile(in: dir), atomically: true, encoding: .utf8)
    try "summary".write(to: SessionPaths.summaryFile(in: dir), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: events.path)
    return (dir, events, body)
}

private func ended(_ directory: URL, id: String, recovered: Bool = false) -> SessionEnded {
    SessionEnded(
        sessionID: id,
        directory: directory,
        stopRequestedWallMs: 0,
        assembledWallMs: 10,
        clean: !recovered,
        recovered: recovered,
        trigger: .button
    )
}

private func chatEnvelope(model: String) throws -> Data {
    let draft = NotesDraft(
        title: "Session notes",
        blocks: [
            BriefBlock(id: "summary", kind: .summary, heading: "Summary", items: [
                BriefItem(text: "A short note.", cites: [1], owner: nil, due: nil),
            ]),
        ]
    )
    let content = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
    let object: [String: Any] = [
        "model": model,
        "choices": [["message": ["role": "assistant", "content": content]]],
        "usage": ["prompt_tokens": 12, "completion_tokens": 4],
    ]
    return try JSONSerialization.data(withJSONObject: object)
}
