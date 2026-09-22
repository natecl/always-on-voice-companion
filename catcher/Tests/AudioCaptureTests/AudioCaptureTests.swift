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

    // No authority readback: Settings stays closed for a microphone block.
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone access denied",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "microphone access denied")
    ) == nil)
    // A denied row for Catcher's own identity is the one case the pane can fix.
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone access denied",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "microphone access denied"),
        authority: authority(status: "denied")
    ) == .microphone)
    // Signing and attribution blocks are not fixable in Settings.
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone permission is judged for Terminal, not Catcher",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "microphone permission is judged for Terminal, not Catcher"),
        authority: authority(status: "authorized", responsiblePID: 77, responsibleName: "Terminal")
    ) == nil)
    #expect(PrivacySettingsPane.settingsPane(
        blockReason: "microphone blocked by signing: hardened runtime without the audio-input entitlement",
        microphonePromptGranted: false,
        followUp: .blocked(reason: "microphone blocked by signing"),
        authority: authority(status: "denied", entitlement: false)
    ) == nil)
    #expect(MicrophoneRegrant.opensMicrophoneSettings(for: authority(status: "denied")))
    #expect(!MicrophoneRegrant.opensMicrophoneSettings(for: authority(status: "notDetermined")))
    let silentDeny = MicrophoneRegrant.dialogFailedCopy(atLaunch: "notDetermined", before: "notDetermined", after: "denied")
    #expect(silentDeny.contains("requestAccess changed notDetermined to denied"))
    #expect(silentDeny.contains("no +"))
    #expect(silentDeny.contains("Request microphone"))
    let alreadyDenied = MicrophoneRegrant.dialogFailedCopy(atLaunch: "denied", before: "denied", after: "denied")
    #expect(alreadyDenied.contains("already denied"))
    #expect(alreadyDenied.contains("Re-grant opens the Microphone pane"))
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

private func authority(
    status: String,
    record: String = "granted",
    hardened: Bool? = true,
    entitlement: Bool? = true,
    pid: Int32 = 500,
    responsiblePID: Int32? = 500,
    responsibleName: String? = "com.catcher.app"
) -> MicrophoneAuthority {
    MicrophoneAuthority(
        authorizationStatus: status,
        recordPermission: record,
        hardenedRuntime: hardened,
        audioInputEntitlement: entitlement,
        pid: pid,
        parentPID: 1,
        responsiblePID: responsiblePID,
        responsibleName: responsibleName,
        bundleIdentifier: "com.catcher.app",
        bundlePath: "/Applications/Catcher.app"
    )
}

@Test func authorizedReadbackIsNeverLabelledDenied() {
    let ok = authority(status: "authorized")
    #expect(ok.blockReason == nil)
    #expect(ok.recovery == .none)
    #expect(ok.explanation == nil)
    #expect(ok.consoleLine.contains("verdict=microphone ok"))
    #expect(ok.consoleLine.hasPrefix("Catcher mic authority "))
    #expect(!ok.consoleLine.contains("denied"))
}

@Test func hardenedRuntimeWithoutEntitlementBlocksWhateverTCCSays() {
    for status in ["authorized", "denied", "notDetermined"] {
        let unsigned = authority(status: status, entitlement: false)
        #expect(unsigned.signingBlocksMicrophone)
        #expect(unsigned.recovery == .rebuildWithEntitlement)
        #expect(unsigned.blockReason?.contains("hardened runtime") == true)
        #expect(unsigned.blockReason?.contains("denied") != true)
        #expect(unsigned.explanation?.contains("com.apple.security.device.audio-input") == true)
        #expect(unsigned.explanation?.contains("build-app.sh") == true)
        #expect(unsigned.explanation?.contains("it read \(status)") == true)
    }
    // Not hardened: the entitlement is not required.
    let plain = authority(status: "authorized", hardened: false, entitlement: false)
    #expect(!plain.signingBlocksMicrophone)
    #expect(plain.blockReason == nil)
    // Unknown signing facts never block on their own.
    let unknown = authority(status: "authorized", hardened: nil, entitlement: nil)
    #expect(unknown.blockReason == nil)
}

@Test func launchedFromAShellIsJudgedForTheShellApp() {
    let inherited = authority(status: "authorized", pid: 500, responsiblePID: 77, responsibleName: "Terminal")
    #expect(!inherited.ownsTCCIdentity)
    #expect(inherited.recovery == .relaunchUnderOwnIdentity)
    #expect(inherited.blockReason == "microphone permission is judged for Terminal, not Catcher")
    #expect(inherited.explanation?.contains("started by Terminal (pid 77)") == true)
    #expect(inherited.explanation?.contains("not on the Microphone list") == true)
    #expect(inherited.explanation?.contains("relaunch") == true)
    #expect(inherited.recovery.buttonTitle == "Relaunch Catcher for microphone")
    #expect(PrivacySettingsPane.forBlockReason(inherited.blockReason ?? "") == .microphone)
    // Signing wins over attribution: nothing else matters until the entitlement is there.
    let both = authority(status: "authorized", entitlement: false, responsiblePID: 77, responsibleName: "Terminal")
    #expect(both.recovery == .rebuildWithEntitlement)
    // Lookup unavailable: assume own identity rather than invent a block.
    let unknown = authority(status: "authorized", responsiblePID: nil, responsibleName: nil)
    #expect(unknown.ownsTCCIdentity)
    #expect(unknown.blockReason == nil)
}

@Test func ownIdentityStatusesMapToPromptSettingsOrNothing() {
    let undetermined = authority(status: "notDetermined")
    #expect(undetermined.recovery == .prompt)
    #expect(undetermined.blockReason == "microphone access not determined")
    #expect(undetermined.recovery.buttonTitle == "Request microphone")
    let denied = authority(status: "denied")
    #expect(denied.recovery == .openMicrophoneSettings)
    #expect(denied.blockReason == "microphone access denied")
    #expect(denied.explanation?.contains("Re-grant opens that pane") == true)
    #expect(denied.recovery.buttonTitle == "Open Microphone settings")
    let restricted = authority(status: "restricted")
    #expect(restricted.recovery == .none)
    #expect(restricted.blockReason == "microphone access unavailable")
    #expect(MicrophoneAuthority.unavailable.blockReason == "microphone status unavailable on this platform")
    #expect(MicrophoneAuthority.unavailable.recovery == .none)
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
