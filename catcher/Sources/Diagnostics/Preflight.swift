import Foundation

public struct PreflightMicrophone: Sendable, Equatable {
    public var status: String
    public var owns: Bool
    public var entitlement: Bool?
    public var responsible: String

    public init(status: String, owns: Bool, entitlement: Bool?, responsible: String) {
        self.status = status
        self.owns = owns
        self.entitlement = entitlement
        self.responsible = responsible
    }
}

public struct PreflightDevice: Sendable, Equatable {
    public var uniqueID: String
    public var name: String

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

public struct PreflightCaptureResult: Sendable, Equatable {
    public var started: Bool
    public var system: Int
    public var microphone: Int
    public var error: String?

    public init(started: Bool, system: Int, microphone: Int, error: String?) {
        self.started = started
        self.system = system
        self.microphone = microphone
        self.error = error
    }
}

public struct PreflightHTTPResult: Sendable, Equatable {
    public var ok: Bool
    public var http: Int?
    public var body: String
    public var errorCode: Int?
    public var errorDomain: String?

    public init(ok: Bool, http: Int? = nil, body: String = "", errorCode: Int? = nil, errorDomain: String? = nil) {
        self.ok = ok
        self.http = http
        self.body = body
        self.errorCode = errorCode
        self.errorDomain = errorDomain
    }
}

public struct PreflightSTTResult: Sendable, Equatable {
    public var created: Bool
    public var milliseconds: Int?
    public var close: String?
    public var http: Int?
    public var error: String?

    public init(created: Bool, milliseconds: Int?, close: String?, http: Int?, error: String?) {
        self.created = created
        self.milliseconds = milliseconds
        self.close = close
        self.http = http
        self.error = error
    }
}

/// ScreenCaptureKit and AVFoundation stay outside this module. The app fills these in.
public struct PreflightDependencies: Sendable {
    public var screenGranted: @Sendable () -> Bool
    public var microphone: @Sendable () -> PreflightMicrophone
    public var micDevice: @Sendable () -> PreflightDevice?
    public var displayID: @Sendable () async -> UInt32?
    public var captureProbe: @Sendable () async -> PreflightCaptureResult
    public var apiReach: @Sendable () async -> PreflightHTTPResult
    public var apiAuth: @Sendable (String) async -> PreflightHTTPResult
    public var apiSTT: @Sendable (String) async -> PreflightSTTResult

    public init(
        screenGranted: @escaping @Sendable () -> Bool,
        microphone: @escaping @Sendable () -> PreflightMicrophone,
        micDevice: @escaping @Sendable () -> PreflightDevice?,
        displayID: @escaping @Sendable () async -> UInt32?,
        captureProbe: @escaping @Sendable () async -> PreflightCaptureResult,
        apiReach: @escaping @Sendable () async -> PreflightHTTPResult,
        apiAuth: @escaping @Sendable (String) async -> PreflightHTTPResult,
        apiSTT: @escaping @Sendable (String) async -> PreflightSTTResult
    ) {
        self.screenGranted = screenGranted
        self.microphone = microphone
        self.micDevice = micDevice
        self.displayID = displayID
        self.captureProbe = captureProbe
        self.apiReach = apiReach
        self.apiAuth = apiAuth
        self.apiSTT = apiSTT
    }
}

public enum Preflight {
    /// Check lines only. The caller appends `PREFLIGHT RESULT` after counting
    /// any signing line the shell already wrote.
    public static func run(
        environment: [String: String],
        dependencies: PreflightDependencies
    ) async -> [StageLine] {
        var lines: [StageLine] = []
        let engine = environment["CATCHER_ENGINE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let stub = engine == "stub"

        let screen = dependencies.screenGranted()
        if screen {
            lines.append(.preflight("tcc-screen", .pass))
        } else {
            lines.append(.preflight("tcc-screen", .fail, [Field("error", "screen recording access denied")]))
        }

        let mic = dependencies.microphone()
        let entitlementText: String
        switch mic.entitlement {
        case .some(true): entitlementText = "true"
        case .some(false): entitlementText = "false"
        case .none: entitlementText = "unknown"
        }
        let micFields = [
            Field("mic", mic.status),
            Field("owns", mic.owns ? "true" : "false"),
            Field("entitlement", entitlementText),
            Field("responsible", mic.responsible),
        ]
        let micPass = mic.status == "authorized" && mic.owns && mic.entitlement == true
        lines.append(.preflight("tcc-mic", micPass ? .pass : .fail, micFields))

        if let device = dependencies.micDevice() {
            lines.append(.preflight("mic-device", .pass, [
                Field("uniqueID", device.uniqueID),
                Field("name", device.name),
            ]))
        } else {
            lines.append(.preflight("mic-device", .fail, [Field("error", "no default audio input")]))
        }

        if let display = await dependencies.displayID() {
            lines.append(.preflight("capture-display", .pass, [Field("display", String(display))]))
        } else {
            lines.append(.preflight("capture-display", .fail, [Field("error", "no display")]))
        }

        if screen && micPass {
            let probe = await dependencies.captureProbe()
            if probe.started {
                lines.append(.preflight("capture-probe", .pass, [
                    Field("system", String(probe.system)),
                    Field("microphone", String(probe.microphone)),
                ]))
            } else {
                lines.append(.preflight("capture-probe", .fail, [
                    Field("error", probe.error ?? "start failed"),
                ]))
            }
        }

        if stub {
            let skipped = [Field("skipped", "stub")]
            lines.append(.preflight("api-key", .pass, skipped))
            lines.append(.preflight("api-reach", .pass, skipped))
            lines.append(.preflight("api-auth", .pass, skipped))
            lines.append(.preflight("api-stt", .pass, skipped))
        } else {
            let key = environment["XAI_API_KEY"] ?? ""
            if key.isEmpty {
                lines.append(.preflight("api-key", .fail, [Field("error", "missing XAI_API_KEY")]))
            } else {
                lines.append(.preflight("api-key", .pass, [Field("length", String(key.utf8.count))]))
            }
            lines.append(reachLine(await dependencies.apiReach()))
            if key.isEmpty {
                lines.append(.preflight("api-auth", .fail, [Field("error", "missing XAI_API_KEY")]))
                lines.append(.preflight("api-stt", .fail, [Field("error", "missing XAI_API_KEY")]))
            } else {
                lines.append(authLine(await dependencies.apiAuth(key)))
                lines.append(sttLine(await dependencies.apiSTT(key)))
            }
        }
        return lines
    }

    public static func result(checks: [StageLine], priorFails: Int = 0) -> StageLine {
        let failed = priorFails + checks.filter { $0.verdict == PreflightVerdict.fail.rawValue }.count
        return .preflightResult(failed == 0 ? .pass : .fail, failed: failed)
    }

    public static func failCount(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).reduce(0) { count, line in
            guard let parsed = StageLine.parse(String(line)) else { return count }
            return count + (parsed.verdict == PreflightVerdict.fail.rawValue ? 1 : 0)
        }
    }

    private static func reachLine(_ result: PreflightHTTPResult) -> StageLine {
        if result.ok {
            var fields: [Field] = []
            if let http = result.http { fields.append(Field("http", String(http))) }
            return .preflight("api-reach", .pass, fields)
        }
        var fields: [Field] = []
        if let domain = result.errorDomain { fields.append(Field("domain", domain)) }
        if let code = result.errorCode { fields.append(Field("code", String(code))) }
        if let http = result.http { fields.append(Field("http", String(http))) }
        if !result.body.isEmpty { fields.append(Field("error", result.body)) }
        return .preflight("api-reach", .fail, fields)
    }

    private static func authLine(_ result: PreflightHTTPResult) -> StageLine {
        var fields: [Field] = []
        if let http = result.http { fields.append(Field("http", String(http))) }
        if !result.body.isEmpty { fields.append(Field("body", result.body)) }
        if let code = result.errorCode { fields.append(Field("code", String(code))) }
        if let domain = result.errorDomain { fields.append(Field("domain", domain)) }
        return .preflight("api-auth", result.ok ? .pass : .fail, fields)
    }

    private static func sttLine(_ result: PreflightSTTResult) -> StageLine {
        if result.created {
            return .preflight("api-stt", .pass, [Field("ms", String(result.milliseconds ?? 0))])
        }
        var fields: [Field] = []
        if let close = result.close, !close.isEmpty { fields.append(Field("close", close)) }
        if let http = result.http { fields.append(Field("http", String(http))) }
        if let error = result.error, !error.isEmpty { fields.append(Field("error", error)) }
        return .preflight("api-stt", .fail, fields)
    }
}
