/// Optional snapshot. Engines that do not conform stay usable; the pipeline casts.
public struct EngineDiagnosticsSnapshot: Sendable, Equatable {
    public var bytesSent: Int
    public var pendingCount: Int
    public var handshakeMs: Int?
    public var lastCloseCode: Int?
    public var lastCloseReason: String?
    public var lastError: String?
    public var httpStatus: Int?
    public var httpBody: String?
    public var unknownMessages: [String]
    public var sendErrors: Int
    public var binaryFrames: Int
    /// Audio queued for the socket that last resumed (replay plus outage), in
    /// ms. Its first finals describe this backlog, not live speech. 0 on the
    /// first connect.
    public var lastResumeBacklogMs: Int

    public init(
        bytesSent: Int = 0,
        pendingCount: Int = 0,
        handshakeMs: Int? = nil,
        lastCloseCode: Int? = nil,
        lastCloseReason: String? = nil,
        lastError: String? = nil,
        httpStatus: Int? = nil,
        httpBody: String? = nil,
        unknownMessages: [String] = [],
        sendErrors: Int = 0,
        binaryFrames: Int = 0,
        lastResumeBacklogMs: Int = 0
    ) {
        self.bytesSent = bytesSent
        self.pendingCount = pendingCount
        self.handshakeMs = handshakeMs
        self.lastCloseCode = lastCloseCode
        self.lastCloseReason = lastCloseReason
        self.lastError = lastError
        self.httpStatus = httpStatus
        self.httpBody = httpBody
        self.unknownMessages = unknownMessages
        self.sendErrors = sendErrors
        self.binaryFrames = binaryFrames
        self.lastResumeBacklogMs = lastResumeBacklogMs
    }
}

public protocol EngineDiagnostics: Sendable {
    func snapshot() async -> EngineDiagnosticsSnapshot
}
