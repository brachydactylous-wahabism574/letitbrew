import Testing
import Foundation
@testable import LetItBrewCore

@Test func reportsAFreshInstallAsHealthy() throws {
    let data = try ClaudeHooks.install(into: nil, cliPath: "/opt/letitbrew")
    let report = ClaudeHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.healthy == Set(ClaudeHooks.events))
    #expect(report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func reportsAnEmptyFileAsAllMissing() {
    let report = ClaudeHooks.report(for: nil, cliPath: "/opt/letitbrew")
    #expect(report.missing == Set(ClaudeHooks.events))
    #expect(report.isAbsent)
    #expect(!report.isHealthy)
}

@Test func reportsADriftedPathAsStale() throws {
    let data = try ClaudeHooks.install(into: nil, cliPath: "/old/letitbrew")
    let report = ClaudeHooks.report(for: data, cliPath: "/new/letitbrew")
    #expect(report.stale == Set(ClaudeHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.missing.isEmpty)
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func reportsADoubledEntryAsDuplicated() throws {
    let data = Data("""
    {"hooks":{"Stop":[
      {"hooks":[{"type":"command","command":"a; : # __letitbrew_hook"}]},
      {"hooks":[{"type":"command","command":"b; : # __letitbrew_hook"}]}]}}
    """.utf8)
    let report = ClaudeHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.duplicated == ["Stop"])
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.missing == Set(ClaudeHooks.events).subtracting(["Stop"]))
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func reportsAnEntryUnderARetiredEventAsOrphaned() {
    let data = Data("""
    {"hooks":{"LegacyEvent":[{"hooks":[{"type":"command","command":"x; : # __letitbrew_hook"}]}]}}
    """.utf8)
    let report = ClaudeHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.orphaned == ["LegacyEvent"])
    #expect(report.missing == Set(ClaudeHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func foreignHooksAloneReportAsMissingNotUnhealthy() {
    let data = Data("""
    {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
    """.utf8)
    let report = ClaudeHooks.report(for: data, cliPath: "/opt/letitbrew")
    #expect(report.missing == Set(ClaudeHooks.events))
    #expect(report.healthy.isEmpty)
    #expect(report.stale.isEmpty)
    #expect(report.orphaned.isEmpty)
    #expect(report.duplicated.isEmpty)
    #expect(report.isAbsent)
    #expect(!report.isHealthy)
}

/// `report` must never crash or emit a partial classification for a settings
/// shape `install`/`remove` would refuse outright — it must report the same
/// "nothing verified" state a truly empty or unreadable file would.
///
/// The last case is the one that matters most: a malformed `PreToolUse`
/// value (not an array) sitting next to a `Stop` entry carrying the *exact*
/// command this build would install. Without validating every event's shape
/// the same way `install`/`remove` do, `HookFile.report` would simply skip
/// the malformed event and classify `Stop` on its own — reporting `healthy`
/// for `Stop` while `install`/`remove` would refuse to touch the file at
/// all. That mismatch (a status display saying "connected" while the
/// installer won't go near the file) is precisely the misleading state this
/// task exists to eliminate.
@Test func unreadableSettingsReportAsAbsentRatherThanCrashing() throws {
    let realStopCommand = try ClaudeHooks.hookCommand(event: "Stop", cliPath: "/opt/letitbrew")
    let mixedMalformedEvent = try JSONSerialization.data(withJSONObject: [
        "hooks": [
            "PreToolUse": "not an array",
            "Stop": [["hooks": [["type": "command", "command": realStopCommand]]]],
        ],
    ] as [String: Any])

    let malformed: [Data] = [
        Data("not json".utf8),           // malformed JSON
        Data(),                          // exists but empty: not "no file yet"
        Data("[1,2,3]".utf8),            // valid JSON, but not an object
        Data(#"{"hooks":[1,2,3]}"#.utf8), // hooks present but not a dictionary
        mixedMalformedEvent,             // one malformed event beside one otherwise-healthy entry
    ]
    for data in malformed {
        let report = ClaudeHooks.report(for: data, cliPath: "/opt/letitbrew")
        #expect(report.missing == Set(ClaudeHooks.events))
        #expect(report.healthy.isEmpty)
        #expect(report.stale.isEmpty)
        #expect(report.duplicated.isEmpty)
        #expect(report.orphaned.isEmpty)
        #expect(report.isAbsent)
        #expect(!report.isHealthy)
    }
}
