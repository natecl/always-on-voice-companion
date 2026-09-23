import AudioCapture
import Foundation
import Testing
import TranscriptionEngine
import Verifier

@Test func silenceOnEveryTrackBecomesNoAudioAtTenSeconds() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    let mic = PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0)
    let early = await verifier.observeFrame(system, atMs: 0)
    _ = await verifier.observeFrame(mic, atMs: 0)
    #expect(early.annotations.isEmpty)
    let before = await verifier.tick(atMs: 9_999)
    #expect(before.snapshot.status.isOk)
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
    if case .noAudio = tripped.snapshot.status {} else {
        Issue.record("expected noAudio, got \(tripped.snapshot.status)")
    }
    #expect(tripped.snapshot.banner?.isEmpty == false)
    #expect(tripped.snapshot.logLine?.isEmpty == false)
    #expect(tripped.snapshot.notificationBody?.isEmpty == false)
}

@Test func lateSilentFramesStillTripNoAudioAtSessionTenSeconds() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    let mic = PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0)
    _ = await verifier.observeFrame(system, atMs: 2_500)
    _ = await verifier.observeFrame(mic, atMs: 2_500)
    let early = await verifier.tick(atMs: 9_999)
    #expect(early.annotations.isEmpty)
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
}

@Test func emptyFinalDoesNotResetTheSilenceClock() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 0)
    let blank = TranscriptEvent(
        track: .system,
        kind: .final,
        text: "",
        words: [],
        seq: 1,
        startMs: 2_000,
        endMs: 4_000
    )
    _ = await verifier.observeEngine(.transcript(blank), track: .system, atMs: 4_000, storedCount: 0)
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
}

@Test func loudSystemTrackDoesNotFailBecauseTheMicIsQuiet() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let loud = tone(track: .system, amplitude: 12_000)
    _ = await verifier.observeFrame(loud, atMs: 0)
    _ = await verifier.observeFrame(loud, atMs: AudioFlowCheck.speechHoldMs)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 14_000)
    let effect = await verifier.tick(atMs: 15_000)
    #expect(effect.snapshot.status.isOk)
    #expect(!effect.annotations.contains { $0.kind == "noAudio" })
}

@Test func handshakeTimeoutIsDegradedAtFiveSeconds() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.observeEngine(.state(.connecting), track: .system, atMs: 0, storedCount: 0)
    let early = await verifier.tick(atMs: 4_999)
    #expect(early.annotations.isEmpty)
    let late = await verifier.tick(atMs: 5_000)
    #expect(late.annotations.contains { $0.kind == "degraded" && $0.atMs == 5_000 })
    if case .degraded = late.snapshot.status {} else {
        Issue.record("expected degraded")
    }
}

@Test func gapThenStreamingEmitsResumed() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let degraded = await verifier.observeEngine(
        .state(.degraded(reason: "ws closed (1006); reconnect #1 in 1s")),
        track: .system,
        atMs: 1_000,
        storedCount: 0
    )
    #expect(degraded.annotations.contains { $0.kind == "degraded" })
    let gap = await verifier.observeEngine(
        .gap(fromMs: 1_000, toMs: 2_000),
        track: .system,
        atMs: 2_000,
        storedCount: 0
    )
    #expect(gap.annotations.contains { annotation in
        if case .gap(let from, let to, let track) = annotation.detail {
            return annotation.kind == "gap" && from == 1_000 && to == 2_000 && track == "system"
        }
        return false
    })
    let resumed = await verifier.observeEngine(.state(.streaming), track: .system, atMs: 2_000, storedCount: 0)
    #expect(resumed.annotations.contains { $0.kind == "resumed" })
    #expect(resumed.snapshot.status.isOk)
}

@Test func systemReconnectDoesNotClearMicrophoneDegraded() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let reason = "ws closed (1006); reconnect #1 in 1s"
    let system = await verifier.observeEngine(.state(.degraded(reason: reason)), track: .system, atMs: 5_000, storedCount: 0)
    let mic = await verifier.observeEngine(.state(.degraded(reason: reason)), track: .microphone, atMs: 5_100, storedCount: 0)
    // Identical reason text on two tracks is two rows.
    #expect(system.annotations.map(text) == ["\(reason) track=system"])
    #expect(mic.annotations.map(text) == ["\(reason) track=microphone"])
    let back = await verifier.observeEngine(.state(.streaming), track: .system, atMs: 20_000, storedCount: 0, backlogMs: 21_000)
    #expect(back.annotations.map(text) == ["transport resumed track=system backlogMs=21000"])
    if case .degraded = back.snapshot.status {} else {
        Issue.record("microphone is still down; got \(back.snapshot.status)")
    }
    let micBack = await verifier.observeEngine(.state(.streaming), track: .microphone, atMs: 22_000, storedCount: 0, backlogMs: 0)
    #expect(micBack.annotations.map(text) == ["transport resumed track=microphone backlogMs=0"])
    #expect(micBack.snapshot.status.isOk)
}

@Test func backdatedResumeDoesNotLookLikeAnEightSecondStall() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .system, atMs: 60_719, storedCount: 0)
    let speech = tone(track: .system, amplitude: 8_000)
    _ = await verifier.observeFrame(speech, atMs: 60_000)
    _ = await verifier.observeFrame(speech, atMs: 60_000 + AudioFlowCheck.speechHoldMs)
    // Gap is stamped on the wall clock; resumed is stamped on the engine clock,
    // ~8s earlier. That rewind must not trip the heartbeat on the next tick.
    _ = await verifier.observeEngine(
        .gap(fromMs: 39_918, toMs: 52_150),
        track: .system,
        atMs: 60_719,
        storedCount: 0
    )
    _ = await verifier.observeEngine(
        .state(.streaming),
        track: .system,
        atMs: 52_150,
        storedCount: 0,
        backlogMs: 17_400
    )
    let tick = await verifier.tick(atMs: 60_793)
    #expect(!tick.annotations.contains { text($0).contains("no engine event") })
}

@Test func transcriptAfterHeartbeatStallWritesResumed() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    _ = await verifier.observeEngine(.state(.streaming), track: .system, atMs: 1_000, storedCount: 0)
    let speech = tone(track: .system, amplitude: 8_000)
    _ = await verifier.observeFrame(speech, atMs: 1_000)
    _ = await verifier.observeFrame(speech, atMs: 1_000 + AudioFlowCheck.speechHoldMs)
    let stalled = await verifier.tick(atMs: 9_000)
    #expect(stalled.annotations.contains { text($0).contains("no engine event for 8000ms") })
    let recovered = await verifier.observeEngine(
        .transcript(TranscriptEvent(
            track: .system,
            kind: .final,
            text: "with no silent gap over two seconds",
            words: [],
            seq: 1,
            startMs: 9_200,
            endMs: 9_500
        )),
        track: .system,
        atMs: 9_500,
        storedCount: 1
    )
    #expect(recovered.annotations.map(text) == ["transport resumed track=system"])
    #expect(recovered.snapshot.status.isOk)
    let later = await verifier.tick(atMs: 10_000)
    #expect(!later.annotations.contains { text($0).contains("no engine event") })
}

@Test func heartbeatIsPerTrack() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .system, atMs: 100, storedCount: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .microphone, atMs: 100, storedCount: 0)
    let speech = tone(track: .microphone, amplitude: 8_000)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(speech, atMs: 0)
    _ = await verifier.observeFrame(speech, atMs: AudioFlowCheck.speechHoldMs)
    // The system engine keeps talking; only the flowing mic track is stale.
    _ = await verifier.observeEngine(.state(.streaming), track: .system, atMs: 8_000, storedCount: 0)
    let tick = await verifier.tick(atMs: 8_100)
    #expect(tick.annotations.map(text) == ["no engine event for 8000ms while audio is flowing track=microphone emittedAtMs=8100"])
}

@Test func finalWordFloorFlagsWhenAudioIsFlowing() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let loud = tone(track: .system, amplitude: 8_000, sampleCount: 80)
    _ = await verifier.observeFrame(loud, atMs: 1_000)
    _ = await verifier.observeFrame(loud, atMs: 1_000 + AudioFlowCheck.speechHoldMs)
    let tooSoon = await verifier.tick(atMs: 19_000)
    #expect(tooSoon.annotations.isEmpty)
    let flagged = await verifier.tick(atMs: 20_000)
    #expect(flagged.annotations.contains { $0.kind == "degraded" && ($0.detail.map { if case .text(let text) = $0 { return text.contains("word floor") } else { return false } } ?? false) })
}

@Test func stuckSegmentCountIsDegraded() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let final = TranscriptEvent(
        track: .system,
        kind: .final,
        text: "hello there friend",
        words: [],
        seq: 1,
        startMs: 0,
        endMs: 500
    )
    _ = await verifier.observeEngine(.transcript(final), track: .system, atMs: 500, storedCount: 0)
    let early = await verifier.tick(atMs: 1_499)
    #expect(!early.annotations.contains { $0.detail.map { if case .text(let text) = $0 { return text.contains("fsync") } else { return false } } ?? false })
    let late = await verifier.tick(atMs: 1_500)
    #expect(late.annotations.contains { annotation in
        if case .text(let text) = annotation.detail { return text.contains("fsync") }
        return false
    })
    let cleared = await verifier.observeStored(count: 1, atMs: 1_600)
    #expect(cleared.snapshot.status.isOk)
}

@Test func revokeBlocksImmediatelyAndSilencePlusFailedProbeDoesToo() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let revoked = await verifier.observeCapture(.tccRevokedMidSession, atMs: 250)
    #expect(revoked.annotations.contains { $0.kind == "blocked" && $0.atMs == 250 })
    #expect(revoked.snapshot.status.isBlocked)

    let second = Verifier()
    _ = await second.beginSession(atMs: 0)
    _ = await second.observeFrame(PCMFrame.silence(track: .system, sampleCount: 16, hostTime: 0), atMs: 0)
    _ = await second.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 16, hostTime: 0), atMs: 0)
    _ = await second.tick(atMs: 10_000)
    let blocked = await second.observeReprobe(.blocked(reason: "screen recording access denied"), atMs: 10_100)
    #expect(blocked.snapshot.status.isBlocked)
}

@Test func pcmExtractionFailureIsDegradedAndNotSilent() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let effect = await verifier.observeCapture(.pcmExtractionFailed(status: -12737, detail: ""), atMs: 100)
    #expect(effect.annotations.contains { annotation in
        if case .text(let text) = annotation.detail {
            return annotation.kind == "degraded" && text.contains("-12737")
        }
        return false
    })
    if case .degraded = effect.snapshot.status {} else {
        Issue.record("expected degraded, got \(effect.snapshot.status)")
    }
    #expect(effect.snapshot.banner?.isEmpty == false)
}

@Test func loudChannelsAlwaysCarryAllFourSurfaces() {
    let annotation = Annotation(atMs: 10, kind: "blocked", detail: .text("no grant"))
    let channels = Loud.channels(annotation: annotation, status: .blocked("no grant"))
    let captured = LoudCapture()
    Loud.deliver(channels, log: { captured.logged = $0 }, notify: { captured.notified = $0 })
    #expect(!channels.banner.isEmpty)
    #expect(!channels.notificationBody.isEmpty)
    #expect(channels.annotation.kind == "blocked")
    #expect(!channels.logLine.isEmpty)
    #expect(captured.logged == channels.logLine)
    #expect(captured.notified == channels.notificationBody)
}

@Test func mutedOutputAndRestingMicEmitsNoAudioInsideTenSeconds() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .system, atMs: 300, storedCount: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    // Above the old 0.001 floor, under the resting-mic floor. Raw RMS and AC RMS match.
    let mic = tone(track: .microphone, amplitude: 600)
    _ = await verifier.observeFrame(system, atMs: 0)
    _ = await verifier.observeFrame(mic, atMs: 0)
    _ = await verifier.observeFrame(mic, atMs: 9_000)
    let early = await verifier.tick(atMs: 9_000)
    #expect(!early.annotations.contains { $0.kind == "degraded" })
    #expect(!early.annotations.contains { $0.kind == "noAudio" })
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
    #expect(!tripped.annotations.contains { annotation in
        if case .text(let text) = annotation.detail {
            return text.contains("audio is flowing")
        }
        return false
    })
}

@Test func micDCOffsetIsSilenceNotFlowingAudio() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .microphone, atMs: 200, storedCount: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    let samples = [Int16](repeating: 8_000, count: 160)
    let dc = PCMFrame(track: .microphone, data: samples.withUnsafeBytes { Data($0) }, hostTime: 0)
    _ = await verifier.observeFrame(system, atMs: 0)
    _ = await verifier.observeFrame(dc, atMs: 0)
    _ = await verifier.observeFrame(dc, atMs: 9_500)
    let early = await verifier.tick(atMs: 9_500)
    #expect(early.annotations.isEmpty)
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
}

@Test func aSingleLoudSpikeDoesNotPushNoAudioPastTenSeconds() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    let spike = tone(track: .microphone, amplitude: 12_000)
    _ = await verifier.observeFrame(system, atMs: 0)
    _ = await verifier.observeFrame(spike, atMs: 400)
    _ = await verifier.observeFrame(system, atMs: 410)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 410)
    let tripped = await verifier.tick(atMs: 10_000)
    #expect(tripped.annotations.contains { $0.kind == "noAudio" && $0.atMs == 10_000 })
}

@Test func sustainedMicSpeechStaysAFlowingHeartbeatNotNoAudio() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .microphone, atMs: 200, storedCount: 0)
    let speech = tone(track: .microphone, amplitude: 8_000)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    _ = await verifier.observeFrame(system, atMs: 0)
    _ = await verifier.observeFrame(speech, atMs: 0)
    _ = await verifier.observeFrame(speech, atMs: AudioFlowCheck.speechHoldMs)
    let heartbeat = await verifier.tick(atMs: 8_200)
    #expect(heartbeat.annotations.contains { $0.kind == "degraded" })
    #expect(!heartbeat.annotations.contains { $0.kind == "noAudio" })
    let later = await verifier.tick(atMs: 12_000)
    #expect(!later.annotations.contains { $0.kind == "noAudio" })
    if case .degraded = later.snapshot.status {} else {
        Issue.record("expected degraded while speech is flowing, got \(later.snapshot.status)")
    }
}

@Test func silenceIsMeasuredFromCaptureStartNotSessionOpen() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 4_000)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 4_000)
    _ = await verifier.observeFrame(tone(track: .microphone, amplitude: 600), atMs: 4_000)
    let early = await verifier.tick(atMs: 13_999)
    #expect(!early.annotations.contains { $0.kind == "noAudio" })
    let tripped = await verifier.tick(atMs: 14_000)
    let noAudio = tripped.annotations.first { $0.kind == "noAudio" }
    #expect(noAudio?.atMs == 14_000)
    #expect(text(noAudio).contains("emittedAtMs=14000"))
    #expect(text(noAudio).contains("observedFromMs=4000"))
}

@Test func noAudioCarriesTheTimeItActuallyFired() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 0)
    // A stalled tick loop: the boundary is still 10s, the emission is not.
    let late = await verifier.tick(atMs: 25_000)
    let noAudio = late.annotations.first { $0.kind == "noAudio" }
    #expect(noAudio?.atMs == 10_000)
    #expect(text(noAudio).contains("emittedAtMs=25000"))
}

@Test func noFramesNoAudioStartsAtCaptureStartAndSaysSo() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 3_000)
    #expect(await verifier.tick(atMs: 12_999).annotations.isEmpty)
    let tripped = await verifier.tick(atMs: 13_000)
    let noAudio = tripped.annotations.first { $0.kind == "noAudio" }
    #expect(noAudio?.atMs == 13_000)
    #expect(text(noAudio).hasPrefix("no frames for >10s"))
}

@Test func syllabicSpeechWithShortDipsIsFlowingNotNoAudio() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    let burst = tone(track: .microphone, amplitude: Int16(0.08 * 32_768))
    let dip = PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0)
    let system = PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0)
    var annotations: [Annotation] = []
    var at = 0
    while at <= 12_000 {
        // 250 ms at 0.08, then an 80 ms syllable gap. No single burst holds 300 ms.
        let frame = at % 330 < 250 ? burst : dip
        annotations += await verifier.observeFrame(frame, atMs: at).annotations
        annotations += await verifier.observeFrame(system, atMs: at).annotations
        if at % 1_000 == 0 {
            annotations += await verifier.tick(atMs: at).annotations
        }
        at += 10
    }
    #expect(!annotations.contains { $0.kind == "noAudio" })
    let effect = await verifier.tick(atMs: 12_000)
    if case .noAudio = effect.snapshot.status {
        Issue.record("syllabic speech was treated as silence")
    }
}

@Test func oneLoudFrameAtATickIsNotAFlowingHeartbeat() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    _ = await verifier.captureStarted(atMs: 0)
    _ = await verifier.observeEngine(.state(.ready), track: .microphone, atMs: 300, storedCount: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .system, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 0)
    _ = await verifier.observeFrame(tone(track: .microphone, amplitude: 12_000), atMs: 8_400)
    let tick = await verifier.tick(atMs: 8_500)
    #expect(!tick.annotations.contains { text($0).contains("audio is flowing") })
}

@Test func thresholdsFileMatchesTheVerifierConstants() throws {
    // Drift guard for grade.py. Not P evidence.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("harness/thresholds.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let thresholds = try #require(object)
    #expect((thresholds["verifierRmsFloor"] as? Double).map(Float.init) == AudioFlowCheck.rmsEpsilon)
    #expect(thresholds["speechHoldMs"] as? Int == AudioFlowCheck.speechHoldMs)
    #expect(thresholds["speechDipMs"] as? Int == AudioFlowCheck.speechDipMs)
    #expect(thresholds["silenceLimitMs"] as? Int == AudioFlowCheck.silenceLimitMs)
    #expect(thresholds["grokEngine"] as? String == EngineFactory.grokModelName)
}

private func text(_ annotation: Annotation?) -> String {
    if case .text(let value) = annotation?.detail { return value }
    return ""
}

private func tone(track: AudioTrack, amplitude: Int16, sampleCount: Int = 160) -> PCMFrame {
    var samples = [Int16](repeating: 0, count: sampleCount)
    for index in samples.indices {
        samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
    }
    return PCMFrame(track: track, data: samples.withUnsafeBytes { Data($0) }, hostTime: 0)
}

private final class LoudCapture: @unchecked Sendable {
    var logged = ""
    var notified = ""
}
