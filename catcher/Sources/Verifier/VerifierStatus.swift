import Foundation

public enum VerifierStatus: Sendable, Equatable {
    case ok
    case degraded(String)
    case noAudio(String)
    case blocked(String)

    public var pill: String {
        switch self {
        case .ok: "OK"
        case .degraded: "DEGRADED"
        case .noAudio: "NO AUDIO"
        case .blocked: "BLOCKED"
        }
    }

    public var human: String {
        switch self {
        case .ok:
            "Capture and transcription look healthy."
        case .degraded(let detail):
            detail
        case .noAudio(let detail):
            detail
        case .blocked(let detail):
            detail
        }
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}

public struct VerifierSnapshot: Sendable, Equatable {
    public var status: VerifierStatus
    public var banner: String?
    public var updatedAt: Date
    public var logLine: String?
    public var notificationBody: String?

    public init(
        status: VerifierStatus,
        banner: String?,
        updatedAt: Date,
        logLine: String? = nil,
        notificationBody: String? = nil
    ) {
        self.status = status
        self.banner = banner
        self.updatedAt = updatedAt
        self.logLine = logLine
        self.notificationBody = notificationBody
    }

    public static let idle = VerifierSnapshot(status: .ok, banner: nil, updatedAt: .distantPast)
}
