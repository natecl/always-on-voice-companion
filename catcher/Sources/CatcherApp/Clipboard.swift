import AppKit
import Brief

/// One pasteboard declare: plain Markdown and HTML together.
enum Clipboard {
    static func write(_ payload: ClipboardPayload) {
        let board = NSPasteboard.general
        board.clearContents()
        let html = NSPasteboard.PasteboardType(ClipboardPayload.htmlType)
        board.declareTypes([.string, html], owner: nil)
        board.setString(payload.plainText, forType: .string)
        board.setString(payload.html, forType: html)
    }
}
