import Foundation

public actor NotesCoordinator {
    private let runner = BriefRunner()
    private var engine: any NotesEngine
    private var lastEnded: SessionEnded?
    private var phase: NotesPhase = .idle

    public init(engine: any NotesEngine) {
        self.engine = engine
    }

    public func replaceEngine(_ engine: any NotesEngine) {
        self.engine = engine
    }

    public func currentPhase() -> NotesPhase {
        phase
    }

    public func stop(ended: SessionEnded, environment: [String: String]) async -> NotesPhase {
        lastEnded = ended
        guard BriefStopAdapter.shouldAutoRun(ended, environment: environment) else {
            if BriefLaunchPolicy.notesEnabled(environment: environment), ended.recovered {
                phase = .needsManualNotes
            } else {
                phase = .idle
            }
            return phase
        }
        return await execute(ended: ended, intent: .automatic, environment: environment)
    }

    public func makeNotes(ended: SessionEnded, environment: [String: String]) async -> NotesPhase {
        lastEnded = ended
        guard BriefLaunchPolicy.notesEnabled(environment: environment) else {
            phase = .idle
            return phase
        }
        return await execute(ended: ended, intent: .manual, environment: environment)
    }

    public func retry(environment: [String: String]) async -> NotesPhase {
        guard let lastEnded, case .failed = phase else { return phase }
        let intent: BriefIntent = lastEnded.recovered ? .manual : .automatic
        return await execute(ended: lastEnded, intent: intent, environment: environment)
    }

    private func execute(
        ended: SessionEnded,
        intent: BriefIntent,
        environment: [String: String]
    ) async -> NotesPhase {
        let report = await runner.run(
            ended,
            engine: engine,
            intent: intent,
            environment: environment
        )
        switch report.outcome {
        case .ready:
            let loaded = NotesDisk.phase(directory: ended.directory, recovered: ended.recovered)
            if case .ready = loaded {
                phase = loaded
            } else {
                phase = .failed("brief unreadable")
            }
        case .failed(let reason):
            phase = .failed(reason)
        case .skipped(let reason):
            phase = .skipped(reason)
        case .suppressed:
            phase = .idle
        case .needsManualNotes:
            phase = .needsManualNotes
        }
        return phase
    }
}
