import Foundation
import Testing
@testable import LetItBrewDaemonCore

@Test func onlyDirectApplicationsChildrenMayManageBackgroundServices() {
    #expect(BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/Applications/Let It Brew.app"),
        bundleIdentifier: "com.ruban24.letitbrew"
    ))
    #expect(BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/Applications/Let It Brew Dev.app"),
        bundleIdentifier: "com.ruban24.letitbrew.dev"
    ))
    #expect(!BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/tmp/Let It Brew.app"),
        bundleIdentifier: "com.ruban24.letitbrew"
    ))
    #expect(!BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/Applications/Tools/Let It Brew.app"),
        bundleIdentifier: "com.ruban24.letitbrew"
    ))
}

@Test func lookalikeIdentifiersAndNonAppBundlesAreRejected() {
    #expect(!BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/Applications/Let It Brew.app"),
        bundleIdentifier: "com.ruban24.letitbrew.evil"
    ))
    #expect(!BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: URL(fileURLWithPath: "/Applications/Let It Brew"),
        bundleIdentifier: "com.ruban24.letitbrew"
    ))
}

@Test func serviceManagementRequiresTheLiveExpectedSigningIdentity() {
    let productionURL = URL(fileURLWithPath: "/Applications/Let It Brew.app")
    let production = RuntimeSigningIdentity(
        identifier: "com.ruban24.letitbrew",
        teamIdentifier: BackgroundServiceEligibility.expectedTeamIdentifier
    )
    #expect(BackgroundServiceEligibility.mayManageBackgroundServices(
        bundleURL: productionURL,
        bundleIdentifier: production.identifier,
        signingIdentity: production
    ))

    for identity in [
        RuntimeSigningIdentity(
            identifier: "com.ruban24.letitbrew.dev",
            teamIdentifier: BackgroundServiceEligibility.expectedTeamIdentifier
        ),
        RuntimeSigningIdentity(
            identifier: "com.ruban24.letitbrew",
            teamIdentifier: "ATTACKERTEAM"
        ),
    ] {
        #expect(!BackgroundServiceEligibility.mayManageBackgroundServices(
            bundleURL: productionURL,
            bundleIdentifier: "com.ruban24.letitbrew",
            signingIdentity: identity
        ))
    }
}
