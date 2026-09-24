import Diagnostics
import Foundation
import Testing

@Test func stageLineRoundTripsQuotedAndPlainFields() throws {
    let plain = StageLine.stage(.framesReceived, .ok, [
        Field("system", "1002"),
        Field("microphone", "1000"),
        Field("invalid", "0"),
        Field("empty", "0"),
    ])
    let plainText = "STAGE frames-received OK system=1002 microphone=1000 invalid=0 empty=0"
    #expect(plain.formatted() == plainText)
    #expect(StageLine.parse(plainText) == plain)

    let quoted = StageLine.trace(
        lastOK: "api-stream",
        firstFail: "segments-received",
        error: "say \"hi\"\nnext"
    )
    let parsed = try #require(StageLine.parse(quoted.formatted()))
    #expect(parsed == quoted)
    #expect(parsed.field("error") == "say \"hi\"\nnext")

    let preflight = StageLine.preflight("api-key", .pass, [Field("length", "12")])
    #expect(preflight.formatted() == "PREFLIGHT api-key PASS length=12")
    #expect(StageLine.parse(preflight.formatted()) == preflight)

    let result = StageLine.preflightResult(.fail, failed: 2)
    #expect(result.formatted() == "PREFLIGHT RESULT FAIL failed=2")
    #expect(StageLine.parse(result.formatted()) == result)
}

@Test func longErrorBodyIsCappedAndKeepsTheOtherFields() throws {
    let long = String(repeating: "e", count: 5_000)
    let line = StageLine.stage(.captureStart, .fail, [
        Field("domain", "SCStreamErrorDomain"),
        Field("code", "-3801"),
        Field("error", long),
    ])
    let text = line.formatted()
    #expect(text.utf8.count <= StageFormat.maxBytes)
    #expect(text.contains("…(+"))
    #expect(text.contains("bytes)"))
    let parsed = try #require(StageLine.parse(text))
    #expect(parsed.field("code") == "-3801")
    #expect(parsed.field("domain") == "SCStreamErrorDomain")
    #expect(parsed.field("error")?.contains("…(+") == true)
}

@Test func sampleLogTracesTheFirstFailingStage() throws {
    let raw = """
    STAGE tcc-check OK screen=granted mic=authorized owns=true entitlement=true responsible=Catcher
    STAGE capture-start OK display=1
    STAGE api-connect OK track=system engine=grok ms=412
    STAGE api-connect OK track=microphone engine=grok ms=398
    STAGE frames-received OK system=1002 microphone=1000 invalid=0 empty=0
    STAGE pcm-extract OK system=1002 microphone=1000 failed=0 osstatus=0 zeroEnergy=system
    STAGE api-stream OK system=320000 microphone=320000 pending=0 sendErrors=0
    STAGE segments-received FAIL system=0 microphone=3 partials=4 blankDropped=21 restated=0 apiErrors=0
    STAGE reconnect OK track=system attempt=1 code=1006 reason="inbound stall"
    STAGE transcript-write OK bytes=88 segments=3 recovered=false
    """
    let lines = raw.split(separator: "\n").compactMap { StageLine.parse(String($0)) }
    #expect(lines.count == 10)
    let report = FailureTrace.report(lines: lines)
    #expect(report.lastOK == "api-stream")
    #expect(report.firstFail == "segments-received")
    #expect(report.lines[0].formatted() == "TRACE last-ok=api-stream first-fail=segments-received error=\"system: 0 finals from 320000 bytes; every system PCM frame is zero\"")
    #expect(report.lines[1].formatted() == "TRACE cause=\"system track captured digital silence\" fix=\"nothing was playing on the captured display, or the mixdown cancelled; check system.pcm peak/RMS and the chosen display\"")
}

@Test func traceUsesLastVerdictAndReportsNotReached() {
    let checkpoint = StageLine.stage(.segmentsReceived, .fail, [
        Field("system", "0"),
        Field("microphone", "0"),
        Field("partials", "0"),
        Field("blankDropped", "0"),
        Field("restated", "0"),
        Field("apiErrors", "0"),
    ])
    let closed = StageLine.stage(.segmentsReceived, .ok, [
        Field("system", "1"),
        Field("microphone", "1"),
        Field("partials", "1"),
        Field("blankDropped", "0"),
        Field("restated", "0"),
        Field("apiErrors", "0"),
    ])
    let report = FailureTrace.report(lines: [
        StageLine.stage(.tccCheck, .ok),
        checkpoint,
        closed,
    ])
    #expect(report.firstFail == "not-reached")
    #expect(report.lastOK == "segments-received")

    let missing = FailureTrace.report(lines: [
        StageLine.stage(.tccCheck, .ok),
        StageLine.stage(.captureStart, .ok, [Field("display", "1")]),
    ])
    #expect(missing.lastOK == "capture-start")
    #expect(missing.firstFail == "not-reached")

    let blocked = FailureTrace.report(lines: [
        StageBuilders.tcc(
            probeGranted: false,
            blockReason: "screen recording access denied",
            micStatus: "authorized",
            owns: true,
            entitlement: true,
            responsible: "Catcher"
        ),
    ])
    #expect(blocked.lastOK == "none")
    #expect(blocked.firstFail == "tcc-check")
    #expect(blocked.cause == "Screen & System Audio Recording missing")
}

@Test func causeTableMatchesEveryRow() {
    func fail(_ stage: Stage, _ fields: [Field], prior: [StageLine] = []) -> CauseMatch? {
        let line = StageLine.stage(stage, .fail, fields)
        return CauseTable.match(failing: line, lines: prior + [line])
    }

    #expect(fail(.tccCheck, [Field("entitlement", "false")])?.cause == "hardened build without audio-input")
    #expect(fail(.tccCheck, [Field("owns", "false")])?.fix.contains("open -n") == true)
    #expect(fail(.tccCheck, [Field("mic", "denied")])?.cause == "denied row for com.catcher.app")
    #expect(fail(.tccCheck, [Field("mic", "notDetermined")])?.cause == "Allow never answered")
    #expect(fail(.tccCheck, [Field("screen", "denied")])?.cause == "Screen & System Audio Recording missing")
    #expect(fail(.tccCheck, [
        Field("entitlement", "false"),
        Field("screen", "denied"),
    ])?.cause == "hardened build without audio-input")

    #expect(fail(.captureStart, [Field("code", "-3801")])?.cause == "user declined screen capture")
    #expect(fail(.captureStart, [Field("code", "1"), Field("domain", "SCStreamErrorDomain")])?.cause == "SCStream failed to start")

    #expect(fail(.framesReceived, [Field("system", "0"), Field("microphone", "4")])?.cause == "no system buffers on the chosen display")
    #expect(fail(.framesReceived, [Field("system", "0"), Field("microphone", "0")])?.cause == "mic device missing or not delivered")

    #expect(fail(.pcmExtract, [Field("osstatus", "-12737"), Field("failed", "2")])?.cause == "retained-block-buffer variant used")
    #expect(fail(.pcmExtract, [
        Field("failed", "1"),
        Field("error", "unsupportedFormat(\"mBytesPerFrame 8 != 4\")"),
    ])?.cause == "SCK format changed")

    #expect(fail(.apiConnect, [Field("error", "missing XAI_API_KEY")])?.cause == "key not forwarded")
    #expect(fail(.apiConnect, [Field("http", "401"), Field("body", "bad")])?.cause == "key rejected")
    #expect(fail(.apiConnect, [Field("http", "403")])?.cause == "key rejected")
    #expect(fail(.apiConnect, [Field("error", "handshakeTimeout")])?.cause == "socket open but no transcript.created")
    #expect(fail(.apiConnect, [Field("domain", "NSURLErrorDomain"), Field("code", "-1009")])?.cause == "DNS / offline / refused")
    #expect(fail(.apiConnect, [Field("code", "-1003"), Field("domain", "NSURLErrorDomain")])?.fix.contains("pfctl -sr") == true)
    #expect(fail(.apiConnect, [Field("code", "-1004"), Field("error", "NSURLErrorDomain")])?.cause == "DNS / offline / refused")

    let pcmOK = StageLine.stage(.pcmExtract, .ok, [Field("system", "3"), Field("microphone", "3")])
    #expect(fail(.apiStream, [Field("system", "0"), Field("microphone", "10")], prior: [pcmOK])?.cause == "pump never ran (ready=false)")

    #expect(fail(.segmentsReceived, [Field("apiErrors", "2"), Field("error", "rate limit")])?.cause == "xAI returned errors mid-stream")
    let silencePrior = [
        StageLine.stage(.pcmExtract, .ok, [Field("zeroEnergy", "system")]),
        StageLine.stage(.apiStream, .ok, [Field("system", "320000"), Field("microphone", "10")]),
    ]
    #expect(fail(.segmentsReceived, [
        Field("system", "0"),
        Field("microphone", "3"),
        Field("blankDropped", "21"),
        Field("apiErrors", "0"),
    ], prior: silencePrior)?.cause == "system track captured digital silence")
    #expect(fail(.segmentsReceived, [
        Field("system", "0"),
        Field("blankDropped", "4"),
        Field("apiErrors", "0"),
    ])?.cause == "only endpoint spam came back")

    #expect(fail(.transcriptWrite, [Field("error", "errno 13")])?.cause == "assemble/end failed")
    #expect(fail(.transcriptWrite, [Field("bytes", "0"), Field("segments", "0")])?.cause == "nothing to write")
    #expect(fail(.transcriptWrite, [
        Field("bytes", "0"),
        Field("segments", "0"),
        Field("error", "errno 13"),
    ])?.cause == "assemble/end failed")
}

@Test func errorDetailWalksUnderlyingOSStatus() {
    let status = Int32(bitPattern: UInt32(0x666D743F))
    let inner = NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "format",
    ])
    let outer = NSError(domain: "SCStreamErrorDomain", code: -3801, userInfo: [
        NSLocalizedDescriptionKey: "declined",
        NSUnderlyingErrorKey: inner,
    ])
    let detail = ErrorDetail.describe(outer)
    #expect(detail["domain"] == "SCStreamErrorDomain")
    #expect(detail["code"] == "-3801")
    #expect(detail["localizedDescription"] == "declined")
    #expect(detail["osstatus"] == "\(status) 'fmt?'")
    #expect(detail["underlying"]?.contains("osstatus=") == true)
    #expect(detail["underlying"]?.contains(NSOSStatusErrorDomain) == true)
    let sentence = ErrorDetail.sentence(detail)
    #expect(sentence.contains("SCStreamErrorDomain"))
    #expect(sentence.contains("-3801"))
    #expect(sentence.contains("fmt?"))

    let plain = Int32(-12737)
    #expect(ErrorDetail.formatStatus(plain) == "-12737")
}

@Test func ledgerCheckpointKeepsSilenceAtOKAndFailsAnEmptyTrack() async {
    let ledger = StageLedger()
    await ledger.frameExtracted(track: "system", energy: false)
    await ledger.frameExtracted(track: "microphone", energy: true)
    let capture = CaptureCounterSnapshot(system: 2, microphone: 2, invalid: 1, empty: 0)
    let lines = await ledger.countLines(capture: capture, stream: StreamSnapshot(
        systemBytes: 100,
        microphoneBytes: 100,
        pending: 0,
        fromEngine: true
    ))
    #expect(lines[0].verdict == "OK")
    #expect(lines[0].field("invalid") == "1")
    #expect(lines[1].verdict == "OK")
    #expect(lines[1].field("zeroEnergy") == "system")
    #expect(lines[1].field("micGain") == nil)
    #expect(lines[2].verdict == "OK")

    let gained = await ledger.countLines(
        capture: CaptureCounterSnapshot(system: 2, microphone: 2, microphoneGain: 1, microphoneGainPeak: 10.5),
        stream: StreamSnapshot(systemBytes: 100, microphoneBytes: 100, fromEngine: true)
    )
    #expect(gained[1].field("micGain") == "1.00")
    #expect(gained[1].field("micGainMax") == "10.50")

    let quiet = StageLedger()
    let missed = await quiet.countLines(
        capture: CaptureCounterSnapshot(system: 0, microphone: 3),
        stream: StreamSnapshot()
    )
    #expect(missed[0].verdict == "FAIL")
    #expect(missed[1].verdict == "FAIL")
    #expect(StageLedger.hasEnergy(Data([0, 0, 1, 0])) == true)
    #expect(StageLedger.hasEnergy(Data([0, 0, 0, 0])) == false)
}

@Test func preflightStubSkipsAPIAndCountsFailures() async {
    let lines = await Preflight.run(environment: ["CATCHER_ENGINE": "stub", "XAI_API_KEY": ""], dependencies: .denied)
    #expect(lines.contains { $0.name == "api-key" && $0.verdict == "PASS" && $0.field("skipped") == "stub" })
    #expect(!lines.contains { $0.name == "capture-probe" })
    let result = Preflight.result(checks: lines, priorFails: 1)
    #expect(result.verdict == "FAIL")
    #expect(result.field("failed") == String(1 + lines.filter { $0.verdict == "FAIL" }.count))
    #expect(Preflight.failCount(in: "PREFLIGHT signing FAIL\n") == 1)
}

@Test func recordingSinkKeepsLinesAndFsyncsFailures() {
    let sink = RecordingStageSink()
    sink.write(StageLine.stage(.tccCheck, .ok), fsync: false)
    sink.write(StageLine.stage(.captureStart, .fail, [Field("code", "-3801")]), fsync: true)
    #expect(sink.recorded().count == 2)
    #expect(sink.fsyncCount == 1)
}

@Test func deadlineEndsACallbackThatNeverFires() async {
    let started = ContinuousClock.now
    let value = await Deadline.first(seconds: 0.2, timedOut: "timedOut") { _ in }
    #expect(value == "timedOut")
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test func deadlineReturnsTheCallbackValueAndDropsTheTimer() async {
    let value = await Deadline.first(seconds: 5, timedOut: "timedOut") { finish in
        finish("started")
        finish("again")
    }
    #expect(value == "started")
}

@Test func deadlineIsNotHeldByAStartThatBlocksItsThread() async {
    let release = DispatchSemaphore(value: 0)
    let started = ContinuousClock.now
    let value = await Deadline.first(seconds: 0.2, timedOut: "timedOut") { finish in
        release.wait()
        finish("late")
    }
    #expect(value == "timedOut")
    #expect(started.duration(to: .now) < .seconds(5))
    release.signal()
}

private extension PreflightDependencies {
    static let denied = PreflightDependencies(
        screenGranted: { false },
        microphone: {
            PreflightMicrophone(status: "denied", owns: true, entitlement: true, responsible: "Catcher")
        },
        micDevice: { nil },
        displayID: { nil },
        captureProbe: { PreflightCaptureResult(started: false, system: 0, microphone: 0, error: "skipped") },
        apiReach: { PreflightHTTPResult(ok: false, errorCode: -1009, errorDomain: "NSURLErrorDomain") },
        apiAuth: { _ in PreflightHTTPResult(ok: false, http: 401, body: "no") },
        apiSTT: { _ in PreflightSTTResult(created: false, milliseconds: nil, close: nil, http: 401, error: "no") }
    )
}
