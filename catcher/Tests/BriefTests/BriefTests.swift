import Foundation
import SessionStore
import Testing
@testable import Brief

@Test func sha256MatchesKnownVectors() {
    #expect(BriefHash.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(BriefHash.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let longer = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    #expect(BriefHash.sha256Hex(Data(longer.utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
}

@Test func notesStayOffDuringHarnessUnlessAsked() {
    #expect(BriefLaunchPolicy.notesEnabled(environment: ["CATCHER_HARNESS": "1"]) == false)
    #expect(BriefLaunchPolicy.notesEnabled(environment: ["CATCHER_HARNESS": "1", "CATCHER_BRIEF": "0"]) == false)
    #expect(BriefLaunchPolicy.notesEnabled(environment: ["CATCHER_HARNESS": "1", "CATCHER_BRIEF": "1"]) == true)
    #expect(BriefLaunchPolicy.notesEnabled(environment: [:]) == true)
    #expect(BriefLaunchPolicy.notesEnabled(environment: ["CATCHER_BRIEF": "0"]) == false)
}

@Test func recoveredSessionsAreManualOnly() {
    #expect(BriefLaunchPolicy.runMode(recoveredAtLaunch: true) == .manual)
    #expect(BriefLaunchPolicy.runMode(recoveredAtLaunch: false) == .automatic)
}

@Test func notesVendorIsXAIOnTheExistingKey() {
    #expect(NotesService.vendor == "xAI")
    #expect(NotesService.completionsURL == "https://api.x.ai/v1/chat/completions")
    #expect(NotesService.apiKeyEnvironment == "XAI_API_KEY")
    #expect(NotesService.temperature == 0.2)
    #expect(NotesService.outputTokenCap == 1_200)
    #expect(NotesService.requestTimeoutSeconds == 22)
    #expect(NotesService.retryCutoffSeconds == 10)
}

@Test func inputLinesUseSeqMeThemAndClock() throws {
    let built = try requireReady(BriefInputBuilder.build(rows: [
        .session(SessionHeader(id: "abc", startedAt: "t", engine: "stub", tracks: ["system", "microphone"], app: "0.0.1")),
        .seg(segment(seq: 1, track: "system", startMs: 10_420, text: counted(10), speaker: "S1")),
        .seg(segment(seq: 2, track: "microphone", startMs: 0, text: counted(15))),
        .seg(segment(seq: 3, track: "system", startMs: 20_000, text: "partial should drop", final: false)),
        .ann(AnnotationRow(atMs: 41_000, kind: "gap", detail: .gap(fromMs: 41_000, toMs: 47_210, track: "system"))),
        .end(EndRow(atMs: 60_000, clean: true)),
    ], eventsSHA256: "abc"))
    #expect(built.lines == [
        "s2 [me] 00:00 \(counted(15))",
        "s1 [them S1] 00:10 \(counted(10))",
    ])
    #expect(built.caveats == ["Transcript gap 00:41\u{2013}00:47 (system)."])
    #expect(built.sessionID == "abc")
    #expect(built.wordCount == 25)
    #expect(built.clean)
    #expect(!built.recovered)
}

@Test func shortAndEmptySessionsSkipTheModel() {
    #expect(BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "system", startMs: 0, text: "not final", final: false)),
    ], eventsSHA256: "x") == .skipped(.noSpeech))
    #expect(BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(24))),
    ], eventsSHA256: "x") == .skipped(.tooShort))
    let ready = BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(25))),
    ], eventsSHA256: "x")
    guard case .ready(let input) = ready else {
        Issue.record("25 words is enough")
        return
    }
    #expect(input.wordCount == 25)
}

@Test func caveatsComeFromCaptureAnnotationsNotTheModel() throws {
    let blocked = try requireReady(BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(25))),
        .ann(AnnotationRow(atMs: 1_000, kind: "blocked", detail: .text("tcc revoked"))),
        .ann(AnnotationRow(atMs: 2_000, kind: "noAudio", detail: .text("silent"))),
        .end(EndRow(atMs: 3_000, clean: false)),
    ], eventsSHA256: "x"))
    #expect(blocked.caveats == [
        "No audio detected.",
        "Recording stopped early: permission revoked.",
    ])
    #expect(!blocked.clean)

    let recovered = try requireReady(BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(25))),
        .end(EndRow(atMs: 3_000, clean: false, recovered: true)),
    ], eventsSHA256: "x"))
    #expect(recovered.recovered)
    #expect(recovered.caveats == ["Session recovered after a crash. The transcript may be incomplete."])

    let stopped = try requireReady(BriefInputBuilder.build(rows: [
        .seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(25))),
        .end(EndRow(atMs: 3_000, clean: false)),
    ], eventsSHA256: "x"))
    #expect(stopped.caveats == ["Recording stopped early."])
}

@Test func builderDoesNotWriteEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-ro-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let events = SessionPaths.eventsFile(in: directory)
    var body = Data()
    let encoder = JSONEncoder()
    for row in [SessionRow.seg(segment(seq: 1, track: "microphone", startMs: 0, text: counted(25)))] {
        body.append(try encoder.encode(row))
        body.append(0x0A)
    }
    try body.write(to: events)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: events.path)
    let before = try Data(contentsOf: events)
    let decoded = try JSONLReader.read(url: events).rows
    let built = BriefInputBuilder.build(rows: decoded, eventsSHA256: BriefHash.sha256Hex(before))
    let after = try Data(contentsOf: events)
    #expect(before == after)
    guard case .ready(let input) = built else {
        Issue.record("expected notes input")
        return
    }
    #expect(input.eventsSha256 == BriefHash.sha256Hex(before))
    #expect(BriefPaths.isV0Artifact(events))
    #expect(!BriefPaths.isV0Artifact(SessionPaths.briefFile(in: directory)))
    #expect(SessionPaths.briefMarkdownFile(in: directory).lastPathComponent == "brief.md")
    #expect(!BriefPaths.v0Artifacts.contains("brief.json"))
}

@Test func validatorDropsBadCitesPrunesAndCaps() throws {
    let words31 = counted(31)
    let draft = NotesDraft(title: "one two three four five six seven eight nine", blocks: [
        BriefBlock(id: "summary", kind: .summary, heading: "Summary", items: [
            BriefItem(text: "kept", cites: [1, 1, 99], owner: "me"),
            BriefItem(text: "no cite", cites: []),
            BriefItem(text: "   ", cites: [1]),
        ]),
        BriefBlock(id: "empty", kind: .topic, heading: "Gone", items: [
            BriefItem(text: " ", cites: [1]),
        ]),
        BriefBlock(id: "t-late", kind: .topic, heading: "Later", items: [
            BriefItem(text: words31, cites: [30]),
        ]),
        BriefBlock(id: "t-early", kind: .topic, heading: "Earlier", items: [
            BriefItem(text: "first topic", cites: [4]),
        ]),
        BriefBlock(id: "decisions", kind: .decisions, heading: "Decisions", items: [
            BriefItem(text: "ship it", cites: [4]),
        ]),
        BriefBlock(id: "next", kind: .actionItems, heading: "Next steps", items: [
            BriefItem(text: "Send it Friday", cites: [4], owner: "Bob", due: "Monday"),
            BriefItem(text: "Send the other Friday", cites: [4], owner: "Me", due: "Friday"),
        ]),
    ])
    let validation = try requireValidation(BriefValidator.validate(
        draft: draft,
        context: sampleContext(seqs: [1, 4, 30], texts: [4: "Send the other Friday", 1: "kept", 30: words31])
    ))
    #expect(validation.droppedCites == 1)
    #expect(validation.uncitedItems == 1)
    #expect(validation.prunedBlocks == 1)
    #expect(validation.logLine.contains("uncited=1"))
    let brief = validation.brief
    #expect(brief.cost == nil)
    #expect(brief.schema == BriefContract.schema)
    #expect(brief.title == "one two three four five six seven eight")
    #expect(brief.caveats == ["recorder only"])
    #expect(brief.blocks.map(\.id) == ["summary", "t-early", "t-late", "decisions", "next"])
    #expect(brief.blocks[0].items.map(\.cites) == [[1], []])
    #expect(brief.blocks[0].items[0].owner == nil)
    #expect(BriefWords.split(brief.blocks[2].items[0].text).count == 30)
    #expect(!brief.blocks[2].items[0].text.contains("w31"))
    #expect(brief.blocks[4].items[0].owner == nil)
    #expect(brief.blocks[4].items[0].due == nil)
    #expect(brief.blocks[4].items[1].owner == "me")
    #expect(brief.blocks[4].items[1].due == "Friday")
}

@Test func validatorRequiresASummaryAndFillsAnEmptyTitle() throws {
    let missing = BriefValidator.validate(
        draft: NotesDraft(title: "x", blocks: [
            BriefBlock(id: "t", kind: .topic, heading: "T", items: [BriefItem(text: "only", cites: [1])]),
        ]),
        context: sampleContext(seqs: [1])
    )
    #expect(missing == .failure(.missingSummary))

    let blank = try requireValidation(BriefValidator.validate(
        draft: NotesDraft(title: "   ", blocks: [
            BriefBlock(id: "", kind: .summary, heading: "", items: [BriefItem(text: "hello", cites: [1])]),
            BriefBlock(id: "topic", kind: .topic, heading: "A", items: [BriefItem(text: "a", cites: [1])]),
            BriefBlock(id: "topic", kind: .topic, heading: "B", items: [BriefItem(text: "b", cites: [1])]),
        ]),
        context: sampleContext(seqs: [1])
    ))
    #expect(blank.brief.title == "Notes")
    #expect(blank.brief.blocks[0].heading == "Summary")
    #expect(blank.brief.blocks.map(\.id) == ["summary", "topic", "topic-2"])
}

@Test func copyPayloadHasFooterAndOmitsCaveatsAndCost() throws {
    let brief = sampleBrief()
    let markdown = BriefRenderer.markdown(brief, footnote: BriefFootnote(line: "about $0.04"))
    let html = BriefRenderer.html(brief, footnote: BriefFootnote(line: "about $0.04"))
    let markdownGolden = try golden("sample.md")
    let htmlGolden = try golden("sample.html")
    #expect(markdown == markdownGolden)
    #expect(html == htmlGolden)
    #expect(markdown.contains(BriefContract.footer))
    #expect(!markdown.contains("network"))
    #expect(!markdown.contains("00:41"))
    #expect(!markdown.contains("41"))
    #expect(!markdown.contains("$0.04"))
    #expect(!html.contains("network"))
    #expect(!html.contains("$0.04"))
    #expect(!BriefRenderer.markdown(brief, footer: false).contains(BriefContract.footer))
    let block = BriefRenderer.markdownBlock(brief.blocks[1])
    #expect(block.hasPrefix("## Pricing\n"))
    #expect(!block.contains(BriefContract.footer))
    #expect(!block.contains("# Q4"))
}

@Test func htmlEscapesText() {
    var brief = sampleBrief()
    brief.blocks[0].items[0].text = "a & b <c>"
    let html = BriefRenderer.html(brief, footer: false)
    #expect(html.contains("<li>a &amp; b &lt;c&gt;</li>"))
}

@Test func briefJSONWritesNullCostAndRejectsAnythingElse() throws {
    let data = try JSONEncoder().encode(sampleBrief())
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(raw["cost"] is NSNull)
    #expect(raw["schema"] as? String == BriefContract.schema)
    let decoded = try JSONDecoder().decode(Brief.self, from: data)
    #expect(decoded == sampleBrief())

    var priced = raw
    priced["cost"] = 1
    let pricedData = try JSONSerialization.data(withJSONObject: priced)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Brief.self, from: pricedData)
    }
}

@Test func stubIsDeterministicAndCitesRealSegments() async throws {
    let input = try requireReady(BriefInputBuilder.build(rows: [
        .session(SessionHeader(id: "s", startedAt: "t", engine: "stub", tracks: ["microphone"], app: "0.0.1")),
        .seg(segment(seq: 7, track: "microphone", startMs: 0, text: "Alpha beta gamma delta epsilon zeta eta theta and several more words for the group now")),
        .seg(segment(seq: 8, track: "microphone", startMs: 1_000, text: "We decided the date")),
        .seg(segment(seq: 9, track: "microphone", startMs: 2_000, text: "I will send the note")),
    ], eventsSHA256: "hash"))
    let engine = StubNotesEngine()
    let first = try await engine.write(input, timeout: .seconds(1))
    let second = try await engine.write(input, timeout: .seconds(1))
    #expect(first == second)
    #expect(BriefWords.split(first.title).count <= BriefContract.titleWordCap)
    let cites = first.blocks.flatMap(\.items).flatMap(\.cites)
    #expect(cites.allSatisfy { input.segmentSeqs.contains($0) })
    #expect(first.blocks.map(\.kind) == [.summary, .topic, .decisions, .actionItems])
    #expect(first.blocks[3].items[0].owner == "me")
    let validation = try requireValidation(BriefValidator.validate(draft: first, context: context(for: input)))
    let markdown = BriefRenderer.markdown(validation.brief)
    #expect(markdown.contains(BriefContract.footer))
    #expect(validation.brief.caveats.isEmpty)
    #expect(validation.brief.cost == nil)
    let empty = BriefInput(
        sessionID: "",
        segments: [],
        caveats: [],
        segmentTexts: [:],
        wordCount: 0,
        durationMs: 0,
        clean: false,
        recovered: false,
        eventsSha256: ""
    )
    await #expect(throws: NotesEngineError.emptyInput) {
        try await engine.write(empty, timeout: .seconds(1))
    }
}

@Test func syntheticHourFixtureIsLongEnoughAndNotPrivate() throws {
    let url = fixtureURL()
    let before = try Data(contentsOf: url)
    let text = String(decoding: before, as: UTF8.self)
    let lowered = text.lowercased()
    #expect(!lowered.contains("nathan"))
    #expect(!text.contains("@"))
    #expect(lowered.contains("\"engine\":\"synthetic\""))
    let contents = try JSONLReader.read(url: url)
    #expect(contents.droppedTruncatedTail == false)
    let built = try requireReady(BriefInputBuilder.build(
        rows: contents.rows,
        eventsSHA256: BriefHash.sha256Hex(before)
    ))
    let after = try Data(contentsOf: url)
    #expect(before == after)
    #expect(built.wordCount >= 9_000)
    #expect(built.durationMs >= 3_600_000)
    #expect(built.lines.contains { $0.contains("[me]") })
    #expect(built.lines.contains { $0.contains("[them S1]") })
    #expect(built.lines.contains { $0.contains("[them S2]") })
    #expect(built.caveats == ["Transcript gap 20:00\u{2013}20:06 (system)."])
    #expect(built.eventsSha256 == BriefHash.sha256Hex(before))
}

private func counted(_ count: Int) -> String {
    (1...count).map { "w\($0)" }.joined(separator: " ")
}

private func segment(
    seq: Int,
    track: String,
    startMs: Int,
    text: String,
    speaker: String? = nil,
    final: Bool = true
) -> SegmentRow {
    SegmentRow(
        seq: seq,
        track: track,
        startMs: startMs,
        endMs: startMs + 1_000,
        final: final,
        text: text,
        speaker: speaker,
        words: []
    )
}

private func sampleContext(seqs: Set<Int>, texts: [Int: String] = [:]) -> BriefContext {
    BriefContext(
        sessionID: "s",
        createdAt: "2026-09-23T11:02:07.412Z",
        source: BriefSource(
            eventsSha256: "abc",
            segmentCount: seqs.count,
            wordCount: 100,
            durationMs: 60_000,
            clean: true,
            recovered: false
        ),
        engine: BriefEngineInfo(name: "stub", model: "stub"),
        latency: BriefLatency(),
        usage: BriefUsage(inputTokens: 1, outputTokens: 1),
        caveats: ["recorder only"],
        validSeqs: seqs,
        segmentTexts: texts
    )
}

private func context(for input: BriefInput) -> BriefContext {
    BriefContext(
        sessionID: input.sessionID,
        createdAt: "2026-09-23T11:02:07.412Z",
        source: BriefSource(
            eventsSha256: input.eventsSha256,
            segmentCount: input.segments.count,
            wordCount: input.wordCount,
            durationMs: input.durationMs,
            clean: input.clean,
            recovered: input.recovered
        ),
        engine: BriefEngineInfo(name: "stub", model: "stub"),
        latency: BriefLatency(),
        usage: BriefUsage(inputTokens: 0, outputTokens: 0),
        caveats: input.caveats,
        validSeqs: input.segmentSeqs,
        segmentTexts: input.segmentTexts
    )
}

private func sampleBrief() -> Brief {
    Brief(
        sessionId: "session",
        createdAt: "2026-09-23T11:02:07.412Z",
        source: BriefSource(
            eventsSha256: "abc",
            segmentCount: 4,
            wordCount: 40,
            durationMs: 3_541_000,
            clean: true,
            recovered: false
        ),
        engine: BriefEngineInfo(name: "grok-notes", model: "pinned-later"),
        latency: BriefLatency(),
        usage: BriefUsage(inputTokens: 10, outputTokens: 2),
        title: "Q4 pricing review with Acme",
        blocks: [
            BriefBlock(id: "summary", kind: .summary, heading: "Summary", items: [
                BriefItem(text: "Acme will pilot the Team plan in October.", cites: [41, 57]),
            ]),
            BriefBlock(id: "topic-1", kind: .topic, heading: "Pricing", items: [
                BriefItem(text: "The pilot covers one workspace.", cites: [12]),
            ]),
            BriefBlock(id: "decisions", kind: .decisions, heading: "Decisions", items: [
                BriefItem(text: "The review date is Friday.", cites: [88]),
            ]),
            BriefBlock(id: "next", kind: .actionItems, heading: "Next steps", items: [
                BriefItem(text: "Send the pilot contract", cites: [201], owner: "me", due: "Friday"),
            ]),
        ],
        caveats: ["Transcript gap 00:41\u{2013}00:47 (network)."]
    )
}

private func golden(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")
        .appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("harness/fixtures/known-60min.events.jsonl")
}

private func requireReady(_ build: BriefBuild) throws -> BriefInput {
    guard case .ready(let input) = build else {
        Issue.record("expected ready input, got \(build)")
        throw BriefValidationError.missingSummary
    }
    return input
}

private func requireValidation(
    _ result: Result<BriefValidation, BriefValidationError>
) throws -> BriefValidation {
    switch result {
    case .success(let validation):
        return validation
    case .failure(let error):
        Issue.record("expected a brief, got \(error)")
        throw error
    }
}
