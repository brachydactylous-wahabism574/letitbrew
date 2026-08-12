import Foundation
import Testing
@testable import LetItBrewAppCore

/// Pins the exact domain/code pair empirically verified (see the fix report)
/// against a real macOS system for a mach service with no registered
/// launchd job: `NSCocoaErrorDomain` / `NSXPCConnectionInvalid` (4099). Only
/// this pair may count as affirmative absence.
@Test func nsCocoaErrorDomainConnectionInvalidIsAffirmativelyAbsent() {
    #expect(
        DaemonConnectionAbsenceClassifier.classify(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionInvalid
        ) == .affirmativelyAbsent
    )
}

/// Pins the literal 4099 value too, so a future accidental change to what
/// `NSXPCConnectionInvalid` resolves to (or a typo re-deriving it) cannot
/// silently widen or narrow what counts as absence without a failing test.
@Test func theAbsenceCodeIsExactly4099() {
    #expect(NSXPCConnectionInvalid == 4099)
    #expect(NSCocoaErrorDomain == "NSCocoaErrorDomain")
}

/// Empirically verified signature of a *registered* daemon that exists but
/// crashed, was killed, or rejected the connection during authentication: a
/// live peer was reached (the interruption handler fires first), and the
/// resulting error carries `NSXPCConnectionInterrupted` (4097) — proof a
/// service exists, not evidence of absence. This must block.
@Test func interruptedConnectionCode4097MustBlock() {
    #expect(
        DaemonConnectionAbsenceClassifier.classify(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionInterrupted
        ) == .mustBlock
    )
}

@Test func sameCodeInAnUnrelatedDomainMustBlock() {
    #expect(
        DaemonConnectionAbsenceClassifier.classify(
            domain: "SomeOtherErrorDomain",
            code: NSXPCConnectionInvalid
        ) == .mustBlock
    )
}

@Test func nsCocoaErrorDomainWithAnUnrecognizedCodeMustBlock() {
    #expect(
        DaemonConnectionAbsenceClassifier.classify(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionReplyInvalid
        ) == .mustBlock
    )
}

@Test func anEntirelyUnrelatedErrorMustBlock() {
    #expect(
        DaemonConnectionAbsenceClassifier.classify(
            domain: NSPOSIXErrorDomain,
            code: 1
        ) == .mustBlock
    )
}
