import Diagnostics
import Foundation

protocol ByteSink: AnyObject {
    func write(_ data: Data) throws
    func synchronize() throws
}

final class FileByteSink: ByteSink {
    private let handle: FileHandle

    init(url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw StoreError.createFailed(url.path)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func synchronize() throws {
        try handle.synchronize()
    }

    deinit {
        do {
            try handle.close()
        } catch {
            StageMirror.note("jsonl close \(ErrorDetail.sentence(error))")
        }
    }
}

/// Append-only JSONL. `fsync` after every final segment and every annotation.
public final class JSONLWriter {
    private let sink: ByteSink
    private let encoder = JSONEncoder()
    public private(set) var fsyncCount = 0

    init(sink: ByteSink) {
        self.sink = sink
    }

    public convenience init(url: URL) throws {
        try self.init(sink: FileByteSink(url: url))
    }

    public func append(_ row: SessionRow, fsync: Bool) throws {
        var data = try encoder.encode(row)
        data.append(0x0A)
        do {
            try sink.write(data)
            if fsync {
                try sink.synchronize()
                fsyncCount += 1
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(String(describing: error))
        }
    }

    public static func replace(url: URL, rows: [SessionRow]) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for row in rows {
            var line = try encoder.encode(row)
            line.append(0x0A)
            data.append(line)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(String(describing: error))
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}

public enum JSONLReader {
    public struct Contents: Sendable, Equatable {
        public var rows: [SessionRow]
        public var droppedTruncatedTail: Bool
    }

    public static func read(url: URL) throws -> Contents {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.corrupt(line: 1)
        }
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = rawLines
        if lines.last == "" {
            lines.removeLast()
        }
        lines.removeAll { $0.isEmpty }
        var rows: [SessionRow] = []
        var dropped = false
        for (index, line) in lines.enumerated() {
            do {
                rows.append(try JSONDecoder().decode(SessionRow.self, from: Data(line.utf8)))
            } catch {
                let isLast = index == lines.count - 1
                if isLast {
                    dropped = true
                    break
                }
                throw StoreError.corrupt(line: index + 1)
            }
        }
        return Contents(rows: rows, droppedTruncatedTail: dropped)
    }
}
