import Foundation

/// Read-only counters. `AudioCapturing` stays unchanged so test fakes do not
/// have to implement this; the pipeline casts with `as? CaptureDiagnostics`.
public struct CaptureCounters: Sendable, Equatable {
    public var system: Int
    public var microphone: Int
    public var invalid: Int
    public var empty: Int
    public var extractFailed: Int
    public var firstOSStatus: Int32
    public var firstFailureDetail: String
    public var displayID: UInt32

    public init(
        system: Int = 0,
        microphone: Int = 0,
        invalid: Int = 0,
        empty: Int = 0,
        extractFailed: Int = 0,
        firstOSStatus: Int32 = 0,
        firstFailureDetail: String = "",
        displayID: UInt32 = 0
    ) {
        self.system = system
        self.microphone = microphone
        self.invalid = invalid
        self.empty = empty
        self.extractFailed = extractFailed
        self.firstOSStatus = firstOSStatus
        self.firstFailureDetail = firstFailureDetail
        self.displayID = displayID
    }
}

public protocol CaptureDiagnostics: Sendable {
    func counters() -> CaptureCounters
}
