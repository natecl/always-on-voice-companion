import AudioCapture
import Foundation
import TranscriptionEngine

/// One engine stream per track. Events are stamped with that track so a buggy
/// engine cannot drop it on the way to the store.
public final class TrackRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [AudioTrack: any TranscriptionEngine]
    private let make: @Sendable (AudioTrack) -> any TranscriptionEngine

    public init(make: @escaping @Sendable (AudioTrack) -> any TranscriptionEngine) {
        self.engines = [:]
        self.make = make
    }

    public init(engines: [AudioTrack: any TranscriptionEngine]) {
        self.engines = engines
        self.make = { track in
            preconditionFailure("no engine for \(track.rawValue)")
        }
    }

    public func engine(for track: AudioTrack) -> any TranscriptionEngine {
        lock.lock()
        defer { lock.unlock() }
        if let existing = engines[track] {
            return existing
        }
        let created = make(track)
        engines[track] = created
        return created
    }

    public static func stamp(_ event: EngineEvent, track: AudioTrack) -> EngineEvent {
        switch event {
        case .transcript(var transcript):
            transcript.track = track
            return .transcript(transcript)
        default:
            return event
        }
    }
}
