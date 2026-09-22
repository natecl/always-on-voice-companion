import Foundation

public struct SessionHeader: Sendable, Equatable {
    public var id: String
    public var startedAt: String
    public var engine: String
    public var tracks: [String]
    public var app: String

    public init(id: String, startedAt: String, engine: String, tracks: [String], app: String) {
        self.id = id
        self.startedAt = startedAt
        self.engine = engine
        self.tracks = tracks
        self.app = app
    }
}

public struct WordStamp: Sendable, Equatable {
    public var w: String
    public var s: Int
    public var e: Int
    public var c: Double?

    public init(w: String, s: Int, e: Int, c: Double? = nil) {
        self.w = w
        self.s = s
        self.e = e
        self.c = c
    }
}

public struct SegmentRow: Sendable, Equatable {
    public var seq: Int
    public var track: String
    public var startMs: Int
    public var endMs: Int
    public var final: Bool
    public var text: String
    public var speaker: String?
    public var conf: Double?
    public var words: [WordStamp]

    public init(
        seq: Int,
        track: String,
        startMs: Int,
        endMs: Int,
        final: Bool,
        text: String,
        speaker: String? = nil,
        conf: Double? = nil,
        words: [WordStamp]
    ) {
        self.seq = seq
        self.track = track
        self.startMs = startMs
        self.endMs = endMs
        self.final = final
        self.text = text
        self.speaker = speaker
        self.conf = conf
        self.words = words
    }
}

public enum AnnotationDetail: Sendable, Equatable {
    case text(String)
    case gap(fromMs: Int, toMs: Int, track: String)
}

public struct AnnotationRow: Sendable, Equatable {
    public var atMs: Int
    public var kind: String
    public var detail: AnnotationDetail?

    public init(atMs: Int, kind: String, detail: AnnotationDetail? = nil) {
        self.atMs = atMs
        self.kind = kind
        self.detail = detail
    }
}

public struct EndRow: Sendable, Equatable {
    public var atMs: Int
    public var clean: Bool
    public var recovered: Bool?

    public init(atMs: Int, clean: Bool, recovered: Bool? = nil) {
        self.atMs = atMs
        self.clean = clean
        self.recovered = recovered
    }
}

public enum SessionRow: Sendable, Equatable {
    case session(SessionHeader)
    case seg(SegmentRow)
    case ann(AnnotationRow)
    case end(EndRow)
}

public enum StoreError: Error, Equatable {
    case createFailed(String)
    case writeFailed(String)
    case corrupt(line: Int)
}

extension SessionRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, id, startedAt, engine, tracks, app
        case seq, track, startMs, endMs, final, text, speaker, conf, words
        case atMs, kind, detail, clean, recovered
        case w, s, e, c
        case fromMs, toMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "session":
            self = .session(SessionHeader(
                id: try container.decode(String.self, forKey: .id),
                startedAt: try container.decode(String.self, forKey: .startedAt),
                engine: try container.decode(String.self, forKey: .engine),
                tracks: try container.decode([String].self, forKey: .tracks),
                app: try container.decode(String.self, forKey: .app)
            ))
        case "seg":
            self = .seg(SegmentRow(
                seq: try container.decode(Int.self, forKey: .seq),
                track: try container.decode(String.self, forKey: .track),
                startMs: try container.decode(Int.self, forKey: .startMs),
                endMs: try container.decode(Int.self, forKey: .endMs),
                final: try container.decode(Bool.self, forKey: .final),
                text: try container.decode(String.self, forKey: .text),
                speaker: try container.decodeIfPresent(String.self, forKey: .speaker),
                conf: try container.decodeIfPresent(Double.self, forKey: .conf),
                words: try container.decodeIfPresent([WordStamp].self, forKey: .words) ?? []
            ))
        case "ann":
            self = .ann(AnnotationRow(
                atMs: try container.decode(Int.self, forKey: .atMs),
                kind: try container.decode(String.self, forKey: .kind),
                detail: try Self.decodeDetail(container)
            ))
        case "end":
            self = .end(EndRow(
                atMs: try container.decode(Int.self, forKey: .atMs),
                clean: try container.decode(Bool.self, forKey: .clean),
                recovered: try container.decodeIfPresent(Bool.self, forKey: .recovered)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t,
                in: container,
                debugDescription: "unknown row type \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let header):
            try container.encode("session", forKey: .t)
            try container.encode(header.id, forKey: .id)
            try container.encode(header.startedAt, forKey: .startedAt)
            try container.encode(header.engine, forKey: .engine)
            try container.encode(header.tracks, forKey: .tracks)
            try container.encode(header.app, forKey: .app)
        case .seg(let seg):
            try container.encode("seg", forKey: .t)
            try container.encode(seg.seq, forKey: .seq)
            try container.encode(seg.track, forKey: .track)
            try container.encode(seg.startMs, forKey: .startMs)
            try container.encode(seg.endMs, forKey: .endMs)
            try container.encode(seg.final, forKey: .final)
            try container.encode(seg.text, forKey: .text)
            try container.encodeIfPresent(seg.speaker, forKey: .speaker)
            try container.encodeIfPresent(seg.conf, forKey: .conf)
            try container.encode(seg.words, forKey: .words)
        case .ann(let ann):
            try container.encode("ann", forKey: .t)
            try container.encode(ann.atMs, forKey: .atMs)
            try container.encode(ann.kind, forKey: .kind)
            if let detail = ann.detail {
                try Self.encode(detail, into: &container)
            }
        case .end(let end):
            try container.encode("end", forKey: .t)
            try container.encode(end.atMs, forKey: .atMs)
            try container.encode(end.clean, forKey: .clean)
            if end.recovered == true {
                try container.encode(true, forKey: .recovered)
            }
        }
    }

    private static func decodeDetail(_ container: KeyedDecodingContainer<CodingKeys>) throws -> AnnotationDetail? {
        if container.contains(.detail) {
            if let text = try? container.decode(String.self, forKey: .detail) {
                return .text(text)
            }
            if let gap = try? container.decode(GapDetail.self, forKey: .detail) {
                return .gap(fromMs: gap.fromMs, toMs: gap.toMs, track: gap.track)
            }
            if try container.decodeNil(forKey: .detail) {
                return nil
            }
            throw DecodingError.dataCorruptedError(forKey: .detail, in: container, debugDescription: "bad detail")
        }
        return nil
    }

    private static func encode(_ detail: AnnotationDetail, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch detail {
        case .text(let text):
            try container.encode(text, forKey: .detail)
        case .gap(let fromMs, let toMs, let track):
            try container.encode(GapDetail(fromMs: fromMs, toMs: toMs, track: track), forKey: .detail)
        }
    }
}

extension WordStamp: Codable {
    private enum CodingKeys: String, CodingKey { case w, s, e, c }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        w = try container.decode(String.self, forKey: .w)
        s = try container.decode(Int.self, forKey: .s)
        e = try container.decode(Int.self, forKey: .e)
        c = try container.decodeIfPresent(Double.self, forKey: .c)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(w, forKey: .w)
        try container.encode(s, forKey: .s)
        try container.encode(e, forKey: .e)
        try container.encodeIfPresent(c, forKey: .c)
    }
}

private struct GapDetail: Codable {
    var fromMs: Int
    var toMs: Int
    var track: String
}
