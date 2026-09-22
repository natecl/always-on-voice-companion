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

@Test func loudSystemTrackDoesNotFailBecauseTheMicIsQuiet() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let samples = [Int16](repeating: 12_000, count: 160)
    let loud = PCMFrame(track: .system, data: samples.withUnsafeBytes { Data($0) }, hostTime: 0)
    _ = await verifier.observeFrame(loud, atMs: 0)
    _ = await verifier.observeFrame(PCMFrame.silence(track: .microphone, sampleCount: 160, hostTime: 0), atMs: 0)
    let effect = await verifier.tick(atMs: 15_000)
    #expect(effect.snapshot.status.isOk)
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

@Test func finalWordFloorFlagsWhenAudioIsFlowing() async {
    let verifier = Verifier()
    _ = await verifier.beginSession(atMs: 0)
    let samples = [Int16](repeating: 8_000, count: 80)
    let loud = PCMFrame(track: .system, data: samples.withUnsafeBytes { Data($0) }, hostTime: 0)
    _ = await verifier.observeFrame(loud, atMs: 1_000)
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

private final class LoudCapture: @unchecked Sendable {
    var logged = ""
    var notified = ""
}
