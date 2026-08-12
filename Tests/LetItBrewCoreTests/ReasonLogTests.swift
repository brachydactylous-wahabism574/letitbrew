import Testing
import Foundation
@testable import LetItBrewCore

/// `ReasonLog.shouldLog` throttles the idle-grace countdown ("all idle,
/// releasing in 214s" ticking down every second) to at most once per 30s,
/// while any genuine transition of the decision reason still logs
/// immediately, and the very first reason always logs.

@Test func firstReasonAlwaysLogs() {
    let now = Date()
    #expect(ReasonLog.shouldLog(reason: "2 working", lastLogged: nil,
                                lastLoggedAt: .distantPast, now: now))
}

@Test func identicalReasonNeverLogsAgain() {
    let now = Date()
    #expect(!ReasonLog.shouldLog(reason: "2 working", lastLogged: "2 working",
                                 lastLoggedAt: now, now: now))
}

@Test func countdownTickWithinThrottleWindowIsSuppressed() {
    let start = Date()
    #expect(!ReasonLog.shouldLog(
        reason: "all idle, releasing in 213s",
        lastLogged: "all idle, releasing in 214s",
        lastLoggedAt: start, now: start.addingTimeInterval(1)))
}

@Test func countdownTickPastThrottleWindowLogsAgain() {
    let start = Date()
    #expect(ReasonLog.shouldLog(
        reason: "all idle, releasing in 184s",
        lastLogged: "all idle, releasing in 214s",
        lastLoggedAt: start, now: start.addingTimeInterval(30)))
}

@Test func enteringTheCountdownLogsImmediately() {
    // Transition INTO the idle grace: shape changes from "2 working" to the
    // countdown shape, so it must not wait for the throttle window even
    // though `lastLoggedAt` is recent.
    let now = Date()
    #expect(ReasonLog.shouldLog(
        reason: "all idle, releasing in 300s", lastLogged: "2 working",
        lastLoggedAt: now, now: now))
}

@Test func leavingTheCountdownLogsImmediately() {
    // The final transition out of the countdown must always print promptly,
    // not wait for the next throttle window.
    let now = Date()
    #expect(ReasonLog.shouldLog(
        reason: "all agents idle", lastLogged: "all idle, releasing in 1s",
        lastLoggedAt: now, now: now.addingTimeInterval(1)))
}

@Test func sessionCountChangeLogsImmediatelyEvenThoughItIsANumber() {
    // Only the countdown is throttled — a change in working/waiting counts
    // is a genuine transition and must not wait for the throttle window.
    let now = Date()
    #expect(ReasonLog.shouldLog(reason: "3 working", lastLogged: "2 working",
                                lastLoggedAt: now, now: now))
}

@Test func shapeBlanksOnlyTheCountdownNumber() {
    #expect(ReasonLog.shape("all idle, releasing in 214s")
            == ReasonLog.shape("all idle, releasing in 1s"))
    #expect(ReasonLog.shape("2 working") == "2 working")
    #expect(ReasonLog.shape("battery 19%") == "battery 19%")
}
