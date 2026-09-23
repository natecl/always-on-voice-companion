import Brief
import SwiftUI

extension BriefBlock: Identifiable {}

struct NotesView: View {
    var surface: NotesSurface
    var onCopyNotes: () -> Void
    var onCopyBlock: (String) -> Void
    var onRetry: () -> Void
    var onMakeNotes: () -> Void
    var onCopyTranscript: () -> Void
    var onCite: (Int) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let shown = surface.refresh(nowMs: Int(context.date.timeIntervalSince1970 * 1000))
            content(shown)
        }
        .accessibilityIdentifier("notesView")
    }

    @ViewBuilder
    private func content(_ surface: NotesSurface) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            if !surface.statusLine.isEmpty {
                Text(surface.statusLine)
                    .foregroundStyle(surface.showRetry ? Color.red : Color.secondary)
                    .accessibilityIdentifier("notesStatus")
            }
            if surface.showMakeNotes {
                Button("Make notes", action: onMakeNotes)
                    .accessibilityIdentifier("makeNotesButton")
            }
            if surface.showRetry {
                Button("Retry", action: onRetry)
                    .accessibilityIdentifier("retryNotesButton")
            }
            if !surface.caveats.isEmpty {
                Text(surface.caveats.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notesCaveats")
            }
            if surface.copyNotesEnabled {
                Text(surface.title)
                    .font(.title3.weight(.semibold))
                ForEach(surface.blocks) { block in
                    blockView(block)
                }
            }
            HStack(spacing: 12) {
                if surface.copyNotesEnabled {
                    Button(surface.copyButtonTitle, action: onCopyNotes)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .accessibilityIdentifier("copyNotesButton")
                }
                if surface.copyTranscriptEnabled {
                    Button("Copy transcript", action: onCopyTranscript)
                        .accessibilityIdentifier("copyTranscriptButton")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockView(_ block: BriefBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(block.heading)
                    .font(.headline)
                Button {
                    onCopyBlock(block.id)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("copyBlock-\(block.id)")
                .help("Copy \(block.heading)")
            }
            ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                Button {
                    if let seq = NotesCite.first(item.cites) {
                        onCite(seq)
                    }
                } label: {
                    Text(bullet(item, action: block.kind == .actionItems))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bullet(_ item: BriefItem, action: Bool) -> String {
        if action {
            return "☐ \(item.text)"
        }
        return "• \(item.text)"
    }
}
