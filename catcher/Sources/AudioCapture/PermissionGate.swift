import Foundation

public enum PermissionGate {
    /// Launch probe. Attempts a real capture start and stops it immediately.
    /// A missing grant becomes `.blocked` — never a fake recording state.
    public static func startCaptureProbe() async -> PermissionState {
        #if canImport(ScreenCaptureKit)
        return await SCKPermissionProbe.run()
        #else
        return .blocked(reason: "ScreenCaptureKit is unavailable on this platform")
        #endif
    }

    /// One-second cadence while recording. Does not open a second `SCStream`
    /// (that would disturb the live capture). Pair a failure here with silent
    /// buffers, or with `CaptureError.tccRevokedMidSession`, to block.
    public static func recheck() -> PermissionState {
        #if canImport(ScreenCaptureKit)
        return SCKPermissionProbe.recheck()
        #else
        return .blocked(reason: "ScreenCaptureKit is unavailable on this platform")
        #endif
    }

    /// Microphone Allow dialog only. Does not open System Settings.
    /// The launch probe calls this only after the screen-capture prompt has
    /// finished. A denied or still-undetermined result does not mean Catcher
    /// is on the Microphone list — that pane has no +.
    public static func promptMicrophone() async -> MicrophonePromptReport {
        #if canImport(ScreenCaptureKit)
        return await SCKPermissionProbe.promptMicrophone()
        #else
        return MicrophonePromptReport(
            attempt: .notDetermined,
            statusAtLaunch: "unavailable",
            statusBeforeRequestAccess: "unavailable",
            statusAfterRequestAccess: "unavailable"
        )
        #endif
    }

    public static func latestMicrophonePrompt() async -> MicrophonePromptReport? {
        #if canImport(ScreenCaptureKit)
        return await SCKPermissionProbe.latestMicrophonePrompt()
        #else
        return nil
        #endif
    }

    /// Fresh readback of TCC status, signing, and the responsible process.
    /// Logged as `Catcher mic authority`. Every microphone banner comes from this.
    public static func readMicrophoneAuthority() -> MicrophoneAuthority {
        #if canImport(ScreenCaptureKit)
        return SCKPermissionProbe.readAuthority()
        #else
        return .unavailable
        #endif
    }
}

/// Statuses around the launch / Request microphone prompt. Settings is not opened.
public struct MicrophonePromptReport: Sendable, Equatable {
    public var attempt: MicrophonePromptAttempt
    public var statusAtLaunch: String
    public var statusBeforeRequestAccess: String
    public var statusAfterRequestAccess: String

    public var loudFailure: String? {
        guard attempt != .granted else { return nil }
        return MicrophoneRegrant.dialogFailedCopy(
            atLaunch: statusAtLaunch,
            before: statusBeforeRequestAccess,
            after: statusAfterRequestAccess
        )
    }
}

/// Result of a microphone prompt that did not open System Settings.
public enum MicrophonePromptAttempt: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case restricted

    public var authorizationStatus: String {
        switch self {
        case .granted: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        }
    }
}

/// Launch order. Screen capture must settle before any microphone prompt.
public enum LaunchPermissionOrder: Sendable {
    public static let steps: [LaunchPermissionStep] = [
        .resolveScreenCapture,
        .promptMicrophone,
    ]
}

public enum LaunchPermissionStep: String, Sendable, Equatable {
    case resolveScreenCapture
    case promptMicrophone
}

public enum MicrophoneRegrant {
    public static func blockReason(for attempt: MicrophonePromptAttempt) -> String {
        switch attempt {
        case .granted:
            ""
        case .denied:
            "microphone access denied"
        case .notDetermined:
            "microphone access not determined"
        case .restricted:
            "microphone access unavailable"
        }
    }

    public static func statusName(forBlockReason reason: String) -> String {
        let lower = reason.lowercased()
        if lower.contains("not determined") { return "notDetermined" }
        if lower.contains("unavailable") || lower.contains("restricted") { return "restricted" }
        return "denied"
    }

    /// Shown when a prompt for Catcher's own identity did not grant access.
    /// Signing and attribution problems are described by `MicrophoneAuthority.explanation` instead.
    public static func dialogFailedCopy(atLaunch: String, before: String, after: String) -> String {
        let verdict: String
        if atLaunch == "notDetermined" && before != "notDetermined" && before != "authorized" {
            verdict = "Status went from notDetermined at launch to \(before) before requestAccess, then requestAccess saw \(after)."
        } else if before == "notDetermined" && (after == "denied" || after == "restricted") {
            verdict = "requestAccess changed \(before) to \(after) without an Allow answer."
        } else if before == "denied" || before == "restricted" {
            verdict = "Status was already \(before) before requestAccess, so macOS will not show Allow; Catcher has a \(before) row and Re-grant opens the Microphone pane."
        } else if after == "notDetermined" {
            verdict = "Status is still notDetermined after requestAccess. The Allow dialog did not finish."
        } else {
            verdict = "Microphone stayed \(after)."
        }
        return "\(verdict) The Microphone list has no +. Press Request microphone with Catcher in front and other permission windows closed. A Zoom call can hide Allow. Launch status was \(atLaunch). Console logs Catcher mic authorizationStatus before and after requestAccess and Catcher mic authority for the readback."
    }

    /// The Microphone pane lists an app only once TCC holds a row for it. A
    /// denied row exists after a real Deny, so that is the one case Settings helps.
    public static func opensMicrophoneSettings(for authority: MicrophoneAuthority) -> Bool {
        authority.recovery == .openMicrophoneSettings
    }
}

/// Which Privacy & Security pane Re-grant should open.
public enum PrivacySettingsPane: Sendable, Equatable {
    /// System Settings → Privacy & Security → Microphone.
    case microphone
    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    /// The anchor is still `Privacy_ScreenCapture`.
    case screenCapture

    public var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenCapture:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    public static func forBlockReason(_ reason: String) -> PrivacySettingsPane {
        if reason.range(of: "microphone", options: .caseInsensitive) != nil {
            return .microphone
        }
        return .screenCapture
    }

    /// `nil` when Settings must stay closed.
    /// The Microphone pane has no +, so it is opened only when TCC already holds a
    /// denied row for com.catcher.app (`recovery == .openMicrophoneSettings`).
    /// Signing and attribution blocks are not fixable there. A mic grant that is
    /// still blocked opens the follow-up pane (screen recording), not Microphone.
    public static func settingsPane(
        blockReason: String,
        microphonePromptGranted: Bool,
        followUp: PermissionState,
        authority: MicrophoneAuthority? = nil
    ) -> PrivacySettingsPane? {
        let pane = forBlockReason(blockReason)
        if pane == .microphone {
            if microphonePromptGranted {
                switch followUp {
                case .granted:
                    return nil
                case .blocked(let reason):
                    let next = forBlockReason(reason)
                    return next == .microphone ? nil : next
                }
            }
            if let authority, MicrophoneRegrant.opensMicrophoneSettings(for: authority) {
                return .microphone
            }
            return nil
        }
        return pane
    }
}
