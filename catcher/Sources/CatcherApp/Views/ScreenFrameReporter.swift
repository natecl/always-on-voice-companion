import AppKit
import Diagnostics
import SwiftUI

/// Writes the view's center in CGEvent coordinates (origin at the top left of
/// the primary display, y downward) so the harness can click it.
struct ScreenFrameReporter: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> FrameReporterView {
        FrameReporterView(url: url)
    }

    func updateNSView(_ view: FrameReporterView, context: Context) {
        view.url = url
    }
}

final class FrameReporterView: NSView {
    var url: URL
    private var last = ""

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publish()
    }

    override func layout() {
        super.layout()
        publish()
    }

    private func publish() {
        guard let window, bounds.width > 1, bounds.height > 1 else { return }
        let cocoa = window.convertToScreen(convert(bounds, to: nil))
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? cocoa.midY
        let text = String(format: "{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f}\n",
                          cocoa.midX, primaryTop - cocoa.midY, cocoa.width, cocoa.height)
        guard text != last else { return }
        last = text
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            StageMirror.note("record button frame \(ErrorDetail.sentence(error))")
        }
    }
}
