import AudioCapture
import Foundation

/// Deterministic engine for P5 and unit tests. Emits a partial on every frame
/// and a canned final every `framesPerFinal` frames. System-track finals carry
/// speaker `S1`; the mic track does not pretend to diarize "them".
public actor StubEngine: TranscriptionEngine {
    public nonisolated let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private var track: AudioTrack
    private var frames = 0
    private var samples = 0
    private var seq = 0
    private var finals = 0
    private let framesPerFinal: Int
    private var finished = false

    public init(track: AudioTrack, framesPerFinal: Int = 4) {
        self.track = track
        self.framesPerFinal = max(1, framesPerFinal)
        let pair = AsyncStream<EngineEvent>.makeStream()
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func connect(track: AudioTrack) async throws {
        self.track = track
        continuation.yield(.state(.connecting))
        continuation.yield(.state(.ready))
        continuation.yield(.state(.streaming))
    }

    public func send(_ frame: PCMFrame) async throws {
        if finished { return }
        frames += 1
        let frameSamples = max(frame.sampleCount, frame.data.count / AudioFormat.bytesPerSample)
        let startSamples = samples
        samples += frameSamples
        seq += 1
        let partialSeq = seq
        let shouldFinal = frames % framesPerFinal == 0
        if shouldFinal {
            finals += 1
            seq += 1
        }
        let finalSeq = seq
        let finalIndex = finals
        let track = self.track
        let startMs = startSamples * 1000 / AudioFormat.sampleRate
        let endMs = max(startMs, samples * 1000 / AudioFormat.sampleRate)

        continuation.yield(.transcript(TranscriptEvent(
            track: track,
            kind: .partial,
            text: "partial",
            words: [],
            speaker: nil,
            confidence: nil,
            seq: partialSeq,
            startMs: startMs,
            endMs: endMs
        )))
        guard shouldFinal else { return }
        continuation.yield(.transcript(TranscriptEvent(
            track: track,
            kind: .final,
            text: "catcher stub \(finalIndex)",
            words: [TranscriptWord(w: "catcher", startMs: startMs, endMs: endMs, conf: 0.99)],
            speaker: track == .system ? "S1" : nil,
            confidence: 0.99,
            seq: finalSeq,
            startMs: startMs,
            endMs: endMs
        )))
    }

    public func finish() async {
        if finished { return }
        finished = true
        continuation.yield(.state(.closed))
        continuation.finish()
    }
}
