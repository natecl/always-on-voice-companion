import Diagnostics
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AuthProbeResult: Sendable, Equatable {
    public var http: Int?
    public var body: String

    public init(http: Int?, body: String) {
        self.http = http
        self.body = body
    }
}

/// HTTPS GET used only after a handshake fails. The WebSocket upgrade hides the
/// 401/403 body; this recovers it. `/v1/api-key` is tried first and `/v1/models`
/// is the fallback when that path is missing.
public enum GrokProbe {
    public static func fetchAuthStatus(apiKey: String, timeout: TimeInterval = 3) async -> AuthProbeResult {
        let primary = await fetch(path: "/v1/api-key", apiKey: apiKey, timeout: timeout)
        if primary.http == 404 {
            return await fetch(path: "/v1/models", apiKey: apiKey, timeout: timeout)
        }
        return primary
    }

    private static func fetch(path: String, apiKey: String, timeout: TimeInterval) async -> AuthProbeResult {
        guard let url = URL(string: "https://api.x.ai\(path)") else {
            return AuthProbeResult(http: nil, body: "bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode
            let body = truncate(String(data: data, encoding: .utf8) ?? "")
            return AuthProbeResult(http: http, body: body)
        } catch {
            return AuthProbeResult(http: nil, body: ErrorDetail.sentence(error))
        }
    }

    private static func truncate(_ text: String) -> String {
        let limit = 400
        guard text.utf8.count > limit else { return text }
        var count = 0
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let size = text[index].utf8.count
            if count + size > limit { break }
            count += size
            end = next
            index = next
        }
        let omitted = text.utf8.count - count
        return String(text[..<end]) + "…(+\(omitted) bytes)"
    }
}
