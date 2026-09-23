import Foundation

/// The two pasteboard flavors Copy writes in one declare. Caveats and cost stay out.
public struct ClipboardPayload: Sendable, Equatable {
    public static let plainType = "public.utf8-plain-text"
    public static let htmlType = "public.html"

    public var plainText: String
    public var html: String

    public init(plainText: String, html: String) {
        self.plainText = plainText
        self.html = html
    }

    public static func notes(_ brief: Brief) -> ClipboardPayload {
        ClipboardPayload(
            plainText: BriefRenderer.markdown(brief),
            html: BriefRenderer.html(brief)
        )
    }

    /// One block. No document title and no footer.
    public static func block(_ block: BriefBlock) -> ClipboardPayload {
        ClipboardPayload(
            plainText: BriefRenderer.markdownBlock(block),
            html: BriefRenderer.htmlBlock(block)
        )
    }

    public static func transcript(_ text: String) -> ClipboardPayload {
        ClipboardPayload(
            plainText: text,
            html: "<p>\(escape(text))</p>\n"
        )
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
