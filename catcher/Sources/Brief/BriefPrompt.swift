import Foundation

public enum BriefPrompt {
    public static let schemaName = "notes_draft"

    public static let system = """
    You write shareable notes from a transcript. Reply with JSON only, matching the schema.
    Each transcript line starts with sN, and N is the cite you must use. Example: s12 [them S1] 00:41 text.
    Title is at most 8 words. Do not introduce a name that is not in the transcript.
    Summary has 1 to 3 items.
    Add 1 to 6 topic blocks in transcript order. Each item is at most 30 words and cites at least one seq.
    Decisions only when a speaker stated a decision. Omit that block when there is nothing.
    Action items use owner me, them, or null. due is a phrase copied from the cited line, or null. Do not invent a date.
    Do not copy capture caveats into the notes.
    """

    public static func userText(_ input: BriefInput) -> String {
        var text = input.lines.joined(separator: "\n")
        if !input.caveats.isEmpty {
            text += "\n\nCapture caveats (context only, do not copy into the notes):\n"
            text += input.caveats.joined(separator: "\n")
        }
        return text
    }

    public static func schema() -> [String: Any] {
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["text", "cites", "owner", "due"],
            "properties": [
                "text": ["type": "string"],
                "cites": ["type": "array", "items": ["type": "integer"]],
                "owner": ["type": ["string", "null"]],
                "due": ["type": ["string", "null"]],
            ],
        ]
        let block: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "kind", "heading", "items"],
            "properties": [
                "id": ["type": "string"],
                "kind": ["type": "string", "enum": ["summary", "topic", "decisions", "actionItems"]],
                "heading": ["type": "string"],
                "items": ["type": "array", "items": item],
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "blocks"],
            "properties": [
                "title": ["type": "string"],
                "blocks": ["type": "array", "items": block],
            ],
        ]
    }
}
