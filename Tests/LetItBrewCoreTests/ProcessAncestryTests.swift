import Testing
import Foundation
@testable import LetItBrewCore

/// Scripted process table: pid -> (ppid, p_comm, raw argv[0]).
private func lookup(
    _ table: [Int32: (ppid: Int32, command: String, argv0: String?)]
) -> (Int32) -> ProcessAncestry.ProcessNode? {
    { pid in
        guard let entry = table[pid] else { return nil }
        return ProcessAncestry.ProcessNode(
            pid: pid, ppid: entry.ppid, command: entry.command, argv0Name: entry.argv0
        )
    }
}

@Test func findsClaudeAboveTheHookShell() {
    // Real shape observed on macOS: hook sh -> claude -> login shell -> terminal.
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        100: (200, "sh", nil),
        200: (300, "claude", "claude"),
        300: (400, "zsh", "zsh"),
        400: (1, "ghostty", "ghostty"),
    ]
    let agent = ProcessAncestry.findAgent(from: 100, maxDepth: 8, lookup: lookup(table))
    #expect(agent?.pid == 200)
    #expect(agent?.command == "claude")
}

@Test func findsCodex() {
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        10: (20, "sh", nil), 20: (30, "codex", "codex"), 30: (1, "zsh", "zsh"),
    ]
    #expect(ProcessAncestry.findAgent(from: 10, maxDepth: 8, lookup: lookup(table))?.command == "codex")
}

@Test func returnsNilWhenNoAgentInAncestry() {
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        10: (20, "sh", nil), 20: (1, "zsh", "zsh"),
    ]
    #expect(ProcessAncestry.findAgent(from: 10, maxDepth: 8, lookup: lookup(table)) == nil)
}

@Test func stopsAtMaxDepth() {
    var table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [:]
    for i in Int32(1)...Int32(20) { table[i] = (i + 1, "sh", nil) }
    table[21] = (1, "claude", "claude")
    #expect(ProcessAncestry.findAgent(from: 1, maxDepth: 8, lookup: lookup(table)) == nil)
}

@Test func survivesAncestryCycle() {
    // A malformed or recycled table must not hang the hook. maxDepth alone
    // would still terminate the walk even if the `seen` guard were deleted,
    // which is exactly what let a broken guard pass silently before — so
    // assert the guard is load-bearing by counting lookups: 10 -> 20 -> back
    // to 10, where `seen` must cut the walk short at exactly 2 lookups
    // instead of looping until maxDepth.
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        10: (20, "sh", nil), 20: (10, "sh", nil),
    ]
    var lookupCount = 0
    let counting: (Int32) -> ProcessAncestry.ProcessNode? = { pid in
        lookupCount += 1
        return lookup(table)(pid)
    }
    #expect(ProcessAncestry.findAgent(from: 10, maxDepth: 8, lookup: counting) == nil)
    #expect(lookupCount == 2)
}

@Test func readsRealProcessInfoForSelf() {
    let me = ProcessAncestry.info(for: getpid())
    #expect(me != nil)
    #expect(me?.pid == getpid())
    #expect(me?.ppid ?? 0 > 0)
    #expect(!(me?.command.isEmpty ?? true))
}

/// Deterministic real-`sysctl(KERN_PROCARGS2)` coverage that always
/// executes, regardless of what other processes happen to be running:
/// compares our own argv0 reader against Swift's own `CommandLine.arguments`
/// for this exact process. Unlike the scripted-table tests, this exercises
/// the real kernel buffer and the real parser end to end.
@Test func argv0NameMatchesOwnCommandLineArguments() {
    let expected = CommandLine.arguments.first.map(ProcessAncestry.lastPathComponent)
    #expect(expected != nil)
    #expect(ProcessAncestry.info(for: getpid())?.argv0Name == expected)
}

// MARK: - Regression tests for the p_comm-vs-argv0 defect
//
// Claude Code overwrites p_comm with its own version string (observed live:
// "2.1.220"), so matching on p_comm alone finds zero real Claude Code
// sessions. argv[0] is unaffected. These tests fail against the old
// p_comm-only matching code.

@Test func findsAgentWhenPCommIsAVersionStringButArgv0IsClaude() {
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        100: (200, "sh", nil),
        200: (300, "2.1.220", "claude"),
        300: (1, "zsh", "zsh"),
    ]
    let agent = ProcessAncestry.findAgent(from: 100, maxDepth: 8, lookup: lookup(table))
    #expect(agent?.pid == 200)
    #expect(agent?.agentName == "claude")
}

@Test func matchesArgv0BasenameNotFullPath() {
    // argv[0] can be a full path (observed for ChatGPT's bundled codex
    // binary: "/Applications/ChatGPT.app/Contents/Resources/codex"); only
    // the last path component should be matched.
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        10: (20, "sh", nil),
        20: (1, "ChatGPT", "/Applications/ChatGPT.app/Contents/Resources/codex"),
    ]
    let agent = ProcessAncestry.findAgent(from: 10, maxDepth: 8, lookup: lookup(table))
    #expect(agent?.pid == 20)
    #expect(agent?.argv0Name == "codex")
}

@Test func fallsBackToPCommWhenArgv0Unavailable() {
    // argv0 read can fail (permissions, a race with exec). p_comm remains a
    // usable fallback when it happens to still say "claude"/"codex".
    let table: [Int32: (ppid: Int32, command: String, argv0: String?)] = [
        10: (20, "sh", nil),
        20: (1, "claude", nil),
    ]
    let agent = ProcessAncestry.findAgent(from: 10, maxDepth: 8, lookup: lookup(table))
    #expect(agent?.pid == 20)
}

/// Finds a real live "claude" or "codex" process (if any is running on this
/// machine right now) and asserts `findAgent` locates it via its real argv0,
/// exercising the actual `sysctl(KERN_PROCARGS2)` code path end to end. This
/// is the test whose absence let the original p_comm-only defect through
/// review: every other test here scripts the process table, so none of them
/// would have caught a live-data assumption (like "p_comm equals argv[0]")
/// that only breaks against the real kernel.
@Test func findsRealRunningAgentProcess() {
    // `pgrep -x` matches macOS's reported short name for the process, which
    // (empirically, on this machine) still resolves live Claude Code and
    // Codex sessions to candidate pids even though raw p_comm does not.
    func candidatePids(_ name: String) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0) }
    }

    let candidates = candidatePids("claude") + candidatePids("codex")

    // Confirm against our OWN argv0 reader, not just pgrep's say-so — pgrep
    // may use a different name source than the sysctl call this fix relies
    // on. Require argv0Name specifically (not the fallback-satisfiable
    // `agentName`), so this proves argv[0] parsing worked, not just that
    // p_comm happened to match.
    guard let pid = candidates.first(where: { pid in
        guard let node = ProcessAncestry.info(for: pid) else { return false }
        return node.argv0Name.map(ProcessAncestry.agentNames.contains) ?? false
    }) else {
        // No agent process running right now: skip gracefully rather than
        // failing. (Ran on this machine during development with live Claude
        // Code sessions present, so the assertion below did execute then.)
        return
    }

    let agent = ProcessAncestry.findAgent(from: pid)
    #expect(agent != nil)
    #expect(agent?.pid == pid)
    #expect(agent?.argv0Name.map(ProcessAncestry.agentNames.contains) == true)
}

// MARK: - parseArgv0 buffer-parsing edge cases
//
// These exercise the KERN_PROCARGS2 byte layout directly, independent of
// sysctl, so malformed-buffer handling doesn't depend on any live process.

@Test func parseArgv0ReturnsNilForTruncatedHeader() {
    // Fewer than 4 bytes: argc itself isn't fully present.
    #expect(ProcessAncestry.parseArgv0(from: [1, 0], length: 2) == nil)
}

@Test func parseArgv0ReturnsNilWhenNoNulTerminatorExists() {
    let argc: [UInt8] = [1, 0, 0, 0]
    let noNul = Array("AAAAAAAAAA".utf8) // no NUL byte anywhere after argc
    let buffer = argc + noNul
    #expect(ProcessAncestry.parseArgv0(from: buffer, length: buffer.count) == nil)
}

@Test func parseArgv0ReturnsNilWhenArgcIsZero() {
    // A buffer claiming zero arguments must not yield an argv[0], even if
    // well-formed path/argv0 bytes happen to follow.
    let argc: [UInt8] = [0, 0, 0, 0]
    let path = Array("/bin/sh".utf8) + [0]
    let argv0 = Array("sh".utf8) + [0]
    let buffer = argc + path + argv0
    #expect(ProcessAncestry.parseArgv0(from: buffer, length: buffer.count) == nil)
}

@Test func parseArgv0ReturnsNilWhenArgv0IsEmpty() {
    // argc says there's an argument, but nothing remains after the
    // executable path's terminator within the valid region.
    let argc: [UInt8] = [1, 0, 0, 0]
    let path = Array("/bin/sh".utf8) + [0] // terminator is the last valid byte
    let buffer = argc + path
    #expect(ProcessAncestry.parseArgv0(from: buffer, length: buffer.count) == nil)
}

@Test func parseArgv0DoesNotReadPastReportedLengthIntoZeroFilledPadding() {
    // Exact shape of the sysctl-shrinks-between-calls bug: the allocated
    // buffer is zero-filled and oversized, but only the first `length`
    // bytes are real data. Parsing bounded by `buffer.count` instead of
    // `length` would treat the untouched zero tail as a synthetic NUL
    // terminator and silently return a wrong/truncated name ("abcd")
    // instead of nil. This test fails against that old behavior.
    let argc: [UInt8] = [1, 0, 0, 0] // offsets 0-3
    let path: [UInt8] = [88, 0] // offsets 4-5: "X\0"
    let truncatedArgv0 = Array("abcd".utf8) // offsets 6-9: no terminator within the valid region
    var buffer = argc + path + truncatedArgv0 // 10 real bytes
    buffer += Array(repeating: 0, count: 10) // 10 more zero-filled but INVALID bytes (over-allocation)
    #expect(buffer.count == 20)
    #expect(ProcessAncestry.parseArgv0(from: buffer, length: 10) == nil)
}
