/// Finals only. Partials never count. Flags when audio is flowing, the grace
/// period has passed, and stored final words are under 8 per minute.
public struct TranscriptSanityCheck: Sendable {
    public static let graceMs = 20_000
    public static let minimumWordsPerMinute = 8.0

    public private(set) var flagged = false
    public private(set) var detail = ""
    private var finalWords = 0
    private var audioFlowing = false
    private var emitted = false

    public init() {}

    public mutating func reset() {
        flagged = false
        detail = ""
        finalWords = 0
        audioFlowing = false
        emitted = false
    }

    public mutating func setAudioFlowing(_ flowing: Bool) {
        audioFlowing = flowing
    }

    public mutating func observeFinal(text: String) {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        finalWords += words
        if flagged {
            evaluate(atMs: Self.graceMs)
        }
    }

    public mutating func tick(atMs: Int) -> Annotation? {
        evaluate(atMs: atMs)
        guard flagged, !emitted else { return nil }
        emitted = true
        return Annotation(atMs: atMs, kind: "degraded", detail: .text(detail))
    }

    private mutating func evaluate(atMs: Int) {
        guard audioFlowing, atMs >= Self.graceMs else {
            flagged = false
            if !audioFlowing { emitted = false }
            return
        }
        let minutes = Double(atMs) / 60_000
        let floor = Self.minimumWordsPerMinute * minutes
        if Double(finalWords) + 0.000_1 < floor {
            flagged = true
            detail = "final words \(finalWords) below \(Int(floor.rounded(.up))) word floor over \(atMs)ms"
        } else {
            flagged = false
            detail = ""
            emitted = false
        }
    }
}
