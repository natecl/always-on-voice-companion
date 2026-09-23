import Foundation

/// What the notes model returns, before cite checks and caps.
public struct NotesDraft: Sendable, Equatable, Codable {
    public var title: String
    public var blocks: [BriefBlock]

    public init(title: String, blocks: [BriefBlock]) {
        self.title = title
        self.blocks = blocks
    }
}

public protocol NotesEngine: Sendable {
    func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft
}

public enum NotesEngineError: Error, Equatable, Sendable {
    case emptyInput
}

/// Cap locked 2026-09-23: xAI chat on the existing `XAI_API_KEY`. No new secret.
/// The HTTP client lands in a later slice. These are the values it must use.
public enum NotesService {
    public static let vendor = "xAI"
    public static let completionsURL = "https://api.x.ai/v1/chat/completions"
    public static let apiKeyEnvironment = "XAI_API_KEY"
    public static let temperature = 0.2
    public static let outputTokenCap = 1_200
    public static let requestTimeoutSeconds = 22
    public static let retryCutoffSeconds = 10
}
