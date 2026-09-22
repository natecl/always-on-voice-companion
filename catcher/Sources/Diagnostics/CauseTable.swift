import Foundation

public struct CauseMatch: Sendable, Equatable {
    public var cause: String
    public var fix: String

    public init(cause: String, fix: String) {
        self.cause = cause
        self.fix = fix
    }
}

/// First match wins. Predicates read the failing line and, where the signal
/// lives on an earlier stage, the other lines in the file.
public enum CauseTable {
    public static func match(failing: StageLine, lines: [StageLine]) -> CauseMatch? {
        guard let stage = failing.stage else { return nil }
        switch stage {
        case .tccCheck:
            if failing.field("entitlement") == "false" {
                return CauseMatch(
                    cause: "hardened build without audio-input",
                    fix: "rebuild with scripts/build-app.sh"
                )
            }
            if failing.field("owns") == "false" {
                return CauseMatch(
                    cause: "started from a shell; TCC bills Terminal/Cursor",
                    fix: "launch with open -n \"$CATCHER_APP\""
                )
            }
            if failing.field("mic") == "denied" {
                return CauseMatch(
                    cause: "denied row for com.catcher.app",
                    fix: "Privacy → Microphone toggle"
                )
            }
            if failing.field("mic") == "notDetermined" {
                return CauseMatch(
                    cause: "Allow never answered",
                    fix: "Request microphone with Catcher frontmost; quit Zoom"
                )
            }
            if failing.field("screen") == "denied" {
                return CauseMatch(
                    cause: "Screen & System Audio Recording missing",
                    fix: "grant it to com.catcher.app, relaunch"
                )
            }
            return nil
        case .captureStart:
            if failing.field("code") == "-3801" {
                return CauseMatch(
                    cause: "user declined screen capture",
                    fix: "grant Screen & System Audio Recording"
                )
            }
            return CauseMatch(
                cause: "SCStream failed to start",
                fix: "copy the domain/code line into the report"
            )
        case .framesReceived:
            let system = int(failing, "system")
            let microphone = int(failing, "microphone")
            if system == 0 && microphone > 0 {
                return CauseMatch(
                    cause: "no system buffers on the chosen display",
                    fix: "play audio on the captured display; check the display choice"
                )
            }
            if microphone == 0 {
                return CauseMatch(
                    cause: "mic device missing or not delivered",
                    fix: "check the default input device (preflight mic-device)"
                )
            }
            return nil
        case .pcmExtract:
            if failing.field("osstatus") == "-12737" {
                return CauseMatch(
                    cause: "retained-block-buffer variant used",
                    fix: "regression in SampleBufferPCM.extract"
                )
            }
            if int(failing, "failed") > 0 && contains(failing, "unsupportedFormat") {
                return CauseMatch(
                    cause: "SCK format changed",
                    fix: "the mBytesPerFrame/format detail names it"
                )
            }
            return nil
        case .apiConnect:
            if contains(failing, "missing XAI_API_KEY") {
                return CauseMatch(
                    cause: "key not forwarded",
                    fix: "export XAI_API_KEY; open --env forwards it via lib.sh"
                )
            }
            if failing.field("http") == "401" || failing.field("http") == "403" {
                return CauseMatch(
                    cause: "key rejected",
                    fix: "rotate the key; body shows the xAI reason"
                )
            }
            if contains(failing, "handshakeTimeout") {
                return CauseMatch(
                    cause: "socket open but no transcript.created",
                    fix: "check the model= query and xAI status"
                )
            }
            if matchesURLError(failing) {
                return CauseMatch(
                    cause: "DNS / offline / refused",
                    fix: "network, VPN, or a leftover P3 pf rule (pfctl -sr)"
                )
            }
            return nil
        case .apiStream:
            if int(failing, "system") == 0, pcmExtractWasOK(lines) {
                return CauseMatch(
                    cause: "pump never ran (ready=false)",
                    fix: "engine state bug; include the snapshot"
                )
            }
            return nil
        case .segmentsReceived:
            if int(failing, "apiErrors") > 0 {
                return CauseMatch(
                    cause: "xAI returned errors mid-stream",
                    fix: "the first error body is in error="
                )
            }
            if zeroEnergyWithBytes(lines) {
                return CauseMatch(
                    cause: "system track captured digital silence",
                    fix: "nothing was playing on the captured display, or the mixdown cancelled; check system.pcm peak/RMS and the chosen display"
                )
            }
            if int(failing, "blankDropped") > 0 && int(failing, "system") == 0 {
                return CauseMatch(
                    cause: "only endpoint spam came back",
                    fix: "audio too quiet or not speech"
                )
            }
            return nil
        case .transcriptWrite:
            if let error = failing.field("error"), !error.isEmpty {
                return CauseMatch(
                    cause: "assemble/end failed",
                    fix: "the error names the path and errno"
                )
            }
            if int(failing, "bytes") == 0 && int(failing, "segments") == 0 {
                return CauseMatch(
                    cause: "nothing to write",
                    fix: "the trace points upstream; this is a symptom"
                )
            }
            return nil
        }
    }

    public static func silenceSentence(lines: [StageLine]) -> String? {
        guard let pcm = last(lines, stage: .pcmExtract),
              let stream = last(lines, stage: .apiStream),
              let segments = last(lines, stage: .segmentsReceived) else { return nil }
        let tracks = zeroEnergyTracks(pcm)
        var parts: [String] = []
        for track in tracks {
            let bytes = int(stream, track)
            let finals = int(segments, track)
            if bytes > 0 && finals == 0 {
                parts.append("\(track): \(finals) finals from \(bytes) bytes; every \(track) PCM frame is zero")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    static func zeroEnergyWithBytes(_ lines: [StageLine]) -> Bool {
        silenceSentence(lines: lines) != nil
    }

    static func zeroEnergyTracks(_ line: StageLine) -> [String] {
        let raw = line.field("zeroEnergy") ?? ""
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { part in
            !part.isEmpty && part != "none"
        }
    }

    static func pcmExtractWasOK(_ lines: [StageLine]) -> Bool {
        last(lines, stage: .pcmExtract)?.verdict == Verdict.ok.rawValue
    }

    static func last(_ lines: [StageLine], stage: Stage) -> StageLine? {
        lines.last { $0.stage == stage }
    }

    static func int(_ line: StageLine, _ key: String) -> Int {
        Int(line.field(key) ?? "") ?? 0
    }

    static func contains(_ line: StageLine, _ needle: String) -> Bool {
        if line.fields.contains(where: { $0.value.contains(needle) }) { return true }
        return line.name?.contains(needle) == true
    }

    static func matchesURLError(_ line: StageLine) -> Bool {
        let codes = ["-1003", "-1009", "-1004"]
        let blob = line.fields.map(\.value).joined(separator: " ")
        guard blob.contains("NSURLError") else { return false }
        if let code = line.field("code"), codes.contains(code) { return true }
        return codes.contains { blob.contains($0) }
    }
}
