import Foundation
import SessionStore

public enum BriefWriteError: Error, Equatable, Sendable {
    case refusedV0Artifact(String)
    case failed(String)
    case eventsMutated
}

public struct BriefFailureRecord: Sendable, Equatable, Codable {
    public var schema: String
    public var error: String
    public var attempts: Int

    public init(schema: String = BriefContract.schema, error: String, attempts: Int) {
        self.schema = schema
        self.error = error
        self.attempts = attempts
    }
}

public enum BriefWriter {
    /// `brief.json` first, `brief.md` last. Never opens `events.jsonl` for writing.
    public static func write(_ brief: Brief, to directory: URL, logLine: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(brief)
        try replace(SessionPaths.briefFile(in: directory), with: json)
        try appendLog(logLine, in: directory)
        let markdown = Data(BriefRenderer.markdown(brief).utf8)
        try replace(SessionPaths.briefMarkdownFile(in: directory), with: markdown)
    }

    /// A failure must not leave `brief.md` behind, or it looks finished.
    public static func writeFailure(_ record: BriefFailureRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in [SessionPaths.briefMarkdownFile(in: directory), SessionPaths.briefFile(in: directory)] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try replace(SessionPaths.briefErrorFile(in: directory), with: try encoder.encode(record))
        try appendLog("failed attempts=\(record.attempts) \(record.error)", in: directory)
    }

    public static func eventsUnchanged(url: URL, sha256: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return BriefHash.sha256Hex(data) == sha256
    }

    private static func appendLog(_ line: String, in directory: URL) throws {
        let url = SessionPaths.briefLogFile(in: directory)
        if BriefPaths.isV0Artifact(url) {
            throw BriefWriteError.refusedV0Artifact(url.lastPathComponent)
        }
        let text = line.hasSuffix("\n") ? line : line + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    private static func replace(_ url: URL, with data: Data) throws {
        if BriefPaths.isV0Artifact(url) {
            throw BriefWriteError.refusedV0Artifact(url.lastPathComponent)
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw BriefWriteError.failed(String(describing: error))
        }
    }
}
