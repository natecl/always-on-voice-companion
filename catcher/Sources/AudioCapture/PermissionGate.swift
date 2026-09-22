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
}
