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
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import os

enum SCKPermissionProbe {
    private static let microphoneLog = Logger(subsystem: "com.catcher.app", category: "microphone")

    /// One launch probe at a time. A second `requestAccess` while the first dialog
    /// is up returns false and TCC records `.denied` with no Allow button.
    static func run() async -> PermissionState {
        await LaunchProbeGate.shared.run()
    }

    static func promptMicrophone(statusAtLaunch: String? = nil) async -> MicrophonePromptReport {
        if let launch = await LaunchProbeGate.shared.inFlight() {
            _ = await launch.value
            if let report = await MicrophonePromptGate.shared.latest() {
                return report
            }
        }
        let launchStatus = statusAtLaunch ?? describe(AVCaptureDevice.authorizationStatus(for: .audio))
        return await MicrophonePromptGate.shared.run(statusAtLaunch: launchStatus)
    }

    /// Screen prompt first, then the microphone dialog. Overlapping them lets the
    /// screen UI win; `requestAccess` then returns without an Allow dialog and
    /// lands `.denied` before Catcher is on the Microphone list.
    fileprivate static func runBody() async -> PermissionState {
        let atLaunch = AVCaptureDevice.authorizationStatus(for: .audio)
        logStatus("at launch before screen or requestAccess", atLaunch)
        NSLog("Catcher permission order: resolveScreenCapture then promptMicrophone")
        let screenGranted = await resolveScreenCapture()
        let afterScreen = AVCaptureDevice.authorizationStatus(for: .audio)
        logStatus("after screen capture before microphone prompt", afterScreen)
        let report = await MicrophonePromptGate.shared.run(statusAtLaunch: describe(atLaunch))
        switch report.attempt {
        case .granted:
            break
        case .denied, .notDetermined, .restricted:
            return .blocked(reason: MicrophoneRegrant.blockReason(for: report.attempt))
        }
        if !screenGranted && !CGPreflightScreenCaptureAccess() {
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

    /// Allow dialog only. Does not request screen capture and does not open Settings.
    /// Off-main `requestAccess` returns false and stores `.denied` with no dialog,
    /// which is the launch banner right after a Microphone reset. While status is
    /// still `.notDetermined`, Sequoia's `requestRecordPermission` runs first on
    /// the main actor so it can present Allow before `requestAccess` is called.
    /// `requestAccess` itself is always invoked on the main actor after that.
    fileprivate static func promptBody(statusAtLaunch: String) async -> MicrophonePromptReport {
        await MainActor.run {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        let initial = AVCaptureDevice.authorizationStatus(for: .audio)
        if initial == .notDetermined {
            let recordGranted = await requestRecordPermission()
            let mid = AVCaptureDevice.authorizationStatus(for: .audio)
            logStatus("after AVAudioApplication.requestRecordPermission granted=\(recordGranted)", mid)
        }

        let before = AVCaptureDevice.authorizationStatus(for: .audio)
        logStatus("before requestAccess", before)
        let accessGranted = await requestDeviceAccess()
        let after = AVCaptureDevice.authorizationStatus(for: .audio)
        logStatus("after requestAccess granted=\(accessGranted)", after)
        return MicrophonePromptReport(
            attempt: attempt(for: after),
            statusAtLaunch: statusAtLaunch,
            statusBeforeRequestAccess: describe(before),
            statusAfterRequestAccess: describe(after)
        )
    }

    /// Wait until the screen-capture prompt is granted or the user is done with it.
    /// `CGRequestScreenCaptureAccess` can return while its dialog is still up on
    /// Sequoia; the microphone prompt must not start until that UI is gone.
    private static func resolveScreenCapture() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            NSLog("Catcher screen capture preflight already granted; microphone prompt is next")
            return true
        }
        NSLog("Catcher screen capture prompt starting; microphone prompt will not run until it finishes")
        let settingsFrontBefore = systemSettingsIsFrontmost()
        let started = Date()
        // Detached so a blocking screen prompt cannot freeze the main actor that
        // the microphone dialog needs next.
        let requested = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        if requested || CGPreflightScreenCaptureAccess() {
            NSLog("Catcher screen capture granted; microphone prompt is next")
            return true
        }
        let callWaited = Date().timeIntervalSince(started) > 0.5
        if callWaited && !screenPromptStillUp(settingsFrontBefore: settingsFrontBefore) {
            NSLog("Catcher screen capture prompt finished without grant; microphone prompt is next")
            return false
        }
        let appearDeadline = Date().addingTimeInterval(3)
        var sawPrompt = false
        while Date() < appearDeadline {
            if CGPreflightScreenCaptureAccess() {
                NSLog("Catcher screen capture granted; microphone prompt is next")
                return true
            }
            if screenPromptStillUp(settingsFrontBefore: settingsFrontBefore) {
                sawPrompt = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard sawPrompt else {
            NSLog("Catcher screen capture prompt finished without grant; microphone prompt is next")
            return false
        }
        let giveUp = Date().addingTimeInterval(120)
        while Date() < giveUp {
            if CGPreflightScreenCaptureAccess() {
                NSLog("Catcher screen capture granted; microphone prompt is next")
                return true
            }
            if !screenPromptStillUp(settingsFrontBefore: settingsFrontBefore) {
                NSLog("Catcher screen capture prompt dismissed; microphone prompt is next")
                return false
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let granted = CGPreflightScreenCaptureAccess()
        NSLog("Catcher screen capture wait ended granted=\(granted); microphone prompt is next")
        return granted
    }

    /// Settings opening on top of Catcher is the screen prompt stealing focus.
    /// Only count Settings if it was not already frontmost before this request.
    private static func screenPromptStillUp(settingsFrontBefore: Bool) -> Bool {
        if screenCapturePromptIsOnScreen() { return true }
        if settingsFrontBefore { return false }
        return systemSettingsIsFrontmost()
    }

    private static func systemSettingsIsFrontmost() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName?.lowercased() ?? ""
        let bundle = app?.bundleIdentifier?.lowercased() ?? ""
        return name.contains("system settings") || bundle == "com.apple.systempreferences"
    }

    private static func screenCapturePromptIsOnScreen() -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let name = (window[kCGWindowName as String] as? String ?? "").lowercased()
            if owner.contains("universalaccessauthwarn") { return true }
            if name.contains("screen recording") || name.contains("screen & system audio") { return true }
        }
        return false
    }

    /// Hop to the main actor, then call. The continuation is resumed from TCC's
    /// callback, which may be synchronous when status is already determined.
    private static func requestDeviceAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                if #available(macOS 14.0, *) {
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func attempt(for status: AVAuthorizationStatus) -> MicrophonePromptAttempt {
        switch status {
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }

    private static func logStatus(_ when: String, _ status: AVAuthorizationStatus) {
        let line = "Catcher mic authorizationStatus \(when): \(describe(status))"
        microphoneLog.notice("\(line, privacy: .public)")
        NSLog("%@", line as NSString)
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "notDetermined"
        case .restricted:
            "restricted"
        case .denied:
            "denied"
        case .authorized:
            "authorized"
        @unknown default:
            "unknown(\(status.rawValue))"
        }
    }

    static func latestMicrophonePrompt() async -> MicrophonePromptReport? {
        await MicrophonePromptGate.shared.latest()
    }
}

private actor LaunchProbeGate {
    static let shared = LaunchProbeGate()
    private var task: Task<PermissionState, Never>?

    func inFlight() -> Task<PermissionState, Never>? { task }

    func run() async -> PermissionState {
        if let task { return await task.value }
        let task = Task.detached { await SCKPermissionProbe.runBody() }
        self.task = task
        let value = await task.value
        self.task = nil
        return value
    }
}

private actor MicrophonePromptGate {
    static let shared = MicrophonePromptGate()
    private var task: Task<MicrophonePromptReport, Never>?
    private var stored: MicrophonePromptReport?

    func latest() -> MicrophonePromptReport? { stored }

    func run(statusAtLaunch: String) async -> MicrophonePromptReport {
        if let task { return await task.value }
        let task = Task.detached {
            await SCKPermissionProbe.promptBody(statusAtLaunch: statusAtLaunch)
        }
        self.task = task
        let report = await task.value
        stored = report
        self.task = nil
        return report
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
