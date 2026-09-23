import Foundation

public struct CostSessionRow: Sendable, Equatable {
    public var t: String
    public var v: Int
    public var sessionId: String
    public var app: String
    public var engine: String
    public var rateCard: String
    public var billingModel: String
    public var startedAt: String

    public init(
        t: String = "cost.session",
        v: Int = 1,
        sessionId: String,
        app: String,
        engine: String,
        rateCard: String,
        billingModel: String,
        startedAt: String
    ) {
        self.t = t
        self.v = v
        self.sessionId = sessionId
        self.app = app
        self.engine = engine
        self.rateCard = rateCard
        self.billingModel = billingModel
        self.startedAt = startedAt
    }
}

/// One minute, one track, one component. Integer fields are deltas, so the
/// sum across minutes is the session total.
public struct CostMinuteRow: Sendable, Equatable {
    public var t: String
    public var m: Int
    public var fromMs: Int
    public var toMs: Int
    public var track: String
    public var component: String
    public var wireBytes: Int
    public var audioMs: Int
    public var replayBytes: Int
    public var tailBytes: Int
    public var socketAttempts: Int
    public var socketsOpened: Int
    public var socketOpenMs: Int
    public var serverAudioMs: Int
    public var shadowGateMs: Int
    public var bothOpenMs: Int?
    public var inputTokens: Int
    public var outputTokens: Int
    public var requests: Int
    /// Nil when `component` is not on the rate card. A null is unpriced spend.
    public var usd: Double?

    public init(
        t: String = "cost.min",
        m: Int,
        fromMs: Int,
        toMs: Int,
        track: String,
        component: String,
        wireBytes: Int = 0,
        audioMs: Int = 0,
        replayBytes: Int = 0,
        tailBytes: Int = 0,
        socketAttempts: Int = 0,
        socketsOpened: Int = 0,
        socketOpenMs: Int = 0,
        serverAudioMs: Int = 0,
        shadowGateMs: Int = 0,
        bothOpenMs: Int? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        requests: Int = 0,
        usd: Double? = nil
    ) {
        self.t = t
        self.m = m
        self.fromMs = fromMs
        self.toMs = toMs
        self.track = track
        self.component = component
        self.wireBytes = wireBytes
        self.audioMs = audioMs
        self.replayBytes = replayBytes
        self.tailBytes = tailBytes
        self.socketAttempts = socketAttempts
        self.socketsOpened = socketsOpened
        self.socketOpenMs = socketOpenMs
        self.serverAudioMs = serverAudioMs
        self.shadowGateMs = shadowGateMs
        self.bothOpenMs = bothOpenMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.usd = usd
    }
}

public struct TrackUnits: Sendable, Equatable {
    public var wireBytes: Int
    public var audioMs: Int
    public var replayBytes: Int
    public var tailBytes: Int
    public var socketAttempts: Int
    public var socketsOpened: Int
    public var socketOpenMs: Int
    public var serverAudioMs: Int
    public var shadowGateMs: Int
    public var bothOpenMs: Int?
    public var inputTokens: Int
    public var outputTokens: Int
    public var requests: Int

    public init(
        wireBytes: Int = 0,
        audioMs: Int = 0,
        replayBytes: Int = 0,
        tailBytes: Int = 0,
        socketAttempts: Int = 0,
        socketsOpened: Int = 0,
        socketOpenMs: Int = 0,
        serverAudioMs: Int = 0,
        shadowGateMs: Int = 0,
        bothOpenMs: Int? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        requests: Int = 0
    ) {
        self.wireBytes = wireBytes
        self.audioMs = audioMs
        self.replayBytes = replayBytes
        self.tailBytes = tailBytes
        self.socketAttempts = socketAttempts
        self.socketsOpened = socketsOpened
        self.socketOpenMs = socketOpenMs
        self.serverAudioMs = serverAudioMs
        self.shadowGateMs = shadowGateMs
        self.bothOpenMs = bothOpenMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requests = requests
    }

    public mutating func add(_ row: CostMinuteRow) {
        wireBytes += row.wireBytes
        audioMs += row.audioMs
        replayBytes += row.replayBytes
        tailBytes += row.tailBytes
        socketAttempts += row.socketAttempts
        socketsOpened += row.socketsOpened
        socketOpenMs += row.socketOpenMs
        serverAudioMs += row.serverAudioMs
        shadowGateMs += row.shadowGateMs
        inputTokens += row.inputTokens
        outputTokens += row.outputTokens
        requests += row.requests
        if let both = row.bothOpenMs {
            bothOpenMs = (bothOpenMs ?? 0) + both
        }
    }
}

public struct RecordedComponent: Sendable, Equatable {
    public var track: String
    public var audioMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var requests: Int
    public var usd: Double?

    public init(
        track: String,
        audioMs: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        requests: Int = 0,
        usd: Double? = nil
    ) {
        self.track = track
        self.audioMs = audioMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.usd = usd
    }
}

public struct CostRollupRow: Sendable, Equatable {
    public var t: String
    public var wallMs: Int
    public var minutes: Int
    public var clean: Bool
    public var recovered: Bool
    public var units: [String: TrackUnits]
    public var usd: Double
    public var usdPerSessionHr: Double
    public var usdIfSocketBilled: Double
    public var shadowUsdPerSessionHr: Double
    /// Present only when some minute named a component the rate card does not price.
    public var unpriced: [String]?
    /// Present only when `record` logged a component other than the session STT id.
    public var recorded: [String: RecordedComponent]?

    public init(
        t: String = "cost.rollup",
        wallMs: Int,
        minutes: Int,
        clean: Bool,
        recovered: Bool,
        units: [String: TrackUnits],
        usd: Double,
        usdPerSessionHr: Double,
        usdIfSocketBilled: Double,
        shadowUsdPerSessionHr: Double,
        unpriced: [String]? = nil,
        recorded: [String: RecordedComponent]? = nil
    ) {
        self.t = t
        self.wallMs = wallMs
        self.minutes = minutes
        self.clean = clean
        self.recovered = recovered
        self.units = units
        self.usd = usd
        self.usdPerSessionHr = usdPerSessionHr
        self.usdIfSocketBilled = usdIfSocketBilled
        self.shadowUsdPerSessionHr = shadowUsdPerSessionHr
        self.unpriced = unpriced
        self.recorded = recorded
    }
}

public struct TrackCost: Sendable, Equatable {
    public var audioMs: Int
    public var usd: Double

    public init(audioMs: Int, usd: Double) {
        self.audioMs = audioMs
        self.usd = usd
    }
}

/// Pull/push readout for Phase 1. `calibrated` is false until the rate card
/// is reconciled, and `usd` is then the pessimistic max, not a bill.
public struct CostSnapshot: Sendable, Equatable {
    public var sessionMs: Int
    public var usd: Double
    public var usdPerSessionHr: Double
    public var perTrack: [String: TrackCost]
    public var rateCardID: String
    public var billingModel: String
    public var calibrated: Bool

    public init(
        sessionMs: Int,
        usd: Double,
        usdPerSessionHr: Double,
        perTrack: [String: TrackCost],
        rateCardID: String,
        billingModel: String,
        calibrated: Bool
    ) {
        self.sessionMs = sessionMs
        self.usd = usd
        self.usdPerSessionHr = usdPerSessionHr
        self.perTrack = perTrack
        self.rateCardID = rateCardID
        self.billingModel = billingModel
        self.calibrated = calibrated
    }
}

public enum CostRow: Sendable, Equatable {
    case session(CostSessionRow)
    case minute(CostMinuteRow)
    case rollup(CostRollupRow)
}

public enum CostPricing {
    /// Session rollup from minute deltas. `usd` uses the card's billing model
    /// on the summed units (uncalibrated = max of the two session totals).
    /// Minute `usd` values are not added up: a per-minute max can exceed the
    /// max of the totals.
    public static func rollup(
        minutes: [CostMinuteRow],
        sttComponent: String,
        wallMs: Int,
        clean: Bool,
        recovered: Bool,
        rateCard: RateCard
    ) -> CostRollupRow {
        var units: [String: TrackUnits] = [:]
        var recorded: [String: RecordedComponent] = [:]
        var minuteIndex: Set<Int> = []
        for row in minutes where row.component == sttComponent {
            minuteIndex.insert(row.m)
            var total = units[row.track] ?? TrackUnits()
            total.add(row)
            units[row.track] = total
        }
        for row in minutes where row.component != sttComponent {
            minuteIndex.insert(row.m)
            let prior = recorded[row.component]
            recorded[row.component] = RecordedComponent(
                track: row.track,
                audioMs: (prior?.audioMs ?? 0) + row.audioMs,
                inputTokens: (prior?.inputTokens ?? 0) + row.inputTokens,
                outputTokens: (prior?.outputTokens ?? 0) + row.outputTokens,
                requests: (prior?.requests ?? 0) + row.requests,
                usd: rateCard.usd(
                    component: row.component,
                    milliseconds: rateCard.billableMs(
                        audioMs: (prior?.audioMs ?? 0) + row.audioMs,
                        socketOpenMs: 0
                    )
                )
            )
        }
        let audioMs = units.values.reduce(0) { $0 + $1.audioMs }
        let socketOpenMs = units.values.reduce(0) { $0 + $1.socketOpenMs }
        let shadowMs = units.values.reduce(0) { $0 + $1.shadowGateMs }
        let sttUSD = rateCard.usd(
            component: sttComponent,
            milliseconds: rateCard.billableMs(audioMs: audioMs, socketOpenMs: socketOpenMs)
        ) ?? 0
        let socketUSD = rateCard.usd(component: sttComponent, milliseconds: socketOpenMs) ?? 0
        let shadowUSD = rateCard.usd(component: sttComponent, milliseconds: shadowMs) ?? 0
        let recordedUSD = recorded.values.reduce(0.0) { $0 + ($1.usd ?? 0) }
        let usd = sttUSD + recordedUSD
        var unpriced = Set<String>()
        for row in minutes where rateCard.contains(row.component) == false {
            unpriced.insert(row.component)
        }
        let unpricedList = unpriced.sorted()
        return CostRollupRow(
            wallMs: wallMs,
            minutes: minuteIndex.count,
            clean: clean,
            recovered: recovered,
            units: units,
            usd: usd,
            usdPerSessionHr: MeteringConstants.perSessionHour(usd: usd, wallMs: wallMs),
            usdIfSocketBilled: socketUSD,
            shadowUsdPerSessionHr: MeteringConstants.perSessionHour(usd: shadowUSD, wallMs: wallMs),
            unpriced: unpricedList.isEmpty ? nil : unpricedList,
            recorded: recorded.isEmpty ? nil : recorded
        )
    }
}

extension CostSessionRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, v, sessionId, app, engine, rateCard, billingModel, startedAt
    }
}

extension CostMinuteRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, m, fromMs, toMs, track, component
        case wireBytes, audioMs, replayBytes, tailBytes
        case socketAttempts, socketsOpened, socketOpenMs, serverAudioMs, shadowGateMs, bothOpenMs
        case inputTokens, outputTokens, requests, usd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decodeIfPresent(String.self, forKey: .t) ?? "cost.min"
        m = try container.decode(Int.self, forKey: .m)
        fromMs = try container.decode(Int.self, forKey: .fromMs)
        toMs = try container.decode(Int.self, forKey: .toMs)
        track = try container.decode(String.self, forKey: .track)
        component = try container.decode(String.self, forKey: .component)
        wireBytes = try container.decodeIfPresent(Int.self, forKey: .wireBytes) ?? 0
        audioMs = try container.decodeIfPresent(Int.self, forKey: .audioMs) ?? 0
        replayBytes = try container.decodeIfPresent(Int.self, forKey: .replayBytes) ?? 0
        tailBytes = try container.decodeIfPresent(Int.self, forKey: .tailBytes) ?? 0
        socketAttempts = try container.decodeIfPresent(Int.self, forKey: .socketAttempts) ?? 0
        socketsOpened = try container.decodeIfPresent(Int.self, forKey: .socketsOpened) ?? 0
        socketOpenMs = try container.decodeIfPresent(Int.self, forKey: .socketOpenMs) ?? 0
        serverAudioMs = try container.decodeIfPresent(Int.self, forKey: .serverAudioMs) ?? 0
        shadowGateMs = try container.decodeIfPresent(Int.self, forKey: .shadowGateMs) ?? 0
        bothOpenMs = try container.decodeIfPresent(Int.self, forKey: .bothOpenMs)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        usd = try container.decodeIfPresent(Double.self, forKey: .usd)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(m, forKey: .m)
        try container.encode(fromMs, forKey: .fromMs)
        try container.encode(toMs, forKey: .toMs)
        try container.encode(track, forKey: .track)
        try container.encode(component, forKey: .component)
        try container.encode(wireBytes, forKey: .wireBytes)
        try container.encode(audioMs, forKey: .audioMs)
        try container.encode(replayBytes, forKey: .replayBytes)
        try container.encode(tailBytes, forKey: .tailBytes)
        try container.encode(socketAttempts, forKey: .socketAttempts)
        try container.encode(socketsOpened, forKey: .socketsOpened)
        try container.encode(socketOpenMs, forKey: .socketOpenMs)
        try container.encode(serverAudioMs, forKey: .serverAudioMs)
        try container.encode(shadowGateMs, forKey: .shadowGateMs)
        try container.encodeIfPresent(bothOpenMs, forKey: .bothOpenMs)
        if inputTokens != 0 { try container.encode(inputTokens, forKey: .inputTokens) }
        if outputTokens != 0 { try container.encode(outputTokens, forKey: .outputTokens) }
        if requests != 0 { try container.encode(requests, forKey: .requests) }
        if let usd {
            try container.encode(usd, forKey: .usd)
        } else {
            try container.encodeNil(forKey: .usd)
        }
    }
}

extension TrackUnits: Codable {
    private enum CodingKeys: String, CodingKey {
        case wireBytes, audioMs, replayBytes, tailBytes
        case socketAttempts, socketsOpened, socketOpenMs, serverAudioMs, shadowGateMs, bothOpenMs
        case inputTokens, outputTokens, requests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wireBytes = try container.decodeIfPresent(Int.self, forKey: .wireBytes) ?? 0
        audioMs = try container.decodeIfPresent(Int.self, forKey: .audioMs) ?? 0
        replayBytes = try container.decodeIfPresent(Int.self, forKey: .replayBytes) ?? 0
        tailBytes = try container.decodeIfPresent(Int.self, forKey: .tailBytes) ?? 0
        socketAttempts = try container.decodeIfPresent(Int.self, forKey: .socketAttempts) ?? 0
        socketsOpened = try container.decodeIfPresent(Int.self, forKey: .socketsOpened) ?? 0
        socketOpenMs = try container.decodeIfPresent(Int.self, forKey: .socketOpenMs) ?? 0
        serverAudioMs = try container.decodeIfPresent(Int.self, forKey: .serverAudioMs) ?? 0
        shadowGateMs = try container.decodeIfPresent(Int.self, forKey: .shadowGateMs) ?? 0
        bothOpenMs = try container.decodeIfPresent(Int.self, forKey: .bothOpenMs)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireBytes, forKey: .wireBytes)
        try container.encode(audioMs, forKey: .audioMs)
        try container.encode(replayBytes, forKey: .replayBytes)
        try container.encode(tailBytes, forKey: .tailBytes)
        try container.encode(socketAttempts, forKey: .socketAttempts)
        try container.encode(socketsOpened, forKey: .socketsOpened)
        try container.encode(socketOpenMs, forKey: .socketOpenMs)
        try container.encode(serverAudioMs, forKey: .serverAudioMs)
        try container.encode(shadowGateMs, forKey: .shadowGateMs)
        try container.encodeIfPresent(bothOpenMs, forKey: .bothOpenMs)
        if inputTokens != 0 { try container.encode(inputTokens, forKey: .inputTokens) }
        if outputTokens != 0 { try container.encode(outputTokens, forKey: .outputTokens) }
        if requests != 0 { try container.encode(requests, forKey: .requests) }
    }
}

extension RecordedComponent: Codable {}

extension CostRollupRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, wallMs, minutes, clean, recovered, units
        case usd, usdPerSessionHr, usdIfSocketBilled, shadowUsdPerSessionHr
        case unpriced, recorded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decodeIfPresent(String.self, forKey: .t) ?? "cost.rollup"
        wallMs = try container.decode(Int.self, forKey: .wallMs)
        minutes = try container.decode(Int.self, forKey: .minutes)
        clean = try container.decode(Bool.self, forKey: .clean)
        recovered = try container.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
        units = try container.decodeIfPresent([String: TrackUnits].self, forKey: .units) ?? [:]
        usd = try container.decodeIfPresent(Double.self, forKey: .usd) ?? 0
        usdPerSessionHr = try container.decodeIfPresent(Double.self, forKey: .usdPerSessionHr) ?? 0
        usdIfSocketBilled = try container.decodeIfPresent(Double.self, forKey: .usdIfSocketBilled) ?? 0
        shadowUsdPerSessionHr = try container.decodeIfPresent(Double.self, forKey: .shadowUsdPerSessionHr) ?? 0
        unpriced = try container.decodeIfPresent([String].self, forKey: .unpriced)
        recorded = try container.decodeIfPresent([String: RecordedComponent].self, forKey: .recorded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(wallMs, forKey: .wallMs)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(clean, forKey: .clean)
        try container.encode(recovered, forKey: .recovered)
        try container.encode(units, forKey: .units)
        try container.encode(usd, forKey: .usd)
        try container.encode(usdPerSessionHr, forKey: .usdPerSessionHr)
        try container.encode(usdIfSocketBilled, forKey: .usdIfSocketBilled)
        try container.encode(shadowUsdPerSessionHr, forKey: .shadowUsdPerSessionHr)
        try container.encodeIfPresent(unpriced, forKey: .unpriced)
        try container.encodeIfPresent(recorded, forKey: .recorded)
    }
}

extension CostRow: Codable {
    private enum CodingKeys: String, CodingKey { case t }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "cost.session":
            self = .session(try CostSessionRow(from: decoder))
        case "cost.min":
            self = .minute(try CostMinuteRow(from: decoder))
        case "cost.rollup":
            self = .rollup(try CostRollupRow(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t,
                in: container,
                debugDescription: "unknown cost row \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .session(let row):
            try row.encode(to: encoder)
        case .minute(let row):
            try row.encode(to: encoder)
        case .rollup(let row):
            try row.encode(to: encoder)
        }
    }
}
