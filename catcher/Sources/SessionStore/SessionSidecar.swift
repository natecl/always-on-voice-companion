import Diagnostics
import Foundation

/// Append-only JSONL beside `events.jsonl`. A write failure is logged once and
/// the sidecar goes quiet. It never throws, so a telemetry file cannot fail a
/// session. Phase 2 reuses this for `meter.jsonl`.
public final class SessionSidecar: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var pending: [Data] = []
    private var disabled = false
    private var noted = false

    public init(url: URL) {
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    fail("createFile failed \(url.path)")
                    return
                }
            }
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
        } catch {
            fail(ErrorDetail.sentence(error))
        }
    }

    public var failed: Bool {
        lock.lock()
        let value = disabled
        lock.unlock()
        return value
    }

    /// `flush` writes this line and anything still buffered, then fsyncs.
    /// Marks use that. Transcript rows may buffer until the next flush.
    public func write(_ line: Data, flush: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, let handle else { return }
        var bytes = line
        if bytes.last != 0x0A {
            bytes.append(0x0A)
        }
        pending.append(bytes)
        let shouldFlush = flush || pending.count >= 20
        guard shouldFlush else { return }
        drain(handle)
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !disabled, let handle else { return }
        drain(handle)
    }

    private func drain(_ handle: FileHandle) {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        do {
            for line in batch {
                try handle.write(contentsOf: line)
            }
            try handle.synchronize()
        } catch {
            fail(ErrorDetail.sentence(error))
        }
    }

    private func fail(_ text: String) {
        disabled = true
        pending.removeAll()
        try? handle?.close()
        handle = nil
        guard !noted else { return }
        noted = true
        StageMirror.note("latency sidecar \(text)")
    }
}
