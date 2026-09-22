import AudioCapture
import Foundation
import GrokEngine
import Testing
import TranscriptionEngine

@Test func urlLocksEndpointingSampleRateAndDiarization() {
    let url = GrokWebSocket.url()
    let query = GrokWebSocket.query(url)
    #expect(GrokWebSocket.endpointingMs == 800)
    #expect(query["endpointing"] == "800")
    #expect(query["sample_rate"] == "16000")
    #expect(query["encoding"] == "pcm")
    #expect(query["interim_results"] == "true")
    #expect(query["language"] == "en")
    #expect(query["diarize"] == "true")
    #expect(query["model"] == EngineFactory.grokModelName)
    #expect(url.absoluteString.contains("endpointing=800"))
}

@Test func decodesPartialFinalAndCreated() throws {
    let created = GrokMessages.decode(#"{"type":"transcript.created"}"#)
    #expect(created == .created)

    let partial = GrokMessages.decode(#"""
    {"type":"transcript.partial","text":"hello","is_final":true,"speech_final":true,"start":0.1,"duration":0.4,"words":[{"text":"hello","start":0.1,"end":0.4,"speaker":0,"confidence":0.5}]}
    """#)
    guard case .partial(let transcript) = partial else {
        Issue.record("expected partial")
        return
    }
    #expect(transcript.isFinal)
    #expect(transcript.words.first?.speaker == 0)
    #expect(transcript.words.first?.confidence == 0.5)
    #expect(transcript.text == "hello")

    let done = GrokMessages.decode(#"{"type":"transcript.done","text":"hello","duration":1}"#)
    guard case .done(let final) = done else {
        Issue.record("expected done")
        return
    }
    #expect(final.isFinal)
    #expect(GrokMessages.audioDone == #"{"type":"audio.done"}"#)
}

@Test func backoffDoublesThenCapsAtThirtySeconds() {
    var schedule = BackoffSchedule()
    let expected: [Double] = [1, 2, 4, 8, 16, 30, 30]
    var actual: [Double] = []
    for _ in expected {
        actual.append(seconds(schedule.delay))
        schedule = schedule.advanced()
    }
    #expect(actual == expected)
}

@Test func rebaseAndGapUseSessionTime() {
    let rebase = TimestampRebase(originMs: 1_000)
    #expect(rebase.sessionMs(engineSeconds: 0.2) == 1_200)
    var gap = GapAccount()
    gap.begin(atMs: 41_000)
    let span = gap.end(atMs: 47_210)
    #expect(span?.fromMs == 41_000)
    #expect(span?.toMs == 47_210)
    #expect(gap.end(atMs: 1) == nil)
    #expect(PCMClock.milliseconds(bytesSent: 3_200) == 100)
}

@Test func engineWaitsForCreatedThenSends3200ByteFramesAndAudioDone() async throws {
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "test-key",
        url: GrokWebSocket.url(),
        makeTransport: { transport },
        handshakeTimeout: .seconds(2),
        inboundStall: .seconds(30)
    ))
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    try await engine.send(PCMFrame(track: .system, data: Data(repeating: 7, count: 3_200), hostTime: 0))
    try await Task.sleep(for: .milliseconds(30))
    #expect(transport.binaryCount == 0)
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    try await waitUntil { transport.binaryCount > 0 }
    #expect(transport.firstBinaryCount == 3_200)
    transport.push(.text(#"""
    {"type":"transcript.partial","text":"hello","is_final":true,"speech_final":true,"start":0.0,"duration":0.1,"words":[{"text":"hello","start":0.0,"end":0.1,"speaker":1,"confidence":0.8}]}
    """#))
    var sawFinal = false
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            #expect(transcript.speaker == "S2")
            #expect(transcript.words.first?.w == "hello")
            #expect(transcript.startMs == 0)
            sawFinal = true
            break
        }
    }
    #expect(sawFinal)
    await engine.finish()
    try await waitUntil { transport.sentTexts.contains(GrokMessages.audioDone) }
}

@Test func reconnectEmitsGapAndRebasesWordTimes() async throws {
    let clock = ManualClock()
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "test-key",
        url: GrokWebSocket.url(),
        makeTransport: { transport },
        sleep: { duration in
            clock.advance(ms: Int(seconds(duration) * 1000))
        },
        nowMs: { clock.ms },
        handshakeTimeout: .seconds(2),
        inboundStall: .seconds(30)
    ))
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    try await engine.send(PCMFrame(track: .system, data: Data(count: 3_200), hostTime: 0))
    try await waitUntil { transport.binaryCount == 1 }

    var iterator = engine.events.makeAsyncIterator()
    transport.push(.closed(code: 1006, reason: "drop"))
    transport.push(.text(#"{"type":"transcript.created"}"#))
    var sawGap = false
    var sawDegraded = false
    for _ in 0..<12 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { sawDegraded = true }
        if case .gap(let from, let to) = event {
            sawGap = true
            #expect(to >= from)
        }
        if case .state(.streaming) = event, sawGap { break }
    }
    #expect(sawDegraded)
    #expect(sawGap)
    #expect(transport.connectCount >= 2)

    transport.push(.text(#"""
    {"type":"transcript.partial","text":"again","is_final":true,"start":0.0,"duration":0.1,"words":[{"text":"again","start":0.0,"end":0.1}]}
    """#))
    var rebased = false
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            // Backoff advanced the session clock by 1s. The new socket lands there,
            // not on the byte cursor from before the drop.
            #expect(transcript.startMs == 1_000)
            rebased = true
            break
        }
    }
    #expect(rebased)
    await engine.finish()
}

@Test func stalledSocketReconnectsReplaysAudioAndEmitsAGap() async throws {
    let clock = ManualClock()
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "test-key",
        url: GrokWebSocket.url(),
        makeTransport: { transport },
        sleep: { duration in
            clock.advance(ms: Int(seconds(duration) * 1000))
        },
        nowMs: { clock.ms },
        handshakeTimeout: .seconds(2),
        inboundStall: .milliseconds(80)
    ))
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    let frame = Data(repeating: 9, count: 3_200)
    try await engine.send(PCMFrame(track: .system, data: frame, hostTime: 0))
    try await waitUntil { transport.binaryCount == 1 }
    try await waitUntil { transport.connectCount >= 2 }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    var sawGap = false
    var sawDegraded = false
    for _ in 0..<16 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { sawDegraded = true }
        if case .gap = event { sawGap = true }
        if case .state(.streaming) = event, sawGap { break }
    }
    #expect(sawDegraded)
    #expect(sawGap)
    try await waitUntil { transport.binaryCount >= 2 }
    #expect(transport.binary(at: 1) == frame)
    await engine.finish()
}

@Test func chunkFinalsAreKeptAndTheStitchedSpeechFinalIsDropped() async throws {
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: testConfig(transport))
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    transport.push(.text(partial(text: "alpha", start: 0, duration: 3, isFinal: true, speechFinal: false)))
    transport.push(.text(partial(text: "beta", start: 3, duration: 3, isFinal: true, speechFinal: false)))
    transport.push(.text(partial(text: "alpha beta", start: 0, duration: 6, isFinal: true, speechFinal: true)))
    transport.push(.text(#"{"type":"transcript.done","text":"alpha beta","duration":6}"#))
    var finals: [String] = []
    for _ in 0..<12 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            finals.append(transcript.text)
            if finals.count == 2 { break }
        }
    }
    #expect(finals == ["alpha", "beta"])
    let extra = Task { await iterator.next() }
    try await Task.sleep(for: .milliseconds(80))
    await engine.finish()
    if case .transcript(let transcript) = await extra.value, transcript.kind == .final {
        Issue.record("stitched final was emitted: \(transcript.text)")
    }
}

@Test func emptyFinalsAreDroppedAndALaterUtteranceIsKept() async throws {
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: testConfig(transport))
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    transport.push(.text(partial(text: "  ", start: 0, duration: 2, isFinal: true, speechFinal: true)))
    transport.push(.text(partial(text: "", start: 2, duration: 2, isFinal: true, speechFinal: false)))
    transport.push(.text(partial(text: "hello", start: 4, duration: 1, isFinal: true, speechFinal: true)))
    var finals: [String] = []
    for _ in 0..<10 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            finals.append(transcript.text)
            break
        }
    }
    #expect(finals == ["hello"])
    await engine.finish()
}

@Test func transcriptDoneAloneIsTheFinalWhenNothingElseWasCommitted() async throws {
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .microphone, configuration: testConfig(transport))
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .microphone) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    transport.push(.text(#"{"type":"transcript.done","text":"only tail","duration":1.5}"#))
    var finals: [String] = []
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            finals.append(transcript.text)
            break
        }
    }
    #expect(finals == ["only tail"])
    await engine.finish()
}

@Test func missingAPIKeyFailsLoud() async {
    let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "",
        url: GrokWebSocket.url(),
        makeTransport: { ScriptedTransport() }
    ))
    await #expect(throws: EngineError.missingAPIKey) {
        try await engine.connect(track: .system)
    }
}

@Test func registeredGrokBuilderIsWhatTheFactoryReturns() throws {
    GrokEngineBootstrap.install()
    let engine = try EngineFactory.make(track: .microphone, environment: ["CATCHER_ENGINE": "grok"])
    #expect(String(describing: type(of: engine)).contains("GrokEngine"))
}

private func testConfig(_ transport: ScriptedTransport) -> GrokEngineConfiguration {
    GrokEngineConfiguration(
        apiKey: "test-key",
        url: GrokWebSocket.url(),
        makeTransport: { transport },
        handshakeTimeout: .seconds(2)
    )
}

private func partial(text: String, start: Double, duration: Double, isFinal: Bool, speechFinal: Bool) -> String {
    #"{"type":"transcript.partial","text":"\#(text)","is_final":\#(isFinal),"speech_final":\#(speechFinal),"start":\#(start),"duration":\#(duration)}"#
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func waitUntil(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting")
}

private final class ManualClock: @unchecked Sendable {
    var ms = 0
    func advance(ms: Int) { self.ms += ms }
}

private final class ScriptedTransport: GrokTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<GrokSocketEvent, Error>] = []
    private var waiters: [UUID: CheckedContinuation<GrokSocketEvent, Error>] = [:]
    private var binaries: [Data] = []
    private var texts: [String] = []
    private(set) var connectCount = 0

    var binaryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return binaries.count
    }

    var firstBinaryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return binaries.first?.count ?? 0
    }

    func binary(at index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard binaries.indices.contains(index) else { return nil }
        return binaries[index]
    }

    var sentTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }

    func connect(url: URL, authorizationBearer: String) async throws {
        noteConnect()
    }

    func sendText(_ text: String) async throws {
        noteText(text)
    }

    func sendBinary(_ data: Data) async throws {
        noteBinary(data)
    }

    private func noteConnect() {
        lock.lock()
        connectCount += 1
        lock.unlock()
    }

    private func noteText(_ text: String) {
        lock.lock()
        texts.append(text)
        lock.unlock()
    }

    private func noteBinary(_ data: Data) {
        lock.lock()
        binaries.append(data)
        lock.unlock()
    }

    func close() async {
        lock.lock()
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: .closed(code: 1006, reason: "stalled"))
        }
    }

    func cancel(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }

    func push(_ event: GrokSocketEvent) {
        lock.lock()
        if let id = waiters.keys.first, let waiter = waiters.removeValue(forKey: id) {
            lock.unlock()
            waiter.resume(returning: event)
            return
        }
        queue.append(.success(event))
        lock.unlock()
    }

    func receive() async throws -> GrokSocketEvent {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GrokSocketEvent, Error>) in
                lock.lock()
                if !queue.isEmpty {
                    let item = queue.removeFirst()
                    lock.unlock()
                    continuation.resume(with: item)
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancel(id)
        }
    }
}
