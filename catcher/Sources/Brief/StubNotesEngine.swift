import Foundation

/// Deterministic notes for Tier L tests. A stub result cannot prove B3.
public struct StubNotesEngine: NotesEngine, Sendable {
    public init() {}

    public var label: BriefEngineInfo {
        BriefEngineInfo(name: "stub", model: "stub")
    }

    public func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft {
        _ = timeout
        guard let first = input.segments.first else {
            throw NotesEngineError.emptyInput
        }
        let title = BriefWords.split(first.text).prefix(BriefContract.titleWordCap).joined(separator: " ")
        var blocks = [
            BriefBlock(
                id: "summary",
                kind: .summary,
                heading: "Summary",
                items: [BriefItem(text: first.text, cites: [first.seq])]
            ),
        ]
        let rest = input.segments.dropFirst().prefix(3)
        if !rest.isEmpty {
            blocks.append(BriefBlock(
                id: "topic-1",
                kind: .topic,
                heading: "Discussion",
                items: rest.map { BriefItem(text: $0.text, cites: [$0.seq]) }
            ))
        }
        let decided = input.segments.filter { $0.text.lowercased().contains("decided") || $0.text.lowercased().contains("decision") }
        if !decided.isEmpty {
            blocks.append(BriefBlock(
                id: "decisions",
                kind: .decisions,
                heading: "Decisions",
                items: decided.map { BriefItem(text: $0.text, cites: [$0.seq]) }
            ))
        }
        let actions = input.segments.filter { segment in
            let text = segment.text.lowercased()
            return text.contains("i will") || text.contains("i'll")
        }
        if !actions.isEmpty {
            blocks.append(BriefBlock(
                id: "next",
                kind: .actionItems,
                heading: "Next steps",
                items: actions.map { BriefItem(text: $0.text, cites: [$0.seq], owner: "me") }
            ))
        }
        return NotesDraft(title: title.isEmpty ? "Notes" : title, blocks: blocks)
    }
}
