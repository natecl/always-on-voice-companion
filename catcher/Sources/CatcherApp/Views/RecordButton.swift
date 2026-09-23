import SwiftUI

struct RecordButton: View {
    var isRecording: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isRecording ? "Stop" : "Record")
                .font(.headline)
                .frame(minWidth: 88)
        }
        .disabled(!enabled)
        .keyboardShortcut(isRecording ? .cancelAction : .defaultAction)
        .accessibilityIdentifier("recordButton")
    }
}
