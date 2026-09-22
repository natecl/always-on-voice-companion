import Foundation

public enum CaptureError: Error, Sendable, Equatable {
    case tccDenied(String)
    case tccRevokedMidSession
    case streamStopped(String)
    case pcmExtractionFailed(status: Int32, detail: String)
    case unavailable(String)
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case blocked(reason: String)
}
