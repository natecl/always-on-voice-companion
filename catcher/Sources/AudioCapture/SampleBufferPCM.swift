import Foundation
#if canImport(CoreMedia) && canImport(AudioToolbox)
import AudioToolbox
import CoreMedia
#endif

/// How one ScreenCaptureKit audio buffer is laid out.
///
/// SCK does not deliver PCM16. `sampleRate` and `channelCount` change the rate
/// and the channel count, and the samples stay 32-bit float, often with one
/// `AudioBuffer` per channel (non-interleaved). An extractor that allocates
/// `frames * channels * 2` bytes and a single `AudioBuffer` makes
/// `CMSampleBufferCopyPCMDataIntoAudioBufferList` fail. Those errors used to be
/// discarded, so the stream stayed up and the pipeline saw zero frames.
public struct SourcePCMFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var bitsPerChannel: Int
    public var isFloat: Bool
    public var isNonInterleaved: Bool
    public var isBigEndian: Bool

    public init(
        sampleRate: Double,
        channels: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isNonInterleaved: Bool,
        isBigEndian: Bool
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
        self.isNonInterleaved = isNonInterleaved
        self.isBigEndian = isBigEndian
    }

    /// One `AudioBuffer` per channel when planar; one buffer when interleaved.
    public var bufferCount: Int {
        isNonInterleaved ? max(channels, 1) : 1
    }

    /// Bytes of one frame inside a single `AudioBuffer`.
    /// Matches `AudioStreamBasicDescription.mBytesPerFrame`: planar is one
    /// channel, interleaved is every channel.
    public var bytesPerFramePerBuffer: Int {
        let sampleBytes = max(bitsPerChannel, 8) / 8
        return isNonInterleaved ? sampleBytes : sampleBytes * max(channels, 1)
    }

    public func bytesPerBuffer(frameCount: Int) -> Int {
        frameCount * bytesPerFramePerBuffer
    }
}

public enum SampleBufferPCM {
    public enum Failure: Error, Equatable {
        case empty
        case invalidChannelCount
        case bufferTooSmall
        case unsupportedFormat(String)
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

/// Float or integer SCK packets → 16 kHz mono PCM16. Planar buffers are
/// mixed per frame; a rate other than 16 kHz is linearly resampled.
/// Already-16 kHz little-endian PCM16 stays on the integer path so samples
/// are not rounded through float.
///
/// A straight average of opposite-polarity channels is digital silence.
/// ScreenCaptureKit's system track delivers that layout (non-interleaved
/// float, second channel an inverted copy). The microphone track is one
/// channel and never hits the mix. When the average cancels and a channel
/// still has energy, the loud channel is kept.
    public static func convertToPCM16Mono(buffers: [Data], format: SourcePCMFormat, frameCount: Int) throws -> Data {
        guard format.channels > 0 else { throw Failure.invalidChannelCount }
        guard frameCount > 0 else { throw Failure.empty }
        guard format.bitsPerChannel >= 8, format.bitsPerChannel % 8 == 0 else {
            throw Failure.unsupportedFormat("\(format.bitsPerChannel)-bit PCM")
        }
        if format.isFloat {
            guard format.bitsPerChannel == 32 || format.bitsPerChannel == 64 else {
                throw Failure.unsupportedFormat("\(format.bitsPerChannel)-bit float")
            }
        } else {
            guard format.bitsPerChannel == 16 else {
                throw Failure.unsupportedFormat("\(format.bitsPerChannel)-bit integer")
            }
        }
        guard buffers.count == format.bufferCount else { throw Failure.bufferTooSmall }
        let needed = format.bytesPerBuffer(frameCount: frameCount)
        guard buffers.allSatisfy({ $0.count >= needed }) else { throw Failure.bufferTooSmall }

        if !format.isFloat && !format.isBigEndian && abs(format.sampleRate - Double(AudioFormat.sampleRate)) < 1 {
            return try integerPCM16Mono(buffers: buffers, format: format, frameCount: frameCount)
        }
        guard format.sampleRate > 0 else {
            throw Failure.unsupportedFormat("sample rate \(format.sampleRate)")
        }
        let mono = decodeMonoFloat(buffers: buffers, format: format, frameCount: frameCount)
        let resampled = resampleLinear(mono, from: format.sampleRate, to: Double(AudioFormat.sampleRate))
        guard !resampled.isEmpty else { throw Failure.empty }
        return encodePCM16(resampled)
    }

    #if canImport(CoreMedia) && canImport(AudioToolbox)
    /// Copies PCM out of an SCK `CMSampleBuffer` and converts it to 16 kHz mono PCM16.
    /// The destination `AudioBufferList` is sized from the buffer's own
    /// `AudioStreamBasicDescription` (float32, planar or interleaved). The
    /// retained-block-buffer variant fails with OSStatus -12737 on SCK buffers;
    /// a list sized for PCM16 fails the copy as well.
    public static func extract(from sampleBuffer: CMSampleBuffer) throws -> Data {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { throw Failure.empty }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw Failure.unsupportedFormat("missing audio format description")
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw Failure.unsupportedFormat("format id \(asbd.mFormatID)")
        }
        let flags = asbd.mFormatFlags
        let format = SourcePCMFormat(
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isFloat: flags & kAudioFormatFlagIsFloat != 0,
            isNonInterleaved: flags & kAudioFormatFlagIsNonInterleaved != 0,
            isBigEndian: flags & kAudioFormatFlagIsBigEndian != 0
        )
        guard format.channels > 0 else { throw Failure.invalidChannelCount }
        guard Int(asbd.mBytesPerFrame) == format.bytesPerFramePerBuffer else {
            throw Failure.unsupportedFormat(
                "mBytesPerFrame \(asbd.mBytesPerFrame) != \(format.bytesPerFramePerBuffer)"
            )
        }

        let bufferCount = format.bufferCount
        let bytesPerBuffer = format.bytesPerBuffer(frameCount: frames)
        let listSize = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        _ = rawList.initializeMemory(as: UInt8.self, repeating: 0, count: listSize)
        let list = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(bufferCount)

        var storage: [UnsafeMutableRawPointer] = []
        storage.reserveCapacity(bufferCount)
        defer { storage.forEach { $0.deallocate() } }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        for index in 0..<bufferCount {
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(bytesPerBuffer, 1), alignment: 16)
            storage.append(bytes)
            abl[index].mNumberChannels = format.isNonInterleaved ? 1 : UInt32(format.channels)
            abl[index].mDataByteSize = UInt32(bytesPerBuffer)
            abl[index].mData = bytes
        }

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: list
        )
        var copiedPCM: Data?
        if status == noErr {
            var copiedBuffers: [Data] = []
            copiedBuffers.reserveCapacity(bufferCount)
            var copyIntact = true
            for index in 0..<bufferCount {
                guard let data = abl[index].mData else {
                    copyIntact = false
                    break
                }
                let copied = Int(abl[index].mDataByteSize)
                guard copied >= bytesPerBuffer else {
                    copyIntact = false
                    break
                }
                copiedBuffers.append(Data(bytes: data, count: bytesPerBuffer))
            }
            if copyIntact {
                let pcm = try convertToPCM16Mono(buffers: copiedBuffers, format: format, frameCount: frames)
                if hasEnergy(pcm) {
                    return pcm
                }
                copiedPCM = pcm
            }
        }

        if let recovered = pcmFromContiguousBlock(sampleBuffer, format: format, frameCount: frames),
           hasEnergy(recovered) {
            return recovered
        }
        if let copiedPCM {
            return copiedPCM
        }
        guard status == noErr else {
            throw CaptureError.pcmExtractionFailed(status: status, detail: "CMSampleBufferCopyPCMDataIntoAudioBufferList")
        }
        throw Failure.bufferTooSmall
    }

    /// SCK packs non-interleaved float as one contiguous block: channel `c`
    /// starts at sample `c * frameCount`. `CMSampleBufferCopyPCMDataIntoAudioBufferList`
    /// can return `noErr` and a zero-filled list for that layout. The block
    /// still holds the samples.
    private static func pcmFromContiguousBlock(
        _ sampleBuffer: CMSampleBuffer,
        format: SourcePCMFormat,
        frameCount: Int
    ) -> Data? {
        guard format.isFloat, format.bitsPerChannel == 32, !format.isBigEndian else { return nil }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, totalLength > 0 else { return nil }
        let sampleBytes = 4
        var interpret = format
        if format.channels > 1 && Int(format.bytesPerFramePerBuffer) == sampleBytes {
            interpret.isNonInterleaved = true
        }
        let channelCount = interpret.channels
        let needed = frameCount * sampleBytes * channelCount
        guard totalLength >= needed, channelCount > 0 else { return nil }
        var channelBuffers: [Data] = []
        channelBuffers.reserveCapacity(interpret.bufferCount)
        if interpret.isNonInterleaved {
            let channelBytes = frameCount * sampleBytes
            for channel in 0..<channelCount {
                let start = channel * channelBytes
                channelBuffers.append(Data(bytes: dataPointer.advanced(by: start), count: channelBytes))
            }
        } else {
            channelBuffers.append(Data(bytes: dataPointer, count: needed))
        }
        guard let pcm = try? convertToPCM16Mono(buffers: channelBuffers, format: interpret, frameCount: frameCount) else {
            return nil
        }
        guard saneFloatBlock(channelBuffers, format: interpret, frameCount: frameCount) else { return nil }
        return pcm
    }

    /// Reject a mis-read block. Real SCK float samples sit near [-1, 1].
    /// Silence is finite and is not treated as recovered audio.
    private static func saneFloatBlock(_ buffers: [Data], format: SourcePCMFormat, frameCount: Int) -> Bool {
        let channels = format.channels
        var seen = 0
        for channel in 0..<min(channels, buffers.count) {
            for frame in 0..<frameCount {
                let sample = readSample(buffers[format.isNonInterleaved ? channel : 0], index: format.isNonInterleaved ? frame : frame * channels + channel, format: format)
                if !sample.isFinite || abs(sample) > 4 { return false }
                seen += 1
            }
        }
        return seen > 0
    }

    private static func hasEnergy(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).contains { $0 != 0 }
        }
    }
    #endif

    private static func integerPCM16Mono(buffers: [Data], format: SourcePCMFormat, frameCount: Int) throws -> Data {
        if format.channels == 1 {
            return Data(buffers[0].prefix(frameCount * AudioFormat.bytesPerSample))
        }
        if !format.isNonInterleaved {
            let byteCount = frameCount * format.channels * AudioFormat.bytesPerSample
            return try monoPCM16(interleaved: Data(buffers[0].prefix(byteCount)), channels: format.channels)
        }
        var output = Data(count: frameCount * AudioFormat.bytesPerSample)
        output.withUnsafeMutableBytes { rawOut in
            let samples = rawOut.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                var sum = 0
                for channel in 0..<format.channels {
                    sum += Int(readInt16(buffers[channel], offset: frame * 2, bigEndian: false))
                }
                samples[frame] = Int16(sum / format.channels)
            }
        }
        return output
    }

    private static func decodeMonoFloat(buffers: [Data], format: SourcePCMFormat, frameCount: Int) -> [Float] {
        let channels = format.channels
        var perChannel = [[Float]]()
        perChannel.reserveCapacity(channels)
        for channel in 0..<channels {
            var samples = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                let index = format.isNonInterleaved ? frame : frame * channels + channel
                let buffer = format.isNonInterleaved ? buffers[channel] : buffers[0]
                samples[frame] = readSample(buffer, index: index, format: format)
            }
            perChannel.append(samples)
        }
        return mixDown(perChannel)
    }

    /// Average channels. If that average cancels (opposite polarity) and one
    /// channel still has energy, keep the loud channel instead of silence.
    private static func mixDown(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        let frames = first.count
        var mixed = [Float](repeating: 0, count: frames)
        var energies = [Float](repeating: 0, count: channels.count)
        for (channel, samples) in channels.enumerated() {
            var energy: Float = 0
            let count = min(frames, samples.count)
            for frame in 0..<count {
                let sample = samples[frame]
                mixed[frame] += sample
                energy += sample * sample
            }
            energies[channel] = energy
        }
        let scale = 1 / Float(channels.count)
        var mixedEnergy: Float = 0
        for frame in 0..<frames {
            mixed[frame] *= scale
            mixedEnergy += mixed[frame] * mixed[frame]
        }
        let loudestEnergy = energies.max() ?? 0
        // Amplitude of the average under ~10% of the loud channel.
        if loudestEnergy > 1e-12 && mixedEnergy * 100 < loudestEnergy {
            let index = energies.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            return channels[index]
        }
        return mixed
    }

    private static func readSample(_ data: Data, index: Int, format: SourcePCMFormat) -> Float {
        let sampleBytes = format.bitsPerChannel / 8
        let offset = index * sampleBytes
        if format.isFloat && format.bitsPerChannel == 64 {
            return Float(readFloat64(data, offset: offset, bigEndian: format.isBigEndian))
        }
        if format.isFloat {
            return readFloat32(data, offset: offset, bigEndian: format.isBigEndian)
        }
        return Float(readInt16(data, offset: offset, bigEndian: format.isBigEndian)) / 32768
    }

    private static func readFloat32(_ data: Data, offset: Int, bigEndian: Bool) -> Float {
        let bits = readUInt32(data, offset: offset, bigEndian: bigEndian)
        return Float(bitPattern: bits)
    }

    private static func readFloat64(_ data: Data, offset: Int, bigEndian: Bool) -> Double {
        let bits = readUInt64(data, offset: offset, bigEndian: bigEndian)
        return Double(bitPattern: bits)
    }

    private static func readInt16(_ data: Data, offset: Int, bigEndian: Bool) -> Int16 {
        Int16(bitPattern: readUInt16(data, offset: offset, bigEndian: bigEndian))
    }

    private static func readUInt16(_ data: Data, offset: Int, bigEndian: Bool) -> UInt16 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let assembled = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            return bigEndian ? assembled.byteSwapped : assembled
        }
    }

    private static func readUInt32(_ data: Data, offset: Int, bigEndian: Bool) -> UInt32 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let assembled = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            return bigEndian ? assembled.byteSwapped : assembled
        }
    }

    private static func readUInt64(_ data: Data, offset: Int, bigEndian: Bool) -> UInt64 {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var assembled: UInt64 = 0
            for index in 0..<8 {
                assembled |= UInt64(bytes[offset + index]) << (8 * index)
            }
            return bigEndian ? assembled.byteSwapped : assembled
        }
    }

    private static func resampleLinear(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        if abs(sourceRate - targetRate) < 1 { return input }
        let outputCount = Int((Double(input.count) * targetRate / sourceRate).rounded(.down))
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        let step = sourceRate / targetRate
        let last = input.count - 1
        for index in 0..<outputCount {
            let position = Double(index) * step
            let left = min(Int(position), last)
            let right = min(left + 1, last)
            let fraction = Float(position - Double(left))
            output[index] = input[left] * (1 - fraction) + input[right] * fraction
        }
        return output
    }

    private static func encodePCM16(_ samples: [Float]) -> Data {
        var output = Data(count: samples.count * AudioFormat.bytesPerSample)
        output.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clamped = min(1, max(-1, sample))
                destination[index] = Int16(clamping: Int((clamped * 32767).rounded()))
            }
        }
        return output
    }
}
