import Testing
@testable import LetItBrewCore

@Test func takesTheHoldWhenWantedAndNobodyHasIt() {
    #expect(LidHold.next(desired: true, systemDisabled: false, weOwn: false) == .take)
}

@Test func leavesSomeoneElsesHoldAlone() {
    // It is already doing the job we want done, and we cannot tell a hold the
    // user set by hand from one another app set.
    #expect(LidHold.next(desired: true, systemDisabled: true, weOwn: false) == .none)
}

@Test func doesNothingWhenWeAlreadyHoldIt() {
    #expect(LidHold.next(desired: true, systemDisabled: true, weOwn: true) == .none)
    #expect(LidHold.next(desired: true, systemDisabled: false, weOwn: true) == .none)
}

@Test func releasesOnlyWhatWeTook() {
    #expect(LidHold.next(desired: false, systemDisabled: true, weOwn: true) == .release)
    #expect(LidHold.next(desired: false, systemDisabled: false, weOwn: true) == .release)
}

@Test func neverClearsAHoldWeDidNotTake() {
    // A disablesleep the user set by hand must survive our session ending.
    #expect(LidHold.next(desired: false, systemDisabled: true, weOwn: false) == .none)
    #expect(LidHold.next(desired: false, systemDisabled: false, weOwn: false) == .none)
}
