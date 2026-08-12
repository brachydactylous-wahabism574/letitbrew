import Testing
@testable import LetItBrewAppCore

@Test(arguments: [
    AgentConnectionState.actionNeeded,
    AgentConnectionState.couldNotConnect,
])
func managedCodexAttentionStatesRefreshAutomatically(state: AgentConnectionState) {
    #expect(CodexTrustAutoRefreshPolicy.shouldRefresh(
        state: state,
        disposition: .managed
    ))
}

@Test(arguments: [
    AgentConnectionState.connecting,
    AgentConnectionState.connected,
])
func settledManagedCodexStatesDoNotRefreshAutomatically(state: AgentConnectionState) {
    #expect(!CodexTrustAutoRefreshPolicy.shouldRefresh(
        state: state,
        disposition: .managed
    ))
}

@Test func nonManagedCodexConnectionsNeverRefreshAutomatically() {
    let states: [AgentConnectionState] = [
        .connecting, .connected, .actionNeeded, .couldNotConnect,
    ]
    let dispositions: [AgentConnectionDisposition] = [
        .intentionallyDisconnected, .disconnectFailed,
    ]
    for state in states {
        for disposition in dispositions {
            #expect(!CodexTrustAutoRefreshPolicy.shouldRefresh(
                state: state,
                disposition: disposition
            ))
        }
    }
}
