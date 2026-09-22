import Foundation

public enum CatcherMetadata {
    public static let appVersion = "0.0.1"
    public static let bundleIdentifier = "com.catcher.app"
}

public enum SessionPaths {
    public static let folderName = "Catcher/sessions"

    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["CATCHER_SESSION_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func directory(id: UUID, root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func eventsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("events.jsonl")
    }

    public static func transcriptFile(in directory: URL) -> URL {
        directory.appendingPathComponent("transcript.txt")
    }

    public static func summaryFile(in directory: URL) -> URL {
        directory.appendingPathComponent("session.json")
    }

    public static func pcmFile(track: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(track).pcm")
    }
}
