import Foundation

/// Copy payload. Caveats stay on `Brief.caveats` and out of this text.
/// `footnote` is accepted and ignored: a cost line never enters the copy.
public enum BriefRenderer {
    public static func markdown(
        _ brief: Brief,
        footnote: BriefFootnote? = nil,
        footer: Bool = true
    ) -> String {
        _ = footnote
        var text = "# \(brief.title)\n\(subtitle(brief))\n\n"
        text += brief.blocks.map(markdownBlock).joined(separator: "\n")
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        if footer {
            text += "\n\(BriefContract.footer)\n"
        }
        return text
    }

    public static func html(
        _ brief: Brief,
        footnote: BriefFootnote? = nil,
        footer: Bool = true
    ) -> String {
        _ = footnote
        var lines = [
            "<h1>\(escape(brief.title))</h1>",
            "<p>\(escape(subtitle(brief)))</p>",
        ]
        for block in brief.blocks {
            lines.append(contentsOf: htmlLines(block))
        }
        if footer {
            lines.append("<p>\(escape(BriefContract.footer))</p>")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func markdownBlock(_ block: BriefBlock) -> String {
        var lines = ["## \(block.heading)"]
        for item in block.items {
            lines.append(bullet(item, action: block.kind == .actionItems))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func htmlBlock(_ block: BriefBlock) -> String {
        htmlLines(block).joined(separator: "\n") + "\n"
    }

    private static func htmlLines(_ block: BriefBlock) -> [String] {
        var lines = ["<h2>\(escape(block.heading))</h2>", "<ul>"]
        for item in block.items {
            let body = block.kind == .actionItems ? item.text + suffix(item) : item.text
            lines.append("<li>\(escape(body))</li>")
        }
        lines.append("</ul>")
        return lines
    }

    private static func bullet(_ item: BriefItem, action: Bool) -> String {
        if action {
            return "- [ ] \(item.text)\(suffix(item))"
        }
        return "- \(item.text)"
    }

    private static func suffix(_ item: BriefItem) -> String {
        switch (item.owner, item.due) {
        case let (owner?, due?):
            return " (\(owner), \(due))"
        case let (owner?, nil):
            return " (\(owner))"
        case let (nil, due?):
            return " (\(due))"
        case (nil, nil):
            return ""
        }
    }

    static func subtitle(_ brief: Brief) -> String {
        let minutes = max(0, brief.source.durationMs) / 60_000
        let length = "\(minutes) min"
        if let date = dateLabel(brief.createdAt) {
            return "\(date) · \(length)"
        }
        return length
    }

    static func dateLabel(_ createdAt: String) -> String? {
        let day = createdAt.prefix(10)
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayOfMonth = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(dayOfMonth) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
