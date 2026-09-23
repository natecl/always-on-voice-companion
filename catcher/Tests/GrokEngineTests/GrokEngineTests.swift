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

/// Two transport profiles for every reconnect test. `.friendly` is a socket
/// whose `close()` returns and wakes `receive`. `.macParked` is Mac
/// `URLSession` under a `pf` drop: `close()` and `cancel()` never return or
/// wake the parked `receive`, and the in-window retry's connect parks too.
/// A new reconnect test that only passes on `.friendly` is a review blocker.
/// Both are Linux fakes; neither is Mac evidence.
enum TransportProfile: String, CaseIterable, Sendable, CustomStringConvertible {
    case friendly
    case macParked

    var description: String { rawValue }

    /// The socket that finally resumes: the parked profile burns one retry.
    var resumeIndex: Int { self == .friendly ? 1 : 2 }
    /// Session clock at that socket's origin: 1 s backoff, plus 2 s after the parked retry.
    var resumeOriginMs: Int { self == .friendly ? 1_000 : 3_000 }
    var handshakeTimeout: Duration { self == .friendly ? .seconds(2) : .milliseconds(400) }

    func configure(_ index: Int, _ socket: ScriptedTransport) {
        guard self == .macParked, index < resumeIndex else { return }
        socket.wakeReceiveOnClose = false
        socket.ignoreReceiveCancel = true
        socket.hangClose = true
        if index >= 1 {
            socket.hangConnect = true
        }
    }
}

private let created = GrokSocketEvent.text(#"{"type":"transcript.created"}"#)

private final class ReconnectRig: @unchecked Sendable {
    let supply = SocketSupply()
    let clock = ManualClock()
    let engine: GrokEngine
    let profile: TransportProfile

    init(
        profile: TransportProfile,
        inboundStall: Duration = .seconds(30),
        handshakeTimeout: Duration? = nil,
        configure: @escaping (Int, ScriptedTransport) -> Void = { _, _ in }
    ) {
        self.profile = profile
        let supply = supply
        let clock = clock
        supply.configure = { index, socket in
            profile.configure(index, socket)
            configure(index, socket)
        }
        engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
            apiKey: "test-key",
            url: GrokWebSocket.url(),
            makeTransport: { supply.make() },
            sleep: { duration in
                clock.advance(ms: Int(seconds(duration) * 1000))
            },
            nowMs: { clock.ms },
            handshakeTimeout: handshakeTimeout ?? profile.handshakeTimeout,
            inboundStall: inboundStall
        ))
    }

    func socket(_ index: Int) async throws -> ScriptedTransport {
        try await waitUntil { self.supply.count > index }
        return try #require(supply.socket(index))
    }

    func connected() async throws -> ScriptedTransport {
        let connecting = Task { try await engine.connect(track: .system) }
        let first = try await socket(0)
        first.push(created)
        try await connecting.value
        return first
    }

    func releaseAll() {
        for index in 0..<supply.count {
            supply.socket(index)?.release()
        }
    }
}

@Test(arguments: TransportProfile.allCases)
func reconnectEmitsGapAndRebasesWordTimes(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile) { index, socket in
        if index == profile.resumeIndex { socket.push(created) }
    }
    let first = try await rig.connected()
    try await rig.engine.send(PCMFrame(track: .system, data: Data(count: 3_200), hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }

    var iterator = rig.engine.events.makeAsyncIterator()
    first.push(.closed(code: 1006, reason: "drop"))
    var sawGap = false
    var sawDegraded = false
    for _ in 0..<24 {
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
    let resumed = try await rig.socket(profile.resumeIndex)

    resumed.push(.text(#"""
    {"type":"transcript.partial","text":"again","is_final":true,"start":0.0,"duration":0.1,"words":[{"text":"again","start":0.0,"end":0.1}]}
    """#))
    var rebased = false
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            // Backoff advanced the session clock. The new socket lands there,
            // not on the byte cursor from before the drop.
            #expect(transcript.startMs == profile.resumeOriginMs)
            rebased = true
            break
        }
    }
    #expect(rebased)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func postResumeFinalIsQueuedBeforeStreamingAndNotBeforeTheGap(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile) { index, socket in
        if index == profile.resumeIndex {
            socket.push(created)
            socket.push(.text(partial(text: "after", start: 0.0, duration: 0.2, isFinal: true, speechFinal: true)))
        }
    }
    let first = try await rig.connected()
    try await rig.engine.send(PCMFrame(track: .system, data: Data(count: 3_200), hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }

    var iterator = rig.engine.events.makeAsyncIterator()
    first.push(.closed(code: 1006, reason: "drop"))

    var order: [String] = []
    var gapTo = 0
    var segStart = -1
    var degraded = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        switch event {
        case .state(.degraded):
            // The parked profile announces each retry; the chain is one degrade.
            if !degraded { order.append("degraded") }
            degraded = true
        case .transcript(let transcript) where degraded && transcript.kind == .final:
            order.append("seg")
            segStart = transcript.startMs
        case .gap(_, let to) where degraded:
            order.append("gap")
            gapTo = to
        case .state(.streaming) where degraded:
            order.append("streaming")
        default:
            break
        }
        if order.last == "streaming" { break }
    }
    #expect(order == ["degraded", "seg", "gap", "streaming"])
    #expect(segStart >= gapTo)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func reconnectSendsTheShortTailTheChunkPumpLeftBehind(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile) { index, socket in
        if index == profile.resumeIndex { socket.push(created) }
    }
    let first = try await rig.connected()
    let tail = Data(repeating: 5, count: 100)
    try await rig.engine.send(PCMFrame(track: .system, data: tail, hostTime: 0))
    try await Task.sleep(for: .milliseconds(30))
    #expect(first.binaryCount == 0)

    var iterator = rig.engine.events.makeAsyncIterator()
    first.push(.closed(code: 1006, reason: "drop"))
    var sawDegraded = false
    var sawStreaming = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { sawDegraded = true }
        if case .state(.streaming) = event, sawDegraded {
            sawStreaming = true
            break
        }
    }
    #expect(sawStreaming)
    let resumed = try await rig.socket(profile.resumeIndex)
    try await waitUntil { resumed.binaryCount >= 1 }
    #expect(resumed.binaryCount == 1)
    #expect(resumed.binary(at: 0) == tail)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func stalledSocketReconnectsReplaysAudioAndEmitsAGap(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile, inboundStall: .milliseconds(80)) { index, socket in
        if index == profile.resumeIndex { socket.push(created) }
    }
    var iterator = rig.engine.events.makeAsyncIterator()
    let first = try await rig.connected()
    let frame = Data(repeating: 9, count: 3_200)
    try await rig.engine.send(PCMFrame(track: .system, data: frame, hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    var sawGap = false
    var sawDegraded = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { sawDegraded = true }
        if case .gap = event { sawGap = true }
        if case .state(.streaming) = event, sawGap { break }
    }
    #expect(sawDegraded)
    #expect(sawGap)
    let resumed = try await rig.socket(profile.resumeIndex)
    try await waitUntil { resumed.binaryCount >= 1 }
    #expect(resumed.binary(at: 0) == frame)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func resumeReportsTheBacklogAndItsFirstFinalIsBacklog(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile)
    let first = try await rig.connected()
    #expect(await rig.engine.snapshot().lastResumeBacklogMs == 0)
    try await rig.engine.send(PCMFrame(track: .system, data: Data(count: 3_200), hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    var iterator = rig.engine.events.makeAsyncIterator()
    first.push(.closed(code: 1006, reason: "drop"))
    let resumed = try await rig.socket(profile.resumeIndex)
    // 1 s of audio captured during the outage, queued behind the 100 ms replay.
    for _ in 0..<10 {
        try await rig.engine.send(PCMFrame(track: .system, data: Data(count: 3_200), hostTime: 0))
    }
    resumed.push(created)
    var streamingAfterDrop = false
    var degraded = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { degraded = true }
        if case .state(.streaming) = event, degraded {
            streamingAfterDrop = true
            break
        }
    }
    #expect(streamingAfterDrop)
    let backlog = await rig.engine.snapshot().lastResumeBacklogMs
    #expect(backlog >= 1_100)
    resumed.push(.text(partial(text: "backlog words", start: 0.0, duration: 0.5, isFinal: true, speechFinal: true)))
    var firstFinal: TranscriptEvent?
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            firstFinal = transcript
            break
        }
    }
    // The first post-resume final is backlog audio, so it lands inside
    // [origin, origin + backlogMs). A grader must not count it as live.
    let start = try #require(firstFinal?.startMs)
    #expect(start >= profile.resumeOriginMs)
    #expect(start < profile.resumeOriginMs + backlog)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func bufferedSendReconnectsWhenCloseDoesNotWakeReceive(profile: TransportProfile) async throws {
    let rig = ReconnectRig(profile: profile, inboundStall: .milliseconds(80)) { index, socket in
        if index == 0 {
            socket.wakeReceiveOnClose = false
            socket.ignoreReceiveCancel = true
        }
    }
    var iterator = rig.engine.events.makeAsyncIterator()
    let first = try await rig.connected()
    let frame = Data(repeating: 9, count: 3_200)
    try await rig.engine.send(PCMFrame(track: .system, data: frame, hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    let parked = first.receiveReturns
    let second = try await rig.socket(profile.resumeIndex)
    second.push(created)
    var sawGap = false
    var sawDegraded = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .state(.degraded) = event { sawDegraded = true }
        if case .gap = event { sawGap = true }
        if case .state(.streaming) = event, sawGap { break }
    }
    #expect(sawDegraded)
    #expect(sawGap)
    #expect(first.receiveReturns == parked)
    try await waitUntil { second.binaryCount >= 1 }
    #expect(second.binary(at: 0) == frame)
    second.push(.text(#"""
    {"type":"transcript.partial","text":"back","is_final":true,"speech_final":true,"start":0.0,"duration":0.1,"words":[{"text":"back","start":0.0,"end":0.1}]}
    """#))
    var rebased = false
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.kind == .final {
            #expect(transcript.startMs == profile.resumeOriginMs)
            rebased = true
            break
        }
    }
    #expect(rebased)
    await rig.engine.finish()
    rig.releaseAll()
}

@Test(arguments: TransportProfile.allCases)
func blockedSendAfterWatermarkStillReconnects(profile: TransportProfile) async throws {
    // Longer than one watchdog poll so the acking transcript lands before the
    // stall check. 80ms would race the first poll and reconnect too soon.
    let rig = ReconnectRig(profile: profile, inboundStall: .milliseconds(250)) { index, socket in
        if index == 0 {
            socket.wakeReceiveOnClose = false
            socket.ignoreReceiveCancel = true
            socket.hangSendsAfter = 1
        }
    }
    var iterator = rig.engine.events.makeAsyncIterator()
    let first = try await rig.connected()
    let sent = Data(repeating: 3, count: 3_200)
    let blocked = Data(repeating: 4, count: 3_200)
    try await rig.engine.send(PCMFrame(track: .system, data: sent, hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    first.push(.text(#"""
    {"type":"transcript.partial","text":"heard","is_final":true,"speech_final":true,"start":0.0,"duration":0.1,"words":[{"text":"heard","start":0.0,"end":0.1}]}
    """#))
    var heard = false
    for _ in 0..<8 {
        guard let event = await iterator.next() else { break }
        if case .transcript(let transcript) = event, transcript.text == "heard" {
            heard = true
            break
        }
    }
    #expect(heard)
    let parked = first.receiveReturns
    let engine = rig.engine
    let hung = Task { try await engine.send(PCMFrame(track: .system, data: blocked, hostTime: 0)) }
    let second = try await rig.socket(profile.resumeIndex)
    second.push(created)
    var sawGap = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .gap = event { sawGap = true }
        if case .state(.streaming) = event, sawGap { break }
    }
    #expect(sawGap)
    #expect(first.receiveReturns == parked)
    // The transcript acked `sent` and cleared it from the replay buffer.
    // Only the chunk still blocked in `send` is replayed.
    try await waitUntil { second.binaryCount >= 1 }
    #expect(second.binary(at: 0) == blocked)
    await rig.engine.finish()
    rig.releaseAll()
    _ = try? await hung.value
}

@Test(arguments: TransportProfile.allCases)
func handshakeTimeoutClosesParkedReceiveAndEmitsGap(profile: TransportProfile) async throws {
    let clock = ManualClock()
    let supply = SocketSupply()
    supply.configure = { index, socket in
        if profile == .macParked, index < 2 {
            // Mac: neither the dead socket's close nor the parked handshake's returns.
            socket.hangClose = true
        }
        if index == 0 {
            socket.wakeReceiveOnClose = false
            socket.ignoreReceiveCancel = true
        }
        if index == 1 {
            // The reconnect attempt while the drop is still in place. Neither
            // cancel nor close resumes `receive` (a later `pf` handshake).
            // Waiting on that receive never opens the socket that emits gap.
            socket.ignoreReceiveCancel = true
            socket.wakeReceiveOnClose = false
        }
        if index >= 2 {
            socket.push(.text(#"{"type":"transcript.created"}"#))
        }
    }
    let engine = stalledEngine(
        supply: supply,
        clock: clock,
        inboundStall: .milliseconds(250),
        handshakeTimeout: .milliseconds(300)
    )
    defer {
        supply.socket(0)?.release()
        supply.socket(1)?.release()
    }
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    try await waitUntil { supply.count >= 1 }
    let first = try #require(supply.socket(0))
    first.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    let frame = Data(repeating: 9, count: 3_200)
    try await engine.send(PCMFrame(track: .system, data: frame, hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    let parked = first.receiveReturns
    try await waitUntil { supply.count >= 3 }
    let failedHandshake = supply.socket(1)
    let resumedSocket = supply.socket(2)
    var sawGap = false
    var sawStreaming = false
    if supply.count >= 3 {
        for _ in 0..<24 {
            guard let event = await iterator.next() else { break }
            if case .gap = event { sawGap = true }
            if case .state(.streaming) = event, sawGap {
                sawStreaming = true
                break
            }
        }
    }
    try await waitUntil { (failedHandshake?.closeCount ?? 0) >= 1 }
    #expect(failedHandshake?.closeCount ?? 0 >= 1)
    #expect(first.receiveReturns == parked)
    #expect(sawGap)
    #expect(sawStreaming)
    if let resumedSocket {
        try await waitUntil { resumedSocket.binaryCount >= 1 }
        #expect(resumedSocket.binary(at: 0) == frame)
    }
    // A parked handshake receive ignores cancel. Release it before finish so a
    // failed run still lets the recovery task leave the task group.
    failedHandshake?.release()
    first.release()
    await engine.finish()
}

@Test func hungCloseStillEmitsGapAndStreaming() async throws {
    let clock = ManualClock()
    let supply = SocketSupply()
    supply.configure = { index, socket in
        if index == 0 || index == 1 {
            // Mac URLSession: close() does not return while the dropped
            // receive is parked, and cancel does not resume it. The in-window
            // retry's connect parks the same way.
            socket.wakeReceiveOnClose = false
            socket.ignoreReceiveCancel = true
            socket.hangClose = true
        }
        if index == 1 {
            socket.hangConnect = true
        }
        if index >= 2 {
            socket.push(.text(#"{"type":"transcript.created"}"#))
        }
    }
    let engine = stalledEngine(
        supply: supply,
        clock: clock,
        inboundStall: .milliseconds(250),
        handshakeTimeout: .milliseconds(300)
    )
    defer {
        supply.socket(0)?.release()
        supply.socket(1)?.release()
    }
    var iterator = engine.events.makeAsyncIterator()
    let connecting = Task { try await engine.connect(track: .system) }
    try await waitUntil { supply.count >= 1 }
    let first = try #require(supply.socket(0))
    first.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    let frame = Data(repeating: 9, count: 3_200)
    try await engine.send(PCMFrame(track: .system, data: frame, hostTime: 0))
    try await waitUntil { first.binaryCount == 1 }
    let parked = first.receiveReturns
    try await waitUntil { supply.count >= 3 }
    let stalledClose = supply.socket(0)
    let parkedConnect = supply.socket(1)
    var sawGap = false
    var sawStreaming = false
    for _ in 0..<24 {
        guard let event = await iterator.next() else { break }
        if case .gap = event { sawGap = true }
        if case .state(.streaming) = event, sawGap {
            sawStreaming = true
            break
        }
    }
    #expect(sawGap)
    #expect(sawStreaming)
    #expect(first.receiveReturns == parked)
    #expect(stalledClose?.closeCount ?? 0 >= 1)
    #expect(stalledClose?.closeFinished == 0)
    #expect(parkedConnect?.connectFinished == 0)
    if let resumed = supply.socket(2) {
        try await waitUntil { resumed.binaryCount >= 1 }
        #expect(resumed.binary(at: 0) == frame)
    }
    stalledClose?.release()
    parkedConnect?.release()
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

@Test func errorFrameKeepsMessageAndCode() {
    let coded = GrokMessages.decode(#"{"type":"error","message":"nope","code":401}"#)
    #expect(coded == .error("nope code=401"))
    let named = GrokMessages.decode(#"{"type":"error","message":"bad key","error":"invalid_api_key"}"#)
    #expect(named == .error("bad key invalid_api_key"))
}

@Test func closedBeforeCreatedKeepsCloseAndHTTPProbe() async throws {
    let transport = ScriptedTransport()
    let probed = ProbeFlag()
    let engine = GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "bad",
        url: GrokWebSocket.url(),
        makeTransport: { transport },
        handshakeTimeout: .seconds(2),
        authProbe: { _ in
            probed.value = true
            return AuthProbeResult(http: 401, body: "{\"code\":\"invalid\"}")
        }
    ))
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.closed(code: 1006, reason: "upgrade failed"))
    do {
        try await connecting.value
        Issue.record("connect should fail before transcript.created")
    } catch {
        #expect(String(describing: error).contains("1006"))
    }
    let snap = await engine.snapshot()
    #expect(snap.lastCloseCode == 1006)
    #expect(snap.lastCloseReason?.contains("upgrade failed") == true)
    #expect(snap.httpStatus == 401)
    #expect(snap.httpBody?.contains("invalid") == true)
    #expect(probed.value)
}

@Test func undecodableServerFrameIsKeptOnTheSnapshot() async throws {
    let transport = ScriptedTransport()
    let engine = GrokEngine(track: .system, configuration: testConfig(transport))
    let connecting = Task { try await engine.connect(track: .system) }
    transport.push(.text(#"{"type":"transcript.created"}"#))
    try await connecting.value
    transport.push(.text("not-json{"))
    var saw = false
    for _ in 0..<25 {
        let snap = await engine.snapshot()
        if snap.unknownMessages.contains(where: { $0.contains("not-json") }) {
            saw = true
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(saw)
    await engine.finish()
}

@Test func registeredGrokBuilderIsWhatTheFactoryReturns() throws {
    GrokEngineBootstrap.install()
    let engine = try EngineFactory.make(track: .microphone, environment: ["CATCHER_ENGINE": "grok"])
    #expect(String(describing: type(of: engine)).contains("GrokEngine"))
}

private func stalledEngine(
    supply: SocketSupply,
    clock: ManualClock,
    inboundStall: Duration = .milliseconds(80),
    handshakeTimeout: Duration = .seconds(2)
) -> GrokEngine {
    GrokEngine(track: .system, configuration: GrokEngineConfiguration(
        apiKey: "test-key",
        url: GrokWebSocket.url(),
        makeTransport: { supply.make() },
        sleep: { duration in
            clock.advance(ms: Int(seconds(duration) * 1000))
        },
        nowMs: { clock.ms },
        handshakeTimeout: handshakeTimeout,
        inboundStall: inboundStall
    ))
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

private final class ProbeFlag: @unchecked Sendable {
    var value = false
}

final class ManualClock: @unchecked Sendable {
    var ms = 0
    func advance(ms: Int) { self.ms += ms }
}

final class SocketSupply: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [ScriptedTransport] = []
    var configure: (Int, ScriptedTransport) -> Void = { _, _ in }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    func socket(_ index: Int) -> ScriptedTransport? {
        lock.lock()
        defer { lock.unlock() }
        guard sockets.indices.contains(index) else { return nil }
        return sockets[index]
    }

    func make() -> ScriptedTransport {
        let socket = ScriptedTransport()
        lock.lock()
        let index = sockets.count
        configure(index, socket)
        sockets.append(socket)
        lock.unlock()
        return socket
    }
}

final class ScriptedTransport: GrokTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<GrokSocketEvent, Error>] = []
    private var waiters: [UUID: CheckedContinuation<GrokSocketEvent, Error>] = [:]
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var binaries: [Data] = []
    private var texts: [String] = []
    private(set) var connectCount = 0
    private(set) var receiveReturns = 0
    private(set) var closeCount = 0
    /// How many `close()` calls have returned. A `pf`-parked URLSession close stays at 0.
    private(set) var closeFinished = 0
    /// How many `connect()` calls have returned. A dropped SYN stays at 0.
    private(set) var connectFinished = 0
    /// When false, `close` does not resume `receive` (a `pf` drop never delivers the close).
    var wakeReceiveOnClose = true
    /// When true, cancelling the reader does not unblock `receive`.
    var ignoreReceiveCancel = false
    /// When true, `close()` does not return until `release()` (Mac `task.cancel()` on a parked receive).
    var hangClose = false
    /// When true, `connect()` does not return until `release()` (Mac `URLSession` connect while `pf` drops the SYN).
    var hangConnect = false
    /// Hang once this many sends have already completed. `Int.max` never hangs.
    var hangSendsAfter = Int.max
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []

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
        if hangConnect {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                connectWaiters.append(continuation)
                lock.unlock()
            }
        }
        noteConnectFinished()
    }

    func sendText(_ text: String) async throws {
        noteText(text)
    }

    func sendBinary(_ data: Data) async throws {
        if shouldHang() {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                sendWaiters.append(continuation)
                lock.unlock()
            }
        }
        noteBinary(data)
    }

    private func shouldHang() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return binaries.count >= hangSendsAfter
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
        noteClose()
        failSends()
        if hangClose {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                closeWaiters.append(continuation)
                lock.unlock()
            }
            noteCloseFinished()
            return
        }
        noteCloseFinished()
        guard wakeReceiveOnClose else { return }
        resumeReceives(reason: "stalled")
    }

    private func noteClose() {
        lock.lock()
        closeCount += 1
        lock.unlock()
    }

    func release() {
        failSends()
        resumeReceives(reason: "released")
        resumeClosers()
        resumeConnects()
    }

    private func noteCloseFinished() {
        lock.lock()
        closeFinished += 1
        lock.unlock()
    }

    private func noteConnectFinished() {
        lock.lock()
        connectFinished += 1
        lock.unlock()
    }

    private func resumeClosers() {
        lock.lock()
        let pending = closeWaiters
        closeWaiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }

    private func resumeConnects() {
        lock.lock()
        let pending = connectWaiters
        connectWaiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }

    private func failSends() {
        lock.lock()
        let pending = sendWaiters
        sendWaiters.removeAll()
        lock.unlock()
        // Resume off this stack. A synchronous resume re-enters the engine
        // while `close` is still on the call that `socketDied` has not left,
        // and the PCM `Data` buffer is not safe to mutate from both.
        guard !pending.isEmpty else { return }
        Task.detached {
            for waiter in pending {
                waiter.resume(throwing: EngineError.socket("send stalled"))
            }
        }
    }

    private func resumeReceives(reason: String) {
        lock.lock()
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: .closed(code: 1006, reason: reason))
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
        let event = try await receiveOnce()
        noteReceiveReturn()
        return event
    }

    private func noteReceiveReturn() {
        lock.lock()
        receiveReturns += 1
        lock.unlock()
    }

    private func receiveOnce() async throws -> GrokSocketEvent {
        let id = UUID()
        if ignoreReceiveCancel {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GrokSocketEvent, Error>) in
                enqueue(id, continuation)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GrokSocketEvent, Error>) in
                enqueue(id, continuation)
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func enqueue(_ id: UUID, _ continuation: CheckedContinuation<GrokSocketEvent, Error>) {
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
}
