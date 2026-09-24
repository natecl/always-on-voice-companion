import Dispatch
import Foundation

/// Races a completion-handler call against a wall-clock deadline.
///
/// ScreenCaptureKit's bridged `try await startCapture()` can leak its
/// continuation when replayd stalls or errors during start, and the caller
/// then waits forever. `start` runs on its own queue, so a call that blocks
/// inside the framework cannot hold the caller either. The first of `finish`
/// or the deadline wins; the other is dropped.
public enum Deadline {
    public static func first<Value: Sendable>(
        seconds: Double,
        timedOut: Value,
        _ start: @escaping @Sendable (_ finish: @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        let once = OnceResume<Value>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                once.resume(timedOut)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                start { once.resume($0) }
            }
        }
    }
}

private final class OnceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
