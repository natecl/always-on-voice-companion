import Foundation

/// Locked capture format: 16 kHz mono PCM16 little-endian.
public enum AudioFormat {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bytesPerSample = 2
    public static let chunkMilliseconds = 100

    /// 100 ms at 16 kHz mono PCM16. Grok's recommended binary frame.
    public static var chunkBytes: Int {
        sampleRate / 10 * bytesPerSample
    }
}

public enum AudioTrack: String, Codable, Sendable, CaseIterable, Equatable {
    case system
    case microphone

    public var attribution: String {
        switch self {
        case .system: "them"
        case .microphone: "me"
        }
    }
}

public struct PCMFrame: Sendable, Equatable {
    public let track: AudioTrack
    public let data: Data
    public let hostTime: UInt64
    public let sampleCount: Int

    public init(track: AudioTrack, data: Data, hostTime: UInt64, sampleCount: Int? = nil) {
        self.track = track
        self.data = data
        self.hostTime = hostTime
        self.sampleCount = sampleCount ?? data.count / AudioFormat.bytesPerSample
    }

    public static func silence(track: AudioTrack, sampleCount: Int, hostTime: UInt64) -> PCMFrame {
        PCMFrame(
            track: track,
            data: Data(count: sampleCount * AudioFormat.bytesPerSample),
            hostTime: hostTime,
            sampleCount: sampleCount
        )
    }
}

public enum PCMEnergy {
    /// Root-mean-square of little-endian PCM16, scaled so full-scale is 1.
    public static func rms(_ pcm16le: Data) -> Float {
        let count = pcm16le.count / AudioFormat.bytesPerSample
        guard count > 0 else { return 0 }
        var sum: Float = 0
        pcm16le.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let unit = Float(sample) / 32768
                sum += unit * unit
            }
        }
        return (sum / Float(count)).squareRoot()
    }
}

public enum HostClock {
    public static func now() -> UInt64 {
        #if canImport(Darwin)
        return mach_absolute_time()
        #else
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        #endif
    }

    public static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        let delta = end &- start
        #if canImport(Darwin)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = delta * UInt64(info.numer) / UInt64(info.denom)
        return Int(nanos / 1_000_000)
        #else
        return Int(delta / 1_000_000)
        #endif
    }
}

/// Pipeline and the engines share this so annotation `atMs` and segment
/// `startMs` are the same session clock. The pipeline resets it when a
/// recording starts.
public enum SessionClockAnchor {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var origin: UInt64 = HostClock.now()
    }

    private static let box = Box()

    public static func reset(to host: UInt64) {
        box.lock.lock()
        box.origin = host
        box.lock.unlock()
    }

    public static func milliseconds(until host: UInt64 = HostClock.now()) -> Int {
        box.lock.lock()
        let start = box.origin
        box.lock.unlock()
        return max(0, HostClock.milliseconds(from: start, to: host))
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
