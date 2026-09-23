import Foundation

/// First reconnect waits 1s, then 2, 4, 8, 16, then capped at 30s.
public struct BackoffSchedule: Sendable, Equatable {
    public private(set) var attempt: Int

    public init(attempt: Int = 0) {
        self.attempt = max(0, attempt)
    }

    public var delay: Duration {
        let shift = min(attempt, 16)
        let seconds = min(1 << shift, 30)
        return .seconds(seconds)
    }

    public func advanced() -> BackoffSchedule {
        BackoffSchedule(attempt: attempt + 1)
    }
}

/// Engine word times restart at 0 on every socket. Add `originMs` (audio already
/// sent on earlier sockets) before anything is written to the session.
public struct TimestampRebase: Sendable, Equatable {
    public var originMs: Int

    public init(originMs: Int) {
        self.originMs = originMs
    }

    public func sessionMs(engineSeconds: Double) -> Int {
        originMs + Int((engineSeconds * 1000).rounded())
    }
}

public struct GapAccount: Sendable, Equatable {
    public private(set) var disconnectedAtMs: Int?

    public init() {}

    /// The first drop wins. A later reconnect must not move the start forward:
    /// that is how a real `pf` block was graded as a 1s gap at the end of the session.
    public mutating func begin(atMs: Int) {
        if let existing = disconnectedAtMs, existing <= atMs {
            return
        }
        disconnectedAtMs = atMs
    }

    public mutating func end(atMs: Int) -> (fromMs: Int, toMs: Int)? {
        guard let from = disconnectedAtMs else { return nil }
        disconnectedAtMs = nil
        return (from, max(atMs, from))
    }
}

public enum PCMClock {
    public static func milliseconds(bytesSent: Int) -> Int {
        let samples = bytesSent / 2
        return samples * 1000 / 16_000
    }
}
