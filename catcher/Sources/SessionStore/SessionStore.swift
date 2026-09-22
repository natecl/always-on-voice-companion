import Foundation

public actor SessionStore {
    public let directory: URL
    public private(set) var syncedFinalCount = 0
    public private(set) var fsyncCount = 0
    private let writer: JSONLWriter
    private var seq = 0

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
    public func appendSegment(_ segment: SegmentRow) throws {
        var stored = segment
        seq += 1
        stored.seq = seq
        stored.final = true
        try append(.seg(stored), fsync: true)
        syncedFinalCount += 1
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
