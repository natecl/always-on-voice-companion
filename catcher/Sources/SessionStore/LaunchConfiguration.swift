import Foundation

/// Harness flags from the process environment or from `open --args` / a direct exec.
/// `open(1)` does not forward the caller's environment, so the same switches exist
/// as arguments: `--session-root`, `--harness`, `--engine`, `--auto-record`.
public struct LaunchConfiguration: Sendable, Equatable {
    public var sessionRoot: String?
    public var harness: Bool
    public var engine: String?
    public var autoRecord: Bool

    public init(
        sessionRoot: String? = nil,
        harness: Bool = false,
        engine: String? = nil,
        autoRecord: Bool = false
    ) {
        self.sessionRoot = sessionRoot
        self.harness = harness
        self.engine = engine
        self.autoRecord = autoRecord
    }

    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchConfiguration {
        var config = LaunchConfiguration(
            sessionRoot: nonempty(environment["CATCHER_SESSION_ROOT"]),
            harness: environment["CATCHER_HARNESS"] == "1",
            engine: nonempty(environment["CATCHER_ENGINE"]),
            autoRecord: environment["CATCHER_AUTO_RECORD"] == "1"
        )
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--harness" {
                config.harness = true
            } else if argument == "--auto-record" {
                config.autoRecord = true
            } else if argument == "--session-root", index + 1 < arguments.count {
                config.sessionRoot = arguments[index + 1]
                index += 1
            } else if let value = value(after: "--session-root=", in: argument) {
                config.sessionRoot = value
            } else if argument == "--engine", index + 1 < arguments.count {
                config.engine = arguments[index + 1]
                index += 1
            } else if let value = value(after: "--engine=", in: argument) {
                config.engine = value
            }
            index += 1
        }
        return config
    }

    /// Arguments win over the base environment. Used for the engine factory and session root.
    public func mergedEnvironment(_ base: [String: String] = [:]) -> [String: String] {
        var environment = base
        if let sessionRoot, !sessionRoot.isEmpty {
            environment["CATCHER_SESSION_ROOT"] = sessionRoot
        }
        if harness {
            environment["CATCHER_HARNESS"] = "1"
        }
        if let engine, !engine.isEmpty {
            environment["CATCHER_ENGINE"] = engine
        }
        if autoRecord {
            environment["CATCHER_AUTO_RECORD"] = "1"
        }
        return environment
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func value(after prefix: String, in argument: String) -> String? {
        guard argument.hasPrefix(prefix) else { return nil }
        let value = String(argument.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}
