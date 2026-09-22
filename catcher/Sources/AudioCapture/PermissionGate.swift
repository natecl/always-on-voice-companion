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

    /// System microphone dialog, only while access is still `.notDetermined`.
    /// Returns true when the user grants it. Denied, restricted, and
    /// already-determined statuses return false and do not present a dialog.
    /// Until this runs, the app is missing from the Microphone list.
    public static func requestMicrophoneAccessIfNotDetermined() async -> Bool {
        #if canImport(ScreenCaptureKit)
        return await SCKPermissionProbe.requestMicrophoneAccessIfNotDetermined()
        #else
        return false
        #endif
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

    /// `nil` when a microphone prompt just granted and nothing remains to toggle.
    /// A follow-up block opens that pane, so a mic grant does not keep sending
    /// the user to Microphone after the blocker is screen recording.
    public static func settingsPane(
        blockReason: String,
        microphonePromptGranted: Bool,
        followUp: PermissionState
    ) -> PrivacySettingsPane? {
        let pane = forBlockReason(blockReason)
        guard pane == .microphone, microphonePromptGranted else { return pane }
        switch followUp {
        case .granted:
            return nil
        case .blocked(let reason):
            return forBlockReason(reason)
        }
    }
}
