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
import Darwin
import ScreenCaptureKit
import Security
import os

enum SCKPermissionProbe {
    private static let microphoneLog = Logger(subsystem: "com.catcher.app", category: "microphone")
    private static let authorityLock = NSLock()
    nonisolated(unsafe) private static var lastLoggedAuthority: String?

    /// Signing does not change while the process runs. Read once.
    private static let signingFacts: (hardened: Bool?, audioInput: Bool?) = readSigningFacts()

    /// Attribution does not change while the process runs either.
    private static let responsibleProcess: (pid: Int32?, name: String?) = readResponsibleProcess()

    /// Everything macOS uses to decide the microphone, in one struct. Logged as
    /// `Catcher mic authority` whenever the verdict changes, and always when `force` is set.
    static func readAuthority(force: Bool = true) -> MicrophoneAuthority {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let record: String
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: record = "granted"
            case .denied: record = "denied"
            case .undetermined: record = "undetermined"
            @unknown default: record = "unknown"
            }
        } else {
            record = "unavailable"
        }
        let bundle = Bundle.main
        let authority = MicrophoneAuthority(
            authorizationStatus: describe(status),
            recordPermission: record,
            hardenedRuntime: signingFacts.hardened,
            audioInputEntitlement: signingFacts.audioInput,
            pid: getpid(),
            parentPID: getppid(),
            responsiblePID: responsibleProcess.pid,
            responsibleName: responsibleProcess.name,
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL.path : bundle.executableURL?.path
        )
        let line = authority.consoleLine
        authorityLock.lock()
        let changed = lastLoggedAuthority != line
        lastLoggedAuthority = line
        authorityLock.unlock()
        if force || changed {
            microphoneLog.notice("\(line, privacy: .public)")
            NSLog("%@", line as NSString)
        }
        return authority
    }

    private static func readSigningFacts() -> (hardened: Bool?, audioInput: Bool?) {
        var hardened: Bool?
        var code: SecCode?
        if SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode {
                var info: CFDictionary?
                let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
                if SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
                   let dictionary = info as? [String: Any] {
                    let raw = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
                    hardened = (raw & SecCodeSignatureFlags.runtime.rawValue) != 0
                }
            }
        }
        var audioInput: Bool?
        if let task = SecTaskCreateFromSelf(nil) {
            var error: Unmanaged<CFError>?
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.device.audio-input" as CFString, &error)
            if error == nil {
                audioInput = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
            }
        }
        return (hardened, audioInput)
    }

    /// `responsibility_get_pid_responsible_for_pid` is what tccd itself consults.
    /// It is exported from libSystem without a public header; resolve it at runtime.
    private static func readResponsibleProcess() -> (pid: Int32?, name: String?) {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return (nil, nil)
        }
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        let responsible = lookup(getpid())
        guard responsible > 0 else { return (nil, nil) }
        if responsible == getpid() {
            return (responsible, Bundle.main.bundleIdentifier ?? "Catcher")
        }
        let app = NSRunningApplication(processIdentifier: responsible)
        let name = app?.localizedName ?? app?.bundleIdentifier ?? "pid \(responsible)"
        return (responsible, name)
    }

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
        // Signing and attribution decide before any dialog. A prompt in either
        // state is a silent deny or a prompt for the wrong app.
        let preflight = readAuthority()
        if preflight.recovery == .rebuildWithEntitlement || preflight.recovery == .relaunchUnderOwnIdentity,
           let reason = preflight.blockReason {
            return .blocked(reason: reason)
        }
        let report = await MicrophonePromptGate.shared.run(statusAtLaunch: describe(atLaunch))
        // The verdict is the readback after the prompt, not the prompt's own label.
        let authority = readAuthority()
        if let reason = authority.blockReason {
            return .blocked(reason: reason)
        }
        if report.attempt != .granted {
            NSLog("Catcher mic prompt reported \(report.attempt.rawValue) but the readback is \(authority.authorizationStatus); the readback wins")
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
            let ns = error as NSError
            return .blocked(reason: "startCapture failed: \(ns.localizedDescription) (\(ns.domain) \(ns.code))")
        }
    }

    static func recheck() -> PermissionState {
        let denied = !CGPreflightScreenCaptureAccess()
        let livePreflight = TCCScreenPreflight.current()
        let liveWindows = windowSample()
        if ScreenGrantMemory.revoked(
            preflightDenied: denied,
            livePreflight: livePreflight,
            liveWindows: liveWindows
        ) {
            NSLog(
                "Catcher screen recording revoked mid-session preflightDenied=\(denied) livePreflight=\(livePreflight.map(String.init) ?? "nil") titled=\(liveWindows.titledOtherWindows)/\(liveWindows.otherWindows)"
            )
            return .blocked(reason: "screen recording access denied")
        }
        if liveWindows.titledOtherWindows > 0 {
            ScreenGrantMemory.noteWindows(liveWindows)
        }
        if let reason = readAuthority(force: false).blockReason {
            return .blocked(reason: reason)
        }
        return .granted
    }

    /// Sampled only after a capture has actually started, while the grant is real.
    static func noteScreenGrant() {
        ScreenGrantMemory.noteAtCaptureStart(
            preflight: TCCScreenPreflight.current(),
            windows: windowSample()
        )
    }

    private static func windowSample() -> WindowTitleSample {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return WindowTitleSample(otherWindows: 0, titledOtherWindows: 0)
        }
        let mine = Int(getpid())
        var others = 0
        var titled = 0
        for window in info {
            let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
            if pid == 0 || pid == mine { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer != 0 { continue }
            others += 1
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                titled += 1
            }
        }
        return WindowTitleSample(otherWindows: others, titledOtherWindows: titled)
    }

    /// Allow dialog only. Does not request screen capture and does not open Settings.
    /// Off-main `requestAccess` returns false and stores `.denied` with no dialog,
    /// which is the launch banner right after a Microphone reset. While status is
    /// still `.notDetermined`, Sequoia's `requestRecordPermission` runs first on
    /// the main actor so it can present Allow before `requestAccess` is called.
    /// `requestAccess` itself is always invoked on the main actor after that.
    fileprivate static func promptBody(statusAtLaunch: String) async -> MicrophonePromptReport {
        let authority = readAuthority()
        if authority.recovery == .rebuildWithEntitlement || authority.recovery == .relaunchUnderOwnIdentity {
            // requestAccess here is either refused with no dialog (signing) or
            // shows Allow for Terminal/Cursor instead of Catcher (attribution).
            NSLog("Catcher mic prompt skipped: \(authority.blockReason ?? "blocked")")
            let current = AVCaptureDevice.authorizationStatus(for: .audio)
            return MicrophonePromptReport(
                attempt: attempt(for: current),
                statusAtLaunch: statusAtLaunch,
                statusBeforeRequestAccess: describe(current),
                statusAfterRequestAccess: describe(current)
            )
        }
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
        SCKPermissionProbe.noteScreenGrant()
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
        if let code = SCStreamError.Code(rawValue: ns.code) {
            switch code {
            case .userDeclined, .systemStoppedStream, .userStopped:
                let domain = ns.domain.lowercased()
                if domain.contains("screencapture") || domain.contains("scstream") {
                    return .tccRevokedMidSession
                }
            default:
                break
            }
        }
        return CaptureStop.classify(domain: ns.domain, code: ns.code, description: ns.localizedDescription)
    }
}

/// TCC's own preflight, not `CGPreflightScreenCaptureAccess`. The CoreGraphics
/// call caches the first answer in this process; this one is asked again.
private enum TCCScreenPreflight {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var resolved = false
        var function: (@convention(c) (CFString, CFDictionary?) -> Int32)?
    }

    private static let box = Box()

    static func current() -> Int32? {
        let function = resolve()
        return function?("kTCCServiceScreenCapture" as CFString, nil)
    }

    private static func resolve() -> (@convention(c) (CFString, CFDictionary?) -> Int32)? {
        box.lock.lock()
        defer { box.lock.unlock() }
        if !box.resolved {
            box.resolved = true
            if let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
               let symbol = dlsym(handle, "TCCAccessPreflight") {
                box.function = unsafeBitCast(symbol, to: (@convention(c) (CFString, CFDictionary?) -> Int32).self)
            }
        }
        return box.function
    }
}

/// Baseline taken when capture started. A later difference is the revoke.
private enum ScreenGrantMemory {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var preflight: Int32?
        var windows = WindowTitleSample(otherWindows: 0, titledOtherWindows: 0)
    }

    private static let box = Box()

    static func noteAtCaptureStart(preflight: Int32?, windows: WindowTitleSample) {
        box.lock.lock()
        if box.preflight == nil {
            box.preflight = preflight
        }
        if box.windows.titledOtherWindows == 0, windows.titledOtherWindows > 0 {
            box.windows = windows
        }
        box.lock.unlock()
    }

    static func noteWindows(_ windows: WindowTitleSample) {
        box.lock.lock()
        if box.windows.titledOtherWindows == 0, windows.titledOtherWindows > 0 {
            box.windows = windows
        }
        box.lock.unlock()
    }

    static func revoked(preflightDenied: Bool, livePreflight: Int32?, liveWindows: WindowTitleSample) -> Bool {
        box.lock.lock()
        let grantedPreflight = box.preflight
        let grantedWindows = box.windows
        box.lock.unlock()
        return ScreenRevokeWatch.isRevoked(
            preflightDenied: preflightDenied,
            grantedPreflight: grantedPreflight,
            livePreflight: livePreflight,
            grantedWindows: grantedWindows,
            liveWindows: liveWindows
        )
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
