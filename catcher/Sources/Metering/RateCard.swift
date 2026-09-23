public enum BillingModel: String, Sendable, Equatable, Codable {
    case audio
    case socket
    case uncalibrated
}

public struct ComponentRate: Sendable, Equatable {
    public var usdPerHour: Double
    public var unit: String

    public init(usdPerHour: Double, unit: String) {
        self.usdPerHour = usdPerHour
        self.unit = unit
    }
}

/// Vendor prices. `catcher/harness/rates.json` is the file; a test fails if
/// `bundled` drifts from it. An uncalibrated card never satisfies B1.
public struct RateCard: Sendable, Equatable {
    public var id: String
    public var billingModel: BillingModel
    public var components: [String: ComponentRate]
    public var calibrationStatus: String

    public init(
        id: String,
        billingModel: BillingModel,
        components: [String: ComponentRate],
        calibrationStatus: String
    ) {
        self.id = id
        self.billingModel = billingModel
        self.components = components
        self.calibrationStatus = calibrationStatus
    }

    public static let bundled = RateCard(
        id: "xai-stt-2026-09-18",
        billingModel: .uncalibrated,
        components: [
            MeterComponent.stream: ComponentRate(usdPerHour: 0.20, unit: "audioMs"),
            MeterComponent.stub: ComponentRate(usdPerHour: 0, unit: "audioMs"),
        ],
        calibrationStatus: "pending"
    )

    /// True only after the xAI console reconciles the card. Pending stays false,
    /// so an uncalibrated session cannot be reported as a B1 pass.
    public var isCalibrated: Bool {
        billingModel != .uncalibrated && calibrationStatus == "reconciled"
    }

    public func contains(_ component: String) -> Bool {
        components[component] != nil
    }

    public func usd(component: String, milliseconds: Int) -> Double? {
        guard let rate = components[component] else { return nil }
        return rate.usdPerHour * Double(milliseconds) / Double(MeteringConstants.millisecondsPerHour)
    }

    /// Billable milliseconds for one slice. Uncalibrated is the pessimistic max
    /// of audio-sent and socket-open, which is what the readout shows until
    /// calibration says which unit xAI actually charges.
    public func billableMs(audioMs: Int, socketOpenMs: Int) -> Int {
        switch billingModel {
        case .audio:
            return audioMs
        case .socket:
            return socketOpenMs
        case .uncalibrated:
            return max(audioMs, socketOpenMs)
        }
    }
}
