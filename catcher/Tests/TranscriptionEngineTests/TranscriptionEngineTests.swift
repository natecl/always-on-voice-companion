import AudioCapture
import Foundation
import Testing
import TranscriptionEngine

@Test func stubEmitsReadyThenCannedFinalsOnTheConnectedTrack() async throws {
    let engine = StubEngine(track: .microphone, framesPerFinal: 2)
    var iterator = engine.events.makeAsyncIterator()
    try await engine.connect(track: .system)
    let states = [
        await iterator.next(),
        await iterator.next(),
        await iterator.next(),
    ]
    #expect(states.contains(.state(.connecting)))
    #expect(states.contains(.state(.ready)))
    #expect(states.contains(.state(.streaming)))

    let frame = PCMFrame(track: .system, data: Data(repeating: 1, count: 3_200), hostTime: 1)
    try await engine.send(frame)
    let first = try #require(await iterator.next())
    guard case .transcript(let partial) = first else {
        Issue.record("expected a partial")
        return
    }
    #expect(partial.kind == .partial)
    #expect(partial.track == .system)
    #expect(partial.text == "partial")

    try await engine.send(frame)
    let second = try #require(await iterator.next())
    guard case .transcript(let secondEvent) = second else {
        Issue.record("expected a second partial")
        return
    }
    #expect(secondEvent.kind == .partial)
    let third = try #require(await iterator.next())
    guard case .transcript(let final) = third else {
        Issue.record("expected a final")
        return
    }
    #expect(final.kind == .final)
    #expect(final.track == .system)
    #expect(final.speaker == "S1")
    #expect(final.text.contains("catcher stub"))
    #expect(final.words.first?.w == "catcher")

    await engine.finish()
    let closed = try #require(await iterator.next())
    #expect(closed == .state(.closed))
    #expect(await iterator.next() == nil)
}

@Test func micStubFinalHasNoSpeaker() async throws {
    let engine = StubEngine(track: .microphone, framesPerFinal: 1)
    var iterator = engine.events.makeAsyncIterator()
    try await engine.connect(track: .microphone)
    _ = await iterator.next()
    _ = await iterator.next()
    _ = await iterator.next()
    try await engine.send(PCMFrame(track: .microphone, data: Data(count: 640), hostTime: 0))
    _ = await iterator.next()
    let event = try #require(await iterator.next())
    guard case .transcript(let final) = event else {
        Issue.record("expected final")
        return
    }
    #expect(final.kind == .final)
    #expect(final.speaker == nil)
    #expect(final.track == .microphone)
}

@Test func factoryDefaultsToGrokAndSelectsStub() throws {
    #expect(EngineFactory.selection(environment: [:]) == "grok")
    #expect(EngineFactory.sessionEngineName(environment: [:]) == EngineFactory.grokModelName)
    #expect(EngineFactory.selection(environment: ["CATCHER_ENGINE": "stub"]) == "stub")
    let engine = try EngineFactory.make(track: .system, environment: ["CATCHER_ENGINE": "stub"])
    #expect(engine is StubEngine)
    #expect(throws: EngineFactory.Failure.unknownEngine("nope")) {
        try EngineFactory.make(track: .system, environment: ["CATCHER_ENGINE": "nope"])
    }
}

extension EngineEvent {
    fileprivate var isPartialTranscript: Bool {
        if case .transcript(let event) = self { return event.kind == .partial }
        return false
    }
}
