import AudioCapture
import Foundation
import TranscriptionEngine

public struct VerifierEffect: Sendable, Equatable {
    public var snapshot: VerifierSnapshot
    public var annotations: [Annotation]

    public init(snapshot: VerifierSnapshot, annotations: [Annotation]) {
        self.snapshot = snapshot
        self.annotations = annotations
    }
}

/// Separate actor from capture and the engine. A dead tick shows up as a stale
/// `updatedAt` on the snapshot; the UI treats that as degraded while recording.
public actor Verifier {
    public private(set) var snapshot: VerifierSnapshot = .idle
    private var permission = PermissionCheck()
    private var audio = AudioFlowCheck()
    private var transport = TransportHeartbeatCheck()
    private var sanity = TranscriptSanityCheck()
    private var crash = CrashSafetyCheck()
    private var recording = false
    private var forcedReason: String?

    public init() {}

    public func beginSession(atMs: Int) -> VerifierEffect {
        permission.reset()
        audio.begin(atMs: atMs)
        transport.reset()
        sanity.reset()
        crash.reset()
        forcedReason = nil
        recording = true
        return publish(annotations: [], atMs: atMs)
    }

    public func endSession() -> VerifierEffect {
        recording = false
        return publish(annotations: [], atMs: 0)
    }

    public func observePermission(_ state: PermissionState, atMs: Int) -> VerifierEffect {
        publish(annotations: permission.observe(state, atMs: atMs), atMs: atMs)
    }

    public func observeCapture(_ error: CaptureError, atMs: Int) -> VerifierEffect {
        var annotations = permission.observe(error, atMs: atMs)
        if case .pcmExtractionFailed(let status, let detail) = error {
            let reason = detail.isEmpty
                ? "pcm extraction failed (\(status))"
                : "pcm extraction failed (\(status)): \(detail)"
            if forcedReason == nil {
                forcedReason = reason
            }
            annotations.append(Annotation(atMs: atMs, kind: "degraded", detail: .text(reason)))
        }
        return publish(annotations: annotations, atMs: atMs)
    }

    public func observeReprobe(_ state: PermissionState, atMs: Int) -> VerifierEffect {
        var annotations = permission.observeSilence(allSilent: audio.allSilent, reprobe: state, atMs: atMs)
        if annotations.isEmpty, case .blocked = state {
            annotations = permission.observe(state, atMs: atMs)
        }
        return publish(annotations: annotations, atMs: atMs)
    }

    public func observeFrame(_ frame: PCMFrame, atMs: Int) -> VerifierEffect {
        guard recording else { return VerifierEffect(snapshot: snapshot, annotations: []) }
        let rms = PCMEnergy.rms(frame.data)
        let annotation = audio.observe(track: frame.track, rms: rms, atMs: atMs)
        sanity.setAudioFlowing(!audio.allSilent && rms > AudioFlowCheck.rmsEpsilon)
        return publish(annotations: annotation.map { [$0] } ?? [], atMs: atMs)
    }

    public func observeEngine(_ event: EngineEvent, track: AudioTrack, atMs: Int, storedCount: Int) -> VerifierEffect {
        let annotations = transport.observe(event, track: track, atMs: atMs)
        if case .transcript(let transcript) = event, transcript.kind == .final {
            sanity.observeFinal(text: transcript.text)
            crash.observeEngineFinal(atMs: atMs, storedCount: storedCount)
        }
        return publish(annotations: annotations, atMs: atMs)
    }

    public func observeStored(count: Int, atMs: Int) -> VerifierEffect {
        crash.observeStored(count: count)
        return publish(annotations: [], atMs: atMs)
    }

    public func observeStoreFailure(_ message: String, atMs: Int) -> VerifierEffect {
        forcedReason = message
        return publish(annotations: [Annotation(atMs: atMs, kind: "degraded", detail: .text(message))], atMs: atMs)
    }

    public func tick(atMs: Int) -> VerifierEffect {
        guard recording else {
            snapshot.updatedAt = Date()
            return VerifierEffect(snapshot: snapshot, annotations: [])
        }
        var annotations: [Annotation] = []
        if let audioAnn = audio.tick(atMs: atMs) {
            annotations.append(audioAnn)
        }
        sanity.setAudioFlowing(!audio.allSilent)
        if let sanityAnn = sanity.tick(atMs: atMs) {
            annotations.append(sanityAnn)
        }
        annotations.append(contentsOf: transport.tick(atMs: atMs, audioFlowing: !audio.allSilent && !audio.noAudio))
        if let crashAnn = crash.tick(atMs: atMs) {
            annotations.append(crashAnn)
        }
        return publish(annotations: annotations, atMs: atMs)
    }

    private func publish(annotations: [Annotation], atMs: Int) -> VerifierEffect {
        let status = reduce()
        var banner: String?
        var logLine: String?
        var notification: String?
        for annotation in annotations {
            let channels = Loud.channels(annotation: annotation, status: status)
            Loud.deliver(channels)
            banner = channels.banner
            logLine = channels.logLine
            notification = channels.notificationBody
        }
        if annotations.isEmpty, status.isOk {
            banner = nil
        } else if annotations.isEmpty {
            banner = snapshot.banner
        }
        snapshot = VerifierSnapshot(
            status: status,
            banner: banner ?? (status.isOk ? nil : snapshot.banner),
            updatedAt: Date(),
            logLine: logLine,
            notificationBody: notification
        )
        _ = atMs
        return VerifierEffect(snapshot: snapshot, annotations: annotations)
    }

    private func reduce() -> VerifierStatus {
        if let reason = permission.blockReason {
            return .blocked(reason)
        }
        if audio.noAudio {
            return .noAudio(audio.detail)
        }
        if let forcedReason {
            return .degraded(forcedReason)
        }
        if transport.degraded {
            return .degraded(transport.reason)
        }
        if sanity.flagged {
            return .degraded(sanity.detail)
        }
        if crash.flagged {
            return .degraded(crash.detail)
        }
        return .ok
    }
}
