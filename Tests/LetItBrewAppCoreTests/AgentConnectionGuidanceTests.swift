import Testing
@testable import LetItBrewAppCore

@Test func invalidConfigurationGuidanceNamesTheSafeRecoveryAction() {
    let details = AgentConfigRecoveryGuidance.details(
        agentName: "Claude",
        path: "/tmp/home/.claude/settings.json"
    )

    #expect(details.count == 2)
    #expect(details[0].contains("left it unchanged"))
    #expect(details[0].contains("/tmp/home/.claude/settings.json"))
    #expect(details[1].contains("Check Again"))
}
