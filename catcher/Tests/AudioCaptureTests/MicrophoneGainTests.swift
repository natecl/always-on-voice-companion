@testable import AudioCapture
import Foundation
import Testing

@Test func roomToneAndClicksPassThroughByteForByte() {
    for rms: Float in [0.001, 0.002, 0.008, 0.015] {
        var room = noise(rms: rms, seconds: 12, seed: 7)
        for second in [2, 5, 9] {
            let at = second * 16_000
            for index in at..<(at + 320) {
                room[index] = index.isMultiple(of: 2) ? 3_000 : -3_000
            }
        }
        var gain = MicrophoneGain()
        let output = feed(room, through: &gain)
        #expect(output == room, "room tone \(rms) was changed")
        #expect(gain.peakGain == 1)
    }
}

@Test func quietHeldSpeechIsLiftedOverTheGraderFloor() {
    let seconds = 12
    let input = mix(speech(rms: 0.02, seconds: seconds), noise(rms: 0.0015, seconds: seconds, seed: 3))
    var gain = MicrophoneGain()
    let output = feed(input, through: &gain)
    let before = windowRMS(input, from: 3)
    let after = windowRMS(output, from: 3)
    #expect(median(before) < 0.03)
    #expect(median(after) >= 0.1)
    #expect(gain.peakGain <= MicrophoneGain.maxGain)
    let ceiling = Int16((MicrophoneGain.peakCeiling * 32_768).rounded()) + 1
    #expect(output.allSatisfy { abs(Int($0)) <= Int(ceiling) })
}

@Test func gainFallsBackToUnityAfterSpeechStops() {
    let talk = mix(speech(rms: 0.02, seconds: 6), noise(rms: 0.0015, seconds: 6, seed: 5))
    let quiet = noise(rms: 0.0015, seconds: 12, seed: 6)
    var gain = MicrophoneGain()
    _ = feed(talk, through: &gain)
    #expect(gain.gain > 4)
    let output = feed(quiet, through: &gain)
    #expect(gain.gain == 1)
    let lastSecond = quiet.count - 16_000
    #expect(Array(output[lastSecond...]) == Array(quiet[lastSecond...]))
}

@Test func speechAlreadyAtTargetIsNotBoosted() {
    let input = mix(speech(rms: 0.3, seconds: 6), noise(rms: 0.0015, seconds: 6, seed: 9))
    var gain = MicrophoneGain()
    let output = feed(input, through: &gain)
    #expect(output == input)
    #expect(gain.peakGain == 1)
}

/// 341 samples is one 1024-frame 48 kHz ScreenCaptureKit buffer after resampling.
private func feed(_ samples: [Int16], through gain: inout MicrophoneGain, frame: Int = 341) -> [Int16] {
    var output: [Int16] = []
    output.reserveCapacity(samples.count)
    var start = 0
    while start < samples.count {
        let end = min(start + frame, samples.count)
        let data = Array(samples[start..<end]).withUnsafeBytes { Data($0) }
        let processed = gain.process(data)
        output.append(contentsOf: processed.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
        start = end
    }
    return output
}

private func noise(rms: Float, seconds: Int, seed: UInt64) -> [Int16] {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    let amplitude: Float = rms * Float(3).squareRoot() * 32_768
    return (0..<(seconds * 16_000)).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit: Float = Float(state >> 40) / Float(1 << 24) * 2 - 1
        let scaled: Float = unit * amplitude
        return Int16(scaled.rounded())
    }
}

/// 250 ms voiced bursts with 80 ms gaps, under the 120 ms dip that ends a burst.
private func speech(rms: Float, seconds: Int) -> [Int16] {
    let amplitude: Float = rms * Float(2).squareRoot() * 32_768
    return (0..<(seconds * 16_000)).map { index in
        let voiced = index % 5_280 < 4_000
        let phase: Float = 2 * Float.pi * 220 * Float(index) / 16_000
        let value: Float = amplitude * sin(phase)
        return voiced ? Int16(value.rounded()) : 0
    }
}

private func mix(_ left: [Int16], _ right: [Int16]) -> [Int16] {
    zip(left, right).map { Int16(clamping: Int($0) + Int($1)) }
}

/// The grader's 100 ms AC RMS windows above its 0.001 digital floor.
private func windowRMS(_ samples: [Int16], from second: Int) -> [Float] {
    stride(from: second * 16_000, to: samples.count - 1_599, by: 1_600).compactMap { start in
        let chunk = samples[start..<(start + 1_600)].map { Float($0) / 32_768 }
        let mean = chunk.reduce(0, +) / Float(chunk.count)
        let energy = chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)
        let rms = max(0, energy - mean * mean).squareRoot()
        return rms > 0.001 ? rms : nil
    }
}

private func median(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}
