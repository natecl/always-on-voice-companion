public enum MeterUnit: String, Sendable, Equatable, Codable {
    case audioMs
    case inputTokens
    case outputTokens
    case requests
}

/// Monotonic totals from one engine. `audioMs` is `wireBytes / 32`, not a
/// second counter, so a partial chunk cannot make minute deltas disagree
/// with the session total.
public struct MeterCounters: Sendable, Equatable {
    public var wireBytes: Int
    public var replayBytes: Int
    public var tailBytes: Int
    public var socketAttempts: Int
    public var socketsOpened: Int
    public var socketOpenMs: Int
    public var serverAudioMs: Int

    public init(
        wireBytes: Int = 0,
        replayBytes: Int = 0,
        tailBytes: Int = 0,
        socketAttempts: Int = 0,
        socketsOpened: Int = 0,
        socketOpenMs: Int = 0,
        serverAudioMs: Int = 0
    ) {
        self.wireBytes = wireBytes
        self.replayBytes = replayBytes
        self.tailBytes = tailBytes
        self.socketAttempts = socketAttempts
        self.socketsOpened = socketsOpened
        self.socketOpenMs = socketOpenMs
        self.serverAudioMs = serverAudioMs
    }

    public static let zero = MeterCounters()

    public var audioMs: Int { wireBytes / MeteringConstants.bytesPerMillisecond }
}

/// Optional. Engines that do not conform still run; the pipeline records zeros.
public protocol MeteredEngine: Sendable {
    func meterCounters() async -> MeterCounters
}

public enum MeterComponent {
    public static let stream = "stt.stream"
    public static let stub = "stt.stub"

    /// `engineLabel` is the session header value (`stub` or the Grok model id).
    public static func stt(engineLabel: String) -> String {
        engineLabel == "stub" ? stub : stream
    }
}
