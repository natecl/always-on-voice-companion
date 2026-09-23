import Foundation
import SessionStore

public struct BriefBakeTrial: Sendable, Equatable, Codable {
    public var model: String
    public var run: Int
    public var passed: Bool
    public var requestMs: Int
    public var error: String?
    public var responseModel: String?

    public init(
        model: String,
        run: Int,
        passed: Bool,
        requestMs: Int,
        error: String? = nil,
        responseModel: String? = nil
    ) {
        self.model = model
        self.run = run
        self.passed = passed
        self.requestMs = requestMs
        self.error = error
        self.responseModel = responseModel
    }
}

public struct BriefBakeModelResult: Sendable, Equatable, Codable {
    public var model: String
    public var passes: Int
    public var runs: Int
    public var medianRequestMs: Int?

    public init(model: String, passes: Int, runs: Int, medianRequestMs: Int?) {
        self.model = model
        self.passes = passes
        self.runs = runs
        self.medianRequestMs = medianRequestMs
    }
}

public enum BriefBakeOff {
    /// At most three fast ids. Only the first is documented non-reasoning as of 2026-09-23.
    /// The other two are the historical fast non-reasoning names; they now alias reasoning `grok-4.3`.
    public static let candidates = [
        "grok-4.20-0309-non-reasoning",
        "grok-4-fast-non-reasoning",
        "grok-4-1-fast-non-reasoning",
    ]

    public static func disqualified(_ responseModel: String?) -> Bool {
        guard let name = responseModel, !name.isEmpty else { return false }
        if name.contains("non-reasoning") { return false }
        if name == "grok-4.3" || name.hasPrefix("grok-4.3-") { return true }
        if name.contains("reasoning") { return true }
        return false
    }

    public static func summarize(_ trials: [BriefBakeTrial]) -> [BriefBakeModelResult] {
        var order: [String] = []
        var grouped: [String: [BriefBakeTrial]] = [:]
        for trial in trials {
            if grouped[trial.model] == nil { order.append(trial.model) }
            grouped[trial.model, default: []].append(trial)
        }
        return order.map { model in
            let rows = grouped[model] ?? []
            let passed = rows.filter(\.passed)
            return BriefBakeModelResult(
                model: model,
                passes: passed.count,
                runs: rows.count,
                medianRequestMs: median(passed.map(\.requestMs))
            )
        }
    }

    /// Fastest model that passed every run. Nil when none went 5/5 (or N/N).
    public static func winner(_ results: [BriefBakeModelResult]) -> String? {
        results
            .filter { $0.runs > 0 && $0.passes == $0.runs }
            .min { ($0.medianRequestMs ?? Int.max) < ($1.medianRequestMs ?? Int.max) }?
            .model
    }

    public static func measure(
        input: BriefInput,
        models: [String],
        runs: Int,
        apiKey: String,
        transport: any NotesHTTPTransport,
        context: BriefContext,
        stopwatch: any BriefStopwatch = SystemStopwatch()
    ) async -> [BriefBakeTrial] {
        var trials: [BriefBakeTrial] = []
        for model in models {
            let engine = GrokNotesEngine(model: model, apiKey: apiKey, transport: transport)
            for run in 1...max(1, runs) {
                let started = stopwatch.nowMs()
                do {
                    let draft = try await engine.write(input, timeout: .seconds(NotesService.requestTimeoutSeconds))
                    let ms = stopwatch.nowMs() - started
                    if disqualified(draft.model) {
                        trials.append(BriefBakeTrial(
                            model: model,
                            run: run,
                            passed: false,
                            requestMs: ms,
                            error: "response model \(draft.model ?? "") is not non-reasoning",
                            responseModel: draft.model
                        ))
                        continue
                    }
                    var ctx = context
                    ctx.engine = BriefEngineInfo(name: "grok-notes", model: draft.model ?? model)
                    if let usage = draft.usage { ctx.usage = usage }
                    switch BriefValidator.validate(draft: draft, context: ctx) {
                    case .success:
                        trials.append(BriefBakeTrial(model: model, run: run, passed: true, requestMs: ms, responseModel: draft.model))
                    case .failure(let error):
                        trials.append(BriefBakeTrial(
                            model: model,
                            run: run,
                            passed: false,
                            requestMs: ms,
                            error: String(describing: error),
                            responseModel: draft.model
                        ))
                    }
                } catch {
                    trials.append(BriefBakeTrial(
                        model: model,
                        run: run,
                        passed: false,
                        requestMs: stopwatch.nowMs() - started,
                        error: String(describing: error)
                    ))
                }
            }
        }
        return trials
    }

    private static func median(_ values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

public enum BriefBench {
    public static func sessions(
        eventsFile: URL,
        outputDirectory: URL,
        runs: Int,
        engine: any NotesEngine,
        environment: [String: String],
        stopwatch: any BriefStopwatch = SystemStopwatch()
    ) async -> [BriefRunReport] {
        let runner = BriefRunner()
        var reports: [BriefRunReport] = []
        for index in 1...max(1, runs) {
            let directory = outputDirectory.appendingPathComponent("run-\(index)", isDirectory: true)
            let ended = SessionEnded(
                sessionID: "bench-\(index)",
                directory: directory,
                stopRequestedWallMs: stopwatch.nowMs(),
                assembledWallMs: stopwatch.nowMs(),
                clean: true,
                recovered: false,
                trigger: .harness
            )
            reports.append(await runner.run(
                ended,
                engine: engine,
                eventsFile: eventsFile,
                outputDirectory: directory,
                environment: environment,
                createdAt: "2026-09-23T00:00:00.000Z",
                stopwatch: stopwatch
            ))
        }
        return reports
    }

    public static func cli(_ arguments: [String]) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CATCHER_BRIEF"] == "1" else {
            FileHandle.standardError.write(Data("brief-bench: notes stay off unless CATCHER_BRIEF=1\n".utf8))
            return 2
        }
        do {
            if arguments.first == "bake" {
                return try await bake(Array(arguments.dropFirst()), environment: environment)
            }
            return try await run(arguments, environment: environment)
        } catch {
            FileHandle.standardError.write(Data("brief-bench \(error)\n".utf8))
            return 1
        }
    }

    private static func run(_ arguments: [String], environment: [String: String]) async throws -> Int32 {
        let parsed = try Parsed(arguments, needsModels: false)
        let engine = try NotesEngineFactory.make(environment: environment)
        let reports = await sessions(
            eventsFile: parsed.events,
            outputDirectory: parsed.output,
            runs: parsed.runs,
            engine: engine,
            environment: environment
        )
        let payload = reports.map { report in
            [
                "outcome": outcomeName(report.outcome),
                "attempts": report.attempts,
                "readMs": report.readMs,
                "requestMs": report.requestMs,
                "validateMs": report.validateMs,
                "writeMs": report.writeMs,
                "totalMs": report.totalMs,
                "model": report.model,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return reports.allSatisfy { if case .ready = $0.outcome { return true }; return false } ? 0 : 1
    }

    private static func bake(_ arguments: [String], environment: [String: String]) async throws -> Int32 {
        let parsed = try Parsed(arguments, needsModels: true)
        let key = environment[NotesService.apiKeyEnvironment] ?? ""
        if key.isEmpty {
            throw NotesEngineFactory.Failure.missingAPIKey
        }
        let data = try Data(contentsOf: parsed.events)
        let rows = try JSONLReader.read(url: parsed.events).rows
        guard case .ready(let input) = BriefInputBuilder.build(rows: rows, eventsSHA256: BriefHash.sha256Hex(data)) else {
            FileHandle.standardError.write(Data("brief-bench bake: fixture skipped\n".utf8))
            return 1
        }
        let context = BriefContext(
            sessionID: "bake",
            createdAt: "2026-09-23T00:00:00.000Z",
            source: BriefSource(
                eventsSha256: input.eventsSha256,
                segmentCount: input.segments.count,
                wordCount: input.wordCount,
                durationMs: input.durationMs,
                clean: input.clean,
                recovered: input.recovered
            ),
            engine: BriefEngineInfo(name: "grok-notes", model: NotesService.briefModel),
            latency: BriefLatency(),
            usage: BriefUsage(inputTokens: 0, outputTokens: 0),
            caveats: input.caveats,
            validSeqs: input.segmentSeqs,
            segmentTexts: input.segmentTexts
        )
        let trials = await BriefBakeOff.measure(
            input: input,
            models: parsed.models,
            runs: parsed.runs,
            apiKey: key,
            transport: URLSessionNotesTransport(),
            context: context
        )
        let results = BriefBakeOff.summarize(trials)
        let payload: [String: Any] = [
            "candidates": parsed.models,
            "winner": BriefBakeOff.winner(results) ?? "",
            "results": results.map {
                [
                    "model": $0.model,
                    "passes": $0.passes,
                    "runs": $0.runs,
                    "medianRequestMs": $0.medianRequestMs ?? -1,
                ] as [String: Any]
            },
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: parsed.output, withIntermediateDirectories: true)
        try encoded.write(to: parsed.output.appendingPathComponent("bake.json"), options: .atomic)
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return BriefBakeOff.winner(results) == nil ? 1 : 0
    }

    private static func outcomeName(_ outcome: BriefOutcome) -> String {
        switch outcome {
        case .ready: "ready"
        case .failed(let reason): "failed \(reason)"
        case .skipped(let reason): "skipped \(reason.rawValue)"
        case .suppressed: "suppressed"
        case .needsManualNotes: "needsManualNotes"
        }
    }
}

private struct Parsed {
    var events: URL
    var output: URL
    var runs: Int
    var models: [String]

    init(_ arguments: [String], needsModels: Bool) throws {
        var events: String?
        var output: String?
        var runs = needsModels ? 5 : 3
        var models = BriefBakeOff.candidates
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--out":
                index += 1
                output = arguments[index]
            case "--runs":
                index += 1
                runs = Int(arguments[index]) ?? runs
            case "--models":
                index += 1
                models = arguments[index].split(separator: ",").map { String($0) }
            default:
                if events == nil { events = arg }
            }
            index += 1
        }
        guard let events, let output else {
            throw BriefBenchError.usage
        }
        if needsModels, models.isEmpty || models.count > 3 {
            throw BriefBenchError.usage
        }
        self.events = URL(fileURLWithPath: events)
        self.output = URL(fileURLWithPath: output, isDirectory: true)
        self.runs = runs
        self.models = models
    }
}

private enum BriefBenchError: Error {
    case usage
}
