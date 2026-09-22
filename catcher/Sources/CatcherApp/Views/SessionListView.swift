import SessionStore
import SwiftUI

extension SessionSummary: Identifiable {}

struct SessionListView: View {
    var sessions: [SessionSummary]
    var selection: String?
    var transcript: String
    var onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.headline)
            if sessions.isEmpty {
                Text("No sessions on disk yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(sessions, selection: Binding(
                    get: { selection },
                    set: { onSelect($0) }
                )) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id)
                            .font(.body.monospaced())
                            .lineLimit(1)
                        Text(meta(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
                .frame(minHeight: 120)
            }
            if !transcript.isEmpty {
                Text(transcript)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("sessionList")
    }

    private func meta(_ session: SessionSummary) -> String {
        var bits = [session.startedAt, "\(session.segmentCount) finals", session.engine]
        if session.recovered { bits.append("recovered") }
        if session.clean { bits.append("clean") }
        return bits.joined(separator: " · ")
    }
}
