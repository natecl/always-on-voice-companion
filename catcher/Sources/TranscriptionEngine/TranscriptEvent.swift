import AudioCapture
import Foundation

public struct TranscriptWord: Sendable, Equatable, Codable {
    public var w: String
    public var startMs: Int
    public var endMs: Int
    public var conf: Double?

    public init(w: String, startMs: Int, endMs: Int, conf: Double? = nil) {
        self.w = w
        self.startMs = startMs
        self.endMs = endMs
        self.conf = conf
    }
}

public struct TranscriptEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case partial
        case final
    }

    public var track: AudioTrack
    public var kind: Kind
    public var text: String
    public var words: [TranscriptWord]
    public var speaker: String?
    public var confidence: Double?
    public var seq: Int
    public var startMs: Int
    public var endMs: Int

    public init(
        track: AudioTrack,
        kind: Kind,
        text: String,
        words: [TranscriptWord],
        speaker: String? = nil,
        confidence: Double? = nil,
        seq: Int,
        startMs: Int,
        endMs: Int
    ) {
        self.track = track
        self.kind = kind
        self.text = text
        self.words = words
        self.speaker = speaker
        self.confidence = confidence
        self.seq = seq
        self.startMs = startMs
        self.endMs = endMs
    }
}
