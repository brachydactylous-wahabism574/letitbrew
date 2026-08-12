import Testing
import Foundation
@testable import LetItBrewCore

private let marker = "__test_marker"
private let ours = "; \(HookFile.ownershipComment(marker: marker))"

private func group(_ commands: [String]) -> [String: Any] {
    ["hooks": commands.map { ["type": "command", "command": $0] as [String: Any] }]
}

private func assertEntry(_ group: [String: Any], command: String = "c", timeout: Int = 5) {
    let entries = group["hooks"] as? [Any]
    #expect(entries?.count == 1)
    let first = entries?.first as? [String: Any]
    #expect(first?["type"] as? String == "command")
    #expect(first?["command"] as? String == command)
    #expect(first?["timeout"] as? Int == timeout)
}

/// Walks every group and every entry under one event's swept value, asserting
/// exact counts and exact contents at each level. No `compactMap`, `.first`,
/// or `?? []` anywhere: those are lossy and would let an extra or malformed
/// survivor pass unnoticed. `zip` is safe here because the preceding
/// `#expect` on `.count` already fails the test if the lengths disagree, so
/// nothing past the shorter length goes unchecked for a reason that matters.
private func assertExactSurvivingGroups(
    _ value: Any?, expectedCommandsPerGroup: [[String]]
) throws {
    let groups = try #require(value as? [Any])
    #expect(groups.count == expectedCommandsPerGroup.count)
    for (rawGroup, expectedCommands) in zip(groups, expectedCommandsPerGroup) {
        let dict = try #require(rawGroup as? [String: Any])
        #expect(Set(dict.keys) == ["hooks"])
        let entries = try #require(dict["hooks"] as? [Any])
        #expect(entries.count == expectedCommands.count)
        for (rawEntry, expectedCommand) in zip(entries, expectedCommands) {
            let entry = try #require(rawEntry as? [String: Any])
            #expect(Set(entry.keys) == ["type", "command"])
            #expect(entry["type"] as? String == "command")
            #expect(entry["command"] as? String == expectedCommand)
        }
    }
}

@Test func recognizesOnlyOurOwnEntries() {
    #expect(HookFile.isOurs(["type": "command", "command": "x\(ours)"], marker: marker))
    #expect(!HookFile.isOurs(["type": "command", "command": "rtk hook claude"], marker: marker))
    #expect(!HookFile.isOurs(["type": "command"], marker: marker))
    #expect(!HookFile.isOurs("not an object", marker: marker))
}

@Test func bareMarkerTextWithoutTheSentinelIsNotOurs() {
    // The marker string appearing anywhere is not enough; only the exact
    // trailing sentinel comment counts.
    #expect(!HookFile.isOurs(["type": "command", "command": "echo \(marker) reminder"], marker: marker))
}

@Test func ownershipMatchesTheFullSentinelNotAPrefix() {
    // A marker that is a prefix of another marker must not own the other's
    // entries: "__test_marker" must not swallow "__test_marker_v2".
    let otherMarker = "\(marker)_v2"
    let theirCommand = "theirs\(HookFile.ownershipComment(marker: otherMarker))"
    let hooks: [String: Any] = ["Stop": [group(["mine\(ours)", theirCommand])]]
    let swept = HookFile.sweep(hooks, marker: marker)
    let entries = ((swept["Stop"] as? [Any])?.first as? [String: Any])?["hooks"] as? [Any]
    let survivors = entries?.compactMap { ($0 as? [String: Any])?["command"] as? String }
    #expect(survivors == [theirCommand])
}

@Test func ownershipMatchesTheFullSentinelNotAPrefixInReverse() {
    // The collision must not swallow entries in the other direction either:
    // sweeping with the LONGER marker "__test_marker_v2" must not claim the
    // SHORTER marker's "__test_marker" entry.
    let otherMarker = "\(marker)_v2"
    let shortCommand = "mine\(ours)"
    let longCommand = "theirs\(HookFile.ownershipComment(marker: otherMarker))"
    let hooks: [String: Any] = ["Stop": [group([shortCommand, longCommand])]]
    let swept = HookFile.sweep(hooks, marker: otherMarker)
    let entries = ((swept["Stop"] as? [Any])?.first as? [String: Any])?["hooks"] as? [Any]
    let survivors = entries?.compactMap { ($0 as? [String: Any])?["command"] as? String }
    #expect(survivors == [shortCommand])
}

@Test func stripRemovesOursAndKeepsTheRest() throws {
    let groups: [Any] = [group(["mine\(ours)", "theirs"])]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 1)
    let survivingGroup = try #require(kept.first as? [String: Any])
    let entries = try #require(survivingGroup["hooks"] as? [Any])
    // Raw count first: catches an extra survivor a lossy projection would hide.
    #expect(entries.count == 1)
    let entry = try #require(entries.first as? [String: Any])
    #expect(Set(entry.keys) == ["type", "command"])
    #expect(entry["type"] as? String == "command")
    #expect(entry["command"] as? String == "theirs")
}

@Test func stripDropsAGroupLeftEmptyAndKeepsTheForeignOne() {
    let groups: [Any] = [group(["mine\(ours)"]), group(["theirs"])]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 1)
    let entries = (kept.first as? [String: Any])?["hooks"] as? [Any]
    let command = (entries?.first as? [String: Any])?["command"] as? String
    #expect(command == "theirs")
}

@Test func stripLeavesAGroupWithNoOwnedEntryCompletelyUntouched() {
    // A group with an empty "hooks" array plus foreign metadata (a matcher)
    // contains none of ours and must survive with every key intact — not be
    // pruned just because the surviving hooks array happens to be empty.
    let untouched: [String: Any] = ["hooks": [], "matcher": "*", "extra": 1]
    let groups: [Any] = [untouched]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 1)
    let dict = kept.first as? [String: Any]
    #expect(dict?["matcher"] as? String == "*")
    #expect(dict?["extra"] as? Int == 1)
    #expect((dict?["hooks"] as? [Any])?.isEmpty == true)
}

@Test func stripPreservesForeignShapesItDoesNotUnderstand() {
    let groups: [Any] = ["a bare string", ["no": "hooks key"]]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 2)
    #expect(kept[0] as? String == "a bare string")
    #expect(kept[1] as? [String: String] == ["no": "hooks key"])
}

@Test func stripPreservesNonDictionaryGroupShapes() {
    let groups: [Any] = [42, true, ["nested"]]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 3)
    #expect(kept[0] as? Int == 42)
    #expect(kept[1] as? Bool == true)
    #expect(kept[2] as? [String] == ["nested"])
}

@Test func stripOnAnEmptyArrayReturnsEmpty() {
    #expect(HookFile.strip([], marker: marker).isEmpty)
}

@Test func stripPreservesAGroupWhoseHooksValueIsNotAnArray() {
    let groups: [Any] = [["hooks": "not an array", "matcher": "*"]]
    let kept = HookFile.strip(groups, marker: marker)
    #expect(kept.count == 1)
    let dict = kept.first as? [String: Any]
    #expect(dict?["hooks"] as? String == "not an array")
    #expect(dict?["matcher"] as? String == "*")
}

@Test func stripPreservesEntriesThatAreNotDictionariesOrLackAStringCommand() {
    let groups: [Any] = [
        ["hooks": ["not a dict", 42, ["type": "command", "command": 123],
                   ["type": "command", "command": "mine\(ours)"]]],
    ]
    let kept = HookFile.strip(groups, marker: marker)
    let entries = (kept.first as? [String: Any])?["hooks"] as? [Any]
    #expect(entries?.count == 3)
    #expect(entries?[0] as? String == "not a dict")
    #expect(entries?[1] as? Int == 42)
    let malformed = entries?[2] as? [String: Any]
    #expect(malformed.map { Set($0.keys) } == ["type", "command"])
    #expect(malformed?["type"] as? String == "command")
    #expect(malformed?["command"] as? Int == 123)
}

@Test func sweepClearsOursFromEveryEventAndPrunesEmptied() throws {
    let hooks: [String: Any] = [
        "Stop": [group(["mine\(ours)"])],
        "PreToolUse": [group(["mine\(ours)", "theirs"])],
        "Other": [group(["theirs only"])],
    ]
    let swept = HookFile.sweep(hooks, marker: marker)
    #expect(Set(swept.keys) == ["PreToolUse", "Other"])

    try assertExactSurvivingGroups(swept["PreToolUse"], expectedCommandsPerGroup: [["theirs"]])
    try assertExactSurvivingGroups(swept["Other"], expectedCommandsPerGroup: [["theirs only"]])
}

@Test func sweepLeavesAnEventWithOnlyForeignEntriesByteForByteUnchanged() throws {
    let hooks: [String: Any] = ["Other": [group(["theirs only"]), ["hooks": [], "matcher": "*"]]]
    let swept = HookFile.sweep(hooks, marker: marker)
    let other = try #require(swept["Other"] as? [Any])
    #expect(other.count == 2)

    // First group: exact key set, exact single entry, exact fields on it.
    let first = try #require(other.first as? [String: Any])
    #expect(Set(first.keys) == ["hooks"])
    let firstEntries = try #require(first["hooks"] as? [Any])
    #expect(firstEntries.count == 1)
    let firstEntry = try #require(firstEntries.first as? [String: Any])
    #expect(Set(firstEntry.keys) == ["type", "command"])
    #expect(firstEntry["type"] as? String == "command")
    #expect(firstEntry["command"] as? String == "theirs only")

    // Second group: exact key set, "hooks" still an empty array (type
    // included, not merely "present"), foreign "matcher" value unchanged.
    let second = try #require(other.last as? [String: Any])
    #expect(Set(second.keys) == ["hooks", "matcher"])
    let secondHooks = try #require(second["hooks"] as? [Any])
    #expect(secondHooks.isEmpty)
    #expect(second["matcher"] as? String == "*")
}

@Test func sweepLeavesAnEventWithAnEmptyGroupArrayPresent() {
    let hooks: [String: Any] = ["Empty": []]
    let swept = HookFile.sweep(hooks, marker: marker)
    #expect(swept["Empty"] != nil)
    #expect((swept["Empty"] as? [Any])?.isEmpty == true)
}

@Test func entryCarriesCommandTimeoutAndOptionalMatcher() {
    let withMatcher = HookFile.entry(command: "c", timeout: 5, matcher: "*")
    #expect(withMatcher["matcher"] as? String == "*")
    assertEntry(withMatcher)

    let without = HookFile.entry(command: "c", timeout: 5, matcher: nil)
    #expect(without["matcher"] == nil)
    assertEntry(without)
}

@Test func reportClassifiesEveryDriftShape() {
    let events = ["Stop", "PreToolUse", "SessionEnd", "Missing"]
    let expected: (String) -> String = { "run \($0)\(ours)" }
    let hooks: [String: Any] = [
        "Stop": [group([expected("Stop")])],
        "PreToolUse": [group(["run PreToolUse\(ours)".replacingOccurrences(
            of: "run", with: "old")])],
        "SessionEnd": [group([expected("SessionEnd")]), group([expected("SessionEnd")])],
        "Retired": [group([expected("Retired")])],
    ]
    let report = HookFile.report(hooks: hooks, events: events, marker: marker,
                                 expectedCommand: expected)
    #expect(report.healthy == ["Stop"])
    #expect(report.stale == ["PreToolUse"])
    #expect(report.duplicated == ["SessionEnd"])
    #expect(report.orphaned == ["Retired"])
    #expect(report.missing == ["Missing"])
    #expect(!report.isHealthy)
    #expect(!report.isAbsent)
}

@Test func reportOnNilHooksIsAllMissingAndAbsent() {
    let report = HookFile.report(hooks: nil, events: ["Stop", "SessionEnd"], marker: marker,
                                 expectedCommand: { "run \($0)" })
    #expect(report.missing == ["Stop", "SessionEnd"])
    #expect(report.isAbsent)
    #expect(!report.isHealthy)
}

@Test func reportIgnoresForeignHooksEntirely() {
    let hooks: [String: Any] = ["Stop": [group(["someone else's hook"])]]
    let report = HookFile.report(hooks: hooks, events: ["Stop"], marker: marker,
                                 expectedCommand: { "run \($0)" })
    #expect(report.missing == ["Stop"])
    #expect(report.isAbsent)
}

@Test func aFullyHealthyInstallReportsHealthy() {
    let events = ["Stop", "SessionEnd"]
    let expected: (String) -> String = { "run \($0)\(ours)" }
    let hooks: [String: Any] = [
        "Stop": [group([expected("Stop")])],
        "SessionEnd": [group([expected("SessionEnd")])],
    ]
    let report = HookFile.report(hooks: hooks, events: events, marker: marker,
                                 expectedCommand: expected)
    #expect(report.isHealthy)
    #expect(!report.isAbsent)
    #expect(report.healthy == Set(events))
}
