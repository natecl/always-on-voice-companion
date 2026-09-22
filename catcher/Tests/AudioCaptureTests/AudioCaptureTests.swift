import AudioCapture
import Foundation
import Testing

@Test func captureConfigMatchesLockedFields() {
    let config = CaptureConfig.make()
    #expect(config.sampleRate == 16_000)
    #expect(config.channelCount == 1)
    #expect(config.width == 2)
    #expect(config.height == 2)
    #expect(config.minimumFrameIntervalSeconds == 1)
    #expect(config.excludesCurrentProcessAudio)
    #expect(config.capturesAudio)
    #expect(config.captureMicrophone)
    #expect(config.wholeDisplay)
    #expect(AudioFormat.chunkBytes == 3_200)
}

@Test func silenceHasZeroRMSAndToneDoesNot() {
    let silence = Data(count: 320)
    #expect(PCMEnergy.rms(silence) == 0)
    let samples = [Int16](repeating: 16_000, count: 160)
    let loud = samples.withUnsafeBytes { Data($0) }
    #expect(PCMEnergy.rms(loud) > 0.4)
}

@Test func monoDownmixAveragesChannels() throws {
    let stereo: [Int16] = [1_000, -1_000, 2_000, 2_000]
    let data = stereo.withUnsafeBytes { Data($0) }
    let mono = try SampleBufferPCM.monoPCM16(interleaved: data, channels: 2)
    let samples = mono.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(samples == [0, 2_000])
}

@Test func monoPassThroughKeepsBytes() throws {
    let data = Data([1, 2, 3, 4])
    let mono = try SampleBufferPCM.monoPCM16(interleaved: data, channels: 1)
    #expect(mono == data)
}

@Test func hostClockMovesForward() {
    let start = HostClock.now()
    let end = HostClock.now()
    #expect(end >= start)
    #expect(HostClock.milliseconds(from: start, to: end) >= 0)
}

@Test func permissionProbeIsBlockedWithoutScreenCaptureKit() async {
    let state = await PermissionGate.startCaptureProbe()
    #if canImport(ScreenCaptureKit)
    _ = state
    #else
    if case .blocked(let reason) = state {
        #expect(reason.contains("ScreenCaptureKit"))
    } else {
        Issue.record("expected a blocked probe off macOS")
    }
    #endif
}

#if os(macOS)
import AudioToolbox
import CoreMedia

@Test func sampleBufferExtractionUsesCopyPCMPath() throws {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 16_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsLittleEndian,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var format: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format
    )
    #expect(formatStatus == noErr)
    let samples: [Int16] = [1000, -1000, 500, -500]
    let byteCount = samples.count * 2
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &block
    ) == noErr)
    try samples.withUnsafeBytes { raw in
        #expect(CMBlockBufferReplaceDataBytes(
            with: raw.baseAddress!,
            blockBuffer: block!,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == noErr)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 16_000),
        presentationTimeStamp: .invalid,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format!,
        sampleCount: samples.count,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    #expect(status == noErr)
    let extracted = try SampleBufferPCM.extract(from: sampleBuffer!)
    let decoded = extracted.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(decoded == samples)
}
#endif
