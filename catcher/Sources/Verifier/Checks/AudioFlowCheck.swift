import AudioCapture

/// Per-track RMS. The session is `noAudio` only when every track that has been
/// seen (or the whole session, if no frames arrived) stays under the epsilon
/// for longer than 10 seconds. A quiet mic during loud system audio is not a failure.
public struct AudioFlowCheck: Sendable {
    public static let silenceLimitMs = 10_000
    public static let rmsEpsilon: Float = 0.001

    public private(set) var noAudio = false
    public private(set) var detail = ""
    public private(set) var allSilent = false
    private var seen: Set<String> = []
    private var quietSince: [String: Int] = [:]
    private var silent: Set<String> = []
    private var recordingStartedMs: Int?
    private var trippedAtMs: Int?

    public init() {}

    public mutating func reset() {
        noAudio = false
        detail = ""
        allSilent = false
        seen = []
        quietSince = [:]
        silent = []
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
            quietSince[key] = nil
            silent.remove(key)
        } else {
            if quietSince[key] == nil {
                quietSince[key] = atMs
            }
            if let since = quietSince[key], atMs - since >= Self.silenceLimitMs {
                silent.insert(key)
            }
        }
        return evaluate(atMs: atMs)
    }

    @discardableResult
    public mutating func tick(atMs: Int) -> Annotation? {
        for (track, since) in quietSince where atMs - since >= Self.silenceLimitMs {
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
