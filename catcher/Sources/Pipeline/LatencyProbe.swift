import AudioCapture
import Foundation
import TranscriptionEngine

/// Per-track map from audio time to the host time of the frame that carried
/// those samples, plus the sidecar rows B2 and B4 grade. Touched only on the
/// pipeline actor. A dead sidecar does not stop capture.
final class LatencyProbe {
    private struct FrameStamp {
        var audioEndMs: Int
        var capAtMs: Int
        var sentAtMs: Int?
    }

    private struct PendingTranscript {
        var event: TranscriptEvent
        var recvAtMs: Int
    }

    private let sidecar: SessionSidecar
    private var origin: UInt64 = 0
    private var frames: [AudioTrack: [FrameStamp]] = [:]
    private var samples: [AudioTrack: Int] = [:]
    private var firstFrameAt: [AudioTrack: Int] = [:]
    private var streamingAt: [AudioTrack: Int] = [:]
    private var pending: [String: PendingTranscript] = [:]
    private var earlyShown: [String: Int] = [:]
    private var liveEmitted = false
    private var stopEmitted = false
    private var endEmitted = false

    init(sidecar: SessionSidecar) {
        self.sidecar = sidecar
    }

    func begin(origin: UInt64, request: StartRequest, originWallMs: Int, app: String) {
        self.origin = origin
        emit([
            "t": "clock",
            "originWallMs": originWallMs,
            "app": app,
        ], flush: true)
        emit([
            "t": "start",
            "source": request.source.rawValue,
            "inputAtMs": Self.signedMilliseconds(from: origin, to: request.inputHostTime),
            "processStartAtMs": Self.signedMilliseconds(from: origin, to: request.processStartHostTime),
        ], flush: true)
    }

    func noteCaptureStarted(atMs: Int) {
        emit(mark("capture-started", atMs: atMs), flush: true)
    }

    func noteFrame(track: AudioTrack, sampleCount: Int, capAtMs: Int) {
        let count = max(0, sampleCount)
        let cursor = samples[track] ?? 0
        let endMs = (cursor + count) * 1000 / AudioFormat.sampleRate
        samples[track] = cursor + count
        frames[track, default: []].append(FrameStamp(audioEndMs: endMs, capAtMs: capAtMs, sentAtMs: nil))
        if firstFrameAt[track] == nil {
            firstFrameAt[track] = capAtMs
            emit(mark("first-frame", atMs: capAtMs, track: track), flush: true)
            considerLive()
        }
    }

    /// `engine.send` has returned for the frame just ingested. That is the
    /// chunk leaving the process when the pending buffer flushed, and only
    /// "queued in the engine" when the tail was still short of a chunk.
    func noteSent(track: AudioTrack, sentAtMs: Int) {
        guard var list = frames[track], let last = list.indices.last, list[last].sentAtMs == nil else { return }
        list[last].sentAtMs = sentAtMs
        frames[track] = list
    }

    func noteStreaming(track: AudioTrack, atMs: Int) {
        guard streamingAt[track] == nil else { return }
        streamingAt[track] = atMs
        emit(mark("streaming", atMs: atMs, track: track), flush: true)
        considerLive()
    }

    func noteTranscript(_ event: TranscriptEvent, recvAtMs: Int) {
        let key = Self.key(event.track, event.seq)
        if let shown = earlyShown.removeValue(forKey: key) {
            writePair(event, recvAtMs: recvAtMs, shownAtMs: shown)
            return
        }
        pending[key] = PendingTranscript(event: event, recvAtMs: recvAtMs)
    }

    func noteShown(track: AudioTrack, seq: Int, atMs: Int) {
        let key = Self.key(track, seq)
        guard let waiting = pending.removeValue(forKey: key) else {
            earlyShown[key] = atMs
            return
        }
        writePair(waiting.event, recvAtMs: waiting.recvAtMs, shownAtMs: atMs)
    }

    func noteStop(source: StartRequest.Source, atMs: Int) {
        guard !stopEmitted else { return }
        stopEmitted = true
        emit(mark("stop-requested", atMs: atMs, source: source), flush: true)
    }

    func noteEnded(atMs: Int) {
        guard !endEmitted else { return }
        endEmitted = true
        emit(mark("ended", atMs: atMs), flush: true)
        sidecar.flush()
    }

    func flush() {
        sidecar.flush()
    }

    /// Frame whose audio range contains `audioMs`. Word end maps here: the
    /// frame that ends at exactly `audioMs` still contains that sample.
    func captured(track: AudioTrack, audioMs: Int) -> (capAtMs: Int, sentAtMs: Int?)? {
        guard let list = frames[track], !list.isEmpty else { return nil }
        var low = 0
        var high = list.count - 1
        var found: FrameStamp?
        while low <= high {
            let mid = (low + high) / 2
            if list[mid].audioEndMs >= audioMs {
                found = list[mid]
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        let stamp = found ?? list[list.count - 1]
        return (stamp.capAtMs, stamp.sentAtMs)
    }

    private func writePair(_ event: TranscriptEvent, recvAtMs: Int, shownAtMs: Int) {
        let words: [[String: Any]] = event.words.map { word in
            let hit = captured(track: event.track, audioMs: word.endMs)
            var row: [String: Any] = [
                "w": word.w,
                "s": word.startMs,
                "e": word.endMs,
            ]
            if let cap = hit?.capAtMs {
                row["capAtMs"] = cap
            }
            if let sent = hit?.sentAtMs {
                row["sentAtMs"] = sent
            }
            return row
        }
        emit([
            "t": "tx",
            "track": event.track.rawValue,
            "seq": event.seq,
            "kind": event.kind.rawValue,
            "recvAtMs": recvAtMs,
            "words": words,
        ], flush: false)
        emit([
            "t": "ui",
            "track": event.track.rawValue,
            "seq": event.seq,
            "shownAtMs": shownAtMs,
        ], flush: true)
    }

    private func considerLive() {
        guard !liveEmitted else { return }
        guard let systemFrame = firstFrameAt[.system],
              let micFrame = firstFrameAt[.microphone],
              let systemStream = streamingAt[.system],
              let micStream = streamingAt[.microphone] else { return }
        liveEmitted = true
        emit(mark("live", atMs: max(systemFrame, micFrame, systemStream, micStream)), flush: true)
    }

    private func mark(_ name: String, atMs: Int, track: AudioTrack? = nil, source: StartRequest.Source? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "t": "mark",
            "name": name,
            "atMs": atMs,
        ]
        if let track {
            row["track"] = track.rawValue
        }
        if let source {
            row["source"] = source.rawValue
        }
        return row
    }

    private func emit(_ object: [String: Any], flush: Bool) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        sidecar.write(data, flush: flush)
    }

    private static func key(_ track: AudioTrack, _ seq: Int) -> String {
        "\(track.rawValue)#\(seq)"
    }

    /// `HostClock.milliseconds` wraps when `end < start`. Inputs land before
    /// the session origin, so the sidecar needs the sign.
    static func signedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        if end >= start {
            return HostClock.milliseconds(from: start, to: end)
        }
        return -HostClock.milliseconds(from: end, to: start)
    }
}
