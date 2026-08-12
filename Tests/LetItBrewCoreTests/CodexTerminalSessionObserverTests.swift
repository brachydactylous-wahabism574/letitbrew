import Foundation
import Testing
@testable import LetItBrewCore

private func terminalTestHome() throws -> URL {
    let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("letitbrew-codex-terminal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func terminalRolloutURL(home: URL, sessionID: String) throws -> URL {
    let directory = home
        .appendingPathComponent(".codex/sessions/2027/01/15", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(
        "rollout-2027-01-15T10-00-00-\(sessionID).jsonl"
    )
}

private func terminalSession(
    id: String,
    tool: String = "codex",
    state: SessionState = .working,
    updatedAt: Date,
    transcriptPath: String?,
    eventObservedAt: TimeInterval? = nil
) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: tool,
        state: state,
        detail: state == .working ? "running-command" : nil,
        cwd: "/tmp/project",
        pid: 77,
        updatedAt: updatedAt,
        lastEvent: state == .working ? "PreToolUse" : "Stop",
        startedAt: updatedAt.addingTimeInterval(-60),
        stateChangedAt: updatedAt,
        stateTransitionID: "hook-edge",
        transcriptPath: transcriptPath,
        eventObservedAt: eventObservedAt
    )
}

private func writeTerminalLines(_ lines: [String], to url: URL) throws {
    let text = lines.joined(separator: "\n") + "\n"
    try Data(text.utf8).write(to: url)
}

private func terminalHookDate() throws -> Date {
    try #require(ISO8601DateFormatter().date(from: "2027-01-15T10:00:00Z"))
}

@Test func legacyRecordWithoutTranscriptPathFindsOnlyItsExactRecentRollout() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "abababab-cdcd-efef-1212-343434343434"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let observer = CodexTerminalSessionObserver(
        homeDirectory: home,
        now: { hookDate }
    )

    let result = await observer.applyingFallback(to: [terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: nil
    )])

    #expect(result.first?.state == .idle)
    #expect(result.first?.lastEvent == "CodexTurnAborted")
}

@Test func newerSupportedStructuralTerminalEventsEndCodexWorkingState() async throws {
    let cases = [
        (event: "task_complete", lastEvent: "CodexTaskComplete"),
        (event: "turn_aborted", lastEvent: "CodexTurnAborted"),
    ]
    for (index, entry) in cases.enumerated() {
        let home = try terminalTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "11111111-2222-3333-4444-55555555555\(index)"
        let url = try terminalRolloutURL(home: home, sessionID: id)
        try writeTerminalLines([
            #"{"timestamp":"2027-01-15T10:00:05.500Z","type":"event_msg","payload":{"type":"\#(entry.event)"}}"#,
        ], to: url)
        let hookDate = try terminalHookDate()
        let observer = CodexTerminalSessionObserver(homeDirectory: home)

        let result = await observer.applyingFallback(to: [terminalSession(
            id: id,
            updatedAt: hookDate,
            transcriptPath: url.path
        )])

        let ended = try #require(result.first)
        #expect(ended.state == .idle)
        #expect(ended.detail == nil)
        #expect(ended.lastEvent == entry.lastEvent)
        #expect(ended.startedAt == hookDate.addingTimeInterval(-60))
        #expect(ended.cwd == "/tmp/project")
    }
}

@Test func completedRolloutWithoutAStopHookCannotRemainWorking() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "61616161-7272-8383-9494-050505050505"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2027-01-15T10:00:06Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )])

    #expect(result.first?.state == .idle)
    #expect(result.first?.detail == nil)
    #expect(result.first?.lastEvent == "CodexTaskComplete")
}

@Test func terminalEventOlderThanTheLatestHookCannotOverrideNewWork() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: url)
    let laterHook = try #require(ISO8601DateFormatter().date(from: "2027-01-15T10:00:10Z"))
    let original = terminalSession(
        id: id,
        updatedAt: laterHook,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [original])

    #expect(result == [original])
}

@Test func subsecondHookAfterTerminalWinsWhenISODateSharesTheSameSecond() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "dddddddd-eeee-ffff-0000-111111111111"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05.500Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: url)
    let encodedHookDate = try #require(ISO8601DateFormatter().date(
        from: "2027-01-15T10:00:05Z"
    ))
    let original = terminalSession(
        id: id,
        updatedAt: encodedHookDate,
        transcriptPath: url.path,
        eventObservedAt: encodedHookDate.timeIntervalSince1970 + 0.8
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [original])

    #expect(result == [original])
}

@Test func appendedTerminalIsDetectedAfterAnInitiallyUnchangedWorkingFile() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "12345678-1234-1234-1234-123456789abc"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:01Z","type":"event_msg","payload":{"type":"token_count"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)
    #expect(await observer.applyingFallback(to: [original]) == [original])

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    let terminalLine = #"{"timestamp":"2027-01-15T10:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    try handle.write(contentsOf: Data((terminalLine + "\n").utf8))
    try handle.close()

    let result = await observer.applyingFallback(to: [original])
    #expect(result.first?.state == .idle)
    #expect(result.first?.lastEvent == "CodexTaskComplete")
}

@Test func incrementalCacheRetainsTheNewestTerminalEventAndItsIdentity() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "23232323-4545-6767-8989-010101010101"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)
    #expect(
        await observer.applyingFallback(to: [original]).first?.lastEvent
            == "CodexTaskComplete"
    )

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    let olderAbort = #"{"timestamp":"2027-01-15T10:00:04Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#
    try handle.write(contentsOf: Data((olderAbort + "\n").utf8))
    try handle.close()

    #expect(
        await observer.applyingFallback(to: [original]).first?.lastEvent
            == "CodexTaskComplete"
    )
}

@Test func terminalLifecycleAtExactOneMiBTailBoundaryIsObserved() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "34343434-4545-5656-6767-121212121212"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    let terminal = #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"
    var data = Data(repeating: 0x78, count: 1_048_577 - 1)
    data.append(0x0A)
    var tail = Data(terminal.utf8)
    tail.append(Data(repeating: 0x79, count: 1_048_576 - tail.count - 1))
    tail.append(0x0A)
    data.append(tail)
    try data.write(to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(id: id, updatedAt: hookDate, transcriptPath: url.path)
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [original])

    #expect(result.first?.state == .idle)
    #expect(result.first?.lastEvent == "CodexTaskComplete")
}

@Test func laterTerminalLineWinsWhenLifecycleTimestampsTie() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "45454545-5656-6767-7878-232323232323"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(id: id, updatedAt: hookDate, transcriptPath: url.path)
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [original])

    #expect(result.first?.state == .idle)
    #expect(result.first?.lastEvent == "CodexTurnAborted")
}

@Test func samePathTerminalReplacementWithPreservedSizeAndMTimeIsRescanned() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "56565656-6767-7878-8989-343434343434"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    let terminal = #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    let unsupported = #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"agent_message"}}"#
    #expect(terminal.utf8.count == unsupported.utf8.count)
    let modifiedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-15T10:00:08Z"))
    try writeTerminalLines([terminal], to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    let hookDate = try terminalHookDate()
    let original = terminalSession(id: id, updatedAt: hookDate, transcriptPath: url.path)
    let observer = CodexTerminalSessionObserver(homeDirectory: home)
    #expect(await observer.applyingFallback(to: [original]).first?.state == .idle)

    let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.jsonl")
    try writeTerminalLines([unsupported], to: replacement)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: replacement.path)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

    #expect(await observer.applyingFallback(to: [original]) == [original])
}

@Test func incompleteJSONLineIsRereadOnlyAfterItsTerminatingNewlineArrives() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "12121212-3434-5656-7878-909090909090"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    let terminalLine = #"{"timestamp":"2027-01-15T10:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    try Data(terminalLine.utf8).write(to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    #expect(await observer.applyingFallback(to: [original]) == [original])

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()

    #expect(await observer.applyingFallback(to: [original]).first?.state == .idle)
    #expect(
        await observer.applyingFallback(to: [original]).first?.lastEvent
            == "CodexTaskComplete"
    )
}

@Test func claudeRecordsAndMalformedCodexLinesRemainUntouched() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "99999999-8888-7777-6666-555555555555"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        "not-json",
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: url)
    let hookDate = Date(timeIntervalSince1970: 1_800_000_000)
    let claude = terminalSession(
        id: id,
        tool: "claude",
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let codex = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [claude, codex])

    #expect(result == [claude, codex])
}

@Test func proseAndUnsupportedEnvelopeTypesCannotSynthesizeTerminalEvents() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "81818181-9292-0303-1414-252525252525"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"task_complete then turn_aborted"}}"#,
        #"{"timestamp":"2027-01-15T10:00:04Z","type":"task_complete","payload":{"type":"turn_aborted"}}"#,
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_started","response":"turn_aborted"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    #expect(await observer.applyingFallback(to: [original]) == [original])
}

@Test func hookSuppliedPathOutsideCodexSessionsDirectoryIsRejected() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "feedfeed-feed-feed-feed-feedfeedfeed"
    let outside = home.appendingPathComponent("outside-\(id).jsonl")
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: outside)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: outside.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [original])

    #expect(result == [original])
}

@Test func symlinkedRolloutInsideCodexSessionsDirectoryIsRejected() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "42424242-5353-6464-7575-868686868686"
    let realURL = try terminalRolloutURL(home: home, sessionID: id)
        .deletingLastPathComponent()
        .appendingPathComponent("real-terminal.jsonl")
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: realURL)
    let symlinkURL = realURL.deletingLastPathComponent().appendingPathComponent(
        "rollout-symlink-\(id).jsonl"
    )
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realURL)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: symlinkURL.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    #expect(await observer.applyingFallback(to: [original]) == [original])
}

@Test func parentDirectoryReplacedBySymlinkImmediatelyBeforeDescriptorOpenIsRejected() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "67676767-7878-8989-9090-454545454545"
    let candidate = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], to: candidate)
    let dateDirectory = candidate.deletingLastPathComponent()
    let movedDirectory = home.appendingPathComponent("outside-date-directory", isDirectory: true)
    let hookDate = try terminalHookDate()
    let original = terminalSession(id: id, updatedAt: hookDate, transcriptPath: candidate.path)
    let observer = CodexTerminalSessionObserver(
        homeDirectory: home,
        beforeOpeningRollout: { url in
            guard url == candidate else { return }
            try? FileManager.default.moveItem(at: dateDirectory, to: movedDirectory)
            try? FileManager.default.createSymbolicLink(
                at: dateDirectory,
                withDestinationURL: movedDirectory
            )
        }
    )

    #expect(await observer.applyingFallback(to: [original]) == [original])
}

@Test func lookalikeFilenameWithoutASessionIDBoundaryIsRejected() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "13571357-2468-2468-2468-135713571357"
    let directory = home
        .appendingPathComponent(".codex/sessions/2027/01/15", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lookalike = directory.appendingPathComponent("not-the-session\(id).jsonl")
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: lookalike)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: lookalike.path
    )
    let observer = CodexTerminalSessionObserver(
        homeDirectory: home,
        now: { hookDate }
    )

    let result = await observer.applyingFallback(to: [original])

    #expect(result == [original])
}

@Test func terminalEventBeyondTheBoundedOneMiBTailIsNotRead() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "62626262-7373-8484-9595-060606060606"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    let terminalLine = #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#
    var data = Data((terminalLine + "\n").utf8)
    data.append(Data(repeating: 0x78, count: 1_048_577))
    data.append(Data("\n".utf8))
    try data.write(to: url)
    let hookDate = try terminalHookDate()
    let original = terminalSession(
        id: id,
        updatedAt: hookDate,
        transcriptPath: url.path
    )
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    #expect(await observer.applyingFallback(to: [original]) == [original])
}

@Test func terminalKeepsAStaleIdleSessionIdle() async throws {
    let home = try terminalTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let id = "00000000-1111-2222-3333-444444444444"
    let url = try terminalRolloutURL(home: home, sessionID: id)
    try writeTerminalLines([
        #"{"timestamp":"2027-01-15T10:00:05Z","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ], to: url)
    let hookDate = try terminalHookDate()
    let observer = CodexTerminalSessionObserver(homeDirectory: home)

    let result = await observer.applyingFallback(to: [terminalSession(
        id: id,
        state: .idle,
        updatedAt: hookDate,
        transcriptPath: url.path
    )])

    #expect(result.first?.state == .idle)
    #expect(result.first?.detail == nil)
}
