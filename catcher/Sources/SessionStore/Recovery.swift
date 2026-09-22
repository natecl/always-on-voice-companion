import Foundation

public struct RecoveryReport: Sendable, Equatable {
    public var directory: URL
    public var id: String
    public var droppedTruncatedTail: Bool

    public init(directory: URL, id: String, droppedTruncatedTail: Bool) {
        self.directory = directory
        self.id = id
        self.droppedTruncatedTail = droppedTruncatedTail
    }
}

public enum Recovery {
    /// Sessions without an `end` row are crashes. Assemble whatever survived
    /// and close them so the next launch does not recover the same directory again.
    public static func scan(root: URL, now: Date = Date()) throws -> [RecoveryReport] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let children = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var reports: [RecoveryReport] = []
        for directory in children {
            let isDirectory = (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let events = SessionPaths.eventsFile(in: directory)
            guard manager.fileExists(atPath: events.path) else { continue }
            let contents = try JSONLReader.read(url: events)
            if contents.rows.contains(where: { if case .end = $0 { return true }; return false }) {
                continue
            }
            if contents.droppedTruncatedTail {
                try JSONLWriter.replace(url: events, rows: contents.rows)
            }
            let atMs = contents.rows.reduce(0) { partial, row in
                switch row {
                case .seg(let seg): return max(partial, seg.endMs)
                case .ann(let ann): return max(partial, ann.atMs)
                case .end(let end): return max(partial, end.atMs)
                case .session: return partial
                }
            }
            let writer = try JSONLWriter(url: events)
            try writer.append(
                .ann(AnnotationRow(
                    atMs: atMs,
                    kind: "recovered",
                    detail: .text("no end row; assembled surviving segments")
                )),
                fsync: true
            )
            try writer.append(.end(EndRow(atMs: atMs, clean: false, recovered: true)), fsync: true)
            let updated = try JSONLReader.read(url: events)
            try Assembler.write(directory: directory, rows: updated.rows, recovered: true)
            let id: String
            if case .session(let header) = contents.rows.first {
                id = header.id
            } else {
                id = directory.lastPathComponent
            }
            reports.append(RecoveryReport(directory: directory, id: id, droppedTruncatedTail: contents.droppedTruncatedTail))
        }
        _ = now
        return reports
    }
}
