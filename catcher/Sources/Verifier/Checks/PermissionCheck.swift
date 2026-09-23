import AudioCapture

public struct PermissionCheck: Sendable {
    public private(set) var blockReason: String?
    private var emitted = false

    public init() {}

    public mutating func reset() {
        blockReason = nil
        emitted = false
    }

    public mutating func observe(_ state: PermissionState, atMs: Int) -> [Annotation] {
        switch state {
        case .granted:
            return []
        case .blocked(let reason):
            return block(reason, atMs: atMs)
        }
    }

    public mutating func observe(_ error: CaptureError, atMs: Int) -> [Annotation] {
        switch error {
        case .tccDenied(let reason), .unavailable(let reason):
            return block(reason, atMs: atMs)
        case .tccRevokedMidSession:
            return block("screen recording permission revoked", atMs: atMs)
        case .streamStopped, .pcmExtractionFailed:
            return []
        }
    }

    /// Silent buffers plus a failed re-probe is the second P2 path, for OS builds
    /// that stop delivering samples without a delegate error.
    public mutating func observeSilence(allSilent: Bool, reprobe: PermissionState, atMs: Int) -> [Annotation] {
        guard allSilent, case .blocked(let reason) = reprobe else { return [] }
        return block("silent buffers and permission re-probe failed: \(reason)", atMs: atMs)
    }

    private mutating func block(_ reason: String, atMs: Int) -> [Annotation] {
        blockReason = reason
        guard !emitted else { return [] }
        emitted = true
        return [Annotation(atMs: atMs, kind: "blocked", detail: .text(reason))]
    }
}
