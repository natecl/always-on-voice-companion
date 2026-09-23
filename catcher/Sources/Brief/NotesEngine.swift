import Foundation

/// What the notes model returns, before cite checks and caps.
public struct NotesDraft: Sendable, Equatable, Codable {
    public var title: String
    public var blocks: [BriefBlock]
    /// Filled by the engine from the API envelope. The model JSON does not include it.
    public var usage: BriefUsage?
    public var model: String?

    public init(title: String, blocks: [BriefBlock], usage: BriefUsage? = nil, model: String? = nil) {
        self.title = title
        self.blocks = blocks
        self.usage = usage
        self.model = model
    }
}

public protocol NotesEngine: Sendable {
    var label: BriefEngineInfo { get }
    func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft
}

public enum NotesEngineError: Error, Equatable, Sendable {
    case emptyInput
    case missingAPIKey
    case transport(String)
    case http(Int, String)
    case invalidJSON
    case timedOut

    var retries: Bool {
        switch self {
        case .transport, .invalidJSON, .timedOut:
            true
        case .http(let code, _) where code == 408 || code == 429 || (500...599).contains(code):
            true
        default:
            false
        }
    }
}

/// Cap locked 2026-09-23: xAI chat on the existing `XAI_API_KEY`. No new secret.
public enum NotesService {
    public static let vendor = "xAI"
    public static let completionsURL = "https://api.x.ai/v1/chat/completions"
    public static let apiKeyEnvironment = "XAI_API_KEY"
    public static let temperature = 0.2
    public static let outputTokenCap = 1_200
    public static let requestTimeoutSeconds = 22
    public static let retryCutoffSeconds = 10

    /// Pinned in this type, not in `catcher/harness/thresholds.json`. That file is the
    /// v0 grader contract and this climb does not edit it. Override per process with
    /// `CATCHER_BRIEF_MODEL`.
    ///
    /// Live timing did not run here: this VM has no `XAI_API_KEY`. This id is the only
    /// model on the xAI price list (2026-09-23) documented as non-reasoning. The other
    /// two bake-off candidates alias reasoning `grok-4.3` and stay in
    /// `BriefBakeOff.candidates` so a keyed run can time them and disqualify them.
    public static let briefModel = "grok-4.20-0309-non-reasoning"
}
