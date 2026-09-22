import AudioCapture
import SwiftUI

struct LiveTranscriptView: View {
    var lines: [TranscriptLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live transcript")
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("Waiting for audio.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lines) { line in
                        Text(label(line))
                            .font(.body)
                            .foregroundStyle(line.isFinal ? color(line.track) : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("liveTranscript")
    }

    private func label(_ line: TranscriptLine) -> String {
        let who = line.track == .microphone ? "[me]" : "[them]"
        if let speaker = line.speaker, !speaker.isEmpty {
            return "\(who) \(speaker) \(line.text)"
        }
        return "\(who) \(line.text)"
    }

    private func color(_ track: AudioTrack) -> Color {
        switch track {
        case .system: Color.blue
        case .microphone: Color.green
        }
    }
}
