import Foundation

/// Per-session cost. Minute rows are deltas. The rollup sums those deltas and
/// prices the sums, so a per-minute pessimistic max cannot inflate the session.
public actor CostMeter {
    public let component: String
    public let rateCard: RateCard
    private var gate: ShadowGate
    private let intervalMs: Int
    private let tracks: [String]
    private var coveredMs = 0
    private var nextDueMs: Int
    private var sealed = false
    private var minuteOrdinal = 0
    private var lastCounters: [String: MeterCounters] = [:]
    private var minutes: [CostMinuteRow] = []
    private var recorded: [RecordKey: Int] = [:]
    private var recordedSampled: [RecordKey: Int] = [:]

    private struct RecordKey: Hashable, Sendable {
        var component: String
        var track: String
        var unit: MeterUnit
    }

    public init(
        component: String,
        rateCard: RateCard = .bundled,
        gate: ShadowGate = ShadowGate(),
        intervalMs: Int = 60_000,
        tracks: [String] = ["system", "microphone"]
    ) {
        self.component = component
        self.rateCard = rateCard
        self.gate = gate
        self.intervalMs = max(1, intervalMs)
        self.tracks = tracks
        self.nextDueMs = max(1, intervalMs)
    }

    public func sessionRow(id: String, app: String, engine: String, startedAt: String) -> CostSessionRow {
        CostSessionRow(
            sessionId: id,
            app: app,
            engine: engine,
            rateCard: rateCard.id,
            billingModel: rateCard.billingModel.rawValue,
            startedAt: startedAt
        )
    }

    public func observeFrame(track: String, pcm16: Data, atMs: Int) {
        gate.observe(track: track, pcm16: pcm16, atMs: atMs)
    }

    /// Phase 3 hook. `stt.stream` / `stt.stub` are owned by engine counters;
    /// recording them here as well would double-count, so those ids are ignored.
    /// A component missing from the rate card is logged with `usd: null`.
    public func record(component: String, track: String?, unit: MeterUnit, amount: Int) {
        guard component != MeterComponent.stream, component != MeterComponent.stub else { return }
        guard amount != 0 else { return }
        let key = RecordKey(component: component, track: track ?? "session", unit: unit)
        recorded[key, default: 0] += amount
    }

    /// The minute that came due at `atMs`, or nothing if the boundary is still ahead.
    /// A clock jump of more than one interval becomes one wide minute: the
    /// counters have no samples inside the jump, so empty minutes would be a lie.
    public func takeDueMinute(atMs: Int, counters: [String: MeterCounters]) -> [CostMinuteRow] {
        guard !sealed, atMs >= nextDueMs else { return [] }
        let end = (atMs - nextDueMs) >= intervalMs ? atMs : nextDueMs
        return emit(from: coveredMs, to: end, counters: counters)
    }

    /// Milliseconds until the next minute boundary. Zero means the meter is sealed.
    public func millisecondsUntilDue(now: Int) -> Int {
        if sealed { return 0 }
        if now >= nextDueMs { return 1 }
        return nextDueMs - now
    }

    /// The partial minute at close. Seals the meter; later `takeDueMinute` is empty.
    public func takeRemainder(atMs: Int, counters: [String: MeterCounters]) -> [CostMinuteRow] {
        guard !sealed else { return [] }
        sealed = true
        guard atMs > coveredMs else { return [] }
        return emit(from: coveredMs, to: atMs, counters: counters)
    }

    public func rollup(wallMs: Int, clean: Bool, recovered: Bool) -> CostRollupRow {
        CostPricing.rollup(
            minutes: minutes,
            sttComponent: component,
            wallMs: wallMs,
            clean: clean,
            recovered: recovered,
            rateCard: rateCard
        )
    }

    /// Live totals from the counters, including the minute that has not closed.
    public func snapshot(atMs: Int, counters: [String: MeterCounters]) -> CostSnapshot {
        var perTrack: [String: TrackCost] = [:]
        var audio = 0
        var socket = 0
        for track in tracks {
            let current = counters[track] ?? .zero
            audio += current.audioMs
            socket += current.socketOpenMs
            let trackUSD = rateCard.usd(
                component: component,
                milliseconds: rateCard.billableMs(audioMs: current.audioMs, socketOpenMs: current.socketOpenMs)
            ) ?? 0
            perTrack[track] = TrackCost(audioMs: current.audioMs, usd: trackUSD)
        }
        let stt = rateCard.usd(
            component: component,
            milliseconds: rateCard.billableMs(audioMs: audio, socketOpenMs: socket)
        ) ?? 0
        let extra = recordedUSD(rateCard: rateCard)
        let usd = stt + extra
        return CostSnapshot(
            sessionMs: max(0, atMs),
            usd: usd,
            usdPerSessionHr: MeteringConstants.perSessionHour(usd: usd, wallMs: atMs),
            perTrack: perTrack,
            rateCardID: rateCard.id,
            billingModel: rateCard.billingModel.rawValue,
            calibrated: rateCard.isCalibrated
        )
    }

    private func emit(from: Int, to: Int, counters: [String: MeterCounters]) -> [CostMinuteRow] {
        guard to > from else { return [] }
        var rows: [CostMinuteRow] = []
        let both = gate.bothOpenMs(fromMs: from, toMs: to)
        for track in tracks {
            let current = counters[track] ?? .zero
            let previous = lastCounters[track] ?? .zero
            let audio = nonNegative(current.audioMs - previous.audioMs)
            let socket = nonNegative(current.socketOpenMs - previous.socketOpenMs)
            let row = CostMinuteRow(
                m: minuteOrdinal,
                fromMs: from,
                toMs: to,
                track: track,
                component: component,
                wireBytes: nonNegative(current.wireBytes - previous.wireBytes),
                audioMs: audio,
                replayBytes: nonNegative(current.replayBytes - previous.replayBytes),
                tailBytes: nonNegative(current.tailBytes - previous.tailBytes),
                socketAttempts: nonNegative(current.socketAttempts - previous.socketAttempts),
                socketsOpened: nonNegative(current.socketsOpened - previous.socketsOpened),
                socketOpenMs: socket,
                serverAudioMs: nonNegative(current.serverAudioMs - previous.serverAudioMs),
                shadowGateMs: gate.openMs(track: track, fromMs: from, toMs: to),
                bothOpenMs: track == "microphone" ? both : nil,
                usd: rateCard.usd(
                    component: component,
                    milliseconds: rateCard.billableMs(audioMs: audio, socketOpenMs: socket)
                )
            )
            rows.append(row)
            lastCounters[track] = current
        }
        var seen: [RecordKey: Int] = [:]
        for (key, total) in recorded {
            let delta = nonNegative(total - (recordedSampled[key] ?? 0))
            seen[key] = total
            guard delta > 0 else { continue }
            var audio = 0
            var tokensIn = 0
            var tokensOut = 0
            var requests = 0
            switch key.unit {
            case .audioMs: audio = delta
            case .inputTokens: tokensIn = delta
            case .outputTokens: tokensOut = delta
            case .requests: requests = delta
            }
            rows.append(CostMinuteRow(
                m: minuteOrdinal,
                fromMs: from,
                toMs: to,
                track: key.track,
                component: key.component,
                audioMs: audio,
                inputTokens: tokensIn,
                outputTokens: tokensOut,
                requests: requests,
                usd: rateCard.usd(
                    component: key.component,
                    milliseconds: rateCard.billableMs(audioMs: audio, socketOpenMs: 0)
                )
            ))
        }
        recordedSampled = seen
        minutes.append(contentsOf: rows)
        coveredMs = to
        nextDueMs = to + intervalMs
        minuteOrdinal += 1
        return rows
    }

    private func recordedUSD(rateCard: RateCard) -> Double {
        var totals: [String: Int] = [:]
        for (key, total) in recorded where key.unit == .audioMs {
            totals[key.component, default: 0] += total
        }
        return totals.reduce(0.0) { partial, item in
            partial + (rateCard.usd(
                component: item.key,
                milliseconds: rateCard.billableMs(audioMs: item.value, socketOpenMs: 0)
            ) ?? 0)
        }
    }

    private func nonNegative(_ value: Int) -> Int { max(0, value) }
}
