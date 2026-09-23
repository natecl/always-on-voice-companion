import Foundation

public enum NotesEngineFactory {
    public enum Failure: Error, Equatable, Sendable {
        case unknownEngine(String)
        case missingAPIKey
        case emptyModel
    }

    /// `CATCHER_NOTES_ENGINE=grok|stub`. Unset means grok. This is the only place engine names are chosen.
    public static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any NotesHTTPTransport = URLSessionNotesTransport()
    ) throws -> any NotesEngine {
        let choice = environment["CATCHER_NOTES_ENGINE"] ?? "grok"
        switch choice {
        case "stub":
            return StubNotesEngine()
        case "grok":
            let key = environment[NotesService.apiKeyEnvironment] ?? ""
            if key.isEmpty {
                throw Failure.missingAPIKey
            }
            let model = environment["CATCHER_BRIEF_MODEL"] ?? NotesService.briefModel
            if model.isEmpty {
                throw Failure.emptyModel
            }
            return GrokNotesEngine(model: model, apiKey: key, transport: transport)
        default:
            throw Failure.unknownEngine(choice)
        }
    }
}
