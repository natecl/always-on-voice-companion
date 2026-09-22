import AudioCapture

/// One stream per track. Capture and the verifier never name a concrete engine.
public protocol TranscriptionEngine: Sendable {
    nonisolated var events: AsyncStream<EngineEvent> { get }
    func connect(track: AudioTrack) async throws
    func send(_ frame: PCMFrame) async throws
    func finish() async
}
