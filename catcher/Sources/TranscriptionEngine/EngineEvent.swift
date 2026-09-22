public enum EngineError: Error, Sendable, Equatable {
    case missingAPIKey
    case handshakeTimeout
    case socket(String)
    case `protocol`(String)
    case closed
}

public enum EngineEvent: Sendable, Equatable {
    case transcript(TranscriptEvent)
    case state(EngineState)
    case gap(fromMs: Int, toMs: Int)
    case error(EngineError)
}
