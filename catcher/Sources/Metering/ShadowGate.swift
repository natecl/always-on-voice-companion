import Foundation

/// What a client speech gate would have sent. It only accumulates milliseconds.
/// It cannot drop, delay, or rewrite a frame.
///
/// RMS is AC (the frame mean removed). A resting mic often carries DC; raw RMS
/// would count that as speech and inflate the shadow cost. The floor matches
/// `metering.json` and is a starting value, not a tuned one.
public struct ShadowGate: Sendable {
    public struct Config: Sendable, Equatable {
        public var rmsFloor: Float
        public var holdMs: Int
        public var preRollMs: Int
        public var hangoverMs: Int

        public init(rmsFloor: Float, holdMs: Int, preRollMs: Int, hangoverMs: Int) {
            self.rmsFloor = rmsFloor
            self.holdMs = holdMs
            self.preRollMs = preRollMs
            self.hangoverMs = hangoverMs
        }

        public static let bundled = Config(
            rmsFloor: MeteringConstants.shadowRmsFloor,
            holdMs: MeteringConstants.shadowHoldMs,
            preRollMs: MeteringConstants.shadowPreRollMs,
            hangoverMs: MeteringConstants.shadowHangoverMs
        )
    }

    private struct Track: Sendable {
        var loudSince: Int?
        var opened = false
        var lastLoudEnd = 0
        var lastFrameEnd: Int?
        var recent: [Range<Int>] = []
        var intervals: [Range<Int>] = []

        mutating func add(_ range: Range<Int>) {
            guard range.lowerBound < range.upperBound else { return }
            var merged: [Range<Int>] = []
            var pending = range
            var placed = false
            for existing in intervals {
                if existing.upperBound < pending.lowerBound {
                    merged.append(existing)
                } else if pending.upperBound < existing.lowerBound {
                    if !placed {
                        merged.append(pending)
                        placed = true
                    }
                    merged.append(existing)
                } else {
                    pending = min(pending.lowerBound, existing.lowerBound)..<max(pending.upperBound, existing.upperBound)
                }
            }
            if !placed { merged.append(pending) }
            intervals = merged
        }

        mutating func remember(_ range: Range<Int>, horizonMs: Int) {
            recent.append(range)
            let keepAfter = range.upperBound - horizonMs
            recent.removeAll { $0.upperBound <= keepAfter }
        }
    }

    private var tracks: [String: Track] = [:]
    public var config: Config

    public init(config: Config = .bundled) {
        self.config = config
    }

    public mutating func observe(track: String, pcm16: Data, atMs: Int) {
        let duration = pcm16.count / MeteringConstants.bytesPerMillisecond
        guard duration > 0 else { return }
        let frameStart = max(0, atMs)
        let frameEnd = frameStart + duration
        var state = tracks[track] ?? Track()
        let loud = Self.acRMS(pcm16) >= config.rmsFloor
        if loud {
            let gap = state.lastFrameEnd.map { frameStart > $0 } ?? false
            if !state.opened, state.loudSince == nil || gap {
                state.loudSince = frameStart
            }
            let onset = state.loudSince ?? frameStart
            if state.opened {
                state.add(frameStart..<frameEnd)
            } else if frameEnd - onset >= config.holdMs {
                let preFrom = onset - config.preRollMs
                for range in state.recent {
                    let lo = max(range.lowerBound, preFrom)
                    let hi = min(range.upperBound, onset)
                    if lo < hi { state.add(lo..<hi) }
                }
                state.add(onset..<frameEnd)
                state.opened = true
            }
            state.lastLoudEnd = frameEnd
        } else {
            state.loudSince = nil
            if state.opened {
                let hangoverEnd = state.lastLoudEnd + config.hangoverMs
                if frameStart >= hangoverEnd {
                    state.opened = false
                } else {
                    let end = min(frameEnd, hangoverEnd)
                    if frameStart < end { state.add(frameStart..<end) }
                    if frameEnd >= hangoverEnd { state.opened = false }
                }
            }
        }
        state.remember(frameStart..<frameEnd, horizonMs: config.preRollMs + config.holdMs)
        state.lastFrameEnd = frameEnd
        tracks[track] = state
    }

    public func openMs(track: String, fromMs: Int, toMs: Int) -> Int {
        Self.covered(tracks[track]?.intervals ?? [], clip: fromMs..<toMs)
    }

    /// Milliseconds both capture tracks would have been open. Echo shows up here:
    /// the mic gate stays open because it hears the system track.
    public func bothOpenMs(fromMs: Int, toMs: Int) -> Int {
        Self.overlap(
            tracks["system"]?.intervals ?? [],
            tracks["microphone"]?.intervals ?? [],
            clip: fromMs..<toMs
        )
    }

    /// Root-mean-square with the frame mean removed, full scale = 1.
    public static func acRMS(_ pcm16le: Data) -> Float {
        let count = pcm16le.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var sumSquares: Float = 0
        pcm16le.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples.prefix(count) {
                let unit = Float(sample) / 32768
                sum += unit
                sumSquares += unit * unit
            }
        }
        let mean = sum / Float(count)
        let variance = sumSquares / Float(count) - mean * mean
        return max(0, variance).squareRoot()
    }

    private static func covered(_ intervals: [Range<Int>], clip: Range<Int>) -> Int {
        var total = 0
        for range in intervals {
            let lo = max(range.lowerBound, clip.lowerBound)
            let hi = min(range.upperBound, clip.upperBound)
            if lo < hi { total += hi - lo }
        }
        return total
    }

    private static func overlap(_ left: [Range<Int>], _ right: [Range<Int>], clip: Range<Int>) -> Int {
        var total = 0
        var index = 0
        for range in left {
            while index < right.count, right[index].upperBound <= range.lowerBound {
                index += 1
            }
            var cursor = index
            while cursor < right.count, right[cursor].lowerBound < range.upperBound {
                let lo = max(max(range.lowerBound, right[cursor].lowerBound), clip.lowerBound)
                let hi = min(min(range.upperBound, right[cursor].upperBound), clip.upperBound)
                if lo < hi { total += hi - lo }
                cursor += 1
            }
        }
        return total
    }
}
