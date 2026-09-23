import AppKit
import AudioCapture
import Diagnostics
import GrokEngine
import Observation
import Pipeline
import SessionStore
import SwiftUI
import TranscriptionEngine
import Verifier

@main
struct CatcherApp: App {
    @NSApplicationDelegateAdaptor(HarnessAppDelegate.self) private var harnessDelegate
    @State private var model = CatcherModel()

    var body: some Scene {
        WindowGroup(id: "content") {
            ContentView(model: model)
        }
        .defaultLaunchBehavior(.presented)
    }
}

/// Harness launches must show the content window. Preflight quits without one.
/// A normal launch is unchanged.
@MainActor
final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    private var ticker: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launch = LaunchConfiguration.resolve()
        guard launch.harness, !launch.preflight else { return }
        let root = SessionPaths.root(environment: launch.mergedEnvironment())
        HarnessWindow.present(sessionRoot: root)
        // `timer` stays in this callback. Moving it into `assumeIsolated` sends
        // a non-Sendable Timer across the main-actor boundary and the build fails.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            let stop = MainActor.assumeIsolated {
                HarnessWindow.noteTick()
            }
            if stop {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                HarnessWindow.present(sessionRoot: root)
            }
        }
    }
}

/// Orders the content window front and records that it is on screen.
@MainActor
enum HarnessWindow {
    private static var ticks = 0

    /// True when the launch-time raise loop should stop.
    static func noteTick() -> Bool {
        ticks += 1
        return ticks > 60
    }

    static func present(sessionRoot: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if contentWindows.isEmpty {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
        for window in contentWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
        let ready = NSApp.isActive && contentWindows.contains { window in
            window.isKeyWindow && window.isVisible && window.screen != nil && window.frame.height >= 20
        }
        let url = sessionRoot.appendingPathComponent("window_front")
        if ready {
            let text = "pid=\(ProcessInfo.processInfo.processIdentifier) frontmost=1 visible=1\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static var contentWindows: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeKey && $0.level == .normal }
    }
}

struct TranscriptLine: Identifiable, Equatable {
    var id: String
    var track: AudioTrack
    var text: String
    var speaker: String?
    var isFinal: Bool
    var startMs: Int
}

@MainActor
@Observable
final class CatcherModel {
    var isRecording = false
    var status: VerifierStatus = .ok
    var banner: String?
    var statusUpdatedAt = Date.distantPast
    var lines: [TranscriptLine] = []
    var permissionAlert: String?
    var microphoneRecovery: MicrophoneRecovery = .none
    var sessions: [SessionSummary] = []
    var selectedID: String?
    var selectedTranscript = ""
    private var finals: [TranscriptEvent] = []
    private var partials: [AudioTrack: TranscriptEvent] = [:]
    private var listenTask: Task<Void, Never>?
    private let pipeline: Pipeline
    private let sessionRoot: URL
    private let autoRecord: Bool
    private let harness: Bool
    private var launchStarted = false
    private var preflightStarted = false
    private let preflight: Bool
    private let launchEnvironment: [String: String]

    init() {
        GrokEngineBootstrap.install()
        let launch = LaunchConfiguration.resolve()
        let environment = launch.mergedEnvironment(ProcessInfo.processInfo.environment)
        launchEnvironment = environment
        preflight = launch.preflight
        if !launch.preflight {
            Loud.prepare()
        }
        let root = SessionPaths.root(environment: environment)
        sessionRoot = root
        autoRecord = launch.autoRecord
        harness = launch.harness
        if launch.harness {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let pid = String(ProcessInfo.processInfo.processIdentifier)
                try pid.write(to: root.appendingPathComponent("catcher.pid"), atomically: true, encoding: .utf8)
            } catch {
                let sentence = ErrorDetail.sentence(error)
                StageMirror.note("catcher.pid \(sentence)")
                let sink = FileStageSink(directory: root, fileName: "launch-stages.log")
                for line in FailureTrace.report(lines: [], fallbackError: "catcher.pid \(sentence)").lines {
                    sink.write(line, fsync: true)
                }
            }
        }
        pipeline = Pipeline(
            sessionRoot: root,
            makeEngine: { track in
                try EngineFactory.make(track: track, environment: environment)
            },
            recordPCM: environment["CATCHER_HARNESS"] == "1",
            engineLabel: EngineFactory.sessionEngineName(environment: environment)
        )
        if harness {
            let pipeline = pipeline
            HarnessShutdown.install {
                await pipeline.stopAfterLiveTail()
            }
        }
        // --preflight must not wait for the SwiftUI window. A launch that
        // never shows a window never runs `.task`, so onAppear never quits
        // and `open -W` would sit on signing PASS. This task writes the
        // report and terminates even when the window stays hidden.
        if preflight {
            preflightStarted = true
            Task { @MainActor in
                await self.runPreflightAndQuit()
            }
        }
    }

    func onAppear() async {
        if preflight {
            if !preflightStarted {
                preflightStarted = true
                await runPreflightAndQuit()
            }
            return
        }
        // A second pass (SwiftUI re-creates the task when Screen Recording is
        // toggled) used to call toggle() on the live session and write a clean
        // end with no blocked ann, then start a new session that failed at 0.
        if launchStarted { return }
        launchStarted = true
        let reports: [RecoveryReport]
        do {
            reports = try Recovery.scan(root: sessionRoot)
        } catch {
            StageMirror.note("recovery scan \(ErrorDetail.sentence(error))")
            reports = []
        }
        if !reports.isEmpty {
            let annotation = Annotation(
                atMs: 0,
                kind: "recovered",
                detail: .text("recovered \(reports.count) session(s) without an end row")
            )
            let channels = Loud.channels(
                annotation: annotation,
                status: .degraded(annotation.detail.map { detail in
                    if case .text(let text) = detail { return text }
                    return "recovered"
                } ?? "recovered")
            )
            Loud.deliver(channels)
            banner = channels.banner
        }
        await refreshSessions()
        if harness {
            HarnessWindow.present(sessionRoot: sessionRoot)
        }
        let probe = await PermissionGate.startCaptureProbe()
        await applyLaunchProbe(probe)
        listen()
        if autoRecord, !status.isBlocked {
            await toggle()
        }
    }

    func toggle() async {
        if await pipeline.isRunning {
            await pipeline.stop()
        } else if !status.isBlocked {
            finals = []
            partials = [:]
            rebuildLines()
            await pipeline.start()
        }
        isRecording = await pipeline.isRunning
        if harness, isRecording {
            await pinLiveSession()
        }
        await refreshSessions()
        if !isRecording {
            await refreshSessions()
        }
    }

    func regrant() {
        let reason = blockReason
        Task { await self.performRegrant(reason: reason) }
    }

    /// Reads the microphone authority first, then does the one thing that
    /// readback calls for. It always re-reads and republishes, so a banner that
    /// disagrees with `AVCaptureDevice` cannot survive a press.
    func requestMicrophone() {
        Task { await self.recoverMicrophone(openScreenSettingsIfNeeded: false) }
    }

    private var blockReason: String {
        if case .blocked(let reason) = status { return reason }
        return ""
    }

    private func performRegrant(reason: String) async {
        if PrivacySettingsPane.forBlockReason(reason) == .microphone || reason.hasPrefix("startCapture failed") {
            await recoverMicrophone(openScreenSettingsIfNeeded: true)
            return
        }
        openSettings(.screenCapture)
    }

    private func recoverMicrophone(openScreenSettingsIfNeeded: Bool) async {
        let authority = PermissionGate.readMicrophoneAuthority()
        microphoneRecovery = authority.recovery
        switch authority.recovery {
        case .rebuildWithEntitlement:
            publish(authority, prompt: nil)
            return
        case .relaunchUnderOwnIdentity:
            publish(authority, prompt: nil)
            relaunchUnderOwnIdentity(authority)
            return
        case .prompt, .openMicrophoneSettings, .none:
            break
        }
        // Authorized returns at once with no dialog; notDetermined shows Allow;
        // a stored denial comes straight back and is then routed to Settings.
        let report = await PermissionGate.promptMicrophone()
        let after = PermissionGate.readMicrophoneAuthority()
        microphoneRecovery = after.recovery
        if after.blockReason != nil {
            publish(after, prompt: report)
            if after.recovery == .openMicrophoneSettings {
                openSettings(.microphone)
            }
            return
        }
        permissionAlert = nil
        // Not blocked on the microphone. Re-prove capture instead of trusting
        // whatever the banner said before. A live session keeps the verifier as
        // the owner of status and only gets the light recheck.
        if isRecording {
            let live = PermissionGate.recheck()
            if case .blocked = live {
                applyPermission(live)
            }
            return
        }
        let followUp = await PermissionGate.startCaptureProbe()
        applyPermission(followUp)
        guard openScreenSettingsIfNeeded,
              case .blocked(let reason) = followUp,
              PrivacySettingsPane.forBlockReason(reason) == .screenCapture else { return }
        openSettings(.screenCapture)
    }

    private func publish(_ authority: MicrophoneAuthority, prompt: MicrophonePromptReport?) {
        guard let reason = authority.blockReason else { return }
        applyPermission(.blocked(reason: reason))
        if authority.recovery == .prompt, let failure = prompt?.loudFailure {
            permissionAlert = failure
        } else {
            permissionAlert = authority.explanation
        }
    }

    /// TCC bills the responsible process. Started from a shell, that is Terminal
    /// or Cursor, and no dialog can ever name Catcher. LaunchServices spawns a
    /// copy that is responsible for itself, with the same arguments and env.
    private func relaunchUnderOwnIdentity(_ authority: MicrophoneAuthority) {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            permissionAlert = (authority.explanation ?? "") + " This binary is not inside a .app bundle, so it cannot relaunch itself. Build with scripts/build-app.sh and start it with open."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        configuration.environment = ProcessInfo.processInfo.environment.filter {
            $0.key.hasPrefix("CATCHER_") || $0.key == "XAI_API_KEY"
        }
        NSLog("Catcher relaunching \(url.path) through LaunchServices so com.catcher.app is its own TCC identity")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let launchedPID = app?.processIdentifier ?? 0
            let failure = error?.localizedDescription
            let sentence = error.map { ErrorDetail.sentence($0) }
            Task { @MainActor in
                if let failure {
                    NSLog("Catcher relaunch failed: \(failure)")
                    if let sentence {
                        self.noteLaunchFailure(sentence)
                    }
                    self.permissionAlert = (authority.explanation ?? "") + " Relaunch failed: \(failure). Quit Catcher and run: open -n \"\(url.path)\""
                    return
                }
                NSLog("Catcher relaunched as pid \(launchedPID); pid \(authority.pid) exits")
                NSApp.terminate(nil)
            }
        }
    }

    private func applyLaunchProbe(_ probe: PermissionState) async {
        guard case .blocked(let reason) = probe else {
            permissionAlert = nil
            microphoneRecovery = .none
            return
        }
        applyPermission(.blocked(reason: reason))
        guard PrivacySettingsPane.forBlockReason(reason) == .microphone else {
            permissionAlert = reason.hasPrefix("startCapture failed") ? reason : nil
            return
        }
        let authority = PermissionGate.readMicrophoneAuthority()
        microphoneRecovery = authority.recovery
        if authority.recovery == .prompt, let report = await PermissionGate.latestMicrophonePrompt() {
            permissionAlert = report.loudFailure
        } else {
            permissionAlert = authority.explanation
        }
    }

    private func openSettings(_ pane: PrivacySettingsPane) {
        #if os(macOS)
        if let url = pane.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func applyPermission(_ state: PermissionState) {
        switch state {
        case .granted:
            status = .ok
            banner = nil
            statusUpdatedAt = Date()
        case .blocked(let reason):
            status = .blocked(reason)
            banner = "BLOCKED: \(reason)"
            statusUpdatedAt = Date()
        }
    }

    func select(_ id: String?) {
        selectedID = id
        guard let id else {
            selectedTranscript = ""
            return
        }
        let directory = sessionRoot.appendingPathComponent(id, isDirectory: true)
        do {
            selectedTranscript = try String(contentsOf: SessionPaths.transcriptFile(in: directory), encoding: .utf8)
        } catch {
            selectedTranscript = ""
            StageMirror.note("transcript read \(ErrorDetail.sentence(error))")
        }
    }

    private func listen() {
        listenTask?.cancel()
        let stream = pipeline.ui
        listenTask = Task { [weak self] in
            for await event in stream {
                await self?.apply(event)
            }
        }
    }

    private func apply(_ event: PipelineUIEvent) {
        switch event {
        case .transcript(let transcript):
            if transcript.kind == .final {
                partials[transcript.track] = nil
                finals.append(transcript)
            } else {
                partials[transcript.track] = transcript
            }
            rebuildLines()
        case .snapshot(let snapshot):
            let previous = status
            status = snapshot.status
            banner = snapshot.banner
            statusUpdatedAt = snapshot.updatedAt
            if case .blocked(let reason) = snapshot.status {
                isRecording = false
                if previous != snapshot.status, PrivacySettingsPane.forBlockReason(reason) == .microphone {
                    let authority = PermissionGate.readMicrophoneAuthority()
                    microphoneRecovery = authority.recovery
                    permissionAlert = authority.explanation
                }
            } else {
                permissionAlert = nil
            }
        }
    }

    private func rebuildLines() {
        var rows: [TranscriptLine] = finals.map { event in
            TranscriptLine(
                id: "final-\(event.track.rawValue)-\(event.seq)",
                track: event.track,
                text: event.text,
                speaker: event.speaker,
                isFinal: true,
                startMs: event.startMs
            )
        }
        for (track, event) in partials {
            rows.append(TranscriptLine(
                id: "partial-\(track.rawValue)",
                track: track,
                text: event.text,
                speaker: event.speaker,
                isFinal: false,
                startMs: event.startMs
            ))
        }
        lines = rows.sorted { $0.startMs < $1.startMs }
    }

    /// First recording only. A later startCapture failure must not replace it.
    private func pinLiveSession() async {
        guard let directory = await pipeline.sessionDirectory else { return }
        let pointer = sessionRoot.appendingPathComponent("live_session")
        guard !FileManager.default.fileExists(atPath: pointer.path) else { return }
        do {
            try directory.path.write(to: pointer, atomically: true, encoding: .utf8)
        } catch {
            StageMirror.note("live_session \(ErrorDetail.sentence(error))")
        }
    }

    private func runPreflightAndQuit() async {
        do {
            try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        } catch {
            StageMirror.note("preflight mkdir \(ErrorDetail.sentence(error))")
        }
        let reportURL = sessionRoot.appendingPathComponent("preflight.txt")
        let prior: String
        if FileManager.default.fileExists(atPath: reportURL.path) {
            do {
                prior = try String(contentsOf: reportURL, encoding: .utf8)
            } catch {
                StageMirror.note("preflight read \(ErrorDetail.sentence(error))")
                prior = ""
            }
        } else {
            prior = ""
        }
        let lines = await preflightChecks()
        let result = Preflight.result(checks: lines, priorFails: Preflight.failCount(in: prior))
        let preflightSink = FileStageSink(directory: sessionRoot, fileName: "preflight.txt")
        let launchSink = FileStageSink(directory: sessionRoot, fileName: "launch-stages.log")
        for line in lines + [result] {
            preflightSink.write(line, fsync: true)
            launchSink.write(line, fsync: line.verdict == PreflightVerdict.fail.rawValue || line.name == "RESULT")
        }
        NSApp.terminate(nil)
    }

    /// Checks, or one `preflight-finish` line if they have not returned in 30s.
    /// `hang-after-signing` is this deadline. It is not a Screen Recording deny.
    private func preflightChecks() async -> [StageLine] {
        let environment = launchEnvironment
        return await withTaskGroup(of: [StageLine].self) { group in
            group.addTask {
                await Preflight.run(environment: environment, dependencies: PreflightHost.dependencies())
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return [.preflight("preflight-finish", .fail, [Field("error", "hang-after-signing")])]
            }
            let lines = await group.next() ?? [.preflight("preflight-finish", .fail, [Field("error", "hang-after-signing")])]
            group.cancelAll()
            return lines
        }
    }

    private func noteLaunchFailure(_ sentence: String) {
        let sink = FileStageSink(directory: sessionRoot, fileName: "launch-stages.log")
        for line in FailureTrace.report(lines: [], fallbackError: "relaunch \(sentence)").lines {
            sink.write(line, fsync: true)
        }
    }

    private func refreshSessions() async {
        do {
            sessions = try SessionStore.list(root: sessionRoot)
        } catch {
            sessions = []
            StageMirror.note("session list \(ErrorDetail.sentence(error))")
        }
        if let selectedID {
            select(selectedID)
        }
    }
}

/// The harness stops the app with SIGTERM. When the signal arrives before the
/// system live-tail floor, the session keeps recording until it; shutdown then
/// fsyncs `end` before a hung socket close. The harness grades after exit.
enum HarnessShutdown {
    private static let lock = NSLock()
    // Read and written only while `lock` is held. Swift 6 requires
    // `nonisolated(unsafe)` when an external lock is the synchronization.
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var source: DispatchSourceSignal?

    static func install(_ stop: @escaping @Sendable () async -> Void) {
        lock.lock()
        if installed {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            source.cancel()
            Task {
                await stop()
                exit(0)
            }
        }
        lock.lock()
        self.source = source
        lock.unlock()
        source.resume()
    }
}

struct ContentView: View {
    @Bindable var model: CatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                RecordButton(
                    isRecording: model.isRecording,
                    enabled: model.isRecording || !model.status.isBlocked
                ) {
                    Task { await model.toggle() }
                }
                VerifierStatusView(
                    status: model.status,
                    banner: model.banner,
                    updatedAt: model.statusUpdatedAt,
                    isRecording: model.isRecording,
                    microphoneButtonTitle: model.microphoneRecovery.buttonTitle,
                    regrant: { model.regrant() },
                    requestMicrophone: { model.requestMicrophone() }
                )
            }
            if let alert = model.permissionAlert, !alert.isEmpty {
                Text(alert)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("microphonePromptFailure")
            }
            LiveTranscriptView(lines: model.lines)
            SessionListView(
                sessions: model.sessions,
                selection: model.selectedID,
                transcript: model.selectedTranscript,
                onSelect: { model.select($0) }
            )
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .task { await model.onAppear() }
    }
}
