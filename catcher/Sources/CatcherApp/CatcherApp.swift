import AppKit
import AudioCapture
import GrokEngine
import Observation
import Pipeline
import SessionStore
import SwiftUI
import TranscriptionEngine
import Verifier

@main
struct CatcherApp: App {
    @State private var model = CatcherModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
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
    var sessions: [SessionSummary] = []
    var selectedID: String?
    var selectedTranscript = ""
    private var finals: [TranscriptEvent] = []
    private var partials: [AudioTrack: TranscriptEvent] = [:]
    private var listenTask: Task<Void, Never>?
    private let pipeline: Pipeline
    private let sessionRoot: URL
    private let autoRecord: Bool

    init() {
        GrokEngineBootstrap.install()
        Loud.prepare()
        let launch = LaunchConfiguration.resolve()
        let environment = launch.mergedEnvironment(ProcessInfo.processInfo.environment)
        let root = SessionPaths.root(environment: environment)
        sessionRoot = root
        autoRecord = launch.autoRecord
        if launch.harness {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            try? pid.write(to: root.appendingPathComponent("catcher.pid"), atomically: true, encoding: .utf8)
        }
        pipeline = Pipeline(
            sessionRoot: root,
            makeEngine: { track in
                try EngineFactory.make(track: track, environment: environment)
            },
            recordPCM: environment["CATCHER_HARNESS"] == "1",
            engineLabel: EngineFactory.sessionEngineName(environment: environment)
        )
    }

    func onAppear() async {
        let reports = (try? Recovery.scan(root: sessionRoot)) ?? []
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
        await refreshSessions()
        if !isRecording {
            await refreshSessions()
        }
    }

    func regrant() {
        let reason = blockReason
        Task { await self.performRegrant(reason: reason) }
    }

    /// Allow dialog only. Does not open System Settings.
    func requestMicrophone() {
        Task { await self.finishMicrophonePrompt(openScreenSettingsIfNeeded: false) }
    }

    private var blockReason: String {
        if case .blocked(let reason) = status { return reason }
        return ""
    }

    /// Microphone blocks prompt for Allow. They do not open the Microphone pane:
    /// it has no +, and Catcher is missing there until that dialog completes.
    /// Screen blocks still open Screen & System Audio.
    private func performRegrant(reason: String) async {
        if PrivacySettingsPane.forBlockReason(reason) == .microphone {
            await finishMicrophonePrompt(openScreenSettingsIfNeeded: true)
            return
        }
        openSettings(.screenCapture)
    }

    private func finishMicrophonePrompt(openScreenSettingsIfNeeded: Bool) async {
        let report = await PermissionGate.promptMicrophone()
        switch report.attempt {
        case .granted:
            permissionAlert = nil
            let followUp = PermissionGate.recheck()
            applyPermission(followUp)
            guard openScreenSettingsIfNeeded,
                  case .blocked(let reason) = followUp,
                  PrivacySettingsPane.forBlockReason(reason) == .screenCapture else { return }
            openSettings(.screenCapture)
        case .denied, .notDetermined, .restricted:
            applyPermission(.blocked(reason: MicrophoneRegrant.blockReason(for: report.attempt)))
            permissionAlert = report.loudFailure
        }
    }

    private func applyLaunchProbe(_ probe: PermissionState) async {
        guard case .blocked(let reason) = probe else {
            permissionAlert = nil
            return
        }
        applyPermission(.blocked(reason: reason))
        guard PrivacySettingsPane.forBlockReason(reason) == .microphone,
              let report = await PermissionGate.latestMicrophonePrompt() else {
            permissionAlert = nil
            return
        }
        permissionAlert = report.loudFailure
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
        selectedTranscript = (try? String(contentsOf: SessionPaths.transcriptFile(in: directory), encoding: .utf8)) ?? ""
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
            status = snapshot.status
            banner = snapshot.banner
            statusUpdatedAt = snapshot.updatedAt
            if snapshot.status.isBlocked {
                isRecording = false
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

    private func refreshSessions() async {
        sessions = (try? SessionStore.list(root: sessionRoot)) ?? []
        if let selectedID {
            select(selectedID)
        }
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
