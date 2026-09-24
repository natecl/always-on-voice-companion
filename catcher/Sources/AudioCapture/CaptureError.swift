import Foundation

public enum CaptureError: Error, Sendable, Equatable {
    case tccDenied(String)
    case tccRevokedMidSession
    case streamStopped(String)
    case pcmExtractionFailed(status: Int32, detail: String)
    case unavailable(String)
}

/// `ErrorDetail.sentence` reads `localizedDescription`. Without this, every
/// case prints as "CaptureError error N" and the detail string is lost.
extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tccDenied(let detail): detail
        case .tccRevokedMidSession: "screen recording access revoked mid-session"
        case .streamStopped(let detail): detail
        case .pcmExtractionFailed(let status, let detail): "pcm extraction failed (\(status)): \(detail)"
        case .unavailable(let detail): detail
        }
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case blocked(reason: String)
}

/// How many other apps' on-screen windows we can see, and how many still have titles.
public struct WindowTitleSample: Sendable, Equatable {
    public var otherWindows: Int
    public var titledOtherWindows: Int

    public init(otherWindows: Int, titledOtherWindows: Int) {
        self.otherWindows = otherWindows
        self.titledOtherWindows = titledOtherWindows
    }
}

/// `CGPreflightScreenCaptureAccess` keeps its first answer for the life of the
/// process. `tccutil reset ScreenCapture` does not flip it, so a one-second
/// probe that trusts only that call never blocks the live session.
public enum ScreenRevokeWatch {
    public static func isRevoked(
        preflightDenied: Bool,
        grantedPreflight: Int32?,
        livePreflight: Int32?,
        grantedWindows: WindowTitleSample,
        liveWindows: WindowTitleSample
    ) -> Bool {
        if preflightDenied { return true }
        if let grantedPreflight, let livePreflight, livePreflight != grantedPreflight {
            return true
        }
        // The window server strips other apps' titles as soon as the grant is
        // gone, while this process's CGPreflight cache still says yes.
        if grantedWindows.titledOtherWindows > 0,
           liveWindows.otherWindows > 0,
           liveWindows.titledOtherWindows == 0 {
            return true
        }
        return false
    }
}

public enum CaptureStop {
    public static func classify(domain: String, code: Int, description: String) -> CaptureError {
        let blob = (domain + " " + description).lowercased()
        if blob.contains("tcc") || blob.contains("permission") || blob.contains("not authorized")
            || blob.contains("denied") || blob.contains("declined") {
            return .tccRevokedMidSession
        }
        let screen = blob.contains("screencapture") || blob.contains("scstream")
        // userDeclined (-3801) and systemStoppedStream (-3821 on macOS 15).
        if screen && (code == -3801 || code == -3821 || code == -3817) {
            return .tccRevokedMidSession
        }
        return .streamStopped(description)
    }
}
