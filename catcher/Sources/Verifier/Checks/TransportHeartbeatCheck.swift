import AudioCapture
import TranscriptionEngine

/// Handshake deadline is 5s from `connecting` without `ready`. Afterwards, a live
/// (non-silent) track with no engine event for 8s is degraded. Gaps and reconnects
/// are recorded as their own annotations.
public struct TransportHeartbeatCheck: Sendable {
    public static let handshakeLimitMs = 5_000
    public static let eventLimitMs = 8_000

    public private(set) var degraded = false
    public private(set) var reason = ""
    private var connectingSince: Int?
    private var ready = false
    private var lastEventAt: Int?
    private var handshakeEmitted = false
    private var heartbeatEmitted = false
    private var degradedReasons: Set<String> = []

    public init() {}

    public static func describe(_ error: EngineError) -> String {
        switch error {
        case .missingAPIKey: "missing XAI_API_KEY"
        case .handshakeTimeout: "no transcript.created"
        case .socket(let message), .protocol(let message): message
        case .closed: "engine closed"
        }
    }

    public mutating func reset() {
        degraded = false
        reason = ""
        connectingSince = nil
        ready = false
        lastEventAt = nil
        handshakeEmitted = false
        heartbeatEmitted = false
        degradedReasons = []
    }

    public mutating func observe(_ event: EngineEvent, track: AudioTrack, atMs: Int) -> [Annotation] {
        lastEventAt = atMs
        heartbeatEmitted = false
        switch event {
        case .state(let state):
            return observe(state, atMs: atMs)
        case .gap(let fromMs, let toMs):
            return [Annotation(
                atMs: atMs,
                kind: "gap",
                detail: .gap(fromMs: fromMs, toMs: toMs, track: track.rawValue)
            )]
        case .transcript:
            return []
        case .error(let error):
            return observe(.degraded(reason: Self.describe(error)), atMs: atMs)
        }
    }

    public mutating func observe(_ state: EngineState, atMs: Int) -> [Annotation] {
        lastEventAt = atMs
        switch state {
        case .connecting:
            connectingSince = atMs
            ready = false
            return []
        case .ready, .streaming:
            let resumed = degraded || !degradedReasons.isEmpty
            ready = true
            connectingSince = nil
            handshakeEmitted = false
            degraded = false
            reason = ""
            degradedReasons = []
            heartbeatEmitted = false
            if resumed {
                return [Annotation(atMs: atMs, kind: "resumed", detail: .text("transport resumed"))]
            }
            return []
        case .degraded(let why):
            degraded = true
            reason = why
            guard degradedReasons.insert(why).inserted else { return [] }
            return [Annotation(atMs: atMs, kind: "degraded", detail: .text(why))]
        case .failed(let why):
            degraded = true
            reason = why
            guard degradedReasons.insert(why).inserted else { return [] }
            return [Annotation(atMs: atMs, kind: "degraded", detail: .text(why))]
        case .closed:
            return []
        }
    }

    public mutating func tick(atMs: Int, audioFlowing: Bool) -> [Annotation] {
        if !ready, let connectingSince, atMs - connectingSince >= Self.handshakeLimitMs, !handshakeEmitted {
            handshakeEmitted = true
            degraded = true
            reason = "no transcript.created within \(Self.handshakeLimitMs)ms"
            return [Annotation(atMs: connectingSince + Self.handshakeLimitMs, kind: "degraded", detail: .text("\(reason) emittedAtMs=\(atMs)"))]
        }
        if ready, audioFlowing, let lastEventAt, atMs - lastEventAt >= Self.eventLimitMs, !heartbeatEmitted {
            heartbeatEmitted = true
            degraded = true
            reason = "no engine event for \(Self.eventLimitMs)ms while audio is flowing"
            return [Annotation(atMs: lastEventAt + Self.eventLimitMs, kind: "degraded", detail: .text("\(reason) emittedAtMs=\(atMs)"))]
        }
        return []
    }
}
