import Foundation
import SessionStore
import Testing
@testable import Brief

@Test func signalStopsAndStaysUpOnlyForABriefHarness() {
    #expect(BriefSignalPolicy.installsStopAndStayUp(environment: [
        "CATCHER_HARNESS": "1",
        "CATCHER_BRIEF": "1",
    ]))
    #expect(BriefSignalPolicy.installsStopAndStayUp(environment: ["CATCHER_HARNESS": "1"]) == false)
    #expect(BriefSignalPolicy.installsStopAndStayUp(environment: ["CATCHER_BRIEF": "1"]) == false)
    #expect(BriefSignalPolicy.installsStopAndStayUp(environment: [:]) == false)
}

@Test func adapterReadsSessionJSONAndRefusesAutomaticRecoveredNotes() throws {
    let directory = try makeNotesDirectory()
    let summary = SessionSummary(
        id: "sess",
        startedAt: "t",
        engine: "stub",
        tracks: ["microphone"],
        app: "0.0.1",
        clean: false,
        recovered: true,
        segmentCount: 1,
        durationMs: 1_000,
        annotationCount: 0
    )
    let data = try JSONEncoder().encode(summary)
    try data.write(to: SessionPaths.summaryFile(in: directory))
    let ended = try BriefStopAdapter.sessionEnded(
        directory: directory,
        stopRequestedWallMs: 10,
        assembledWallMs: 20,
        trigger: .button
    )
    #expect(ended.sessionID == "sess")
    #expect(ended.recovered == true)
    #expect(ended.clean == false)
    #expect(ended.stopRequestedWallMs == 10)
    #expect(BriefStopAdapter.shouldAutoRun(ended, environment: ["CATCHER_BRIEF": "1"]) == false)
    let live = SessionEnded(
        sessionID: "sess",
        directory: directory,
        stopRequestedWallMs: 10,
        assembledWallMs: 20,
        clean: true,
        recovered: false,
        trigger: .harness
    )
    #expect(BriefStopAdapter.shouldAutoRun(live, environment: ["CATCHER_HARNESS": "1"]) == false)
    #expect(BriefStopAdapter.shouldAutoRun(live, environment: [
        "CATCHER_HARNESS": "1",
        "CATCHER_BRIEF": "1",
    ]))
    #expect(BriefStopAdapter.shouldAutoRun(live, environment: ["CATCHER_BRIEF": "0"]) == false)
}

@Test func copyPayloadKeepsTheFooterAndDropsCaveats() throws {
    let brief = sampleBrief(caveat: "Transcript gap 00:41\u{2013}00:47 (system).")
    let payload = ClipboardPayload.notes(brief)
    #expect(payload.plainText.contains(BriefContract.footer))
    #expect(!payload.plainText.contains("Transcript gap"))
    #expect(!payload.html.contains("Transcript gap"))
    #expect(payload.html.contains("<h1>"))
    #expect(payload.html.contains("<h2>Summary</h2>"))
    #expect(payload.html.contains(BriefContract.footer))
    #expect(ClipboardPayload.plainType == "public.utf8-plain-text")
    #expect(ClipboardPayload.htmlType == "public.html")
    let block = try #require(brief.blocks.first)
    let one = ClipboardPayload.block(block)
    #expect(one.plainText.contains("## Summary"))
    #expect(!one.plainText.contains(BriefContract.footer))
    #expect(!one.html.contains("<h1>"))
    let transcript = ClipboardPayload.transcript("a <b> & quote")
    #expect(transcript.plainText == "a <b> & quote")
    #expect(transcript.html.contains("&lt;b&gt;"))
    #expect(!transcript.html.contains("<b>"))
}

@Test func notesSurfaceStatesMatchTheCopyUX() {
    let writing = NotesSurface.make(phase: .writing(startedWallMs: 1_000), nowMs: 4_200)
    #expect(writing.statusLine == "Writing notes… 3s")
    #expect(writing.copyNotesEnabled == false)
    #expect(writing.elapsedSeconds == 3)

    let ready = NotesSurface.make(phase: .ready(sampleBrief(caveat: "gap")), nowMs: 0)
    #expect(ready.copyNotesEnabled == true)
    #expect(ready.caveats == ["gap"])
    #expect(ready.copyButtonTitle == "Copy notes")
    let copied = ready.markedCopied(nowMs: 0)
    #expect(copied.copyButtonTitle == "Copied")
    #expect(copied.refresh(nowMs: 1_499).copyButtonTitle == "Copied")
    #expect(copied.refresh(nowMs: 1_500).copyButtonTitle == "Copy notes")

    let failed = NotesSurface.make(phase: .failed("timed out"), nowMs: 0)
    #expect(failed.statusLine == "Notes failed: timed out")
    #expect(failed.showRetry == true)
    #expect(failed.copyTranscriptEnabled == true)
    #expect(failed.copyNotesEnabled == false)

    #expect(NotesSurface.make(phase: .skipped(.noSpeech), nowMs: 0).statusLine == "No speech captured")
    #expect(NotesSurface.make(phase: .skipped(.tooShort), nowMs: 0).statusLine == "Too short for notes")
    let manual = NotesSurface.make(phase: .needsManualNotes, nowMs: 0)
    #expect(manual.showMakeNotes == true)
    #expect(manual.copyNotesEnabled == false)
    #expect(NotesCite.first([4, 9]) == 4)
    #expect(NotesCite.first([]) == nil)
}

@Test func diskAndTranscriptReadsDoNotTouchEvents() throws {
    let directory = try makeNotesDirectory()
    let events = SessionPaths.eventsFile(in: directory)
    let row = SegmentRow(seq: 7, track: "microphone", startMs: 0, endMs: 1_000, final: true, text: words(25), words: [])
    var body = try JSONEncoder().encode(SessionRow.seg(row))
    body.append(0x0A)
    try body.write(to: events)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: events.path)
    let before = try Data(contentsOf: events)
    let rows = NotesTranscript.rows(eventsFile: events)
    #expect(rows.count == 1)
    #expect(rows[0].seq == 7)
    #expect(rows[0].text.contains("[me]"))
    #expect(NotesDisk.phase(directory: directory, recovered: true) == .needsManualNotes)
    #expect(NotesDisk.phase(directory: directory, recovered: false) == .idle)
    let brief = sampleBrief(caveat: "gap")
    try JSONEncoder().encode(brief).write(to: SessionPaths.briefFile(in: directory))
    guard case .ready(let loaded) = NotesDisk.phase(directory: directory, recovered: true) else {
        Issue.record("expected ready")
        return
    }
    #expect(loaded.title == brief.title)
    #expect(loaded.caveats == ["gap"])
    try FileManager.default.removeItem(at: SessionPaths.briefFile(in: directory))
    let failure = BriefFailureRecord(error: "timed out", attempts: 1)
    try JSONEncoder().encode(failure).write(to: SessionPaths.briefErrorFile(in: directory))
    #expect(NotesDisk.phase(directory: directory, recovered: false) == .failed("timed out"))
    #expect(try Data(contentsOf: events) == before)
}

@Test func coordinatorAutoRunsCopiesAndLeavesARecoveredSessionManual() async throws {
    let live = try makeNotesDirectory()
    try writeSpeech(in: live)
    let before = try Data(contentsOf: SessionPaths.eventsFile(in: live))
    let engine = ScriptedEngine()
    let coordinator = NotesCoordinator(engine: engine)
    let ended = SessionEnded(
        sessionID: "live",
        directory: live,
        stopRequestedWallMs: 0,
        assembledWallMs: 5,
        clean: true,
        recovered: false,
        trigger: .button
    )
    let ready = await coordinator.stop(ended: ended, environment: [:])
    guard case .ready(let brief) = ready else {
        Issue.record("expected ready")
        return
    }
    #expect(engine.calls == 1)
    #expect(ClipboardPayload.notes(brief).plainText.contains(BriefContract.footer))
    #expect(!ClipboardPayload.notes(brief).plainText.contains("Transcript gap"))
    #expect(try Data(contentsOf: SessionPaths.eventsFile(in: live)) == before)

    let harness = try makeNotesDirectory()
    try writeSpeech(in: harness)
    let quiet = ScriptedEngine()
    let held = NotesCoordinator(engine: quiet)
    let suppressed = await held.stop(
        ended: SessionEnded(
            sessionID: "h",
            directory: harness,
            stopRequestedWallMs: 0,
            assembledWallMs: 1,
            clean: true,
            recovered: false,
            trigger: .harness
        ),
        environment: ["CATCHER_HARNESS": "1"]
    )
    #expect(suppressed == .idle)
    #expect(quiet.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.briefMarkdownFile(in: harness).path))

    let recoveredDir = try makeNotesDirectory()
    try writeSpeech(in: recoveredDir)
    let manualEngine = ScriptedEngine()
    let manual = NotesCoordinator(engine: manualEngine)
    let recovered = SessionEnded(
        sessionID: "recovered",
        directory: recoveredDir,
        stopRequestedWallMs: 0,
        assembledWallMs: 1,
        clean: false,
        recovered: true,
        trigger: .button
    )
    let waiting = await manual.stop(ended: recovered, environment: [:])
    #expect(waiting == .needsManualNotes)
    #expect(manualEngine.calls == 0)
    let made = await manual.makeNotes(ended: recovered, environment: [:])
    guard case .ready = made else {
        Issue.record("expected notes after Make notes")
        return
    }
    #expect(manualEngine.calls == 1)
}

@Test func coordinatorRetryRunsAgainAfterAHardFailure() async throws {
    let directory = try makeNotesDirectory()
    try writeSpeech(in: directory)
    let engine = ScriptedEngine()
    engine.error = .http(400, "no such model")
    let coordinator = NotesCoordinator(engine: engine)
    let ended = SessionEnded(
        sessionID: "retry",
        directory: directory,
        stopRequestedWallMs: 0,
        assembledWallMs: 1,
        clean: true,
        recovered: false,
        trigger: .button
    )
    let failed = await coordinator.stop(ended: ended, environment: [:])
    #expect(failed == .failed("http 400 no such model"))
    #expect(engine.calls == 1)
    #expect(!FileManager.default.fileExists(atPath: SessionPaths.briefMarkdownFile(in: directory).path))
    engine.error = nil
    let retried = await coordinator.retry(environment: [:])
    guard case .ready = retried else {
        Issue.record("expected retry to finish")
        return
    }
    #expect(engine.calls == 2)
    #expect(FileManager.default.fileExists(atPath: SessionPaths.briefMarkdownFile(in: directory).path))
}

private final class ScriptedEngine: NotesEngine, @unchecked Sendable {
    var label = BriefEngineInfo(name: "stub", model: "stub")
    var error: NotesEngineError?
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft {
        _ = timeout
        bump()
        if let error { throw error }
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

    private func bump() {
        lock.lock()
        _calls += 1
        lock.unlock()
    }
}

private func words(_ count: Int) -> String {
    (1...count).map { "w\($0)" }.joined(separator: " ")
}

private func sampleBrief(caveat: String) -> Brief {
    Brief(
        sessionId: "s",
        createdAt: "2026-09-23T11:02:07.412Z",
        source: BriefSource(
            eventsSha256: "abc",
            segmentCount: 1,
            wordCount: 25,
            durationMs: 60_000,
            clean: true,
            recovered: false
        ),
        engine: BriefEngineInfo(name: "stub", model: "stub"),
        latency: BriefLatency(),
        usage: BriefUsage(inputTokens: 1, outputTokens: 1),
        title: "Session notes",
        blocks: [
            BriefBlock(id: "summary", kind: .summary, heading: "Summary", items: [
                BriefItem(text: "A short note.", cites: [1]),
            ]),
        ],
        caveats: [caveat]
    )
}

private func makeNotesDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSpeech(in directory: URL) throws {
    let row = SegmentRow(
        seq: 1,
        track: "microphone",
        startMs: 0,
        endMs: 1_000,
        final: true,
        text: words(25),
        words: []
    )
    var body = try JSONEncoder().encode(SessionRow.seg(row))
    body.append(0x0A)
    let events = SessionPaths.eventsFile(in: directory)
    try body.write(to: events)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: events.path)
}
