import Foundation

/// One description for every catch site. Call sites do not format `NSError` themselves.
public enum ErrorDetail {
    public static func describe(_ error: Error) -> [String: String] {
        let ns = error as NSError
        var result: [String: String] = [
            "domain": ns.domain,
            "code": String(ns.code),
            "localizedDescription": ns.localizedDescription,
        ]
        if let status = osStatus(of: ns) {
            result["osstatus"] = formatStatus(status)
        }
        var chain: [String] = []
        var current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let next = current, depth < 6 {
            var piece = "\(next.domain) \(next.code) \(next.localizedDescription)"
            if let status = osStatus(of: next) {
                let formatted = formatStatus(status)
                piece += " osstatus=\(formatted)"
                if result["osstatus"] == nil {
                    result["osstatus"] = formatted
                }
            }
            chain.append(piece)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if !chain.isEmpty {
            result["underlying"] = chain.joined(separator: " | ")
        }
        return result
    }

    /// Domain, code, OSStatus, description, and the underlying chain, in that order.
    public static func sentence(_ fields: [String: String]) -> String {
        var parts: [String] = []
        if let domain = fields["domain"], !domain.isEmpty { parts.append(domain) }
        if let code = fields["code"], !code.isEmpty { parts.append(code) }
        if let status = fields["osstatus"], !status.isEmpty { parts.append("osstatus=\(status)") }
        if let description = fields["localizedDescription"], !description.isEmpty {
            parts.append(description)
        }
        if let underlying = fields["underlying"], !underlying.isEmpty {
            parts.append("underlying=\(underlying)")
        }
        return parts.joined(separator: " ")
    }

    public static func sentence(_ error: Error) -> String {
        sentence(describe(error))
    }

    /// FourCC when the four bytes are printable ASCII, otherwise the decimal code.
    public static func formatStatus(_ status: Int32) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        if printable, let text = String(bytes: bytes, encoding: .ascii), text.count == 4 {
            return "\(status) '\(text)'"
        }
        return String(status)
    }

    private static func osStatus(of error: NSError) -> Int32? {
        if error.domain == NSOSStatusErrorDomain {
            return Int32(truncatingIfNeeded: error.code)
        }
        return nil
    }
}
