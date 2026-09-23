import Diagnostics
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
            let isDirectory: Bool
            do {
                isDirectory = try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                StageMirror.note("recovery resource \(ErrorDetail.sentence(error))")
                continue
            }
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
            let segmentCount = updated.rows.reduce(0) { count, row in
                if case .seg = row { return count + 1 }
                return count
            }
            do {
                try Assembler.write(directory: directory, rows: updated.rows, recovered: true)
            } catch {
                let sentence = ErrorDetail.sentence(error)
                StageMirror.note("recovery assemble \(sentence)")
                let sink = FileStageSink(directory: directory, fileName: "stages.log")
                sink.write(StageLine.stage(.transcriptWrite, .fail, [
                    Field("bytes", "0"),
                    Field("segments", String(segmentCount)),
                    Field("recovered", "true"),
                    Field("error", sentence),
                ]), fsync: true)
                throw error
            }
            let transcriptURL = SessionPaths.transcriptFile(in: directory)
            let bytes: Int
            do {
                bytes = try Data(contentsOf: transcriptURL).count
            } catch {
                StageMirror.note("recovery transcript \(ErrorDetail.sentence(error))")
                bytes = 0
            }
            let sink = FileStageSink(directory: directory, fileName: "stages.log")
            sink.write(StageLine.stage(.transcriptWrite, bytes > 0 ? .ok : .fail, [
                Field("bytes", String(bytes)),
                Field("segments", String(segmentCount)),
                Field("recovered", "true"),
            ]), fsync: true)
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
