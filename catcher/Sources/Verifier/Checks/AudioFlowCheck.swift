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
///
/// Numbers are mirrored in `catcher/harness/thresholds.json`; a test fails if
/// they drift.
public struct AudioFlowCheck: Sendable {
    public static let silenceLimitMs = 10_000
    /// About -26 dBFS. Full scale is 1. Resting-mic energy sits under this; the
    /// loud frames in the verifier tests sit near 0.24.
    public static let rmsEpsilon: Float = 0.05
    /// One loud buffer must not push `noAudio` past the harness window.
    public static let speechHoldMs = 300
    /// Syllable gaps inside speech. Sub-floor frames shorter than this do not
    /// restart the hold, so syllabic speech still counts as sustained.
    public static let speechDipMs = 120

    public private(set) var noAudio = false
    public private(set) var detail = ""
    public private(set) var allSilent = false
    /// Tracks that have held audio above the floor and are not currently quiet.
    public private(set) var sustainedTracks: Set<AudioTrack> = []
    public var audioFlowing: Bool { !sustainedTracks.isEmpty }
    private var seen: Set<String> = []
    private var quietSince: [String: Int] = [:]
    private var silent: Set<String> = []
    private var everLoud: Set<String> = []
    private var above: Set<String> = []
    private var pendingLoudSince: [String: Int] = [:]
    private var dipSince: [String: Int] = [:]
    private var recordingStartedMs: Int?
    private var trippedAtMs: Int?

    public init() {}

    public mutating func reset() {
        noAudio = false
        detail = ""
        allSilent = false
        sustainedTracks = []
        seen = []
        quietSince = [:]
        silent = []
        everLoud = []
        above = []
        pendingLoudSince = [:]
        dipSince = [:]
        recordingStartedMs = nil
        trippedAtMs = nil
    }

    public mutating func begin(atMs: Int) {
        reset()
        recordingStartedMs = atMs
    }

    /// Capture is delivering (or about to deliver) frames. The never-loud and
    /// no-frames silence clocks start here, not at session open: the launch
    /// probe and engine setup run in between and nothing is observed then.
    public mutating func captureStarted(atMs: Int) {
        begin(atMs: atMs)
    }

    @discardableResult
    public mutating func observe(track: AudioTrack, rms: Float, atMs: Int) -> Annotation? {
        let key = track.rawValue
        seen.insert(key)
        if rms > Self.rmsEpsilon {
            above.insert(key)
            silent.remove(key)
            dipSince[key] = nil
            let started = pendingLoudSince[key] ?? atMs
            pendingLoudSince[key] = started
            if atMs - started >= Self.speechHoldMs {
                everLoud.insert(key)
                quietSince[key] = nil
            }
        } else {
            above.remove(key)
            if dipSince[key] == nil {
                dipSince[key] = atMs
            }
            settle(key, atMs: atMs)
        }
        refreshFlow()
        return evaluate(atMs: atMs)
    }

    @discardableResult
    public mutating func tick(atMs: Int) -> Annotation? {
        for key in seen {
            settle(key, atMs: atMs)
        }
        refreshFlow()
        return evaluate(atMs: atMs)
    }

    /// A sub-floor run shorter than `speechDipMs` inside a pending burst is a
    /// syllable gap. Longer, the burst is over and the track is quiet: from
    /// the dip for a track that held speech, from capture start for one that
    /// never did (a one-buffer spike must not move the clock).
    private mutating func settle(_ key: String, atMs: Int) {
        guard !above.contains(key), let dipStart = dipSince[key] else { return }
        if pendingLoudSince[key] != nil {
            guard atMs - dipStart >= Self.speechDipMs else { return }
            pendingLoudSince[key] = nil
        }
        if quietSince[key] == nil {
            quietSince[key] = everLoud.contains(key) ? dipStart : (recordingStartedMs ?? dipStart)
        }
        if let since = quietSince[key], atMs - since >= Self.silenceLimitMs {
            silent.insert(key)
        }
    }

    private mutating func refreshFlow() {
        sustainedTracks = Set(AudioTrack.allCases.filter { track in
            everLoud.contains(track.rawValue) && quietSince[track.rawValue] == nil
        })
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
        // `atMs` is the silence boundary. The grader needs the time the
        // detector actually fired and where observation began to prove it.
        let stamped = "\(detail) emittedAtMs=\(atMs) observedFromMs=\(recordingStartedMs ?? 0)"
        return Annotation(atMs: when, kind: "noAudio", detail: .text(stamped))
    }
}
