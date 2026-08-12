public enum CodexTrustAutoRefreshPolicy {
    public static func shouldRefresh(
        state: AgentConnectionState,
        disposition: AgentConnectionDisposition
    ) -> Bool {
        guard disposition == .managed else { return false }
        return state == .actionNeeded || state == .couldNotConnect
    }
}
