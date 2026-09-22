public enum VerifierDetail: Sendable, Equatable {
    case text(String)
    case gap(fromMs: Int, toMs: Int, track: String)
}

public struct Annotation: Sendable, Equatable {
    public var atMs: Int
    public var kind: String
    public var detail: VerifierDetail?

    public init(atMs: Int, kind: String, detail: VerifierDetail? = nil) {
        self.atMs = atMs
        self.kind = kind
        self.detail = detail
    }
}
