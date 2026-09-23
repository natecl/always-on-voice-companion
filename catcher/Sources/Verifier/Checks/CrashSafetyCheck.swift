/// After the engine emits a final, the fsync'd segment count must grow.
/// A stuck count means the transcript was "recorded" nowhere.
public struct CrashSafetyCheck: Sendable {
    public static let growLimitMs = 1_000

    public private(set) var flagged = false
    public private(set) var detail = ""
    private var pendingFinalAt: Int?
    private var countAtFinal = 0
    private var emitted = false

    public init() {}

    public mutating func reset() {
        flagged = false
        detail = ""
        pendingFinalAt = nil
        countAtFinal = 0
        emitted = false
    }

    public mutating func observeEngineFinal(atMs: Int, storedCount: Int) {
        pendingFinalAt = atMs
        countAtFinal = storedCount
        emitted = false
    }

    public mutating func observeStored(count: Int) {
        if count > countAtFinal {
            pendingFinalAt = nil
            flagged = false
            detail = ""
            emitted = false
        }
    }

    public mutating func tick(atMs: Int) -> Annotation? {
        guard let pendingFinalAt, atMs - pendingFinalAt >= Self.growLimitMs else { return nil }
        flagged = true
        detail = "fsync segment count \(countAtFinal) did not grow after a final"
        guard !emitted else { return nil }
        emitted = true
        return Annotation(atMs: pendingFinalAt + Self.growLimitMs, kind: "degraded", detail: .text(detail))
    }
}
