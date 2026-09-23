/// Versioned meter bar. `catcher/harness/metering.json` is the file; a test fails
/// if these constants drift from it. Prices live on `RateCard`.
public enum MeteringConstants {
    /// B1 ceiling for the whole session, transcription plus later components.
    public static let b1UsdPerSessionHr = 0.25
    /// Cap-call locked 2026-09-23: streaming STT stays inside this, on the same bar.
    public static let sttBudgetUsdPerSessionHr = 0.20
    /// What the bar leaves for Phase 3. `stt` + this equals `b1`.
    public static let phase3ReserveUsdPerSessionHr = 0.05
    public static let b1MinSessionMs = 3_600_000
    public static let b1MinSystemSpeechDuty = 0.40
    public static let serverUnderMeterTolerance = 0.02
    public static let reconcileTolerance = 0.05
    public static let shadowRmsFloor: Float = 0.02
    public static let shadowHoldMs = 120
    public static let shadowPreRollMs = 300
    public static let shadowHangoverMs = 1_000
    /// 16 kHz mono PCM16. One millisecond on the wire is 32 bytes.
    public static let bytesPerMillisecond = 32
    public static let millisecondsPerHour = 3_600_000

    public static func perSessionHour(usd: Double, wallMs: Int) -> Double {
        guard wallMs > 0 else { return 0 }
        return usd * Double(millisecondsPerHour) / Double(wallMs)
    }
}
