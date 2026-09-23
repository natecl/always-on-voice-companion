import Foundation

/// One readback of everything macOS uses to decide whether Catcher may record
/// the microphone. The banner, the red line, the block reason, and the Console
/// line are all derived from the same instance, so they cannot disagree.
public struct MicrophoneAuthority: Sendable, Equatable {
    /// `AVCaptureDevice.authorizationStatus(for: .audio)`.
    public var authorizationStatus: String
    /// `AVAudioApplication.shared.recordPermission`.
    public var recordPermission: String
    /// Code signature carries the hardened-runtime flag. `nil` = could not read.
    public var hardenedRuntime: Bool?
    /// `com.apple.security.device.audio-input` is present. `nil` = could not read.
    public var audioInputEntitlement: Bool?
    public var pid: Int32
    public var parentPID: Int32
    /// Process TCC bills for this one. `nil` = lookup unavailable.
    public var responsiblePID: Int32?
    public var responsibleName: String?
    public var bundleIdentifier: String?
    public var bundlePath: String?

    public init(
        authorizationStatus: String,
        recordPermission: String,
        hardenedRuntime: Bool?,
        audioInputEntitlement: Bool?,
        pid: Int32,
        parentPID: Int32,
        responsiblePID: Int32?,
        responsibleName: String?,
        bundleIdentifier: String?,
        bundlePath: String?
    ) {
        self.authorizationStatus = authorizationStatus
        self.recordPermission = recordPermission
        self.hardenedRuntime = hardenedRuntime
        self.audioInputEntitlement = audioInputEntitlement
        self.pid = pid
        self.parentPID = parentPID
        self.responsiblePID = responsiblePID
        self.responsibleName = responsibleName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
    }

    public static let unavailable = MicrophoneAuthority(
        authorizationStatus: "unavailable",
        recordPermission: "unavailable",
        hardenedRuntime: nil,
        audioInputEntitlement: nil,
        pid: 0,
        parentPID: 0,
        responsiblePID: nil,
        responsibleName: nil,
        bundleIdentifier: nil,
        bundlePath: nil
    )

    /// A hardened-runtime binary with no audio-input entitlement never gets a
    /// TCC case: no prompt, no row in the Microphone pane, and whatever
    /// `authorizationStatus` returns is not a grant.
    public var signingBlocksMicrophone: Bool {
        hardenedRuntime == true && audioInputEntitlement == false
    }

    /// TCC judges the responsible process. A binary exec'd from a shell inherits
    /// Terminal (or Cursor, iTerm, Xcode) as that process, so the status read
    /// here is theirs and Catcher never appears in the Microphone pane.
    public var ownsTCCIdentity: Bool {
        guard let responsiblePID else { return true }
        return responsiblePID == pid
    }

    public var isAuthorized: Bool {
        authorizationStatus == "authorized"
    }

    public var recovery: MicrophoneRecovery {
        if signingBlocksMicrophone { return .rebuildWithEntitlement }
        if !ownsTCCIdentity { return .relaunchUnderOwnIdentity }
        switch authorizationStatus {
        case "authorized": return .none
        case "notDetermined": return .prompt
        case "restricted", "unavailable": return .none
        default: return .openMicrophoneSettings
        }
    }

    /// `nil` when the microphone is not what blocks recording.
    public var blockReason: String? {
        switch recovery {
        case .rebuildWithEntitlement:
            return "microphone blocked by signing: hardened runtime without the audio-input entitlement"
        case .relaunchUnderOwnIdentity:
            return "microphone permission is judged for \(responsibleName ?? "the app that launched Catcher"), not Catcher"
        case .none:
            if authorizationStatus == "restricted" {
                return "microphone access unavailable"
            }
            if authorizationStatus == "unavailable" {
                return "microphone status unavailable on this platform"
            }
            return nil
        case .prompt:
            return "microphone access not determined"
        case .openMicrophoneSettings:
            return "microphone access denied"
        }
    }

    /// Red line under the banner. States the fact, the proof, and the one action.
    public var explanation: String? {
        switch recovery {
        case .rebuildWithEntitlement:
            return "Catcher.app is signed with the hardened runtime and has no com.apple.security.device.audio-input entitlement. macOS will not show Allow and will not list Catcher under Privacy & Security → Microphone, whatever authorizationStatus says (it read \(authorizationStatus)). Rebuild with scripts/build-app.sh, which now signs Catcher.entitlements, then relaunch. \(readbackSentence)"
        case .relaunchUnderOwnIdentity:
            let who = responsibleName ?? "the launching process"
            let rpid = responsiblePID.map { " (pid \($0))" } ?? ""
            return "Catcher was started by \(who)\(rpid), so macOS bills microphone access to \(who), not to com.catcher.app. The status read here (\(authorizationStatus)) is \(who)'s, and Catcher is not on the Microphone list. Press Request microphone to relaunch Catcher under its own identity (the same as Finder or open); the relaunched Catcher asks for the microphone itself. \(readbackSentence)"
        case .none:
            if authorizationStatus == "restricted" {
                return "Microphone access is restricted for this user (MDM or parental controls). \(readbackSentence)"
            }
            return nil
        case .prompt:
            return "Microphone status is notDetermined. Press Request microphone with Catcher in front and other permission windows closed; a Zoom call can hide Allow. \(readbackSentence)"
        case .openMicrophoneSettings:
            return "Microphone status is denied for com.catcher.app, so macOS will not show Allow again. Catcher has a row under Privacy & Security → Microphone; Re-grant opens that pane so you can turn it on. \(readbackSentence)"
        }
    }

    /// Same text goes to Console. Grep: `Catcher mic authority`.
    public var consoleLine: String {
        var parts = [
            "status=\(authorizationStatus)",
            "recordPermission=\(recordPermission)",
            "hardenedRuntime=\(describe(hardenedRuntime))",
            "audioInputEntitlement=\(describe(audioInputEntitlement))",
            "pid=\(pid)",
            "ppid=\(parentPID)",
            "responsiblePID=\(responsiblePID.map(String.init) ?? "unknown")",
            "responsible=\(responsibleName ?? "unknown")",
            "ownsTCCIdentity=\(ownsTCCIdentity)",
            "bundle=\(bundleIdentifier ?? "none")",
        ]
        if let bundlePath {
            parts.append("path=\(bundlePath)")
        }
        parts.append("verdict=\(blockReason ?? "microphone ok")")
        return "Catcher mic authority " + parts.joined(separator: " ")
    }

    private var readbackSentence: String {
        "Console line for this readback: Catcher mic authority (status=\(authorizationStatus) recordPermission=\(recordPermission) hardenedRuntime=\(describe(hardenedRuntime)) audioInputEntitlement=\(describe(audioInputEntitlement)) responsible=\(responsibleName ?? "unknown"))."
    }

    private func describe(_ flag: Bool?) -> String {
        switch flag {
        case .some(true): "true"
        case .some(false): "false"
        case .none: "unknown"
        }
    }
}

/// What the microphone button does. Never a no-op: `.none` still re-reads
/// and republishes the state so a stale banner clears.
public enum MicrophoneRecovery: Sendable, Equatable {
    /// Not blocked on the microphone.
    case none
    /// Own identity, status notDetermined: the Allow dialog can appear.
    case prompt
    /// Own identity, denied row exists: the Microphone pane has a toggle for Catcher.
    case openMicrophoneSettings
    /// TCC is judging the launcher. Relaunch through LaunchServices.
    case relaunchUnderOwnIdentity
    /// Nothing at runtime can fix a missing entitlement.
    case rebuildWithEntitlement

    public var buttonTitle: String {
        switch self {
        case .none, .prompt: "Request microphone"
        case .openMicrophoneSettings: "Open Microphone settings"
        case .relaunchUnderOwnIdentity: "Relaunch Catcher for microphone"
        case .rebuildWithEntitlement: "Re-read microphone status"
        }
    }
}
