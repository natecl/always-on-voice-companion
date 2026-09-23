import Foundation
import SessionStore

public enum NotesPhase: Sendable, Equatable {
    case idle
    case writing(startedWallMs: Int)
    case ready(Brief)
    case failed(String)
    case skipped(BriefSkip)
    case needsManualNotes
}

/// What NotesView renders. The copy payload is separate and never includes caveats.
public struct NotesSurface: Sendable, Equatable {
    public static let copiedHoldMs = 1_500

    public var phase: NotesPhase
    public var statusLine: String
    public var title: String
    public var blocks: [BriefBlock]
    public var caveats: [String]
    public var copyNotesEnabled: Bool
    public var copyTranscriptEnabled: Bool
    public var showRetry: Bool
    public var showMakeNotes: Bool
    public var copyButtonTitle: String
    public var elapsedSeconds: Int
    public var copiedUntilMs: Int?

    public init(
        phase: NotesPhase,
        statusLine: String,
        title: String,
        blocks: [BriefBlock],
        caveats: [String],
        copyNotesEnabled: Bool,
        copyTranscriptEnabled: Bool,
        showRetry: Bool,
        showMakeNotes: Bool,
        copyButtonTitle: String,
        elapsedSeconds: Int,
        copiedUntilMs: Int?
    ) {
        self.phase = phase
        self.statusLine = statusLine
        self.title = title
        self.blocks = blocks
        self.caveats = caveats
        self.copyNotesEnabled = copyNotesEnabled
        self.copyTranscriptEnabled = copyTranscriptEnabled
        self.showRetry = showRetry
        self.showMakeNotes = showMakeNotes
        self.copyButtonTitle = copyButtonTitle
        self.elapsedSeconds = elapsedSeconds
        self.copiedUntilMs = copiedUntilMs
    }

    public static let idle = NotesSurface.make(phase: .idle, nowMs: 0)

    public static func make(phase: NotesPhase, nowMs: Int, copiedUntilMs: Int? = nil) -> NotesSurface {
        let elapsed: Int
        if case .writing(let started) = phase {
            elapsed = max(0, (nowMs - started) / 1_000)
        } else {
            elapsed = 0
        }
        let brief: Brief?
        if case .ready(let value) = phase {
            brief = value
        } else {
            brief = nil
        }
        let copied = copiedUntilMs.map { nowMs < $0 } ?? false
        let status: String
        switch phase {
        case .idle:
            status = ""
        case .writing:
            status = "Writing notes… \(elapsed)s"
        case .ready:
            status = ""
        case .failed(let reason):
            status = "Notes failed: \(reason)"
        case .skipped(.noSpeech):
            status = "No speech captured"
        case .skipped(.tooShort):
            status = "Too short for notes"
        case .needsManualNotes:
            status = ""
        }
        return NotesSurface(
            phase: phase,
            statusLine: status,
            title: brief?.title ?? "",
            blocks: brief?.blocks ?? [],
            caveats: brief?.caveats ?? [],
            copyNotesEnabled: brief != nil,
            copyTranscriptEnabled: {
                switch phase {
                case .failed, .skipped: true
                default: false
                }
            }(),
            showRetry: {
                if case .failed = phase { return true }
                return false
            }(),
            showMakeNotes: phase == .needsManualNotes,
            copyButtonTitle: copied ? "Copied" : "Copy notes",
            elapsedSeconds: elapsed,
            copiedUntilMs: copied ? copiedUntilMs : nil
        )
    }

    public func refresh(nowMs: Int) -> NotesSurface {
        NotesSurface.make(phase: phase, nowMs: nowMs, copiedUntilMs: copiedUntilMs)
    }

    public func markedCopied(nowMs: Int) -> NotesSurface {
        NotesSurface.make(phase: phase, nowMs: nowMs, copiedUntilMs: nowMs + Self.copiedHoldMs)
    }
}

public enum NotesCite {
    public static func first(_ cites: [Int]) -> Int? {
        cites.first
    }
}

public struct NotesTranscriptRow: Sendable, Equatable, Identifiable {
    public var seq: Int
    public var text: String

    public var id: Int { seq }

    public init(seq: Int, text: String) {
        self.seq = seq
        self.text = text
    }
}

public enum NotesTranscript {
    /// Reads finals for cite scrolling. Does not open the file for writing.
    public static func rows(eventsFile: URL) -> [NotesTranscriptRow] {
        guard let contents = try? JSONLReader.read(url: eventsFile) else { return [] }
        return contents.rows.compactMap { row in
            guard case .seg(let segment) = row, segment.final else { return nil }
            return NotesTranscriptRow(seq: segment.seq, text: Assembler.line(segment))
        }
    }
}

public enum NotesDisk {
    public static func phase(directory: URL, recovered: Bool) -> NotesPhase {
        let briefURL = SessionPaths.briefFile(in: directory)
        if let data = try? Data(contentsOf: briefURL),
           let brief = try? JSONDecoder().decode(Brief.self, from: data) {
            return .ready(brief)
        }
        let errorURL = SessionPaths.briefErrorFile(in: directory)
        if let data = try? Data(contentsOf: errorURL),
           let record = try? JSONDecoder().decode(BriefFailureRecord.self, from: data) {
            return .failed(record.error)
        }
        if recovered {
            return .needsManualNotes
        }
        return .idle
    }
}
