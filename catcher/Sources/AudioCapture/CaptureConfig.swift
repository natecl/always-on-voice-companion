import Foundation
#if canImport(ScreenCaptureKit)
import CoreMedia
import ScreenCaptureKit
#endif

/// The one complete capture configuration. `SCStream.updateConfiguration` replaces
/// the whole object, so every session must start from `CaptureConfig.make()`.
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
            sampleRate: AudioFormat.sampleRate,
            channelCount: AudioFormat.channels,
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
