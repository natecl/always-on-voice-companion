import AudioCapture
import Foundation
import Testing

@Test func captureConfigMatchesLockedFields() {
    let config = CaptureConfig.make()
    #expect(config.sampleRate == 48_000)
    #expect(config.channelCount == 2)
    #expect(AudioFormat.sampleRate == 16_000)
    #expect(AudioFormat.channels == 1)
    #expect(config.width == 2)
    #expect(config.height == 2)
    #expect(config.minimumFrameIntervalSeconds == 1)
    #expect(config.excludesCurrentProcessAudio)
    #expect(config.capturesAudio)
    #expect(config.captureMicrophone)
    #expect(config.wholeDisplay)
    #expect(config.queueDepth == 8)
    #expect(config.microphoneDeviceID == nil)
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

@Test func float32MonoIsWiderThanTheOldPCM16Allocation() {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 1,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    #expect(format.bufferCount == 1)
    #expect(format.bytesPerFramePerBuffer == 4)
    let frames = 480
    let oldByteCount = frames * format.channels * AudioFormat.bytesPerSample
    #expect(format.bytesPerBuffer(frameCount: frames) == frames * 4)
    #expect(format.bytesPerBuffer(frameCount: frames) != oldByteCount)
}

@Test func planarFloatStereoNeedsOneBufferPerChannel() {
    let format = SourcePCMFormat(
        sampleRate: 48_000,
        channels: 2,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    #expect(format.bufferCount == 2)
    #expect(format.bytesPerBuffer(frameCount: 100) == 400)
}

@Test func float32MonoConvertsToPCM16() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 1,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([0.5, -0.5, 0])],
        format: format,
        frameCount: 3
    )
    #expect(int16Samples(pcm) == [16_384, -16_384, 0])
}

@Test func bigEndianFloatFullScaleBecomesPCM16() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 1,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: false,
        isBigEndian: true
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [beFloat32([1, -1])],
        format: format,
        frameCount: 2
    )
    #expect(int16Samples(pcm) == [32_767, -32_767])
}

@Test func planarOppositePolarityKeepsTheLoudChannel() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 2,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([1, 1]), leFloat32([-1, -1])],
        format: format,
        frameCount: 2
    )
    #expect(int16Samples(pcm) == [32_767, 32_767])
}

@Test func interleavedOppositePolarityKeepsTheLoudChannel() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 2,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: false,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([1, -1, 0.5, -0.5])],
        format: format,
        frameCount: 2
    )
    #expect(int16Samples(pcm) == [32_767, 16_384])
}

@Test func correlatedStereoStillAverages() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 2,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([0.5, 0]), leFloat32([0.5, 0])],
        format: format,
        frameCount: 2
    )
    #expect(int16Samples(pcm) == [16_384, 0])
}

@Test func oneSilentChannelStillAverages() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 2,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([1, 0]), leFloat32([0, 0])],
        format: format,
        frameCount: 2
    )
    #expect(int16Samples(pcm) == [16_384, 0])
}

@Test func prefersMainAwakeDisplayOverAnInactiveBuiltIn() {
    let displays = [
        SystemAudioDisplay(id: 1, active: false, asleep: true, isMain: true),
        SystemAudioDisplay(id: 2, active: true, asleep: false, isMain: false),
    ]
    #expect(SystemAudioDisplayChoice.preferred(displays) == 2)
    let main = [
        SystemAudioDisplay(id: 9, active: true, asleep: false, isMain: false),
        SystemAudioDisplay(id: 3, active: true, asleep: false, isMain: true),
    ]
    #expect(SystemAudioDisplayChoice.preferred(main) == 3)
    #expect(SystemAudioDisplayChoice.preferred([]) == nil)
}

@Test func fortyEightKilohertzFloatResamplesToSixteen() throws {
    let format = SourcePCMFormat(
        sampleRate: 48_000,
        channels: 1,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: true,
        isBigEndian: false
    )
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [leFloat32([Float](repeating: 0.25, count: 480))],
        format: format,
        frameCount: 480
    )
    let samples = int16Samples(pcm)
    #expect(samples.count == 160)
    #expect(samples.allSatisfy { $0 == 8_192 })
}

@Test func sixteenKilohertzPCM16PassesThroughWithoutFloatRounding() throws {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 1,
        bitsPerChannel: 16,
        isFloat: false,
        isNonInterleaved: false,
        isBigEndian: false
    )
    let source: [Int16] = [1000, -1000, 500, -500]
    let pcm = try SampleBufferPCM.convertToPCM16Mono(
        buffers: [source.withUnsafeBytes { Data($0) }],
        format: format,
        frameCount: source.count
    )
    #expect(int16Samples(pcm) == source)
}

@Test func shortFloatBufferIsRejected() {
    let format = SourcePCMFormat(
        sampleRate: 16_000,
        channels: 1,
        bitsPerChannel: 32,
        isFloat: true,
        isNonInterleaved: false,
        isBigEndian: false
    )
    #expect(throws: SampleBufferPCM.Failure.bufferTooSmall) {
        try SampleBufferPCM.convertToPCM16Mono(
            buffers: [Data([0, 0, 0, 0])],
            format: format,
            frameCount: 2
        )
    }
}

@Test func hostClockMovesForward() {
    let start = HostClock.now()
    let end = HostClock.now()
    #expect(end >= start)
    #expect(HostClock.milliseconds(from: start, to: end) >= 0)
}

@Test func regrantOpensMicrophoneForMicBlocksAndScreenForScreenBlocks() {
    #expect(PrivacySettingsPane.forBlockReason("microphone access denied") == .microphone)
    #expect(PrivacySettingsPane.forBlockReason("microphone access not determined") == .microphone)
    #expect(PrivacySettingsPane.forBlockReason("microphone access unavailable") == .microphone)
    #expect(PrivacySettingsPane.forBlockReason("silent buffers and permission re-probe failed: microphone access denied") == .microphone)
    #expect(PrivacySettingsPane.forBlockReason("screen recording access denied") == .screenCapture)
    #expect(PrivacySettingsPane.forBlockReason("screen recording permission revoked") == .screenCapture)
    #expect(PrivacySettingsPane.forBlockReason("ScreenCaptureKit is unavailable on this platform") == .screenCapture)

    let microphone = PrivacySettingsPane.microphone.systemSettingsURL?.absoluteString
    let screen = PrivacySettingsPane.screenCapture.systemSettingsURL?.absoluteString
    #expect(microphone?.contains("Privacy_Microphone") == true)
    #expect(screen?.contains("Privacy_ScreenCapture") == true)
    #expect(microphone?.contains("ScreenCapture") != true)

    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone access denied",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "microphone access denied")
    ) == nil)
    #expect(MicrophoneRegrant.opensMicrophoneSettings(after: .denied) == false)
    #expect(MicrophoneRegrant.opensMicrophoneSettings(after: .notDetermined) == false)
    let silentDeny = MicrophoneRegrant.dialogFailedCopy(atLaunch: "notDetermined", before: "notDetermined", after: "denied")
    #expect(silentDeny.contains("requestAccess changed notDetermined to denied"))
    #expect(silentDeny.contains("no +"))
    #expect(silentDeny.contains("System Settings was not opened"))
    #expect(silentDeny.contains("Request microphone"))
    let alreadyDenied = MicrophoneRegrant.dialogFailedCopy(atLaunch: "denied", before: "denied", after: "denied")
    #expect(alreadyDenied.contains("already denied"))
    #expect(LaunchPermissionOrder.steps == [.resolveScreenCapture, .promptMicrophone])
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "screen recording access denied",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "screen recording access denied")
    ) == .screenCapture)
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone access not determined",
        microphonePromptGranted: true,
        followUp: .granted
    ) == nil)
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone access not determined",
        microphonePromptGranted: true,
        followUp: .blocked(reason: "screen recording access denied")
    ) == .screenCapture)
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

private func leFloat32(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
        var bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func beFloat32(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
        var bits = sample.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func int16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
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
    #expect(int16Samples(extracted) == samples)
}

@Test func sampleBufferExtractionConvertsFloat32() throws {
    let floats: [Float] = [0.5, -0.5]
    let extracted = try SampleBufferPCM.extract(from: try makePCMSampleBuffer(
        asbd: AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        ),
        bytes: leFloat32(floats),
        sampleCount: floats.count
    ))
    #expect(int16Samples(extracted) == [16_384, -16_384])
}

private func makePCMSampleBuffer(
    asbd: AudioStreamBasicDescription,
    bytes: Data,
    sampleCount: Int
) throws -> CMSampleBuffer {
    var description = asbd
    var format: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format
    )
    #expect(formatStatus == noErr)
    var block: CMBlockBuffer?
    #expect(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: bytes.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: bytes.count,
        flags: 0,
        blockBufferOut: &block
    ) == noErr)
    try bytes.withUnsafeBytes { raw in
        #expect(CMBlockBufferReplaceDataBytes(
            with: raw.baseAddress!,
            blockBuffer: block!,
            offsetIntoDestination: 0,
            dataLength: bytes.count
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
        sampleCount: sampleCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    #expect(status == noErr)
    return try #require(sampleBuffer)
}
#endif
