import Foundation
import SessionStore

public protocol BriefStopwatch: Sendable {
    func nowMs() -> Int
}

public struct SystemStopwatch: BriefStopwatch {
    public init() {}

    public func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

public struct BriefBudget: Sendable, Equatable {
    public var requestTimeout: Duration
    public var retryCutoffMs: Int
    public var singleCallTokenCap: Int
    public var chunkTokenCap: Int

    public init(requestTimeout: Duration, retryCutoffMs: Int, singleCallTokenCap: Int, chunkTokenCap: Int) {
        self.requestTimeout = requestTimeout
        self.retryCutoffMs = retryCutoffMs
        self.singleCallTokenCap = singleCallTokenCap
        self.chunkTokenCap = chunkTokenCap
    }

    public static let standard = BriefBudget(
        requestTimeout: .seconds(NotesService.requestTimeoutSeconds),
        retryCutoffMs: NotesService.retryCutoffSeconds * 1000,
        singleCallTokenCap: 60_000,
        chunkTokenCap: 30_000
    )
}

public enum BriefOutcome: Sendable, Equatable {
    case ready
    case failed(String)
    case skipped(BriefSkip)
    case suppressed
    case needsManualNotes
}

public struct BriefRunReport: Sendable, Equatable {
    public var outcome: BriefOutcome
    public var attempts: Int
    public var readMs: Int
    public var requestMs: Int
    public var validateMs: Int
    public var writeMs: Int
    public var totalMs: Int
    public var model: String

    public init(
        outcome: BriefOutcome,
        attempts: Int,
        readMs: Int,
        requestMs: Int,
        validateMs: Int,
        writeMs: Int,
        totalMs: Int,
        model: String
    ) {
        self.outcome = outcome
        self.attempts = attempts
        self.readMs = readMs
        self.requestMs = requestMs
        self.validateMs = validateMs
        self.writeMs = writeMs
        self.totalMs = totalMs
        self.model = model
    }
}

public actor BriefRunner {
    private var inFlight: [String: Task<BriefRunReport, Never>] = [:]

    public init() {}

    public func run(
        _ ended: SessionEnded,
        engine: any NotesEngine,
        intent: BriefIntent = .automatic,
        eventsFile: URL? = nil,
        outputDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        createdAt: String? = nil,
        budget: BriefBudget = .standard,
        stopwatch: any BriefStopwatch = SystemStopwatch()
    ) async -> BriefRunReport {
        if let existing = inFlight[ended.sessionID] {
            return await existing.value
        }
        let events = eventsFile ?? SessionPaths.eventsFile(in: ended.directory)
        let output = outputDirectory ?? ended.directory
        let stamp = createdAt ?? ISO8601.string(from: Date())
        let task = Task.detached {
            await self.execute(
                ended: ended,
                engine: engine,
                intent: intent,
                eventsFile: events,
                outputDirectory: output,
                environment: environment,
                createdAt: stamp,
                budget: budget,
                stopwatch: stopwatch
            )
        }
        inFlight[ended.sessionID] = task
        let report = await task.value
        inFlight[ended.sessionID] = nil
        return report
    }

    private func execute(
        ended: SessionEnded,
        engine: any NotesEngine,
        intent: BriefIntent,
        eventsFile: URL,
        outputDirectory: URL,
        environment: [String: String],
        createdAt: String,
        budget: BriefBudget,
        stopwatch: any BriefStopwatch
    ) async -> BriefRunReport {
        let started = stopwatch.nowMs()
        var report = BriefRunReport(
            outcome: .failed("unstarted"),
            attempts: 0,
            readMs: 0,
            requestMs: 0,
            validateMs: 0,
            writeMs: 0,
            totalMs: 0,
            model: engine.label.model
        )
        if !BriefLaunchPolicy.notesEnabled(environment: environment) {
            report.outcome = .suppressed
            report.totalMs = stopwatch.nowMs() - started
            return report
        }
        if ended.recovered && intent == .automatic {
            report.outcome = .needsManualNotes
            report.totalMs = stopwatch.nowMs() - started
            return report
        }

        let readStarted = stopwatch.nowMs()
        let eventsData: Data
        let rows: [SessionRow]
        do {
            eventsData = try Data(contentsOf: eventsFile)
            rows = try JSONLReader.read(url: eventsFile).rows
        } catch {
            return await fail(report, output: outputDirectory, reason: "events unreadable", started: started, stopwatch: stopwatch)
        }
        let sha = BriefHash.sha256Hex(eventsData)
        let built = BriefInputBuilder.build(rows: rows, eventsSHA256: sha)
        report.readMs = stopwatch.nowMs() - readStarted
        let input: BriefInput
        switch built {
        case .skipped(let reason):
            report.outcome = .skipped(reason)
            report.totalMs = stopwatch.nowMs() - started
            return report
        case .ready(let ready):
            input = ready
        }

        let requestStarted = stopwatch.nowMs()
        let draft: NotesDraft
        do {
            draft = try await call(input: input, engine: engine, ended: ended, budget: budget, stopwatch: stopwatch, attempts: &report.attempts)
        } catch let error as NotesEngineError {
            return await fail(report, output: outputDirectory, reason: Self.describe(error), started: started, stopwatch: stopwatch)
        } catch {
            return await fail(report, output: outputDirectory, reason: String(describing: error), started: started, stopwatch: stopwatch)
        }
        report.requestMs = stopwatch.nowMs() - requestStarted
        if let model = draft.model, !model.isEmpty {
            report.model = model
        }

        let validateStarted = stopwatch.nowMs()
        let context = Self.context(input: input, ended: ended, engine: engine, draft: draft, createdAt: createdAt, attempts: report.attempts, stopwatch: stopwatch, requestStarted: requestStarted)
        let validation: BriefValidation
        switch BriefValidator.validate(draft: draft, context: context) {
        case .success(let value):
            validation = value
        case .failure(let error):
            report.validateMs = stopwatch.nowMs() - validateStarted
            return await fail(report, output: outputDirectory, reason: String(describing: error), started: started, stopwatch: stopwatch)
        }
        report.validateMs = stopwatch.nowMs() - validateStarted

        let writeStarted = stopwatch.nowMs()
        do {
            try BriefWriter.write(validation.brief, to: outputDirectory, logLine: validation.logLine)
        } catch {
            return await fail(report, output: outputDirectory, reason: "write \(error)", started: started, stopwatch: stopwatch)
        }
        if !BriefWriter.eventsUnchanged(url: eventsFile, sha256: sha) {
            return await fail(report, output: outputDirectory, reason: "events.jsonl changed", started: started, stopwatch: stopwatch)
        }
        report.writeMs = stopwatch.nowMs() - writeStarted
        report.outcome = .ready
        report.totalMs = stopwatch.nowMs() - started
        return report
    }

    private func call(
        input: BriefInput,
        engine: any NotesEngine,
        ended: SessionEnded,
        budget: BriefBudget,
        stopwatch: any BriefStopwatch,
        attempts: inout Int
    ) async throws -> NotesDraft {
        attempts = 1
        do {
            return try await once(input: input, engine: engine, timeout: budget.requestTimeout, budget: budget)
        } catch let error as NotesEngineError {
            let elapsed = stopwatch.nowMs() - ended.stopRequestedWallMs
            guard error.retries, elapsed <= budget.retryCutoffMs else { throw error }
            attempts = 2
            let budgetMs = Self.milliseconds(budget.requestTimeout)
            let remaining = max(1, budgetMs - max(0, elapsed))
            return try await once(
                input: input,
                engine: engine,
                timeout: .milliseconds(remaining),
                budget: budget
            )
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    private func once(
        input: BriefInput,
        engine: any NotesEngine,
        timeout: Duration,
        budget: BriefBudget
    ) async throws -> NotesDraft {
        try await withThrowingTaskGroup(of: NotesDraft.self) { group in
            group.addTask {
                try await BriefNotesCall.write(input: input, engine: engine, timeout: timeout, budget: budget)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NotesEngineError.timedOut
            }
            do {
                guard let first = try await group.next() else {
                    throw NotesEngineError.timedOut
                }
                group.cancelAll()
                return first
            } catch is CancellationError {
                group.cancelAll()
                throw NotesEngineError.timedOut
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func fail(
        _ report: BriefRunReport,
        output: URL,
        reason: String,
        started: Int,
        stopwatch: any BriefStopwatch
    ) async -> BriefRunReport {
        var report = report
        report.outcome = .failed(reason)
        try? BriefWriter.writeFailure(BriefFailureRecord(error: reason, attempts: report.attempts), to: output)
        report.totalMs = stopwatch.nowMs() - started
        return report
    }

    private static func context(
        input: BriefInput,
        ended: SessionEnded,
        engine: any NotesEngine,
        draft: NotesDraft,
        createdAt: String,
        attempts: Int,
        stopwatch: any BriefStopwatch,
        requestStarted: Int
    ) -> BriefContext {
        let now = stopwatch.nowMs()
        return BriefContext(
            sessionID: ended.sessionID,
            createdAt: createdAt,
            source: BriefSource(
                eventsSha256: input.eventsSha256,
                segmentCount: input.segments.count,
                wordCount: input.wordCount,
                durationMs: input.durationMs,
                clean: input.clean,
                recovered: input.recovered
            ),
            engine: BriefEngineInfo(name: engine.label.name, model: draft.model ?? engine.label.model),
            latency: BriefLatency(
                stopRequestedWallMs: ended.stopRequestedWallMs,
                assembledWallMs: ended.assembledWallMs,
                requestStartWallMs: requestStarted,
                responseWallMs: now,
                writtenWallMs: now,
                attempts: attempts
            ),
            usage: draft.usage ?? BriefUsage(inputTokens: 0, outputTokens: 0),
            caveats: input.caveats,
            validSeqs: input.segmentSeqs,
            segmentTexts: input.segmentTexts
        )
    }

    private static func describe(_ error: NotesEngineError) -> String {
        switch error {
        case .emptyInput:
            "empty input"
        case .missingAPIKey:
            "missing XAI_API_KEY"
        case .transport(let text):
            "transport \(text)"
        case .http(let code, let body):
            "http \(code) \(body)"
        case .invalidJSON:
            "invalid JSON"
        case .timedOut:
            "timed out"
        }
    }
}

enum BriefTokens {
    static func estimate(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }
}

enum BriefNotesCall {
    static func write(
        input: BriefInput,
        engine: any NotesEngine,
        timeout: Duration,
        budget: BriefBudget
    ) async throws -> NotesDraft {
        let groups = chunks(input.segments, cap: budget.chunkTokenCap)
        let whole = BriefTokens.estimate(input.lines.joined(separator: "\n"))
        if whole <= budget.singleCallTokenCap || groups.count <= 1 {
            return try await engine.write(input, timeout: timeout)
        }
        var partials = [NotesDraft?](repeating: nil, count: groups.count)
        try await withThrowingTaskGroup(of: (Int, NotesDraft).self) { group in
            for (index, segments) in groups.enumerated() {
                let chunk = input.selecting(segments)
                group.addTask {
                    (index, try await engine.write(chunk, timeout: timeout))
                }
            }
            for try await (index, draft) in group {
                partials[index] = draft
            }
        }
        let reduce = reduceInput(original: input, partials: partials.compactMap { $0 })
        return try await engine.write(reduce, timeout: timeout)
    }

    static func chunks(_ segments: [BriefSegment], cap: Int) -> [[BriefSegment]] {
        var groups: [[BriefSegment]] = []
        var current: [BriefSegment] = []
        var tokens = 0
        for segment in segments {
            let cost = BriefTokens.estimate(segment.line)
            if !current.isEmpty, tokens + cost > cap {
                groups.append(current)
                current = []
                tokens = 0
            }
            current.append(segment)
            tokens += cost
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func reduceInput(original: BriefInput, partials: [NotesDraft]) -> BriefInput {
        var picked: [BriefSegment] = []
        var seen = Set<Int>()
        for draft in partials {
            for item in draft.blocks.flatMap(\.items) {
                for seq in item.cites where seen.insert(seq).inserted {
                    if let segment = original.segments.first(where: { $0.seq == seq }) {
                        picked.append(segment)
                    }
                }
            }
        }
        if picked.isEmpty, let first = original.segments.first {
            picked = [first]
        }
        return original.selecting(picked)
    }
}

extension BriefInput {
    func selecting(_ picked: [BriefSegment]) -> BriefInput {
        var texts: [Int: String] = [:]
        for segment in picked {
            texts[segment.seq] = segment.text
        }
        return BriefInput(
            sessionID: sessionID,
            segments: picked,
            caveats: caveats,
            segmentTexts: texts,
            wordCount: wordCount,
            durationMs: durationMs,
            clean: clean,
            recovered: recovered,
            eventsSha256: eventsSha256
        )
    }
}
