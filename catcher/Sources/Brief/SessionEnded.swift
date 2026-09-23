import Foundation

public enum StopTrigger: String, Sendable, Equatable {
    case button
    case hotkey
    case harness
    case blocked
    case failure
}

/// Phase 1 owns this shape. It lives here until that module lands.
public struct SessionEnded: Sendable, Equatable {
    public let sessionID: String
    public let directory: URL
    public let stopRequestedWallMs: Int
    public let assembledWallMs: Int
    public let clean: Bool
    public let recovered: Bool
    public let trigger: StopTrigger

    public init(
        sessionID: String,
        directory: URL,
        stopRequestedWallMs: Int,
        assembledWallMs: Int,
        clean: Bool,
        recovered: Bool,
        trigger: StopTrigger
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.stopRequestedWallMs = stopRequestedWallMs
        self.assembledWallMs = assembledWallMs
        self.clean = clean
        self.recovered = recovered
        self.trigger = trigger
    }
}

public enum BriefIntent: String, Sendable, Equatable {
    /// Stop → notes. A recovered session does not take this path.
    case automatic
    /// The Make notes button. The only path for a recovered session.
    case manual
}
