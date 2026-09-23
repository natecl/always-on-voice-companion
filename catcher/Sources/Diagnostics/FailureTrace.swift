import Foundation

public struct FailureTraceReport: Sendable, Equatable {
    public var lastOK: String
    public var firstFail: String
    public var error: String
    public var cause: String
    public var fix: String
    public var lines: [StageLine]

    public init(lastOK: String, firstFail: String, error: String, cause: String, fix: String, lines: [StageLine]) {
        self.lastOK = lastOK
        self.firstFail = firstFail
        self.error = error
        self.cause = cause
        self.fix = fix
        self.lines = lines
    }
}

public enum FailureTrace {
    /// Last line for a stage (and per `track=` for api-connect) is its verdict.
    /// The trace's first FAIL is the earliest of those verdicts in file order.
    /// A stage that was never written is `not-reached` when nothing failed.
    public static func report(lines: [StageLine], fallbackError: String? = nil) -> FailureTraceReport {
        let verdicts = verdictLines(lines)
        let firstFailIndex = verdicts.firstIndex { $0.verdict == Verdict.fail.rawValue }
        let lastOK: String
        let firstFail: String
        let failing: StageLine?
        if let firstFailIndex {
            failing = verdicts[firstFailIndex]
            firstFail = failing?.name ?? "not-reached"
            lastOK = verdicts[..<firstFailIndex].last { $0.verdict == Verdict.ok.rawValue }?.name ?? "none"
        } else {
            failing = nil
            firstFail = "not-reached"
            lastOK = verdicts.last { $0.verdict == Verdict.ok.rawValue }?.name ?? "none"
        }
        let error = underlying(failing: failing, lines: lines, fallback: fallbackError)
        let matched = failing.flatMap { CauseTable.match(failing: $0, lines: lines) }
        let cause = matched?.cause ?? ""
        let fix = matched?.fix ?? ""
        let trace = [
            StageLine.trace(lastOK: lastOK, firstFail: firstFail, error: error),
            StageLine.traceCause(cause, fix: fix),
        ]
        return FailureTraceReport(
            lastOK: lastOK,
            firstFail: firstFail,
            error: error,
            cause: cause,
            fix: fix,
            lines: trace
        )
    }

    /// Checkpoint lines are rewritten at close. `api-connect` keeps one line per track.
    public static func verdictLines(_ lines: [StageLine]) -> [StageLine] {
        var lastIndex: [String: Int] = [:]
        // Names outside the eight checkpoints (reconnect) are a dig trail.
        // They must not become last-ok or first-fail.
        for (index, line) in lines.enumerated() where line.kind == .stage && line.stage != nil {
            let track = line.field("track") ?? ""
            lastIndex["\(line.name ?? "")\t\(track)"] = index
        }
        return lastIndex.values.sorted().compactMap { index in
            lines.indices.contains(index) ? lines[index] : nil
        }
    }

    static func underlying(failing: StageLine?, lines: [StageLine], fallback: String?) -> String {
        guard let failing else {
            return fallback ?? ""
        }
        if let error = failing.field("error"), !error.isEmpty {
            return error
        }
        if failing.stage == .segmentsReceived, let sentence = CauseTable.silenceSentence(lines: lines) {
            return sentence
        }
        if let http = failing.field("http") {
            if let body = failing.field("body"), !body.isEmpty {
                return "http=\(http) \(body)"
            }
            return "http=\(http)"
        }
        if let domain = failing.field("domain"), let code = failing.field("code") {
            var parts = [domain, code]
            if let description = failing.field("localizedDescription"), !description.isEmpty {
                parts.append(description)
            }
            return parts.joined(separator: " ")
        }
        if let fallback, !fallback.isEmpty { return fallback }
        return ""
    }
}
