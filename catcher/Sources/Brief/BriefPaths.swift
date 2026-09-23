import Foundation
import SessionStore

extension SessionPaths {
    public static func briefFile(in directory: URL) -> URL {
        directory.appendingPathComponent("brief.json")
    }

    public static func briefMarkdownFile(in directory: URL) -> URL {
        directory.appendingPathComponent("brief.md")
    }

    public static func briefErrorFile(in directory: URL) -> URL {
        directory.appendingPathComponent("brief-error.json")
    }

    public static func briefLogFile(in directory: URL) -> URL {
        directory.appendingPathComponent("brief.log")
    }
}

public enum BriefPaths {
    /// Files the brief is not allowed to open for writing.
    public static let v0Artifacts = ["events.jsonl", "transcript.txt", "session.json"]

    public static func isV0Artifact(_ url: URL) -> Bool {
        v0Artifacts.contains(url.lastPathComponent)
    }
}
