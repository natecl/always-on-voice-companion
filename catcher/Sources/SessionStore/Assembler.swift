import Foundation

public struct SessionSummary: Sendable, Equatable, Codable {
    public var id: String
    public var startedAt: String
    public var engine: String
    public var tracks: [String]
    public var app: String
    public var clean: Bool
    public var recovered: Bool
    public var segmentCount: Int
    public var durationMs: Int
    public var annotationCount: Int

    public init(
        id: String,
        startedAt: String,
        engine: String,
        tracks: [String],
        app: String,
        clean: Bool,
        recovered: Bool,
        segmentCount: Int,
        durationMs: Int,
        annotationCount: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.engine = engine
        self.tracks = tracks
        self.app = app
        self.clean = clean
        self.recovered = recovered
        self.segmentCount = segmentCount
        self.durationMs = durationMs
        self.annotationCount = annotationCount
    }
}

public enum Assembler {
    /// Time-interleaved transcript. System audio is `[them]`, mic is `[me]`.
    /// Speaker labels stay inside that prefix so `S1` on each track is not the same person.
    public static func transcript(rows: [SessionRow]) -> String {
        let segments = rows.compactMap { row -> SegmentRow? in
            if case .seg(let seg) = row, seg.final { return seg }
            return nil
        }.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return lhs.track > rhs.track
        }
        return segments.map(line).joined(separator: "\n") + (segments.isEmpty ? "" : "\n")
    }

    public static func summary(rows: [SessionRow], recovered: Bool) -> SessionSummary {
        var header: SessionHeader?
        var end: EndRow?
        var segments = 0
        var annotations = 0
        var lastMs = 0
        for row in rows {
            switch row {
            case .session(let value):
                header = value
            case .seg(let seg):
                segments += 1
                lastMs = max(lastMs, seg.endMs)
            case .ann(let ann):
                annotations += 1
                lastMs = max(lastMs, ann.atMs)
            case .end(let value):
                end = value
                lastMs = max(lastMs, value.atMs)
            }
        }
        let recoveredFlag = recovered || end?.recovered == true
        return SessionSummary(
            id: header?.id ?? "",
            startedAt: header?.startedAt ?? "",
            engine: header?.engine ?? "",
            tracks: header?.tracks ?? [],
            app: header?.app ?? CatcherMetadata.headerApp,
            clean: end?.clean == true && !recoveredFlag,
            recovered: recoveredFlag,
            segmentCount: segments,
            durationMs: end?.atMs ?? lastMs,
            annotationCount: annotations
        )
    }

    public static func write(directory: URL, rows: [SessionRow], recovered: Bool) throws {
        let transcript = transcript(rows: rows)
        let summary = summary(rows: rows, recovered: recovered)
        try transcript.write(to: SessionPaths.transcriptFile(in: directory), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: SessionPaths.summaryFile(in: directory), options: .atomic)
    }

    public static func line(_ seg: SegmentRow) -> String {
        let who = seg.track == "microphone" ? "[me]" : "[them]"
        if let speaker = seg.speaker, !speaker.isEmpty {
            return "\(who) \(speaker) \(seg.text)"
        }
        return "\(who) \(seg.text)"
    }
}
