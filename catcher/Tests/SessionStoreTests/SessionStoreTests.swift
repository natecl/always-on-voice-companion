import Foundation
@testable import SessionStore
import Testing

@Test func finalsAndAnnotationsFsyncAndRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("catcher-store-\(UUID().uuidString)", isDirectory: true)
    let store = try SessionStore(directory: directory)
    try await store.begin(SessionHeader(
        id: "abc",
        startedAt: "2026-09-22T00:00:00.000Z",
        engine: "stub",
        tracks: ["system", "microphone"],
        app: "0.0.1"
    ))
    try await store.appendSegment(SegmentRow(
        seq: 1,
        track: "system",
        startMs: 10_420,
        endMs: 13_880,
        final: true,
        text: "hello",
        speaker: "S1",
        conf: 0.93,
        words: [WordStamp(w: "hello", s: 10_420, e: 10_610, c: 0.97)]
    ))
    try await store.appendAnnotation(AnnotationRow(
        atMs: 41_000,
        kind: "gap",
        detail: .gap(fromMs: 41_000, toMs: 47_210, track: "system")
    ))
    try await store.appendAnnotation(AnnotationRow(atMs: 47_210, kind: "resumed"))
    try await store.end(atMs: 60_000, clean: true)
    #expect(await store.fsyncCount == 5)
    #expect(await store.syncedFinalCount == 1)

    let text = try String(contentsOf: SessionPaths.eventsFile(in: directory), encoding: .utf8)
    #expect(text.contains("\"fromMs\":41000"))
    #expect(!text.contains("\"final\":false"))
    let rows = try decodeLines(text)
    #expect(rows.count == 5)
    guard case .seg(let seg) = rows[1] else {
        Issue.record("expected seg")
        return
    }
    #expect(seg.final)
    #expect(seg.speaker == "S1")
    #expect(seg.words.first?.w == "hello")
}

@Test func assemblerNamespacesSpeakersByTrack() {
    let rows: [SessionRow] = [
        .session(SessionHeader(id: "1", startedAt: "t", engine: "stub", tracks: ["system", "microphone"], app: "0.0.1")),
        .seg(SegmentRow(seq: 2, track: "microphone", startMs: 50, endMs: 80, final: true, text: "hi", words: [])),
        .seg(SegmentRow(seq: 1, track: "system", startMs: 10, endMs: 40, final: true, text: "hello", speaker: "S1", words: [])),
        .seg(SegmentRow(seq: 3, track: "system", startMs: 10, endMs: 40, final: false, text: "skip", words: [])),
    ]
    let transcript = Assembler.transcript(rows: rows)
    #expect(transcript == "[them] S1 hello\n[me] hi\n")
}

@Test func truncatedTailIsRecoveredOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let events = SessionPaths.eventsFile(in: directory)
    var body = Data()
    let header = SessionRow.session(SessionHeader(
        id: "session",
        startedAt: "2026-09-22T00:00:00.000Z",
        engine: "stub",
        tracks: ["system"],
        app: "0.0.1"
    ))
    let seg = SessionRow.seg(SegmentRow(
        seq: 1, track: "system", startMs: 0, endMs: 500, final: true, text: "kept", speaker: "S1", words: []
    ))
    body.append(try JSONEncoder().encode(header))
    body.append(0x0A)
    body.append(try JSONEncoder().encode(seg))
    body.append(0x0A)
    body.append(Data(#"{"t":"seg","text":"cut"#.utf8))
    try body.write(to: events)

    let reports = try Recovery.scan(root: root)
    #expect(reports.count == 1)
    #expect(reports[0].droppedTruncatedTail)
    let contents = try JSONLReader.read(url: events)
    #expect(contents.droppedTruncatedTail == false)
    #expect(contents.rows.contains { if case .seg(let row) = $0 { return row.text == "kept" }; return false })
    #expect(!contents.rows.contains { if case .seg(let row) = $0 { return row.text == "cut" }; return false })
    #expect(contents.rows.contains { if case .ann(let ann) = $0 { return ann.kind == "recovered" }; return false })
    #expect(contents.rows.contains { if case .end(let end) = $0 { return end.clean == false && end.recovered == true }; return false })
    let summary = try JSONDecoder().decode(SessionSummary.self, from: Data(contentsOf: SessionPaths.summaryFile(in: directory)))
    #expect(summary.recovered)
    #expect(!summary.clean)
    let transcript = try String(contentsOf: SessionPaths.transcriptFile(in: directory), encoding: .utf8)
    #expect(transcript.contains("[them] S1 kept"))
    let again = try Recovery.scan(root: root)
    #expect(again.isEmpty)
}

@Test func corruptMiddleLineIsLoud() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-bad-\(UUID().uuidString).jsonl")
    let good = try JSONEncoder().encode(SessionRow.session(SessionHeader(
        id: "x", startedAt: "t", engine: "stub", tracks: ["system"], app: "0.0.1"
    )))
    var data = good
    data.append(0x0A)
    data.append(Data(#"{"t":"nope"}"#.utf8))
    data.append(0x0A)
    data.append(Data(#"{"t":"end","atMs":1,"clean":true}"#.utf8))
    data.append(0x0A)
    try data.write(to: url)
    #expect(throws: StoreError.corrupt(line: 2)) {
        try JSONLReader.read(url: url)
    }
}

private func decodeLines(_ text: String) throws -> [SessionRow] {
    try text.split(separator: "\n").map { line in
        try JSONDecoder().decode(SessionRow.self, from: Data(line.utf8))
    }
}
