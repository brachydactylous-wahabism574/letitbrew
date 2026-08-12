/// Identifies one hold request on one daemon connection generation.
public struct DaemonHoldRequestToken: Equatable, Sendable {
    fileprivate let connectionGeneration: UInt64
    fileprivate let requestID: UInt64
}

/// Tracks the single allowed in-flight hold request without letting a late
/// completion from a replaced XPC connection disturb its replacement.
public struct DaemonHoldRequestState: Sendable {
    private var connectionGeneration: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var currentRequest: DaemonHoldRequestToken?

    public init() {}

    public var isInFlight: Bool {
        currentRequest != nil
    }

    /// Invalidates the old connection's request and permits the replacement
    /// to send immediately. Any late old completion retains its old token and
    /// is therefore ignored by `complete(_:)`.
    public mutating func replaceConnection() {
        connectionGeneration &+= 1
        currentRequest = nil
    }

    /// Starts a request only when the current connection has none in flight.
    public mutating func beginRequest() -> DaemonHoldRequestToken? {
        guard currentRequest == nil else { return nil }
        nextRequestID &+= 1
        let token = DaemonHoldRequestToken(
            connectionGeneration: connectionGeneration,
            requestID: nextRequestID
        )
        currentRequest = token
        return token
    }

    /// Completes only the currently tracked request. A stale token cannot
    /// clear a newer connection's in-flight latch.
    @discardableResult
    public mutating func complete(_ token: DaemonHoldRequestToken) -> Bool {
        guard currentRequest == token else { return false }
        currentRequest = nil
        return true
    }
}
