import Foundation

/// The eight pipeline checkpoints, in verdict order.
public enum Stage: String, Sendable, CaseIterable, Equatable {
    case tccCheck = "tcc-check"
    case captureStart = "capture-start"
    case framesReceived = "frames-received"
    case pcmExtract = "pcm-extract"
    case apiConnect = "api-connect"
    case apiStream = "api-stream"
    case segmentsReceived = "segments-received"
    case transcriptWrite = "transcript-write"

    public var index: Int {
        Stage.allCases.firstIndex(of: self) ?? 0
    }
}

public enum Verdict: String, Sendable, Equatable {
    case ok = "OK"
    case fail = "FAIL"
}

public enum PreflightVerdict: String, Sendable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
}

public enum LineKind: String, Sendable, Equatable {
    case stage = "STAGE"
    case trace = "TRACE"
    case preflight = "PREFLIGHT"
}

public struct Field: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// One diagnostic line. The file copy has no timestamp prefix.
public struct StageLine: Sendable, Equatable {
    public var kind: LineKind
    /// Stage name, preflight check, or `RESULT`. Nil for `TRACE`.
    public var name: String?
    /// `OK`/`FAIL` or `PASS`/`FAIL`. Nil for `TRACE`.
    public var verdict: String?
    public var fields: [Field]

    public init(kind: LineKind, name: String?, verdict: String?, fields: [Field]) {
        self.kind = kind
        self.name = name
        self.verdict = verdict
        self.fields = fields
    }

    public static func stage(_ stage: Stage, _ verdict: Verdict, _ fields: [Field] = []) -> StageLine {
        StageLine(kind: .stage, name: stage.rawValue, verdict: verdict.rawValue, fields: fields)
    }

    public static func trace(lastOK: String, firstFail: String, error: String) -> StageLine {
        StageLine(kind: .trace, name: nil, verdict: nil, fields: [
            Field("last-ok", lastOK),
            Field("first-fail", firstFail),
            Field("error", error),
        ])
    }

    public static func traceCause(_ cause: String, fix: String) -> StageLine {
        StageLine(kind: .trace, name: nil, verdict: nil, fields: [
            Field("cause", cause),
            Field("fix", fix),
        ])
    }

    public static func preflight(_ check: String, _ verdict: PreflightVerdict, _ fields: [Field] = []) -> StageLine {
        StageLine(kind: .preflight, name: check, verdict: verdict.rawValue, fields: fields)
    }

    public static func preflightResult(_ verdict: PreflightVerdict, failed: Int) -> StageLine {
        StageLine(kind: .preflight, name: "RESULT", verdict: verdict.rawValue, fields: [
            Field("failed", String(failed)),
        ])
    }

    public func field(_ key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    public var stage: Stage? {
        guard kind == .stage, let name else { return nil }
        return Stage(rawValue: name)
    }

    public func formatted() -> String {
        var tokens = [kind.rawValue]
        if let name { tokens.append(name) }
        if let verdict { tokens.append(verdict) }
        return StageFormat.render(prefix: tokens.joined(separator: " "), fields: fields)
    }

    public static func parse(_ line: String) -> StageLine? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = StageFormat.tokenize(trimmed)
        guard let first = tokens.first, let kind = LineKind(rawValue: first) else { return nil }
        if kind == .trace {
            return StageLine(kind: .trace, name: nil, verdict: nil, fields: StageFormat.fields(in: tokens.dropFirst()))
        }
        guard tokens.count >= 3 else { return nil }
        return StageLine(
            kind: kind,
            name: tokens[1],
            verdict: tokens[2],
            fields: StageFormat.fields(in: tokens.dropFirst(3))
        )
    }
}

public enum StageFormat {
    public static let maxBytes = 1024

    public static func render(prefix: String, fields: [Field]) -> String {
        let full = join(prefix: prefix, fields: fields)
        if full.utf8.count <= maxBytes { return full }
        let index = fields.firstIndex { $0.key == "error" }
            ?? fields.firstIndex { $0.key == "body" }
            ?? fields.indices.last
        guard let index else { return hardCap(full) }
        let original = fields[index].value
        var best = hardCap(full)
        var low = 0
        var high = original.utf8.count
        while low <= high {
            let mid = (low + high) / 2
            let kept = prefixUTF8(original, bytes: mid)
            let omitted = original.utf8.count - kept.utf8.count
            var trialFields = fields
            trialFields[index] = Field(fields[index].key, kept + "…(+\(omitted) bytes)")
            let trial = join(prefix: prefix, fields: trialFields)
            if trial.utf8.count <= maxBytes {
                best = trial
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for character in line {
            if escape {
                current.append("\\")
                current.append(character)
                escape = false
                continue
            }
            if character == "\\" {
                escape = true
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                current.append(character)
                continue
            }
            if character == " " && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if escape { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    public static func fields<S: Sequence>(in tokens: S) -> [Field] where S.Element == String {
        tokens.compactMap(parseField)
    }

    public static func parseField(_ token: String) -> Field? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let key = String(token[..<eq])
        guard !key.isEmpty else { return nil }
        var raw = String(token[token.index(after: eq)...])
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            raw = unescape(String(raw.dropFirst().dropLast()))
        }
        return Field(key, raw)
    }

    public static func quote(_ value: String) -> String {
        guard needsQuotes(value) else { return value }
        return "\"\(escape(value))\""
    }

    static func needsQuotes(_ value: String) -> Bool {
        if value.isEmpty { return true }
        for character in value {
            if character == " " || character == "\"" || character == "\\" || character == "\n" || character == "\t" {
                return true
            }
        }
        return false
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            default: out.append(character)
            }
        }
        return out
    }

    static func unescape(_ raw: String) -> String {
        var out = ""
        var escape = false
        for character in raw {
            if escape {
                switch character {
                case "n": out.append("\n")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(character)
                }
                escape = false
                continue
            }
            if character == "\\" {
                escape = true
                continue
            }
            out.append(character)
        }
        if escape { out.append("\\") }
        return out
    }

    static func join(prefix: String, fields: [Field]) -> String {
        var parts = [prefix]
        for field in fields {
            parts.append("\(field.key)=\(quote(field.value))")
        }
        return parts.joined(separator: " ")
    }

    static func prefixUTF8(_ value: String, bytes: Int) -> String {
        if bytes <= 0 { return "" }
        var count = 0
        var end = value.startIndex
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            let size = value[index].utf8.count
            if count + size > bytes { break }
            count += size
            end = next
            index = next
        }
        return String(value[..<end])
    }

    static func hardCap(_ line: String) -> String {
        if line.utf8.count <= maxBytes { return line }
        let marker = "…"
        let room = maxBytes - marker.utf8.count
        return prefixUTF8(line, bytes: max(0, room)) + marker
    }
}
