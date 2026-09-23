import Foundation
import SessionStore

public struct BriefSegment: Sendable, Equatable {
    public var seq: Int
    public var track: String
    public var speaker: String?
    public var startMs: Int
    public var text: String
    public var line: String

    public init(seq: Int, track: String, speaker: String?, startMs: Int, text: String, line: String) {
        self.seq = seq
        self.track = track
        self.speaker = speaker
        self.startMs = startMs
        self.text = text
        self.line = line
    }
}

public struct BriefInput: Sendable, Equatable {
    public var sessionID: String
    public var segments: [BriefSegment]
    public var caveats: [String]
    public var segmentTexts: [Int: String]
    public var wordCount: Int
    public var durationMs: Int
    public var clean: Bool
    public var recovered: Bool
    public var eventsSha256: String

    public var lines: [String] { segments.map(\.line) }
    public var segmentSeqs: Set<Int> { Set(segments.map(\.seq)) }

    public init(
        sessionID: String,
        segments: [BriefSegment],
        caveats: [String],
        segmentTexts: [Int: String],
        wordCount: Int,
        durationMs: Int,
        clean: Bool,
        recovered: Bool,
        eventsSha256: String
    ) {
        self.sessionID = sessionID
        self.segments = segments
        self.caveats = caveats
        self.segmentTexts = segmentTexts
        self.wordCount = wordCount
        self.durationMs = durationMs
        self.clean = clean
        self.recovered = recovered
        self.eventsSha256 = eventsSha256
    }
}

public enum BriefSkip: String, Sendable, Equatable {
    case noSpeech
    case tooShort
}

public enum BriefBuild: Sendable, Equatable {
    case ready(BriefInput)
    case skipped(BriefSkip)
}

public enum BriefRunMode: String, Sendable, Equatable {
    case automatic
    case manual
}

/// When notes run. The app calls this in a later slice; v0 gates do not.
public enum BriefLaunchPolicy {
    /// Harness runs (the v0 gates) leave notes off unless `CATCHER_BRIEF=1`.
    /// Outside the harness, notes are on unless `CATCHER_BRIEF=0`.
    public static func notesEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CATCHER_HARNESS"] == "1" {
            return environment["CATCHER_BRIEF"] == "1"
        }
        return environment["CATCHER_BRIEF"] != "0"
    }

    /// A session recovered at launch gets Make notes. It does not auto-run.
    public static func runMode(recoveredAtLaunch: Bool) -> BriefRunMode {
        recoveredAtLaunch ? .manual : .automatic
    }
}

public enum BriefInputBuilder {
    public static func build(rows: [SessionRow], eventsSHA256: String) -> BriefBuild {
        let header: SessionHeader? = rows.compactMap { row in
            if case .session(let header) = row { return header }
            return nil
        }.first
        let end: EndRow? = rows.compactMap { row in
            if case .end(let end) = row { return end }
            return nil
        }.last
        let segments = rows.compactMap { row -> SegmentRow? in
            if case .seg(let seg) = row, seg.final, !BriefWords.split(seg.text).isEmpty {
                return seg
            }
            return nil
        }.sorted { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            return lhs.track > rhs.track
        }
        if segments.isEmpty {
            return .skipped(.noSpeech)
        }
        let wordCount = segments.reduce(0) { $0 + BriefWords.split($1.text).count }
        if wordCount < BriefContract.minimumWords {
            return .skipped(.tooShort)
        }
        let built = segments.map { segment in
            BriefSegment(
                seq: segment.seq,
                track: segment.track,
                speaker: segment.speaker,
                startMs: segment.startMs,
                text: segment.text,
                line: line(segment)
            )
        }
        var texts: [Int: String] = [:]
        for segment in built {
            texts[segment.seq] = segment.text
        }
        let recovered = end?.recovered == true || rows.contains { row in
            if case .ann(let ann) = row { return ann.kind == "recovered" }
            return false
        }
        let lastMs = segments.map(\.endMs).max() ?? 0
        let durationMs = end?.atMs ?? lastMs
        return .ready(BriefInput(
            sessionID: header?.id ?? "",
            segments: built,
            caveats: caveats(rows: rows, end: end, recovered: recovered),
            segmentTexts: texts,
            wordCount: wordCount,
            durationMs: durationMs,
            clean: end?.clean == true && !recovered,
            recovered: recovered,
            eventsSha256: eventsSHA256
        ))
    }

    static func line(_ segment: SegmentRow) -> String {
        let who = segment.track == "microphone" ? "me" : "them"
        let speaker: String
        if let name = segment.speaker, !name.isEmpty {
            speaker = " \(name)"
        } else {
            speaker = ""
        }
        return "s\(segment.seq) [\(who)\(speaker)] \(BriefClock.label(segment.startMs)) \(segment.text)"
    }

    static func caveats(rows: [SessionRow], end: EndRow?, recovered: Bool) -> [String] {
        var lines: [String] = []
        var gaps: [(fromMs: Int, toMs: Int, track: String)] = []
        var sawNoAudio = false
        var sawBlocked = false
        for row in rows {
            guard case .ann(let ann) = row else { continue }
            switch ann.kind {
            case "gap":
                if case .gap(let fromMs, let toMs, let track) = ann.detail {
                    gaps.append((fromMs, toMs, track))
                }
            case "noAudio":
                sawNoAudio = true
            case "blocked":
                sawBlocked = true
            default:
                break
            }
        }
        for gap in gaps.sorted(by: { $0.fromMs < $1.fromMs }) {
            let from = BriefClock.label(gap.fromMs)
            let to = BriefClock.label(gap.toMs)
            if gap.track.isEmpty {
                lines.append("Transcript gap \(from)\u{2013}\(to).")
            } else {
                lines.append("Transcript gap \(from)\u{2013}\(to) (\(gap.track)).")
            }
        }
        if sawNoAudio {
            lines.append("No audio detected.")
        }
        if sawBlocked {
            lines.append("Recording stopped early: permission revoked.")
        } else if recovered {
            lines.append("Session recovered after a crash. The transcript may be incomplete.")
        } else if end?.clean == false {
            lines.append("Recording stopped early.")
        }
        return lines
    }
}

enum BriefWords {
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

enum BriefClock {
    static func label(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
