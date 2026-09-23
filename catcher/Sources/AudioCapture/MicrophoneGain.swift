import Foundation

/// Automatic gain for the microphone track. It runs on the 16 kHz mono PCM16
/// frame before the verifier, `microphone.pcm`, and the engine see it, so all
/// three hear the same level.
///
/// Normal speech at arm's length from a laptop mic lands near -35 dBFS AC RMS,
/// under the verifier's 0.05 (-26 dBFS) `noAudio` floor. This scales the real
/// signal so sustained speech sits near `targetRMS`. It never adds energy that
/// is not in the input: gain only multiplies samples.
///
/// Gain moves only on held speech: 10-20 ms blocks at least `speechOverNoise`
/// above the rolling 2 s noise minimum and above `minimumSpeechRMS`, for
/// `speechHoldMs`. Steady room tone, fans, and single clicks keep gain at
/// exactly 1, so a quiet room (P4) is passed through byte for byte. After
/// `idleMs` without speech, gain falls back to 1 at `fallDbPerSecond`.
public struct MicrophoneGain: Sendable {
    /// About -14 dBFS: a voice-chat speech level.
    public static let targetRMS: Float = 0.2
    /// +24 dB.
    public static let maxGain: Float = 16
    /// About -1 dBFS. The per-block peak after gain stays under this.
    public static let peakCeiling: Float = 0.89
    /// About -48 dBFS. Quieter blocks are never speech.
    public static let minimumSpeechRMS: Float = 0.004
    /// 10 dB.
    public static let speechOverNoise: Float = 3.162
    public static let speechHoldMs = 300
    public static let speechDipMs = 120
    public static let idleMs = 4_000
    public static let noiseWindowMs = 2_000
    public static let levelTimeConstantMs = 1_000
    public static let riseDbPerSecond: Float = 12
    public static let fallDbPerSecond: Float = 6

    static let blockSamples = AudioFormat.sampleRate / 100

    public private(set) var gain: Float = 1
    /// Highest gain applied this session. Stage diagnostics report it.
    public private(set) var peakGain: Float = 1

    private var noise: [Float] = []
    private var noiseIndex = 0
    private var logLevel: Float?
    private var activeSamples = 0
    private var dipSamples = 0
    private var idleSamples = 0

    public init() {}

    public mutating func process(_ pcm16le: Data) -> Data {
        let count = pcm16le.count / AudioFormat.bytesPerSample
        guard count > 0 else { return pcm16le }
        var input = [Int16](repeating: 0, count: count)
        _ = input.withUnsafeMutableBytes { pcm16le.copyBytes(to: $0) }
        var output = input
        var unity = true
        var start = 0
        while start < count {
            var end = min(start + Self.blockSamples, count)
            // A 21-sample tail has almost no AC energy after mean removal and
            // would drag both the noise floor and the speech level down.
            if count - end < Self.blockSamples {
                end = count
            }
            let before = gain
            let after = step(input[start..<end])
            if before != 1 || after != 1 {
                unity = false
                apply(input, into: &output, range: start..<end, from: before, to: after)
            }
            start = end
        }
        if unity { return pcm16le }
        return output.withUnsafeBytes { Data($0) }
    }

    /// Advances the detector over one block and returns the gain at its end.
    private mutating func step(_ block: ArraySlice<Int16>) -> Float {
        let samples = block.count
        var sum: Float = 0
        var squares: Float = 0
        var peak: Float = 0
        for sample in block {
            let unit = Float(sample) / 32768
            sum += unit
            squares += unit * unit
            peak = max(peak, abs(unit))
        }
        let mean = sum / Float(samples)
        let rms = max(0, squares / Float(samples) - mean * mean).squareRoot()

        let slots = Self.noiseWindowMs * Self.blockSamples / 10
        if noise.count < slots {
            noise.append(rms)
        } else {
            noise[noiseIndex] = rms
            noiseIndex = (noiseIndex + 1) % slots
        }
        let floor = noise.min() ?? rms

        let active = rms > max(Self.minimumSpeechRMS, floor * Self.speechOverNoise)
        if active {
            activeSamples += samples
            dipSamples = 0
        } else {
            dipSamples += samples
            if dipSamples >= Self.samples(ms: Self.speechDipMs) {
                activeSamples = 0
            }
        }

        let seconds = Float(samples) / Float(AudioFormat.sampleRate)
        if active && activeSamples >= Self.samples(ms: Self.speechHoldMs) {
            idleSamples = 0
            let value = log(rms)
            if let current = logLevel {
                let weight = min(1, Float(samples) / Float(Self.samples(ms: Self.levelTimeConstantMs)))
                logLevel = current + (value - current) * weight
            } else {
                logLevel = value
            }
        } else {
            idleSamples += samples
            if let current = logLevel, idleSamples > Self.samples(ms: Self.idleMs) {
                let raised = current + Self.fallDbPerSecond * seconds * log(10) / 20
                logLevel = raised >= log(Self.targetRMS) ? nil : raised
            }
        }

        var want: Float = 1
        if let logLevel {
            want = min(Self.maxGain, max(1, Self.targetRMS / exp(logLevel)))
        }
        if peak > 0 {
            want = min(want, max(1, Self.peakCeiling / peak))
        }
        if want > gain {
            gain = min(want, gain * pow(10, Self.riseDbPerSecond * seconds / 20))
        } else {
            gain = want
        }
        peakGain = max(peakGain, gain)
        return gain
    }

    /// Ramps up across the block; a drop (limiter or release) lands at the block start.
    private func apply(_ input: [Int16], into output: inout [Int16], range: Range<Int>, from: Float, to: Float) {
        let length = Float(range.count)
        let rising = to > from
        for (offset, index) in range.enumerated() {
            let factor = rising ? from + (to - from) * Float(offset) / length : to
            let scaled = (Float(input[index]) * factor).rounded()
            output[index] = Int16(max(-32_768, min(32_767, scaled)))
        }
    }

    private static func samples(ms: Int) -> Int {
        ms * AudioFormat.sampleRate / 1000
    }
}
