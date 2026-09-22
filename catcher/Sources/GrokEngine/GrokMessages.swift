import Foundation

public struct GrokTranscript: Sendable, Equatable {
    public var text: String
    public var words: [GrokWord]
    public var isFinal: Bool
    public var speechFinal: Bool
    public var start: Double
    public var duration: Double

    public init(
        text: String,
        words: [GrokWord],
        isFinal: Bool,
        speechFinal: Bool,
        start: Double,
        duration: Double
    ) {
        self.text = text
        self.words = words
        self.isFinal = isFinal
        self.speechFinal = speechFinal
        self.start = start
        self.duration = duration
    }
}

public struct GrokWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: Int?
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, speaker: Int? = nil, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.confidence = confidence
    }
}

public enum GrokServerMessage: Sendable, Equatable {
    case created
    case partial(GrokTranscript)
    case done(GrokTranscript)
    case error(String)
    case unknown(String)
}

public enum GrokMessages {
    public static let audioDone = #"{"type":"audio.done"}"#

    public static func decode(_ text: String) -> GrokServerMessage {
        guard let data = text.data(using: .utf8) else {
            return .unknown(text)
        }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(RawMessage.self, from: data) else {
            return .unknown(text)
        }
        switch raw.type {
        case "transcript.created":
            return .created
        case "transcript.partial":
            return .partial(raw.transcript(isFinalDefault: false))
        case "transcript.done":
            return .done(raw.transcript(isFinalDefault: true))
        case "error":
            return .error(raw.message ?? "unknown error")
        default:
            return .unknown(raw.type)
        }
    }
}

private struct RawMessage: Decodable {
    var type: String
    var text: String?
    var words: [RawWord]?
    var is_final: Bool?
    var speech_final: Bool?
    var start: Double?
    var duration: Double?
    var message: String?

    func transcript(isFinalDefault: Bool) -> GrokTranscript {
        GrokTranscript(
            text: text ?? "",
            words: (words ?? []).map { $0.parsed },
            isFinal: is_final ?? isFinalDefault,
            speechFinal: speech_final ?? false,
            start: start ?? 0,
            duration: duration ?? 0
        )
    }
}

private struct RawWord: Decodable {
    var text: String?
    var word: String?
    var start: Double?
    var end: Double?
    var speaker: Int?
    var confidence: Double?
    var conf: Double?

    var parsed: GrokWord {
        GrokWord(
            text: text ?? self.word ?? "",
            start: start ?? 0,
            end: end ?? start ?? 0,
            speaker: speaker,
            confidence: confidence ?? conf
        )
    }
}
