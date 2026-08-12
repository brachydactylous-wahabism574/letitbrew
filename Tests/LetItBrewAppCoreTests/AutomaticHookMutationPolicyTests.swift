import Foundation
import Testing
@testable import LetItBrewAppCore

@Test func directApplicationBundlesAreEligibleForAutomaticHookWrites() {
    for path in [
        "/Applications/Let It Brew.app",
        "/Applications/Let It Brew Dev.app",
        "/Applications/A Renamed Let It Brew.app",
    ] {
        #expect(AutomaticHookMutationPolicy.evaluate(
            appBundleURL: URL(fileURLWithPath: path)
        ) == .eligible)
    }
}

@Test func ephemeralNestedAndNonBundleLaunchesAreReadOnly() {
    let paths = [
        "/tmp/DerivedData/Build/Products/Debug/Let It Brew.app",
        "/Users/test/Downloads/Let It Brew.app",
        "/Volumes/Let It Brew/Let It Brew.app",
        "/private/var/folders/AppTranslocation/Let It Brew.app",
        "/Applications/Utilities/Let It Brew.app",
        "/Applications/Let It Brew.app/Contents/MacOS/LetItBrew",
        "/Applications/Let It Brew",
    ]

    for path in paths {
        let result = AutomaticHookMutationPolicy.evaluate(
            appBundleURL: URL(fileURLWithPath: path)
        )
        guard case .actionNeeded(let details) = result else {
            Issue.record("Expected read-only Action needed for \(path)")
            continue
        }
        #expect(details.joined(separator: " ").contains("/Applications"))
        #expect(details.joined(separator: " ").contains("Check Again"))
    }
}

@Test func dotSegmentsCannotMakeANestedBundleLookDirectlyInstalled() {
    let nested = URL(fileURLWithPath: "/Applications/Utilities/../Utilities/Let It Brew.app")

    #expect(AutomaticHookMutationPolicy.evaluate(appBundleURL: nested).isEligible == false)
}
