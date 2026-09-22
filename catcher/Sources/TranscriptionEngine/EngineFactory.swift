import AudioCapture
import Foundation

/// The only switch on `CATCHER_ENGINE`. Concrete engines register; this file
/// names `grok` and `stub`. Pipeline does not branch on an engine type.
public enum EngineFactory {
    public static let grokModelName = "grok-voice-transcribe-2.0"
    public static let environmentKey = "CATCHER_ENGINE"

    public enum Failure: Error, Equatable {
        case unregistered(String)
        case unknownEngine(String)
    }

    public typealias Builder = @Sendable (AudioTrack) -> any TranscriptionEngine

    private static let builders = Locked([
        "stub": { track in StubEngine(track: track) } as Builder,
    ])

    public static func selection(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let raw, !raw.isEmpty {
            return raw
        }
        return "grok"
    }

    public static func sessionEngineName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch selection(environment: environment) {
        case "stub":
            return "stub"
        default:
            return grokModelName
        }
    }

    public static func register(_ name: String, builder: @escaping Builder) {
        builders.withLock { $0[name] = builder }
    }

    public static func make(
        track: AudioTrack,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any TranscriptionEngine {
        let name = selection(environment: environment)
        let builder = builders.withLock { $0[name] }
        guard let builder else {
            if name == "grok" || name == "stub" {
                throw Failure.unregistered(name)
            }
            throw Failure.unknownEngine(name)
        }
        return builder(track)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
