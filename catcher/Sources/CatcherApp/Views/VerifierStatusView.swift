import SwiftUI
import Verifier

struct VerifierStatusView: View {
    var status: VerifierStatus
    var banner: String?
    var updatedAt: Date
    var isRecording: Bool
    var regrant: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            statusBody
        }
    }

    private var statusBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(shownPill)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.2))
                    .foregroundStyle(color)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("verifierPill")
                if status.isBlocked {
                    Button("Re-grant", action: regrant)
                        .accessibilityIdentifier("regrantButton")
                }
            }
            if let banner, !banner.isEmpty {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(color)
                    .accessibilityIdentifier("verifierBanner")
            }
            Text(stale ? "Verifier heartbeat is stale." : status.human)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stale: Bool {
        isRecording && Date().timeIntervalSince(updatedAt) > 3 && updatedAt != .distantPast
    }

    private var shownPill: String {
        stale ? "DEGRADED" : status.pill
    }

    private var color: Color {
        if stale { return .orange }
        switch status {
        case .ok: return .green
        case .degraded: return .orange
        case .noAudio: return .red
        case .blocked: return .red
        }
    }
}
