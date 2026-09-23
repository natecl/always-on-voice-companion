import AudioCapture
import Foundation
import SessionStore
@testable import Pipeline
import Testing

@Test func wordEndMapsOntoTheFrameThatContainsIt() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("latency-map-\(UUID().uuidString).jsonl")
    let probe = LatencyProbe(sidecar: SessionSidecar(url: url))
    probe.noteFrame(track: .system, sampleCount: 16_000, capAtMs: 100)
    probe.noteSent(track: .system, sentAtMs: 140)
    let inside = try #require(probe.captured(track: .system, audioMs: 1_000))
    #expect(inside.capAtMs == 100)
    #expect(inside.sentAtMs == 140)
    probe.noteFrame(track: .system, sampleCount: 16_000, capAtMs: 1_100)
    let next = try #require(probe.captured(track: .system, audioMs: 1_001))
    #expect(next.capAtMs == 1_100)
    let boundary = try #require(probe.captured(track: .system, audioMs: 1_000))
    #expect(boundary.capAtMs == 100)
}

@Test func liveMarkWaitsForBothTracksAndBothStreams() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("latency-live-\(UUID().uuidString).jsonl")
    let probe = LatencyProbe(sidecar: SessionSidecar(url: url))
    let origin = HostClock.now()
    probe.begin(
        origin: origin,
        request: StartRequest(source: .recordButton, inputHostTime: origin, processStartHostTime: origin),
        originWallMs: 1_700_000_000_000,
        app: "0.0.1+test"
    )
    probe.noteFrame(track: .system, sampleCount: 160, capAtMs: 10)
    probe.noteStreaming(track: .system, atMs: 20)
    probe.noteFrame(track: .microphone, sampleCount: 160, capAtMs: 30)
    probe.flush()
    var text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("\"name\":\"live\""))
    probe.noteStreaming(track: .microphone, atMs: 40)
    text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"name\":\"live\""))
    #expect(text.contains("\"atMs\":40"))
}

@Test func inputBeforeTheSessionOriginIsNegative() {
    let origin = HostClock.now()
    var earlier = origin
    var delta = 0
    for _ in 0..<30 {
        earlier = earlier &- 50_000_000
        delta = HostClock.milliseconds(from: earlier, to: origin)
        if delta >= 5 && delta < 60_000 { break }
    }
    #expect(delta >= 5)
    #expect(LatencyProbe.signedMilliseconds(from: origin, to: earlier) == -delta)
}
