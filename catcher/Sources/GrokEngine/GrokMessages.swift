import Diagnostics
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
        let raw: RawMessage
        do {
            raw = try decoder.decode(RawMessage.self, from: data)
        } catch {
            noteDecode(error)
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
            return .error(errorText(raw))
        default:
            return .unknown(text)
        }
    }

    private static let decodeLogLock = NSLock()
    nonisolated(unsafe) private static var decodeLogs = 0

    private static func noteDecode(_ error: Error) {
        decodeLogLock.lock()
        let shouldLog = decodeLogs < 3
        if shouldLog { decodeLogs += 1 }
        decodeLogLock.unlock()
        if shouldLog {
            StageMirror.note("grok decode \(ErrorDetail.sentence(error))")
        }
    }

    private static func errorText(_ raw: RawMessage) -> String {
        var parts: [String] = []
        if let message = raw.message, !message.isEmpty { parts.append(message) }
        if let error = raw.error, !error.isEmpty, error != raw.message { parts.append(error) }
        if let code = raw.code?.value, !code.isEmpty { parts.append("code=\(code)") }
        return parts.isEmpty ? "unknown error" : parts.joined(separator: " ")
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
    var error: String?
    var code: LooseString?

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

private struct LooseString: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
            return
        }
        if let number = try? container.decode(Int.self) {
            value = String(number)
            return
        }
        value = ""
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
