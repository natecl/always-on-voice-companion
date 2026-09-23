import Foundation

/// Capture counters the pipeline copies off `CaptureDiagnostics`. Diagnostics
/// does not import AudioCapture.
public struct CaptureCounterSnapshot: Sendable, Equatable {
    public var system: Int
    public var microphone: Int
    public var invalid: Int
    public var empty: Int
    public var extractFailed: Int
    public var firstOSStatus: Int32
    public var firstFailureDetail: String
    public var displayID: UInt32
    public var microphoneGain: Float?
    public var microphoneGainPeak: Float?

    public init(
        system: Int = 0,
        microphone: Int = 0,
        invalid: Int = 0,
        empty: Int = 0,
        extractFailed: Int = 0,
        firstOSStatus: Int32 = 0,
        firstFailureDetail: String = "",
        displayID: UInt32 = 0,
        microphoneGain: Float? = nil,
        microphoneGainPeak: Float? = nil
    ) {
        self.system = system
        self.microphone = microphone
        self.invalid = invalid
        self.empty = empty
        self.extractFailed = extractFailed
        self.firstOSStatus = firstOSStatus
        self.firstFailureDetail = firstFailureDetail
        self.displayID = displayID
        self.microphoneGain = microphoneGain
        self.microphoneGainPeak = microphoneGainPeak
    }

    public static let empty = CaptureCounterSnapshot()
}

public struct StreamSnapshot: Sendable, Equatable {
    public var systemBytes: Int
    public var microphoneBytes: Int
    public var pending: Int
    public var sendErrors: Int
    public var firstSendError: String
    /// When false, the ledger's own send counts are used.
    public var fromEngine: Bool

    public init(
        systemBytes: Int = 0,
        microphoneBytes: Int = 0,
        pending: Int = 0,
        sendErrors: Int = 0,
        firstSendError: String = "",
        fromEngine: Bool = false
    ) {
        self.systemBytes = systemBytes
        self.microphoneBytes = microphoneBytes
        self.pending = pending
        self.sendErrors = sendErrors
        self.firstSendError = firstSendError
        self.fromEngine = fromEngine
    }
}

/// Per-track counters. Hooks bump these; the checkpoint and close paths render lines.
public actor StageLedger {
    private var pcmSystem = 0
    private var pcmMicrophone = 0
    private var sawFrame: Set<String> = []
    private var sawEnergy: Set<String> = []
    private var sentBytes: [String: Int] = [:]
    private var sendErrors = 0
    private var firstSendError = ""
    private var finals: [String: Int] = [:]
    private var partials = 0
    private var blankDropped = 0
    private var restated = 0
    private var apiErrors = 0
    private var firstAPIError = ""
    private var pcmFileError = ""

    public init() {}

    public func reset() {
        pcmSystem = 0
        pcmMicrophone = 0
        sawFrame = []
        sawEnergy = []
        sentBytes = [:]
        sendErrors = 0
        firstSendError = ""
        finals = [:]
        partials = 0
        blankDropped = 0
        restated = 0
        apiErrors = 0
        firstAPIError = ""
        pcmFileError = ""
    }

    public func frameExtracted(track: String, energy: Bool) {
        if track == "system" {
            pcmSystem += 1
        } else if track == "microphone" {
            pcmMicrophone += 1
        }
        sawFrame.insert(track)
        if energy { sawEnergy.insert(track) }
    }

    public func noteSent(track: String, bytes: Int) {
        sentBytes[track, default: 0] += bytes
    }

    public func noteSendError(_ text: String) {
        sendErrors += 1
        if firstSendError.isEmpty { firstSendError = text }
    }

    public func notePartial() { partials += 1 }

    public func noteStoredFinal(track: String) {
        finals[track, default: 0] += 1
    }

    public func noteBlankDropped() { blankDropped += 1 }

    public func noteRestated() { restated += 1 }

    public func noteAPIError(_ text: String) {
        apiErrors += 1
        if firstAPIError.isEmpty { firstAPIError = text }
    }

    public func notePCMError(_ text: String) {
        if pcmFileError.isEmpty { pcmFileError = text }
    }

    public func storedFinals() -> Int {
        finals.values.reduce(0, +)
    }

    public func extractedCounts() -> (system: Int, microphone: Int) {
        (pcmSystem, pcmMicrophone)
    }

    public func countLines(capture: CaptureCounterSnapshot, stream: StreamSnapshot) -> [StageLine] {
        let framesOK = capture.system >= 1 && capture.microphone >= 1
        let frames = StageLine.stage(.framesReceived, framesOK ? .ok : .fail, [
            Field("system", String(capture.system)),
            Field("microphone", String(capture.microphone)),
            Field("invalid", String(capture.invalid)),
            Field("empty", String(capture.empty)),
        ])

        let failed = capture.extractFailed
        let zero = zeroEnergyValue()
        var pcmFields = [
            Field("system", String(pcmSystem)),
            Field("microphone", String(pcmMicrophone)),
            Field("failed", String(failed)),
            Field("osstatus", String(capture.firstOSStatus)),
            Field("zeroEnergy", zero),
        ]
        if let gain = capture.microphoneGain, let peak = capture.microphoneGainPeak {
            pcmFields.append(Field("micGain", String(format: "%.2f", Double(gain))))
            pcmFields.append(Field("micGainMax", String(format: "%.2f", Double(peak))))
        }
        if !capture.firstFailureDetail.isEmpty {
            pcmFields.append(Field("error", capture.firstFailureDetail))
        }
        if !pcmFileError.isEmpty {
            pcmFields.append(Field("pcmError", pcmFileError))
        }
        // zeroEnergy is informational. OK is one extracted frame on each track.
        let pcmOK = pcmSystem >= 1 && pcmMicrophone >= 1
        let pcm = StageLine.stage(.pcmExtract, pcmOK ? .ok : .fail, pcmFields)

        let systemBytes = stream.fromEngine ? stream.systemBytes : (sentBytes["system"] ?? 0)
        let microphoneBytes = stream.fromEngine ? stream.microphoneBytes : (sentBytes["microphone"] ?? 0)
        let errors = stream.fromEngine ? stream.sendErrors : sendErrors
        let sendError = stream.fromEngine ? stream.firstSendError : firstSendError
        var streamFields = [
            Field("system", String(systemBytes)),
            Field("microphone", String(microphoneBytes)),
            Field("pending", String(stream.pending)),
            Field("sendErrors", String(errors)),
        ]
        let streamOK = systemBytes > 0 && microphoneBytes > 0
        if !streamOK, !sendError.isEmpty {
            streamFields.append(Field("error", sendError))
        }
        let streamed = StageLine.stage(.apiStream, streamOK ? .ok : .fail, streamFields)

        let systemFinals = finals["system"] ?? 0
        let microphoneFinals = finals["microphone"] ?? 0
        var segmentFields = [
            Field("system", String(systemFinals)),
            Field("microphone", String(microphoneFinals)),
            Field("partials", String(partials)),
            Field("blankDropped", String(blankDropped)),
            Field("restated", String(restated)),
            Field("apiErrors", String(apiErrors)),
        ]
        let segmentsOK = systemFinals + microphoneFinals >= 1
        if !segmentsOK, apiErrors > 0, !firstAPIError.isEmpty {
            segmentFields.append(Field("error", firstAPIError))
        }
        let segments = StageLine.stage(.segmentsReceived, segmentsOK ? .ok : .fail, segmentFields)
        return [frames, pcm, streamed, segments]
    }

    public func transcriptLine(bytes: Int, segments: Int, recovered: Bool, error: String?) -> StageLine {
        var fields = [
            Field("bytes", String(bytes)),
            Field("segments", String(segments)),
            Field("recovered", recovered ? "true" : "false"),
        ]
        if let error, !error.isEmpty {
            fields.append(Field("error", error))
            return StageLine.stage(.transcriptWrite, .fail, fields)
        }
        let ok = bytes > 0
        return StageLine.stage(.transcriptWrite, ok ? .ok : .fail, fields)
    }

    public nonisolated static func hasEnergy(_ data: Data) -> Bool {
        let count = data.count / 2
        guard count > 0 else { return false }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples where sample != 0 {
                return true
            }
            return false
        }
    }

    private func zeroEnergyValue() -> String {
        let tracks = ["system", "microphone"].filter { sawFrame.contains($0) && !sawEnergy.contains($0) }
        return tracks.isEmpty ? "none" : tracks.joined(separator: ",")
    }
}

public enum StageBuilders {
    public static func tcc(
        probeGranted: Bool,
        blockReason: String?,
        micStatus: String,
        owns: Bool,
        entitlement: Bool?,
        responsible: String
    ) -> StageLine {
        let screen: String
        if probeGranted {
            screen = "granted"
        } else {
            let lower = (blockReason ?? "").lowercased()
            if lower.contains("screen") || lower.contains("startcapture") {
                screen = "denied"
            } else if blockReason == nil {
                screen = "unknown"
            } else {
                screen = "granted"
            }
        }
        let entitlementText: String
        switch entitlement {
        case .some(true): entitlementText = "true"
        case .some(false): entitlementText = "false"
        case .none: entitlementText = "unknown"
        }
        var fields = [
            Field("screen", screen),
            Field("mic", micStatus),
            Field("owns", owns ? "true" : "false"),
            Field("entitlement", entitlementText),
            Field("responsible", responsible.isEmpty ? "unknown" : responsible),
        ]
        if let blockReason, !probeGranted {
            fields.append(Field("error", blockReason))
        }
        return StageLine.stage(.tccCheck, probeGranted ? .ok : .fail, fields)
    }

    public static func captureStart(display: String, error: Error?) -> StageLine {
        var fields = [Field("display", display)]
        if let error {
            let detail = ErrorDetail.describe(error)
            if let domain = detail["domain"] { fields.append(Field("domain", domain)) }
            if let code = detail["code"] { fields.append(Field("code", code)) }
            fields.append(Field("error", ErrorDetail.sentence(detail)))
            return StageLine.stage(.captureStart, .fail, fields)
        }
        return StageLine.stage(.captureStart, .ok, fields)
    }

    public static func apiConnectOK(track: String, engine: String, milliseconds: Int) -> StageLine {
        StageLine.stage(.apiConnect, .ok, [
            Field("track", track),
            Field("engine", engine),
            Field("ms", String(milliseconds)),
        ])
    }

    public static func apiConnectFAIL(track: String, engine: String, fields extra: [Field]) -> StageLine {
        var fields = [Field("track", track), Field("engine", engine)]
        fields.append(contentsOf: extra)
        return StageLine.stage(.apiConnect, .fail, fields)
    }
}
