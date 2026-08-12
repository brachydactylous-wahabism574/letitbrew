import Testing
@testable import LetItBrewAppCore

@Test func replacingAConnectionClearsItsInFlightRequest() {
    var state = DaemonHoldRequestState()
    let oldRequest = state.beginRequest()

    #expect(oldRequest != nil)
    #expect(state.isInFlight)

    state.replaceConnection()

    #expect(!state.isInFlight)
    let replacementRequest = state.beginRequest()
    #expect(replacementRequest != nil)
}

@Test func lateCompletionFromReplacedConnectionCannotClearNewRequest() {
    var state = DaemonHoldRequestState()
    let oldRequest = state.beginRequest()!
    state.replaceConnection()
    let newRequest = state.beginRequest()!

    let acceptedOldCompletion = state.complete(oldRequest)
    #expect(!acceptedOldCompletion)
    #expect(state.isInFlight)
    let acceptedNewCompletion = state.complete(newRequest)
    #expect(acceptedNewCompletion)
    #expect(!state.isInFlight)
}

@Test func onlyOneRequestMayBeInFlightForAConnection() {
    var state = DaemonHoldRequestState()
    let request = state.beginRequest()!

    let overlappingRequest = state.beginRequest()
    #expect(overlappingRequest == nil)
    let acceptedCompletion = state.complete(request)
    #expect(acceptedCompletion)
    let followingRequest = state.beginRequest()
    #expect(followingRequest != nil)
}
