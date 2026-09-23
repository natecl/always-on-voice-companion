import Foundation
import Metering
import Testing

@Test func costRowsRoundTripAndNullUsdStaysNull() throws {
    let minute = CostMinuteRow(
        m: 0,
        fromMs: 0,
        toMs: 60_000,
        track: "system",
        component: "llm.notes",
        inputTokens: 10,
        usd: nil
    )
    let encoded = try JSONEncoder().encode(CostRow.minute(minute))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["usd"] is NSNull)
    #expect(object["bothOpenMs"] == nil)
    #expect(object["inputTokens"] as? Int == 10)
    let decoded = try JSONDecoder().decode(CostRow.self, from: encoded)
    #expect(decoded == .minute(minute))

    let mic = CostMinuteRow(
        m: 0,
        fromMs: 0,
        toMs: 60_000,
        track: "microphone",
        component: MeterComponent.stream,
        wireBytes: 1_920_000,
        audioMs: 60_000,
        bothOpenMs: 18_400,
        usd: 0.0033333333333333335
    )
    let micData = try JSONEncoder().encode(CostRow.minute(mic))
    let micObject = try #require(JSONSerialization.jsonObject(with: micData) as? [String: Any])
    #expect(micObject["bothOpenMs"] as? Int == 18_400)
    let micDecoded = try JSONDecoder().decode(CostRow.self, from: micData)
    #expect(micDecoded == .minute(mic))
}

@Test func minuteDeltasSumToTheRollupAndPartialChunksStayExact() async {
    let meter = CostMeter(component: MeterComponent.stream, intervalMs: 10)
    let first = await meter.takeDueMinute(atMs: 10, counters: [
        "system": MeterCounters(wireBytes: 100),
        "microphone": .zero,
    ])
    let second = await meter.takeDueMinute(atMs: 20, counters: [
        "system": MeterCounters(wireBytes: 128),
        "microphone": .zero,
    ])
    let system = (first + second).filter { $0.track == "system" }
    #expect(system.map(\.audioMs) == [3, 1])
    #expect(system.map(\.m) == [0, 1])
    #expect(system[0].toMs == system[1].fromMs)
    let rollup = await meter.rollup(wallMs: 20, clean: true, recovered: false)
    #expect(rollup.units["system"]?.audioMs == 4)
    #expect(rollup.units["system"]?.wireBytes == 128)
    #expect(rollup.minutes == 2)
}

@Test func uncalibratedSessionUsesTheMaxOfTheTotals() async {
    let hour = 3_600_000
    let bytes = hour * MeteringConstants.bytesPerMillisecond
    let meter = CostMeter(component: MeterComponent.stream, intervalMs: hour)
    _ = await meter.takeDueMinute(atMs: hour, counters: [
        "system": MeterCounters(wireBytes: bytes, socketOpenMs: 0),
        "microphone": MeterCounters(wireBytes: 0, socketOpenMs: hour),
    ])
    let rollup = await meter.rollup(wallMs: hour, clean: true, recovered: false)
    // Per track the max is an hour each. The session max of the two totals is one hour.
    #expect(abs(rollup.usd - 0.20) < 1e-9)
    #expect(abs(rollup.usdPerSessionHr - 0.20) < 1e-9)
    #expect(abs(rollup.usdIfSocketBilled - 0.20) < 1e-9)
    #expect(rollup.units["system"]?.audioMs == hour)
    #expect(rollup.units["microphone"]?.socketOpenMs == hour)

    let audioCard = RateCard(
        id: RateCard.bundled.id,
        billingModel: .audio,
        components: RateCard.bundled.components,
        calibrationStatus: "pending"
    )
    let audioMeter = CostMeter(component: MeterComponent.stream, rateCard: audioCard, intervalMs: hour)
    _ = await audioMeter.takeDueMinute(atMs: hour, counters: [
        "system": MeterCounters(wireBytes: bytes),
        "microphone": MeterCounters(socketOpenMs: hour),
    ])
    let audio = await audioMeter.rollup(wallMs: hour, clean: true, recovered: false)
    #expect(abs(audio.usd - 0.20) < 1e-9)
    #expect(abs(audio.usdIfSocketBilled - 0.20) < 1e-9)

    let socketCard = RateCard(
        id: RateCard.bundled.id,
        billingModel: .socket,
        components: RateCard.bundled.components,
        calibrationStatus: "reconciled"
    )
    #expect(socketCard.isCalibrated)
    #expect(RateCard.bundled.isCalibrated == false)
    let socketMeter = CostMeter(component: MeterComponent.stream, rateCard: socketCard, intervalMs: hour)
    _ = await socketMeter.takeDueMinute(atMs: hour, counters: [
        "system": MeterCounters(wireBytes: bytes, socketOpenMs: 0),
        "microphone": .zero,
    ])
    let socket = await socketMeter.rollup(wallMs: hour, clean: true, recovered: false)
    #expect(socket.usd == 0)
    let snap = await socketMeter.snapshot(atMs: hour, counters: [
        "system": MeterCounters(wireBytes: bytes),
        "microphone": .zero,
    ])
    #expect(snap.calibrated)
    #expect(snap.billingModel == "socket")
    #expect(snap.usd == 0)
    #expect(snap.perTrack["system"]?.audioMs == hour)
}

@Test func oneStreamMinuteMatchesTheListedRate() async throws {
    let meter = CostMeter(component: MeterComponent.stream, intervalMs: 60_000)
    let bytes = 60_000 * MeteringConstants.bytesPerMillisecond
    let rows = await meter.takeDueMinute(atMs: 60_000, counters: [
        "system": MeterCounters(wireBytes: bytes, socketOpenMs: 59_588),
        "microphone": .zero,
    ])
    let system = try #require(rows.first { $0.track == "system" })
    #expect(system.audioMs == 60_000)
    #expect(abs((system.usd ?? 0) - 0.0033333333333333335) < 1e-12)
    #expect(rows.first { $0.track == "microphone" }?.bothOpenMs == 0)
    #expect(system.bothOpenMs == nil)
}

@Test func unpricedComponentIsNullAndDoesNotEnterTheSessionUsd() async throws {
    let meter = CostMeter(component: MeterComponent.stub, intervalMs: 1_000)
    await meter.record(component: "llm.notes", track: nil, unit: .inputTokens, amount: 2_000)
    await meter.record(component: MeterComponent.stream, track: "system", unit: .audioMs, amount: 9_999)
    let rows = await meter.takeDueMinute(atMs: 1_000, counters: [:])
    let notes = try #require(rows.first { $0.component == "llm.notes" })
    #expect(notes.usd == nil)
    #expect(notes.inputTokens == 2_000)
    #expect(notes.track == "session")
    #expect(rows.contains { $0.component == MeterComponent.stream } == false)
    let rollup = await meter.rollup(wallMs: 1_000, clean: true, recovered: false)
    #expect(rollup.usd == 0)
    #expect(rollup.unpriced == ["llm.notes"])
    let encoded = try JSONEncoder().encode(CostRow.minute(notes))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["usd"] is NSNull)
}

@Test func shadowGateCountsHoldPreRollHangoverAndEchoOverlap() {
    var gate = ShadowGate()
    for at in stride(from: 0, through: 1_700, by: 100) {
        let systemLoud = at == 0 || at == 100
        let micLoud = at == 500 || at == 600
        gate.observe(track: "system", pcm16: systemLoud ? tone() : silence(), atMs: at)
        gate.observe(track: "microphone", pcm16: micLoud ? tone() : silence(), atMs: at)
    }
    #expect(gate.openMs(track: "system", fromMs: 0, toMs: 10_000) == 1_200)
    #expect(gate.openMs(track: "microphone", fromMs: 0, toMs: 10_000) == 1_500)
    #expect(gate.bothOpenMs(fromMs: 0, toMs: 10_000) == 1_000)
    #expect(gate.bothOpenMs(fromMs: 0, toMs: 200) == 0)
    #expect(gate.openMs(track: "system", fromMs: 0, toMs: 200) == 200)

    var reset = ShadowGate()
    reset.observe(track: "system", pcm16: tone(), atMs: 0)
    reset.observe(track: "system", pcm16: silence(), atMs: 100)
    reset.observe(track: "system", pcm16: tone(), atMs: 200)
    #expect(reset.openMs(track: "system", fromMs: 0, toMs: 10_000) == 0)

    var direct = ShadowGate()
    let dc = Data(repeating: 0x10, count: 3_200)
    direct.observe(track: "system", pcm16: dc, atMs: 0)
    direct.observe(track: "system", pcm16: dc, atMs: 100)
    #expect(direct.openMs(track: "system", fromMs: 0, toMs: 10_000) == 0)
    #expect(ShadowGate.acRMS(dc) < 0.02)
    #expect(ShadowGate.acRMS(tone()) > 0.02)
}

@Test func recoverAllClosesATruncatedLogAndDoesNotRewriteARollup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catcher-cost-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = CostLog.fileURL(in: directory)
    let minute = CostMinuteRow(
        m: 0,
        fromMs: 0,
        toMs: 60_000,
        track: "system",
        component: MeterComponent.stream,
        wireBytes: 1_920_000,
        audioMs: 60_000,
        usd: 0.0033333333333333335
    )
    let session = CostSessionRow(
        sessionId: "s",
        app: "0.0.1+test",
        engine: "grok-voice-transcribe-2.0",
        rateCard: RateCard.bundled.id,
        billingModel: "uncalibrated",
        startedAt: "2026-09-23T00:00:00Z"
    )
    var data = try JSONEncoder().encode(CostRow.session(session))
    data.append(0x0A)
    data.append(try JSONEncoder().encode(CostRow.minute(minute)))
    data.append(0x0A)
    data.append(Data("{\"t\":\"cost.min\",\"m\":1,\"wireBy".utf8))
    try data.write(to: url)
    #expect(try CostLog.recoverAll(root: root) == 1)
    let repaired = try CostLog.read(url: url)
    #expect(repaired.droppedTruncatedTail == false)
    guard case .rollup(let rollup) = repaired.rows.last else {
        Issue.record("missing rollup")
        return
    }
    #expect(rollup.recovered)
    #expect(rollup.clean == false)
    #expect(rollup.wallMs == 60_000)
    #expect(rollup.units["system"]?.audioMs == 60_000)
    #expect(abs(rollup.usd - 0.0033333333333333335) < 1e-9)
    let before = try Data(contentsOf: url)
    #expect(try CostLog.recoverAll(root: root) == 0)
    #expect(try Data(contentsOf: url) == before)
}

@Test func rateCardAndMeteringConstantsMatchTheHarnessFiles() throws {
    let rates = try harnessJSON("rates.json")
    #expect(rates["id"] as? String == RateCard.bundled.id)
    #expect(rates["billingModel"] as? String == RateCard.bundled.billingModel.rawValue)
    let components = try #require(rates["components"] as? [String: Any])
    let stream = try #require(components[MeterComponent.stream] as? [String: Any])
    let stub = try #require(components[MeterComponent.stub] as? [String: Any])
    #expect(jsonNumber(stream["usdPerHour"]) == RateCard.bundled.components[MeterComponent.stream]?.usdPerHour)
    #expect(stream["unit"] as? String == "audioMs")
    #expect(jsonNumber(stub["usdPerHour"]) == 0)
    let calibration = try #require(rates["calibration"] as? [String: Any])
    #expect(calibration["status"] as? String == RateCard.bundled.calibrationStatus)
    #expect(calibration["evidence"] is NSNull)

    let metering = try harnessJSON("metering.json")
    #expect(jsonNumber(metering["b1UsdPerSessionHr"]) == MeteringConstants.b1UsdPerSessionHr)
    #expect(jsonNumber(metering["sttBudgetUsdPerSessionHr"]) == MeteringConstants.sttBudgetUsdPerSessionHr)
    #expect(jsonNumber(metering["phase3ReserveUsdPerSessionHr"]) == MeteringConstants.phase3ReserveUsdPerSessionHr)
    let budget = MeteringConstants.sttBudgetUsdPerSessionHr + MeteringConstants.phase3ReserveUsdPerSessionHr
    #expect(abs(budget - MeteringConstants.b1UsdPerSessionHr) < 1e-9)
    #expect(jsonNumber(metering["b1MinSessionMs"]) == Double(MeteringConstants.b1MinSessionMs))
    #expect(jsonNumber(metering["b1MinSystemSpeechDuty"]) == MeteringConstants.b1MinSystemSpeechDuty)
    #expect(jsonNumber(metering["serverUnderMeterTolerance"]) == MeteringConstants.serverUnderMeterTolerance)
    #expect(jsonNumber(metering["reconcileTolerance"]) == MeteringConstants.reconcileTolerance)
    let shadow = try #require(metering["shadowGate"] as? [String: Any])
    let floor = jsonNumber(shadow["rmsFloor"]) ?? -1
    #expect(abs(floor - Double(MeteringConstants.shadowRmsFloor)) < 1e-6)
    #expect(jsonNumber(shadow["holdMs"]) == Double(MeteringConstants.shadowHoldMs))
    #expect(jsonNumber(shadow["preRollMs"]) == Double(MeteringConstants.shadowPreRollMs))
    #expect(jsonNumber(shadow["hangoverMs"]) == Double(MeteringConstants.shadowHangoverMs))
}

private func tone() -> Data {
    var data = Data(count: 3_200)
    data.withUnsafeMutableBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for index in 0..<1_600 {
            let value = sin(Float(index) * 0.4) * 0.2
            samples[index] = Int16(value * 32_767)
        }
    }
    return data
}

private func silence() -> Data {
    Data(count: 3_200)
}

private func harnessJSON(_ name: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("harness/\(name)")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}

private func jsonNumber(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}
