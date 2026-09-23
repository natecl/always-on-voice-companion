import AudioCapture

/// Per-track RMS. The session is `noAudio` only when every track that has been
/// seen (or the whole session, if no frames arrived) stays under the floor
/// for longer than 10 seconds. A quiet mic during loud system audio is not a failure.
///
/// Muted output is digital zero on the system track. A live mic at rest is not:
/// DC and room tone sit above 0.001, and one noisy buffer used to restart the
/// silence clock so `noAudio` landed after the 10s gate (or not at all). The
/// floor treats that rest energy as silence. Only energy that holds counts as
/// audio and moves the clock.
public struct AudioFlowCheck: Sendable {
    public static let silenceLimitMs = 10_000
    /// About -26 dBFS. Full scale is 1. Resting-mic energy sits under this; the
    /// loud frames in the verifier tests sit near 0.24.
    public static let rmsEpsilon: Float = 0.05
    /// One loud buffer must not push `noAudio` past the harness window.
    public static let speechHoldMs = 300

    public private(set) var noAudio = false
    public private(set) var detail = ""
    public private(set) var allSilent = false
    /// Latest frame on some track is above the floor. Distinct from `allSilent`,
    /// which stays false for the whole 10s silence window.
    public private(set) var audioFlowing = false
    private var seen: Set<String> = []
    private var quietSince: [String: Int] = [:]
    private var silent: Set<String> = []
    private var everLoud: Set<String> = []
    private var above: Set<String> = []
    private var pendingLoudSince: [String: Int] = [:]
    private var recordingStartedMs: Int?
    private var trippedAtMs: Int?

    public init() {}

    public mutating func reset() {
        noAudio = false
        detail = ""
        allSilent = false
        audioFlowing = false
        seen = []
        quietSince = [:]
        silent = []
        everLoud = []
        above = []
        pendingLoudSince = [:]
        recordingStartedMs = nil
        trippedAtMs = nil
    }

    public mutating func begin(atMs: Int) {
        reset()
        recordingStartedMs = atMs
    }

    @discardableResult
    public mutating func observe(track: AudioTrack, rms: Float, atMs: Int) -> Annotation? {
        let key = track.rawValue
        seen.insert(key)
        if rms > Self.rmsEpsilon {
            above.insert(key)
            silent.remove(key)
            if pendingLoudSince[key] == nil {
                pendingLoudSince[key] = atMs
            }
            if let started = pendingLoudSince[key], atMs - started >= Self.speechHoldMs {
                everLoud.insert(key)
                quietSince[key] = nil
            }
        } else {
            pendingLoudSince[key] = nil
            above.remove(key)
            if quietSince[key] == nil {
                // Never-sustained audio is quiet from the session start. Dating
                // silence from the first frame, or from a one-buffer spike,
                // pushes noAudio past the 10s gate.
                quietSince[key] = everLoud.contains(key) ? atMs : (recordingStartedMs ?? atMs)
            }
            if let since = quietSince[key], atMs - since >= Self.silenceLimitMs {
                silent.insert(key)
            }
        }
        audioFlowing = !above.isEmpty
        return evaluate(atMs: atMs)
    }

    @discardableResult
    public mutating func tick(atMs: Int) -> Annotation? {
        for (track, since) in quietSince where !above.contains(track) && atMs - since >= Self.silenceLimitMs {
            silent.insert(track)
        }
        return evaluate(atMs: atMs)
    }

    private mutating func evaluate(atMs: Int) -> Annotation? {
        let tracksSilent = !seen.isEmpty && silent == seen
        let noFrames: Bool
        if seen.isEmpty, let start = recordingStartedMs, atMs - start >= Self.silenceLimitMs {
            noFrames = true
        } else {
            noFrames = false
        }
        allSilent = tracksSilent || noFrames
        guard allSilent else {
            noAudio = false
            detail = ""
            trippedAtMs = nil
            return nil
        }
        let when: Int
        if noFrames, let start = recordingStartedMs {
            when = start + Self.silenceLimitMs
            detail = "no frames for >10s"
        } else {
            when = silent.compactMap { key -> Int? in
                guard let since = quietSince[key] else { return nil }
                return since + Self.silenceLimitMs
            }.max() ?? atMs
            detail = "RMS≈0 for >10s on " + silent.sorted().joined(separator: ",")
        }
        noAudio = true
        guard trippedAtMs == nil else { return nil }
        trippedAtMs = when
        return Annotation(atMs: when, kind: "noAudio", detail: .text(detail))
    }
}
