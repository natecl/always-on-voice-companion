import Foundation

public actor SessionStore {
    public let directory: URL
    public private(set) var syncedFinalCount = 0
    public private(set) var fsyncCount = 0
    private let writer: JSONLWriter
    private var seq = 0
    private var committed: [String: [SegmentRow]] = [:]

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = try JSONLWriter(url: SessionPaths.eventsFile(in: directory))
    }

    init(directory: URL, writer: JSONLWriter) {
        self.directory = directory
        self.writer = writer
    }

    public func begin(_ header: SessionHeader) throws {
        try append(.session(header), fsync: true)
    }

    /// Partials are never written. Every stored segment is a final and is fsync'd.
    /// Blank text is silence-endpoint spam. A row whose words restate finals it
    /// already covers is the stitched utterance, not new speech.
    @discardableResult
    public func appendSegment(_ segment: SegmentRow) throws -> Bool {
        if Self.normalizedWords(segment.text).isEmpty { return false }
        if isCoveredRestatement(segment) { return false }
        var stored = segment
        seq += 1
        stored.seq = seq
        stored.final = true
        try append(.seg(stored), fsync: true)
        syncedFinalCount += 1
        committed[stored.track, default: []].append(stored)
        return true
    }

    public func appendAnnotation(_ annotation: AnnotationRow) throws {
        try append(.ann(annotation), fsync: true)
    }

    public func end(atMs: Int, clean: Bool) throws {
        try append(.end(EndRow(atMs: atMs, clean: clean)), fsync: true)
    }

    public func assemble(recovered: Bool) throws {
        let contents = try JSONLReader.read(url: SessionPaths.eventsFile(in: directory))
        try Assembler.write(directory: directory, rows: contents.rows, recovered: recovered)
    }

    public static func list(root: URL) throws -> [SessionSummary] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let children = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var summaries: [SessionSummary] = []
        for directory in children {
            let summaryURL = SessionPaths.summaryFile(in: directory)
            if let data = try? Data(contentsOf: summaryURL),
               let summary = try? JSONDecoder().decode(SessionSummary.self, from: data) {
                summaries.append(summary)
                continue
            }
            let events = SessionPaths.eventsFile(in: directory)
            guard let contents = try? JSONLReader.read(url: events) else { continue }
            summaries.append(Assembler.summary(rows: contents.rows, recovered: false))
        }
        return summaries.sorted { $0.startedAt > $1.startedAt }
    }

    /// `speech_final` / `transcript.done` repeat chunk text over the same span.
    /// A later sentence that merely uses the same words does not cover that span.
    private func isCoveredRestatement(_ segment: SegmentRow) -> Bool {
        let candidate = Self.normalizedWords(segment.text)
        let prior = committed[segment.track] ?? []
        let tolerance = 250
        var collected: [[String]] = []
        for row in prior.reversed() {
            if row.endMs + tolerance < segment.startMs { break }
            let covers = segment.startMs <= row.startMs + tolerance
                && segment.endMs + tolerance >= row.endMs
            if !covers { break }
            collected.append(Self.normalizedWords(row.text))
            var joined: [String] = []
            for words in collected.reversed() {
                joined.append(contentsOf: words)
            }
            if joined == candidate { return true }
            if joined.count > candidate.count { return false }
        }
        return false
    }

    static func normalizedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private func append(_ row: SessionRow, fsync: Bool) throws {
        try writer.append(row, fsync: fsync)
        if fsync {
            fsyncCount = writer.fsyncCount
        }
    }
}

public enum ISO8601 {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
