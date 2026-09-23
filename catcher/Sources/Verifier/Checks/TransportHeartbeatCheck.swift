import AudioCapture
import TranscriptionEngine

/// Handshake deadline is 5s from `connecting` without `ready`. Afterwards, a live
/// (sustained-audio) track with no engine event for 8s is degraded. Gaps and
/// reconnects are recorded as their own annotations.
///
/// State is per track. Under a network drop both sockets die; the first track
/// back must not write `resumed` for, or clear the degrade of, the other one.
/// Degraded and resumed detail text ends in `track=<t>` so the grader can pair
/// one chain per track.
public struct TransportHeartbeatCheck: Sendable {
    public static let handshakeLimitMs = 5_000
    public static let eventLimitMs = 8_000

    private struct TrackTransport: Sendable {
        var degraded = false
        var reason = ""
        var connectingSince: Int?
        var ready = false
        var lastEventAt: Int?
        var handshakeEmitted = false
        var heartbeatEmitted = false
        var degradedReasons: Set<String> = []
    }

    private var tracks: [AudioTrack: TrackTransport] = [:]

    public var degraded: Bool { tracks.values.contains { $0.degraded } }
    public var reason: String {
        AudioTrack.allCases.lazy.compactMap { self.tracks[$0] }.first { $0.degraded }?.reason ?? ""
    }

    public init() {}

    public static func describe(_ error: EngineError) -> String {
        switch error {
        case .missingAPIKey: "missing XAI_API_KEY"
        case .handshakeTimeout: "no transcript.created"
        case .socket(let message), .protocol(let message): message
        case .closed: "engine closed"
        }
    }

    public func isDegraded(_ track: AudioTrack) -> Bool {
        tracks[track]?.degraded ?? false
    }

    public mutating func reset() {
        tracks = [:]
    }

    /// `backlogMs` is the audio the engine must replay on a reconnected socket
    /// before it reaches live audio. It is appended to `resumed`.
    public mutating func observe(_ event: EngineEvent, track: AudioTrack, atMs: Int, backlogMs: Int? = nil) -> [Annotation] {
        tracks[track, default: TrackTransport()].lastEventAt = atMs
        tracks[track, default: TrackTransport()].heartbeatEmitted = false
        switch event {
        case .state(let state):
            return observe(state, track: track, atMs: atMs, backlogMs: backlogMs)
        case .gap(let fromMs, let toMs):
            return [Annotation(
                atMs: atMs,
                kind: "gap",
                detail: .gap(fromMs: fromMs, toMs: toMs, track: track.rawValue)
            )]
        case .transcript:
            return []
        case .error(let error):
            return observe(.degraded(reason: Self.describe(error)), track: track, atMs: atMs)
        }
    }

    public mutating func observe(_ state: EngineState, track: AudioTrack, atMs: Int, backlogMs: Int? = nil) -> [Annotation] {
        var entry = tracks[track, default: TrackTransport()]
        defer { tracks[track] = entry }
        entry.lastEventAt = atMs
        switch state {
        case .connecting:
            entry.connectingSince = atMs
            entry.ready = false
            return []
        case .ready, .streaming:
            let resumed = entry.degraded || !entry.degradedReasons.isEmpty
            entry.ready = true
            entry.connectingSince = nil
            entry.handshakeEmitted = false
            entry.degraded = false
            entry.reason = ""
            entry.degradedReasons = []
            entry.heartbeatEmitted = false
            guard resumed else { return [] }
            var text = "transport resumed track=\(track.rawValue)"
            if let backlogMs {
                text += " backlogMs=\(backlogMs)"
            }
            return [Annotation(atMs: atMs, kind: "resumed", detail: .text(text))]
        case .degraded(let why), .failed(let why):
            entry.degraded = true
            entry.reason = why
            guard entry.degradedReasons.insert(why).inserted else { return [] }
            return [Annotation(atMs: atMs, kind: "degraded", detail: .text("\(why) track=\(track.rawValue)"))]
        case .closed:
            return []
        }
    }

    public mutating func tick(atMs: Int, audioFlowingTracks: Set<AudioTrack>) -> [Annotation] {
        var annotations: [Annotation] = []
        for track in AudioTrack.allCases {
            guard var entry = tracks[track] else { continue }
            defer { tracks[track] = entry }
            if !entry.ready, let since = entry.connectingSince, atMs - since >= Self.handshakeLimitMs, !entry.handshakeEmitted {
                entry.handshakeEmitted = true
                entry.degraded = true
                entry.reason = "no transcript.created within \(Self.handshakeLimitMs)ms"
                annotations.append(Annotation(
                    atMs: since + Self.handshakeLimitMs,
                    kind: "degraded",
                    detail: .text("\(entry.reason) track=\(track.rawValue) emittedAtMs=\(atMs)")
                ))
                continue
            }
            if entry.ready, audioFlowingTracks.contains(track), let last = entry.lastEventAt,
               atMs - last >= Self.eventLimitMs, !entry.heartbeatEmitted {
                entry.heartbeatEmitted = true
                entry.degraded = true
                entry.reason = "no engine event for \(Self.eventLimitMs)ms while audio is flowing"
                annotations.append(Annotation(
                    atMs: last + Self.eventLimitMs,
                    kind: "degraded",
                    detail: .text("\(entry.reason) track=\(track.rawValue) emittedAtMs=\(atMs)")
                ))
            }
        }
        return annotations
    }
}
