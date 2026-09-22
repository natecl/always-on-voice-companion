import Foundation
#if canImport(CoreMedia) && canImport(AudioToolbox)
import AudioToolbox
import CoreMedia
#endif

public enum SampleBufferPCM {
    public enum Failure: Error, Equatable {
        case empty
        case invalidChannelCount
    }

    /// Downmix interleaved little-endian PCM16 to mono by averaging channels.
    /// ScreenCaptureKit is configured for mono; this still refuses to drop a channel
    /// if a buffer arrives wider than the config.
    public static func monoPCM16(interleaved: Data, channels: Int) throws -> Data {
        guard channels > 0 else { throw Failure.invalidChannelCount }
        guard !interleaved.isEmpty else { throw Failure.empty }
        if channels == 1 {
            return interleaved
        }
        let frameCount = interleaved.count / (channels * AudioFormat.bytesPerSample)
        guard frameCount > 0 else { throw Failure.empty }
        var output = Data(count: frameCount * AudioFormat.bytesPerSample)
        interleaved.withUnsafeBytes { rawIn in
            output.withUnsafeMutableBytes { rawOut in
                let input = rawIn.bindMemory(to: Int16.self)
                let samples = rawOut.bindMemory(to: Int16.self)
                for frame in 0..<frameCount {
                    var sum = 0
                    for channel in 0..<channels {
                        sum += Int(input[frame * channels + channel])
                    }
                    samples[frame] = Int16(sum / channels)
                }
            }
        }
        return output
    }

    #if canImport(CoreMedia) && canImport(AudioToolbox)
    /// Copies PCM out of an SCK `CMSampleBuffer`.
    /// Uses `CMSampleBufferCopyPCMDataIntoAudioBufferList`. The retained-block-buffer
    /// variant fails with OSStatus -12737 on ScreenCaptureKit buffers.
    public static func extract(from sampleBuffer: CMSampleBuffer) throws -> Data {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { throw Failure.empty }

        var channels = 1
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
        }

        let byteCount = frames * channels * AudioFormat.bytesPerSample
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Int16>.alignment)
        defer { raw.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(byteCount),
                mData: raw
            )
        )
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: &bufferList
        )
        guard status == noErr else {
            throw CaptureError.pcmExtractionFailed(status: status)
        }
        let copied = Int(bufferList.mBuffers.mDataByteSize)
        let interleaved = Data(bytes: raw, count: copied > 0 ? copied : byteCount)
        return try monoPCM16(interleaved: interleaved, channels: channels)
    }
    #endif
}
