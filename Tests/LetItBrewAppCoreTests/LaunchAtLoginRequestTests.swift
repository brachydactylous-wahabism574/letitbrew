import Foundation
import Testing
@testable import LetItBrewAppCore

private final class RecordingLoginItemRegistration: LaunchAtLoginRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [Bool] = []
    var failure: Error?

    func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        requests.append(enabled)
        if let failure { throw failure }
    }
}

private final class RecordingChoicePersistence: LaunchAtLoginChoicePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var choices: [Bool] = []
    var savedChoice: Bool?

    func loadChoice() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return savedChoice
    }

    func saveChoice(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        savedChoice = enabled
        choices.append(enabled)
    }
}

@Test func successfulRequestReportsTheChoiceTheSystemAccepted() {
    let registration = RecordingLoginItemRegistration()
    let persistence = RecordingChoicePersistence()
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence
    )

    #expect(requester.request(true) == .succeeded(enabled: true))
    #expect(registration.requests == [true])
    #expect(persistence.choices == [true])
}

@Test func failedRequestPreservesTheMessageAndNestedErrorIdentities() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "OuterRegistrationDomain",
        code: 42,
        userInfo: [
            NSLocalizedDescriptionKey: "Login item registration was denied.",
            NSUnderlyingErrorKey: NSError(
                domain: "UnderlyingRegistrationDomain",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Underlying refusal."]
            ),
        ]
    )
    let persistence = RecordingChoicePersistence()
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence
    )

    #expect(
        requester.request(false)
            == .failed(LaunchAtLoginRequestFailure(
                message: "Login item registration was denied.",
                diagnostic: "OuterRegistrationDomain (42): Login item registration was denied.; underlying: UnderlyingRegistrationDomain (7): Underlying refusal."
            ))
    )
    #expect(registration.requests == [false])
    #expect(persistence.choices.isEmpty)
}

@Test func disablingANeverRequestedLoginItemTreatsMacOSRecordNotFoundAsSuccess() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
    )
    let persistence = RecordingChoicePersistence()
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence,
        operatingSystemMajorVersion: 26
    )

    #expect(requester.request(false) == .succeeded(enabled: false))
    #expect(registration.requests == [false])
    #expect(persistence.choices == [false])
}

@Test func aPreviouslyEnabledLoginItemDoesNotHideTheSameMacOSError() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
    )
    let persistence = RecordingChoicePersistence()
    persistence.savedChoice = true
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence
    )

    guard case .failed = requester.request(false) else {
        Issue.record("A previously enabled login item must keep a real failure visible.")
        return
    }
    #expect(registration.requests == [false])
    #expect(persistence.choices.isEmpty)
}

@Test func documentedJobNotFoundIsAlwaysAnIdempotentDisableSuccess() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "kSMErrorDomainFramework",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "The specified job could not be found."]
    )
    let persistence = RecordingChoicePersistence()
    persistence.savedChoice = true
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence
    )

    #expect(requester.request(false) == .succeeded(enabled: false))
    #expect(persistence.choices == [false])
}

@Test func registrationNeverTreatsAnyDisableOnlyErrorAsSuccess() {
    let errors = [
        NSError(
            domain: "SMAppServiceErrorDomain",
            code: 1,
            userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
        ),
        NSError(
            domain: "kSMErrorDomainFramework",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "The specified job could not be found."]
        ),
    ]

    for error in errors {
        let registration = RecordingLoginItemRegistration()
        registration.failure = error
        let persistence = RecordingChoicePersistence()
        let requester = LaunchAtLoginRequester(
            registration: registration,
            persistence: persistence,
            operatingSystemMajorVersion: 26
        )

        guard case .failed = requester.request(true) else {
            Issue.record("A registration failure must never be treated as already disabled: \(error.domain) (\(error.code))")
            continue
        }
        #expect(persistence.choices.isEmpty)
    }
}

@Test func earlierMacOSDoesNotApplyTheMacOS26RecordNotFoundWorkaround() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
    )
    let persistence = RecordingChoicePersistence()
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence,
        operatingSystemMajorVersion: 15
    )

    guard case .failed = requester.request(false) else {
        Issue.record("Only the observed macOS 26 behavior may use the code-1 workaround.")
        return
    }
    #expect(persistence.choices.isEmpty)
}

@Test func anAlreadyDisabledChoiceUsesTheMacOS26RecordNotFoundWorkaround() {
    let registration = RecordingLoginItemRegistration()
    registration.failure = NSError(
        domain: "SMAppServiceErrorDomain",
        code: 1,
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"]
    )
    let persistence = RecordingChoicePersistence()
    persistence.savedChoice = false
    let requester = LaunchAtLoginRequester(
        registration: registration,
        persistence: persistence,
        operatingSystemMajorVersion: 26
    )

    #expect(requester.request(false) == .succeeded(enabled: false))
    #expect(persistence.choices == [false])
}
