import Foundation

public enum CostLogError: Error, Equatable, CustomStringConvertible {
    case createFailed(String)
    case readFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .createFailed(let path):
            "cost log create failed \(path)"
        case .readFailed(let detail):
            "cost log read failed \(detail)"
        case .writeFailed(let detail):
            "cost log write failed \(detail)"
        }
    }
}

public struct CostRead: Sendable, Equatable {
    public var rows: [CostRow]
    public var droppedTruncatedTail: Bool

    public init(rows: [CostRow], droppedTruncatedTail: Bool) {
        self.rows = rows
        self.droppedTruncatedTail = droppedTruncatedTail
    }

    public var hasRollup: Bool {
        rows.contains { if case .rollup = $0 { return true }; return false }
    }
}

/// Append-only `cost.jsonl` in a session directory. A meter write failure is
/// the caller's to log; it must not fail the recording.
public final class CostLog: @unchecked Sendable {
    public static let fileName = "cost.jsonl"

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    private let lock = NSLock()
    private let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    public init(directory: URL) throws {
        let url = Self.fileURL(in: directory)
        self.url = url
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw CostLogError.createFailed(url.path)
            }
        }
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw CostLogError.createFailed(String(describing: error))
        }
    }

    deinit {
        try? handle.close()
    }

    public func append(_ rows: [CostRow], fsync: Bool) throws {
        guard !rows.isEmpty else { return }
        var data = Data()
        for row in rows {
            var line = try encoder.encode(row)
            line.append(0x0A)
            data.append(line)
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: data)
            if fsync {
                try handle.synchronize()
            }
        } catch {
            throw CostLogError.writeFailed(String(describing: error))
        }
    }

    /// Sessions whose `cost.jsonl` has minute rows and no rollup (a `kill -9`).
    /// Drops a truncated last line and appends a rollup with `recovered: true`.
    /// A recovered rollup is not a B1 pass. Returns how many files were closed.
    public static func recoverAll(
        root: URL,
        rateCard: RateCard = .bundled,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CostLogError.readFailed(String(describing: error))
        }
        var repaired = 0
        for directory in children {
            let isDirectory: Bool
            do {
                isDirectory = try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                continue
            }
            guard isDirectory else { continue }
            let url = fileURL(in: directory)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let contents: CostRead
            do {
                contents = try read(url: url)
            } catch {
                throw CostLogError.readFailed(String(describing: error))
            }
            if contents.hasRollup { continue }
            let minutes = contents.rows.compactMap { row -> CostMinuteRow? in
                if case .minute(let minute) = row { return minute }
                return nil
            }
            let session = contents.rows.compactMap { row -> CostSessionRow? in
                if case .session(let session) = row { return session }
                return nil
            }.first
            var card = rateCard
            if let model = session.flatMap({ BillingModel(rawValue: $0.billingModel) }) {
                card.billingModel = model
            }
            let component = minutes.first?.component ?? MeterComponent.stream
            let wallMs = minutes.map(\.toMs).max() ?? 0
            let rollup = CostPricing.rollup(
                minutes: minutes,
                sttComponent: component,
                wallMs: wallMs,
                clean: false,
                recovered: true,
                rateCard: card
            )
            let kept = contents.rows
            var data = Data()
            let encoder = JSONEncoder()
            for row in kept {
                var line = try encoder.encode(row)
                line.append(0x0A)
                data.append(line)
            }
            var rollupLine = try encoder.encode(CostRow.rollup(rollup))
            rollupLine.append(0x0A)
            data.append(rollupLine)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw CostLogError.writeFailed(String(describing: error))
            }
            repaired += 1
        }
        return repaired
    }

    /// Reads a cost log. A file that does not end in a newline loses its last
    /// line, which is the crash cut. A last line that does not parse is dropped
    /// the same way. An earlier bad line throws.
    public static func read(url: URL) throws -> CostRead {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CostLogError.readFailed(String(describing: error))
        }
        if data.isEmpty {
            return CostRead(rows: [], droppedTruncatedTail: false)
        }
        var dropped = false
        var payload = data
        if payload.last != 0x0A {
            dropped = true
            if let newline = payload.lastIndex(of: 0x0A) {
                payload = Data(payload[...newline])
            } else {
                payload = Data()
            }
        }
        let text = String(decoding: payload, as: UTF8.self)
        let decoder = JSONDecoder()
        var rows: [CostRow] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            do {
                rows.append(try decoder.decode(CostRow.self, from: Data(line.utf8)))
            } catch {
                let last = index == lines.count - 1 || lines[(index + 1)...].allSatisfy(\.isEmpty)
                if last {
                    dropped = true
                    continue
                }
                throw CostLogError.readFailed("line \(index + 1) \(error)")
            }
        }
        return CostRead(rows: rows, droppedTruncatedTail: dropped)
    }
}
