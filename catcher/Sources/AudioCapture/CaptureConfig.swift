import Foundation
#if canImport(ScreenCaptureKit)
import CoreMedia
import ScreenCaptureKit
#endif

/// One display ScreenCaptureKit offered for the system-audio mix.
public struct SystemAudioDisplay: Equatable, Sendable {
    public var id: UInt32
    public var active: Bool
    public var asleep: Bool
    public var isMain: Bool

    public init(id: UInt32, active: Bool, asleep: Bool, isMain: Bool) {
        self.id = id
        self.active = active
        self.asleep = asleep
        self.isMain = isMain
    }
}

public enum SystemAudioDisplayChoice {
    /// `.audio` follows the display in the content filter. The microphone track does not.
    /// ScreenCaptureKit keeps listing a closed-lid built-in, and that display's mix is silence.
    public static func preferred(_ displays: [SystemAudioDisplay]) -> UInt32? {
        let awake = displays.filter { $0.active && !$0.asleep }
        if let main = awake.first(where: \.isMain) {
            return main.id
        }
        if let firstAwake = awake.first {
            return firstAwake.id
        }
        return displays.first?.id
    }
}

/// The one complete capture configuration. `SCStream.updateConfiguration` replaces
/// the whole object, so every session must start from `CaptureConfig.make()`.
///
/// `sampleRate` and `channelCount` are what ScreenCaptureKit is asked to deliver.
/// Frames are still converted to `AudioFormat` (16 kHz mono PCM16) after the copy.
/// SCK's default is 48 kHz stereo. Forcing 16 kHz mono makes the system `.audio`
/// mix a pair of opposite-polarity channels and the average is digital silence.
/// The microphone track is already one channel, so the same setting leaves it intact.
public struct CaptureConfig: Sendable, Equatable {
    public var sampleRate: Int
    public var channelCount: Int
    public var width: Int
    public var height: Int
    public var minimumFrameIntervalSeconds: Int
    public var excludesCurrentProcessAudio: Bool
    public var capturesAudio: Bool
    public var captureMicrophone: Bool
    public var wholeDisplay: Bool
    public var queueDepth: Int
    /// Nil keeps SCK's default input. The session fills this from the default device when one exists.
    public var microphoneDeviceID: String?

    public static func make() -> CaptureConfig {
        CaptureConfig(
            sampleRate: 48_000,
            channelCount: 2,
            width: 2,
            height: 2,
            minimumFrameIntervalSeconds: 1,
            excludesCurrentProcessAudio: true,
            capturesAudio: true,
            captureMicrophone: true,
            wholeDisplay: true,
            queueDepth: 8,
            microphoneDeviceID: nil
        )
    }

    #if canImport(ScreenCaptureKit)
    /// Copies every locked field onto a fresh `SCStreamConfiguration`.
    public func apply(to config: SCStreamConfiguration) {
        config.capturesAudio = capturesAudio
        config.captureMicrophone = captureMicrophone
        config.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        config.width = width
        config.height = height
        config.queueDepth = queueDepth
        config.minimumFrameInterval = CMTime(
            value: CMTimeValue(minimumFrameIntervalSeconds),
            timescale: 1
        )
        if let microphoneDeviceID {
            config.microphoneCaptureDeviceID = microphoneDeviceID
        }
    }
    #endif
}
