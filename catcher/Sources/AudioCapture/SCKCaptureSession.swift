import Foundation

public protocol AudioCapturing: Sendable {
    nonisolated var frames: AsyncStream<PCMFrame> { get }
    nonisolated var failures: AsyncStream<CaptureError> { get }
    func start() async throws
    func stop() async
}

public enum AudioCaptureBackend {
    public static func make() -> any AudioCapturing {
        #if canImport(ScreenCaptureKit)
        return SCKCaptureSession()
        #else
        return UnavailableCapture()
        #endif
    }
}

/// Used where ScreenCaptureKit cannot run. `start` fails loud.
public final class UnavailableCapture: AudioCapturing, @unchecked Sendable {
    public let frames: AsyncStream<PCMFrame>
    public let failures: AsyncStream<CaptureError>
    private let frameContinuation: AsyncStream<PCMFrame>.Continuation
    private let failureContinuation: AsyncStream<CaptureError>.Continuation

    public init() {
        let frames = AsyncStream<PCMFrame>.makeStream()
        let failures = AsyncStream<CaptureError>.makeStream()
        self.frames = frames.stream
        self.frameContinuation = frames.continuation
        self.failures = failures.stream
        self.failureContinuation = failures.continuation
    }

    public func start() async throws {
        let error = CaptureError.unavailable("ScreenCaptureKit is unavailable on this platform")
        failureContinuation.yield(error)
        throw error
    }

    public func stop() async {
        frameContinuation.finish()
        failureContinuation.finish()
    }
}

#if canImport(ScreenCaptureKit)
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum SCKPermissionProbe {
    static func run() async -> PermissionState {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if !granted {
                return .blocked(reason: "microphone access denied")
            }
        case .denied, .restricted:
            return .blocked(reason: "microphone access denied")
        @unknown default:
            return .blocked(reason: "microphone access unavailable")
        }
        if !CGPreflightScreenCaptureAccess() {
            return .blocked(reason: "screen recording access denied")
        }
        let session = SCKCaptureSession()
        do {
            try await session.start()
            await session.stop()
            return .granted
        } catch {
            return .blocked(reason: error.localizedDescription)
        }
    }

    static func recheck() -> PermissionState {
        if !CGPreflightScreenCaptureAccess() {
            return .blocked(reason: "screen recording access denied")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .blocked(reason: "microphone access denied")
        case .notDetermined:
            return .blocked(reason: "microphone access not determined")
        @unknown default:
            return .blocked(reason: "microphone access unavailable")
        }
    }

    static func requestMicrophoneAccessIfNotDetermined() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            return false
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }
}

public final class SCKCaptureSession: NSObject, AudioCapturing, SCStreamDelegate, @unchecked Sendable {
    public let frames: AsyncStream<PCMFrame>
    public let failures: AsyncStream<CaptureError>
    private let frameContinuation: AsyncStream<PCMFrame>.Continuation
    private let failureContinuation: AsyncStream<CaptureError>.Continuation
    private let audioQueue = DispatchQueue(label: "com.catcher.sck.audio", qos: .userInteractive)
    private let microphoneQueue = DispatchQueue(label: "com.catcher.sck.microphone", qos: .userInteractive)
    private let screenQueue = DispatchQueue(label: "com.catcher.sck.screen", qos: .utility)
    private let lock = NSLock()
    private var stream: SCStream?
    private var outputs: [NSObject] = []
    private var accepting = false
    private var reportedExtractionFailure = false

    public override init() {
        let frames = AsyncStream<PCMFrame>.makeStream()
        let failures = AsyncStream<CaptureError>.makeStream()
        self.frames = frames.stream
        self.frameContinuation = frames.continuation
        self.failures = failures.stream
        self.failureContinuation = failures.continuation
        super.init()
    }

    public func start() async throws {
        var config = CaptureConfig.make()
        if config.microphoneDeviceID == nil {
            config.microphoneDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }
        guard config.wholeDisplay else {
            throw CaptureError.streamStopped("capture config is not whole-display")
        }
        // onScreenWindowsOnly would hide windowless players such as afplay.
        // excludingWindows only attaches audio to apps that have windows on the
        // chosen display, so that fixture never enters the .audio mix. An empty
        // excludingApplications list is the whole-display mix, including processes
        // that start after the stream (the harness plays afplay two seconds in).
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ranked = content.displays.map { display -> SystemAudioDisplay in
            let id = display.displayID
            return SystemAudioDisplay(
                id: id,
                active: CGDisplayIsActive(id) != 0,
                asleep: CGDisplayIsAsleep(id) != 0,
                isMain: id == CGMainDisplayID()
            )
        }
        guard let chosen = SystemAudioDisplayChoice.preferred(ranked),
              let display = content.displays.first(where: { $0.displayID == chosen }) else {
            throw CaptureError.tccDenied("no display available for whole-display capture")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let streamConfig = SCStreamConfiguration()
        config.apply(to: streamConfig)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        let audio = PCMOutput(track: .system, onFrame: { [weak self] frame in
            self?.emit(frame)
        }, onFailure: { [weak self] error in
            self?.emitFailure(error)
        })
        let microphone = PCMOutput(track: .microphone, onFrame: { [weak self] frame in
            self?.emit(frame)
        }, onFailure: { [weak self] error in
            self?.emitFailure(error)
        })
        // Video still runs inside an audio capture. A screen consumer keeps those
        // frames off the audio queue. Audio-only still delivers buffers if this add fails.
        let screen = DiscardingScreenOutput()
        try? stream.addStreamOutput(screen, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(audio, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(microphone, type: .microphone, sampleHandlerQueue: microphoneQueue)
        // Accept before startCapture. Buffers can arrive before startCapture returns,
        // and dropping them on `accepting == false` used to throw away the head of the take.
        arm(stream: stream, outputs: [audio, microphone, screen])
        do {
            try await stream.startCapture()
        } catch {
            _ = takeStream()
            throw error
        }
    }

    private func arm(stream: SCStream, outputs: [NSObject]) {
        lock.lock()
        self.stream = stream
        self.outputs = outputs
        self.accepting = true
        lock.unlock()
    }

    public func stop() async {
        let stream = takeStream()
        if let stream {
            try? await stream.stopCapture()
        }
        frameContinuation.finish()
        failureContinuation.finish()
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        failureContinuation.yield(Self.classify(error))
    }

    private func takeStream() -> SCStream? {
        lock.lock()
        accepting = false
        let stream = self.stream
        self.stream = nil
        self.outputs = []
        lock.unlock()
        return stream
    }

    private func emit(_ frame: PCMFrame) {
        lock.lock()
        let open = accepting
        lock.unlock()
        guard open else { return }
        frameContinuation.yield(frame)
    }

    private func emitFailure(_ error: CaptureError) {
        lock.lock()
        let open = accepting
        let report: Bool
        if case .pcmExtractionFailed = error {
            report = !reportedExtractionFailure
            reportedExtractionFailure = true
        } else {
            report = true
        }
        lock.unlock()
        guard open, report else { return }
        failureContinuation.yield(error)
    }

    static func classify(_ error: Error) -> CaptureError {
        let ns = error as NSError
        let blob = (ns.domain + " " + ns.localizedDescription).lowercased()
        if blob.contains("tcc") || blob.contains("permission") || blob.contains("not authorized") || blob.contains("denied") {
            return .tccRevokedMidSession
        }
        return .streamStopped(ns.localizedDescription)
    }
}

private final class DiscardingScreenOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

private final class PCMOutput: NSObject, SCStreamOutput {
    let track: AudioTrack
    let onFrame: (PCMFrame) -> Void
    let onFailure: (CaptureError) -> Void

    init(
        track: AudioTrack,
        onFrame: @escaping (PCMFrame) -> Void,
        onFailure: @escaping (CaptureError) -> Void
    ) {
        self.track = track
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        do {
            let data = try SampleBufferPCM.extract(from: sampleBuffer)
            let frame = PCMFrame(
                track: track,
                data: data,
                hostTime: HostClock.now(),
                sampleCount: data.count / AudioFormat.bytesPerSample
            )
            onFrame(frame)
        } catch let error as CaptureError {
            onFailure(error)
        } catch let failure as SampleBufferPCM.Failure {
            onFailure(.pcmExtractionFailed(status: -1, detail: String(describing: failure)))
        } catch {
            onFailure(.pcmExtractionFailed(status: -1, detail: String(describing: error)))
        }
    }
}
#endif
