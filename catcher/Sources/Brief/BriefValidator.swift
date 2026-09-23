import Foundation

public struct BriefContext: Sendable, Equatable {
    public var sessionID: String
    public var createdAt: String
    public var source: BriefSource
    public var engine: BriefEngineInfo
    public var latency: BriefLatency
    public var usage: BriefUsage
    public var caveats: [String]
    public var validSeqs: Set<Int>
    public var segmentTexts: [Int: String]

    public init(
        sessionID: String,
        createdAt: String,
        source: BriefSource,
        engine: BriefEngineInfo,
        latency: BriefLatency,
        usage: BriefUsage,
        caveats: [String],
        validSeqs: Set<Int>,
        segmentTexts: [Int: String]
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.source = source
        self.engine = engine
        self.latency = latency
        self.usage = usage
        self.caveats = caveats
        self.validSeqs = validSeqs
        self.segmentTexts = segmentTexts
    }
}

public struct BriefValidation: Sendable, Equatable {
    public var brief: Brief
    public var droppedCites: Int
    public var uncitedItems: Int
    public var prunedBlocks: Int

    public var logLine: String {
        "droppedCites=\(droppedCites) uncited=\(uncitedItems) prunedBlocks=\(prunedBlocks)"
    }

    public init(brief: Brief, droppedCites: Int, uncitedItems: Int, prunedBlocks: Int) {
        self.brief = brief
        self.droppedCites = droppedCites
        self.uncitedItems = uncitedItems
        self.prunedBlocks = prunedBlocks
    }
}

public enum BriefValidationError: Error, Equatable, Sendable {
    case missingSummary
}

public enum BriefValidator {
    public static func validate(draft: NotesDraft, context: BriefContext) -> Result<BriefValidation, BriefValidationError> {
        var droppedCites = 0
        var prunedBlocks = 0
        var summaries: [BriefBlock] = []
        var topics: [(order: Int, earliest: Int, block: BriefBlock)] = []
        var decisions: [BriefBlock] = []
        var actions: [BriefBlock] = []

        for (index, block) in draft.blocks.enumerated() {
            let cleaned = clean(block, context: context, droppedCites: &droppedCites)
            if cleaned.items.isEmpty {
                prunedBlocks += 1
                continue
            }
            switch cleaned.kind {
            case .summary:
                summaries.append(cleaned)
            case .topic:
                let earliest = cleaned.items.flatMap(\.cites).min() ?? Int.max
                topics.append((index, earliest, cleaned))
            case .decisions:
                decisions.append(cleaned)
            case .actionItems:
                actions.append(cleaned)
            }
        }

        var summaryItems = summaries.flatMap(\.items)
        if summaryItems.count > BriefContract.summaryItemCap {
            summaryItems = Array(summaryItems.prefix(BriefContract.summaryItemCap))
        }
        if summaryItems.isEmpty {
            return .failure(.missingSummary)
        }
        let summary = BriefBlock(
            id: "summary",
            kind: .summary,
            heading: summaries.first?.heading.nonEmpty ?? "Summary",
            items: summaryItems
        )

        let orderedTopics = topics.sorted { lhs, rhs in
            if lhs.earliest != rhs.earliest { return lhs.earliest < rhs.earliest }
            return lhs.order < rhs.order
        }
        if orderedTopics.count > BriefContract.topicCap {
            prunedBlocks += orderedTopics.count - BriefContract.topicCap
        }
        let topicBlocks = orderedTopics.prefix(BriefContract.topicCap).enumerated().map { offset, entry in
            var block = entry.block
            if block.items.count > BriefContract.topicItemCap {
                block.items = Array(block.items.prefix(BriefContract.topicItemCap))
            }
            if block.id.isEmpty {
                block.id = "topic-\(offset + 1)"
            }
            if block.heading.isEmpty {
                block.heading = "Topic"
            }
            return block
        }

        let decisionBlock = cappedList(decisions, kind: .decisions, id: "decisions", heading: "Decisions")
        let actionBlock = cappedList(actions, kind: .actionItems, id: "next", heading: "Next steps")
        if decisions.count > 1 { prunedBlocks += decisions.count - 1 }
        if actions.count > 1 { prunedBlocks += actions.count - 1 }

        var blocks = [summary] + topicBlocks
        if let decisionBlock { blocks.append(decisionBlock) }
        if let actionBlock { blocks.append(actionBlock) }
        blocks = uniqueIDs(blocks)

        let uncited = blocks.flatMap(\.items).filter(\.cites.isEmpty).count
        let title = cappedTitle(draft.title)
        let brief = Brief(
            sessionId: context.sessionID,
            createdAt: context.createdAt,
            source: context.source,
            engine: context.engine,
            latency: context.latency,
            usage: context.usage,
            cost: nil,
            title: title,
            blocks: blocks,
            caveats: context.caveats
        )
        return .success(BriefValidation(
            brief: brief,
            droppedCites: droppedCites,
            uncitedItems: uncited,
            prunedBlocks: prunedBlocks
        ))
    }

    private static func clean(
        _ block: BriefBlock,
        context: BriefContext,
        droppedCites: inout Int
    ) -> BriefBlock {
        var items: [BriefItem] = []
        for item in block.items {
            var kept: [Int] = []
            var seen = Set<Int>()
            for cite in item.cites {
                if context.validSeqs.contains(cite) {
                    if seen.insert(cite).inserted {
                        kept.append(cite)
                    }
                } else {
                    droppedCites += 1
                }
            }
            let words = BriefWords.split(item.text)
            if words.isEmpty { continue }
            let text = words.prefix(BriefContract.itemWordCap).joined(separator: " ")
            var owner: String?
            var due: String?
            if block.kind == .actionItems {
                if let raw = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    if raw == "me" || raw == "them" {
                        owner = raw
                    }
                }
                if let raw = item.due?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    let haystack = kept.map { context.segmentTexts[$0] ?? "" }.joined(separator: " ").lowercased()
                    if haystack.contains(raw.lowercased()) {
                        due = raw
                    }
                }
            }
            items.append(BriefItem(text: text, cites: kept, owner: owner, due: due))
        }
        var heading = block.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        if heading.isEmpty {
            heading = defaultHeading(block.kind)
        }
        return BriefBlock(id: block.id, kind: block.kind, heading: heading, items: items)
    }

    private static func cappedList(
        _ blocks: [BriefBlock],
        kind: BlockKind,
        id: String,
        heading: String
    ) -> BriefBlock? {
        let items = Array(blocks.flatMap(\.items).prefix(BriefContract.listItemCap))
        if items.isEmpty { return nil }
        let usedHeading = blocks.first?.heading.nonEmpty ?? heading
        return BriefBlock(id: id, kind: kind, heading: usedHeading, items: items)
    }

    private static func cappedTitle(_ title: String) -> String {
        let words = BriefWords.split(title).prefix(BriefContract.titleWordCap)
        if words.isEmpty { return "Notes" }
        return words.joined(separator: " ")
    }

    private static func uniqueIDs(_ blocks: [BriefBlock]) -> [BriefBlock] {
        var seen = Set<String>()
        return blocks.map { block in
            var block = block
            var candidate = block.id.isEmpty ? block.kind.rawValue : block.id
            if !seen.insert(candidate).inserted {
                var suffix = 2
                while !seen.insert("\(candidate)-\(suffix)").inserted {
                    suffix += 1
                }
                candidate = "\(candidate)-\(suffix)"
            }
            block.id = candidate
            return block
        }
    }

    private static func defaultHeading(_ kind: BlockKind) -> String {
        switch kind {
        case .summary: "Summary"
        case .topic: "Topic"
        case .decisions: "Decisions"
        case .actionItems: "Next steps"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
