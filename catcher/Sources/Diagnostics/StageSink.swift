import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol StageSink: Sendable {
    func write(_ line: StageLine, fsync: Bool)
    func recorded() -> [StageLine]
}

/// stderr and `os_log` (`com.catcher.app` / `stage`). The stage file is separate.
public enum StageMirror {
    public static func emit(_ line: String) {
        #if canImport(OSLog)
        Logger(subsystem: "com.catcher.app", category: "stage").notice("\(line, privacy: .public)")
        #endif
        writeStandardError(line)
    }

    /// A catch that is not itself a STAGE line. Stays off `stages.log`.
    public static func note(_ text: String) {
        emit("note \(text)")
    }

    private static func writeStandardError(_ line: String) {
        var text = line
        if !text.hasSuffix("\n") { text.append("\n") }
        text.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }
}

/// Append-only session log. FAIL lines and checkpoints fsync; nothing is written per frame.
public final class FileStageSink: StageSink, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var lines: [StageLine] = []
    private var disabled = false

    public init(directory: URL, fileName: String) {
        self.url = directory.appendingPathComponent(fileName)
    }

    public func write(_ line: StageLine, fsync: Bool) {
        let text = line.formatted()
        var payload = Data(text.utf8)
        payload.append(0x0A)
        lock.lock()
        lines.append(line)
        let opened = openLocked()
        if let opened {
            do {
                try opened.write(contentsOf: payload)
                if fsync {
                    try opened.synchronize()
                }
            } catch {
                disabled = true
                lock.unlock()
                StageMirror.note("stages write \(ErrorDetail.sentence(error))")
                StageMirror.emit(text)
                return
            }
        }
        lock.unlock()
        StageMirror.emit(text)
    }

    public func recorded() -> [StageLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public var fileURL: URL { url }

    private func openLocked() -> FileHandle? {
        if disabled { return nil }
        if let handle { return handle }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "createFile failed \(url.path)",
                    ])
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            return handle
        } catch {
            disabled = true
            StageMirror.note("stages open \(ErrorDetail.sentence(error))")
            return nil
        }
    }
}

/// In-memory sink for tests.
public final class RecordingStageSink: StageSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [StageLine] = []
    public private(set) var fsyncCount = 0

    public init() {}

    public func write(_ line: StageLine, fsync: Bool) {
        lock.lock()
        lines.append(line)
        if fsync { fsyncCount += 1 }
        lock.unlock()
        StageMirror.emit(line.formatted())
    }

    public func recorded() -> [StageLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
