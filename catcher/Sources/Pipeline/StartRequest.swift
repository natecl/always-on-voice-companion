import Foundation

/// Who asked for a start or a stop, and when. Phase 1 S0 records this on the
/// latency sidecar. The hotkey and the orb do not exist yet; their source
/// names are reserved so later slices do not rename the row.
public struct StartRequest: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case hotkey
        case orb
        case recordButton
        case harnessAutoRecord
        case harnessShutdown
    }

    public var source: Source
    /// Host clock at the input. May be earlier than the session origin, so the
    /// sidecar stores a negative `inputAtMs`.
    public var inputHostTime: UInt64
    /// Host clock taken when the process came up. Cold start is measured from
    /// launch, which is before the session origin.
    public var processStartHostTime: UInt64

    public init(source: Source, inputHostTime: UInt64, processStartHostTime: UInt64) {
        self.source = source
        self.inputHostTime = inputHostTime
        self.processStartHostTime = processStartHostTime
    }
}
