public enum EngineState: Sendable, Equatable {
    case connecting
    case ready
    case streaming
    case degraded(reason: String)
    case closed
    case failed(reason: String)
}
