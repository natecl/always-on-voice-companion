import Foundation

/// On-disk notes. Schema `catcher.brief/1`. `cost` is always null in Phase 3.
public struct Brief: Sendable, Equatable {
    public var schema: String
    public var sessionId: String
    public var createdAt: String
    public var source: BriefSource
    public var engine: BriefEngineInfo
    public var latency: BriefLatency
    public var usage: BriefUsage
    public var cost: Int?
    public var title: String
    public var blocks: [BriefBlock]
    public var caveats: [String]

    public init(
        schema: String = BriefContract.schema,
        sessionId: String,
        createdAt: String,
        source: BriefSource,
        engine: BriefEngineInfo,
        latency: BriefLatency,
        usage: BriefUsage,
        cost: Int? = nil,
        title: String,
        blocks: [BriefBlock],
        caveats: [String]
    ) {
        self.schema = schema
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.source = source
        self.engine = engine
        self.latency = latency
        self.usage = usage
        self.cost = cost
        self.title = title
        self.blocks = blocks
        self.caveats = caveats
    }
}

public struct BriefSource: Sendable, Equatable, Codable {
    public var eventsSha256: String
    public var segmentCount: Int
    public var wordCount: Int
    public var durationMs: Int
    public var clean: Bool
    public var recovered: Bool

    public init(
        eventsSha256: String,
        segmentCount: Int,
        wordCount: Int,
        durationMs: Int,
        clean: Bool,
        recovered: Bool
    ) {
        self.eventsSha256 = eventsSha256
        self.segmentCount = segmentCount
        self.wordCount = wordCount
        self.durationMs = durationMs
        self.clean = clean
        self.recovered = recovered
    }
}

public struct BriefEngineInfo: Sendable, Equatable, Codable {
    public var name: String
    public var model: String
    public var promptVersion: String

    public init(name: String, model: String, promptVersion: String = BriefContract.promptVersion) {
        self.name = name
        self.model = model
        self.promptVersion = promptVersion
    }
}

public struct BriefLatency: Sendable, Equatable, Codable {
    public var stopRequestedWallMs: Int
    public var assembledWallMs: Int
    public var requestStartWallMs: Int
    public var responseWallMs: Int
    public var writtenWallMs: Int
    public var attempts: Int

    public init(
        stopRequestedWallMs: Int = 0,
        assembledWallMs: Int = 0,
        requestStartWallMs: Int = 0,
        responseWallMs: Int = 0,
        writtenWallMs: Int = 0,
        attempts: Int = 1
    ) {
        self.stopRequestedWallMs = stopRequestedWallMs
        self.assembledWallMs = assembledWallMs
        self.requestStartWallMs = requestStartWallMs
        self.responseWallMs = responseWallMs
        self.writtenWallMs = writtenWallMs
        self.attempts = attempts
    }
}

public struct BriefUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum BlockKind: String, Sendable, Equatable, Codable {
    case summary
    case topic
    case decisions
    case actionItems
}

public struct BriefBlock: Sendable, Equatable, Codable {
    public var id: String
    public var kind: BlockKind
    public var heading: String
    public var items: [BriefItem]

    public init(id: String, kind: BlockKind, heading: String, items: [BriefItem]) {
        self.id = id
        self.kind = kind
        self.heading = heading
        self.items = items
    }
}

public struct BriefItem: Sendable, Equatable, Codable {
    public var text: String
    public var cites: [Int]
    public var owner: String?
    public var due: String?

    public init(text: String, cites: [Int], owner: String? = nil, due: String? = nil) {
        self.text = text
        self.cites = cites
        self.owner = owner
        self.due = due
    }
}

/// Phase 2 may show this in the UI. The copy renderer never includes it.
public struct BriefFootnote: Sendable, Equatable {
    public var line: String

    public init(line: String) {
        self.line = line
    }
}

public enum BriefContract {
    public static let schema = "catcher.brief/1"
    public static let promptVersion = "brief-v1"
    public static let footer = "Notes by Catcher"
    public static let minimumWords = 25
    public static let titleWordCap = 8
    public static let itemWordCap = 30
    public static let summaryItemCap = 3
    public static let topicCap = 6
    public static let topicItemCap = 5
    public static let listItemCap = 8
}

extension Brief: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema, sessionId, createdAt, source, engine, latency, usage, cost, title, blocks, caveats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(String.self, forKey: .schema)
        if schema != BriefContract.schema {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "schema \(schema)"
            )
        }
        guard container.contains(.cost), try container.decodeNil(forKey: .cost) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cost,
                in: container,
                debugDescription: "cost must be null"
            )
        }
        self.schema = schema
        sessionId = try container.decode(String.self, forKey: .sessionId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        source = try container.decode(BriefSource.self, forKey: .source)
        engine = try container.decode(BriefEngineInfo.self, forKey: .engine)
        latency = try container.decode(BriefLatency.self, forKey: .latency)
        usage = try container.decode(BriefUsage.self, forKey: .usage)
        cost = nil
        title = try container.decode(String.self, forKey: .title)
        blocks = try container.decode([BriefBlock].self, forKey: .blocks)
        caveats = try container.decode([String].self, forKey: .caveats)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(source, forKey: .source)
        try container.encode(engine, forKey: .engine)
        try container.encode(latency, forKey: .latency)
        try container.encode(usage, forKey: .usage)
        try container.encodeNil(forKey: .cost)
        try container.encode(title, forKey: .title)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(caveats, forKey: .caveats)
    }
}
