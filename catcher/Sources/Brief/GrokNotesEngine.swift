import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NotesHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol NotesHTTPTransport: Sendable {
    func post(url: URL, body: Data, authorization: String, timeout: Duration) async throws -> NotesHTTPResponse
}

public struct URLSessionNotesTransport: NotesHTTPTransport {
    public init() {}

    public func post(url: URL, body: Data, authorization: String, timeout: Duration) async throws -> NotesHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.seconds(timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return NotesHTTPResponse(status: status, body: data)
        } catch let error as NotesEngineError {
            throw error
        } catch is CancellationError {
            throw NotesEngineError.timedOut
        } catch {
            throw NotesEngineError.transport(Self.clip(String(describing: error)))
        }
    }

    private static func seconds(_ timeout: Duration) -> TimeInterval {
        let parts = timeout.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func clip(_ text: String) -> String {
        GrokNotesRequest.clip(text)
    }
}

public struct GrokNotesEngine: NotesEngine, Sendable {
    public let label: BriefEngineInfo
    private let apiKey: String
    private let transport: any NotesHTTPTransport
    private let url: URL

    public init(
        model: String,
        apiKey: String,
        transport: any NotesHTTPTransport = URLSessionNotesTransport(),
        url: URL = URL(string: NotesService.completionsURL)!
    ) {
        label = BriefEngineInfo(name: "grok-notes", model: model)
        self.apiKey = apiKey
        self.transport = transport
        self.url = url
    }

    public func write(_ input: BriefInput, timeout: Duration) async throws -> NotesDraft {
        if apiKey.isEmpty {
            throw NotesEngineError.missingAPIKey
        }
        if input.segments.isEmpty {
            throw NotesEngineError.emptyInput
        }
        let body = try GrokNotesRequest.body(model: label.model, input: input)
        let response: NotesHTTPResponse
        do {
            response = try await transport.post(url: url, body: body, authorization: apiKey, timeout: timeout)
        } catch let error as NotesEngineError {
            throw error
        } catch is CancellationError {
            throw NotesEngineError.timedOut
        } catch {
            throw NotesEngineError.transport(GrokNotesRequest.clip(String(describing: error)))
        }
        if !(200...299).contains(response.status) {
            throw NotesEngineError.http(response.status, GrokNotesRequest.clip(String(decoding: response.body, as: UTF8.self)))
        }
        return try GrokNotesRequest.draft(from: response.body, requestedModel: label.model)
    }
}

enum GrokNotesRequest {
    static func body(model: String, input: BriefInput) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "temperature": NotesService.temperature,
            "max_tokens": NotesService.outputTokenCap,
            "stream": false,
            "messages": [
                ["role": "system", "content": BriefPrompt.system],
                ["role": "user", "content": BriefPrompt.userText(input)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": BriefPrompt.schemaName,
                    "strict": true,
                    "schema": BriefPrompt.schema(),
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw NotesEngineError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func draft(from body: Data, requestedModel: String) throws -> NotesDraft {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw NotesEngineError.invalidJSON
        }
        guard let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw NotesEngineError.invalidJSON
        }
        let draft: NotesDraft
        do {
            draft = try JSONDecoder().decode(NotesDraft.self, from: contentData)
        } catch {
            throw NotesEngineError.invalidJSON
        }
        let usage = usage(from: root["usage"] as? [String: Any])
        let returned = root["model"] as? String
        return NotesDraft(title: draft.title, blocks: draft.blocks, usage: usage, model: returned ?? requestedModel)
    }

    static func usage(from object: [String: Any]?) -> BriefUsage {
        BriefUsage(
            inputTokens: object?["prompt_tokens"] as? Int ?? 0,
            outputTokens: object?["completion_tokens"] as? Int ?? 0
        )
    }

    static func clip(_ text: String) -> String {
        let limit = 180
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }
}
