import Testing
@testable import LetItBrewDaemonCore

private let expectedHash = "00112233445566778899aabbccddeeff00112233"

private func makeExpectedBuild() throws -> LetItBrewDaemonBuildIdentity {
    try #require(LetItBrewDaemonBuildIdentity(
        marketingVersion: "0.2.0",
        buildVersion: "2",
        codeDirectoryHash: expectedHash
    ))
}

@Test func buildIdentityRequiresCompleteCanonicalValues() throws {
    let expectedBuild = try makeExpectedBuild()
    #expect(LetItBrewDaemonBuildIdentity(
        marketingVersion: nil,
        buildVersion: "2",
        codeDirectoryHash: expectedHash
    ) == nil)
    #expect(LetItBrewDaemonBuildIdentity(
        marketingVersion: "0.2.0",
        buildVersion: "   ",
        codeDirectoryHash: expectedBuild.codeDirectoryHash
    ) == nil)
    #expect(LetItBrewDaemonBuildIdentity(
        marketingVersion: "0.2.0",
        buildVersion: "2",
        codeDirectoryHash: "not-a-hash"
    ) == nil)
    #expect(LetItBrewDaemonBuildIdentity(
        marketingVersion: " 0.2.0 ",
        buildVersion: " 2 ",
        codeDirectoryHash: "00112233445566778899AABBCCDDEEFF00112233"
    ) == expectedBuild)
    #expect(expectedBuild.versionDescription == "0.2.0 (2)")
}

@Test func exactProtocolBuildAndReadinessAreCompatible() throws {
    let expectedBuild = try makeExpectedBuild()
    let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
        expectedBuild: expectedBuild,
        receivedProtocol: LetItBrewDaemonProtocolVersion.current,
        receivedMarketingVersion: expectedBuild.marketingVersion,
        receivedBuildVersion: expectedBuild.buildVersion,
        receivedCodeDirectoryHash: expectedBuild.codeDirectoryHash,
        reconciliationReady: true,
        reconciliationMessage: nil
    )

    #expect(result == .compatible)
}

@Test func sameProtocolAndVersionWithDifferentSignedImageIsStale() throws {
    let expectedBuild = try makeExpectedBuild()
    let received = try #require(LetItBrewDaemonBuildIdentity(
        marketingVersion: expectedBuild.marketingVersion,
        buildVersion: expectedBuild.buildVersion,
        codeDirectoryHash: "ffeeddccbbaa99887766554433221100ffeeddcc"
    ))

    let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
        expectedBuild: expectedBuild,
        receivedProtocol: LetItBrewDaemonProtocolVersion.current,
        receivedMarketingVersion: received.marketingVersion,
        receivedBuildVersion: received.buildVersion,
        receivedCodeDirectoryHash: received.codeDirectoryHash,
        reconciliationReady: true,
        reconciliationMessage: nil
    )

    #expect(result == .staleBuild(expected: expectedBuild, received: received))
}

@Test func missingOrMalformedBuildIdentityIsLegacyOrUnidentified() throws {
    let expectedBuild = try makeExpectedBuild()
    for hash in [nil, "", "xyz"] as [String?] {
        let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
            expectedBuild: expectedBuild,
            receivedProtocol: LetItBrewDaemonProtocolVersion.current,
            receivedMarketingVersion: expectedBuild.marketingVersion,
            receivedBuildVersion: expectedBuild.buildVersion,
            receivedCodeDirectoryHash: hash,
            reconciliationReady: true,
            reconciliationMessage: nil
        )

        #expect(result == .legacyOrUnidentified(
            receivedProtocol: LetItBrewDaemonProtocolVersion.current
        ))
    }
}

@Test func incompatibleProtocolIsReportedSeparately() throws {
    let expectedBuild = try makeExpectedBuild()
    let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
        expectedProtocol: 2,
        expectedBuild: expectedBuild,
        receivedProtocol: 1,
        receivedMarketingVersion: expectedBuild.marketingVersion,
        receivedBuildVersion: expectedBuild.buildVersion,
        receivedCodeDirectoryHash: expectedBuild.codeDirectoryHash,
        reconciliationReady: true,
        reconciliationMessage: nil
    )

    #expect(result == .incompatibleProtocol(expected: 2, received: 1))
}

@Test func blockedReconciliationCannotLookCompatibleOrMerelyStale() throws {
    let expectedBuild = try makeExpectedBuild()
    let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
        expectedProtocol: 2,
        expectedBuild: expectedBuild,
        receivedProtocol: 1,
        receivedMarketingVersion: nil,
        receivedBuildVersion: nil,
        receivedCodeDirectoryHash: nil,
        reconciliationReady: false,
        reconciliationMessage: " Restore debt remains. "
    )

    #expect(result == .reconciliationBlocked("Restore debt remains."))
}

@Test func blockedReconciliationHasANonemptyFallbackMessage() throws {
    let expectedBuild = try makeExpectedBuild()
    let result = LetItBrewDaemonHandshakeCompatibility.evaluate(
        expectedBuild: expectedBuild,
        receivedProtocol: LetItBrewDaemonProtocolVersion.current,
        receivedMarketingVersion: expectedBuild.marketingVersion,
        receivedBuildVersion: expectedBuild.buildVersion,
        receivedCodeDirectoryHash: expectedBuild.codeDirectoryHash,
        reconciliationReady: false,
        reconciliationMessage: "  "
    )

    #expect(result == .reconciliationBlocked(
        "The daemon could not reconcile its prior sleep state."
    ))
}

@Test func protocolRemainsVersionOneForTheAdditiveMethods() {
    #expect(LetItBrewDaemonProtocolVersion.current == 1)
}
