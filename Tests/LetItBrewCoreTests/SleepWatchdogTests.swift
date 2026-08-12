import Testing
import Foundation
import Darwin
@testable import LetItBrewCore

// MARK: - Basics: pid watching, backgrounding, escaping

@Test func watchdogCommandWatchesTheAppPID() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 4242, leasePath: "/tmp/lease")
    #expect(command.contains("kill -0 4242"))
}

@Test func watchdogCommandIsBackgroundedAndDetached() {
    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.hasSuffix("&"))
    #expect(command.contains("</dev/null"))
}

@Test func appleScriptEscapingProtectsQuotesAndBackslashes() {
    #expect(OsascriptSleepWatchdog.appleScriptEscaped(#"say "hi""#) == #"say \"hi\""#)
    #expect(OsascriptSleepWatchdog.appleScriptEscaped(#"a\b"#) == #"a\\b"#)
    // Backslashes must be escaped before quotes, or the escape itself breaks.
    #expect(OsascriptSleepWatchdog.appleScriptEscaped(#"\""#) == #"\\\""#)
}

@Test func appleScriptComposedScriptRoundTripsToTheOriginalCommand() throws {
    // Covers quoting through the FULL shell -> AppleScript composition, not
    // just one occurrence in isolation: escape the real generated command,
    // wrap it exactly as `start(appPID:)` does, then reverse AppleScript's
    // string-literal escaping (quotes first, then backslashes — the exact
    // inverse order of `appleScriptEscaped`) and confirm it reconstructs the
    // original command byte for byte.
    let original = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: "/tmp/o'brien \"x\" `cmd`/flag", appPID: 99, leasePath: "/tmp/l ease")
    let escaped = OsascriptSleepWatchdog.appleScriptEscaped(original)
    let composed = "do shell script \"\(escaped)\" with administrator privileges"

    let prefix = "do shell script \""
    let suffix = "\" with administrator privileges"
    #expect(composed.hasPrefix(prefix))
    #expect(composed.hasSuffix(suffix))
    let inner = String(composed.dropFirst(prefix.count).dropLast(suffix.count))
    let unescaped = inner
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    #expect(unescaped == original)
}

// MARK: - Quoting: every occurrence of every path, with hostile characters

@Test func watchdogCommandSingleQuotesEveryFlagPathOccurrence() {
    // Single quote, double quote, backslash, space, backtick, newline.
    let nasty = "/tmp/o'brien \"x\" `cmd` \\slash\nline/flag"
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: nasty, appPID: 1, leasePath: "/tmp/lease")
    let quoted = ClaudeHooks.shellSingleQuoted(nasty)
    let occurrences = command.components(separatedBy: quoted).count - 1
    // The `-e` presence check and both `rm -f` cleanup sites (confirmed-
    // restore exit branch and never-owned exit branch).
    #expect(occurrences == 3)
}

@Test func watchdogCommandSingleQuotesEveryLeasePathOccurrence() {
    let nasty = "/tmp/l'ease \"x\" `cmd` \\slash\nline/lease"
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: nasty)
    let leaseQuoted = ClaudeHooks.shellSingleQuoted(nasty)
    let debtQuoted = ClaudeHooks.shellSingleQuoted(nasty + "/debt")
    let debtTmpQuoted = ClaudeHooks.shellSingleQuoted(nasty + "/debt.tmp")
    #expect(command.components(separatedBy: leaseQuoted).count - 1 == 5)
    #expect(command.components(separatedBy: debtQuoted).count - 1 == 1)
    #expect(command.components(separatedBy: debtTmpQuoted).count - 1 == 2)
}

// MARK: - Behavioral shape: prior-value restore, edge-triggering, ordering
//
// These check the STRUCTURE that makes the loop safe rather than word
// presence, so an edit that keeps every substring below but drops a guard
// would still be caught by the harness tests further down.

@Test func watchdogCommandCapturesThePriorValueBeforeEngaging() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.contains("p=$(read_disabled)"))
    #expect(command.contains("owned=1; prior=$p"))
}

@Test func watchdogCommandNeverRestoresToAHardcodedZero() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    let restoreCalls = command.components(separatedBy: #"do_write "$prior""#).count - 1
    #expect(restoreCalls == 2)  // mid-loop release + exit-path restore
    #expect(!command.contains("do_write 0"))
}

@Test func watchdogCommandOnlyEverAttemptsOneEngageCallPerRisingEdge() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.components(separatedBy: "do_write 1").count - 1 == 1)
    #expect(command.contains(#"if [ "$owned" -eq 0 ]; then"#))
}

@Test func watchdogCommandGuardsTheMidLoopReleaseOnOwnership() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.contains(#"elif [ "$owned" -eq 1 ]; then"#))
}

@Test func watchdogCommandExitPathGuardsRestoreOnOwnershipAfterTheLoopEnds() throws {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    let doneRange = try #require(command.range(of: "done"))
    let afterLoop = command[doneRange.upperBound...]
    #expect(afterLoop.contains(#"if [ "$owned" -eq 1 ]; then"#))
    #expect(afterLoop.contains(#"do_write "$prior""#))
}

@Test func watchdogCommandWritesTheDebtRecordBeforeEngagingPmset() throws {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    let debtWriteRange = try #require(command.range(of: "mv "))
    let engageRange = try #require(command.range(of: "do_write 1"))
    #expect(debtWriteRange.upperBound < engageRange.lowerBound)
}

@Test func watchdogCommandBindsAppLivenessToPidAndStartTimeNotBareKillZero() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 4242, leasePath: "/tmp/lease")
    let startTimeReads = command.components(separatedBy: "ps -o lstart= -p 4242").count - 1
    #expect(startTimeReads == 2)  // captured once, re-checked in the loop condition
    #expect(command.contains(#"[ "$(ps -o lstart= -p 4242 2>/dev/null)" = "$app_start" ]"#))
}

// MARK: - New Critical: mkdir-based exclusive lease

@Test func watchdogCommandTakesAnAtomicExclusiveLeaseBeforeWritingAnyDebt() throws {
    // `mkdir` on a fixed path is atomic on POSIX: it fails if the directory
    // already exists, with no race window. The debt write (and everything
    // after it) is gated on `mkdir` succeeding via `&&`.
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.components(separatedBy: "mkdir ").count - 1 == 1)
    let mkdirRange = try #require(command.range(of: "mkdir "))
    let debtWriteRange = try #require(command.range(of: "printf 'app_pid=%s"))
    #expect(mkdirRange.upperBound < debtWriteRange.lowerBound)
    #expect(command.contains("&& mkdir"))  // engage is refused, not attempted, without a readable prior
}

@Test func watchdogCommandRecordsTheWatchdogsOwnIdentityNotOnlyTheAppsPid() {
    // The debt marker must carry the WATCHDOG loop's own pid ($$) and start
    // time, not just the app's — the watchdog is the thing that can die and
    // strand the flag, and detecting that requires watching IT.
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 4242, leasePath: "/tmp/lease")
    #expect(command.contains("watchdog_start=$(ps -o lstart= -p $$ 2>/dev/null)"))
    #expect(command.contains("watchdog_pid=%s"))
    #expect(command.contains(#""$$" "$watchdog_start""#))
}

// MARK: - Critical 2: three-way read (enabled / disabled / unreadable)

@Test func readDisabledChecksPmsetsExitStatusRatherThanInferringFromEmptyOutput() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.contains(#"out=$('/usr/bin/pmset' -g 2>/dev/null) || return 1"#))
}

@Test func readDisabledOnlyEverPrintsZeroOrOneNeverGuessingOnAnUnexpectedValue() {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.contains(#"case "$v" in"#))
    #expect(command.contains("0|1) printf '%s' \"$v\" ;;"))
}

@Test func engageOnlyReleasesWhenTheReadBackMatchesPriorAndPriorWasZero() throws {
    // Round 3 fix: releasing requires the read-back to equal the RECORDED
    // PRIOR (`$p`), not a hardcoded "0" — AND requires prior itself to have
    // been "0". Both conjuncts are load-bearing:
    //   - Dropping "$v" = "$p" reintroduces the exact bug the review named:
    //     with prior=1 and a read-back of 0, the old bare `"$v" = "0"` check
    //     released anyway, destroying the only record that a restore to 1
    //     was owed.
    //   - Dropping "$p" = "0" makes a prior of "1" release as soon as its
    //     read-back trivially reconfirms "1", which re-opens the
    //     `if owned == 0` branch on the very next cycle while the flag is
    //     still present — verified empirically to turn the loop
    //     level-triggered (a full mkdir/write/pmset/release every single
    //     poll cycle) instead of edge-triggered.
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    let ifRange = try #require(
        command.range(of: #"if [ "$v" = "$p" ] && [ "$p" = "0" ]; then"#))
    let after = command[ifRange.upperBound...]
    #expect(after.contains("rm -rf"))
    #expect(after.contains("owned=1; prior=$p"))
    #expect(!command.contains(#"if [ "$v" = "0" ]"#))  // the old, wrong, bare comparison is gone
}

// MARK: - Important 2: shell debt fields validated before commit and pmset

@Test func watchdogCommandValidatesSetAtBeforeMkdirAndBeforeCommittingTheDebt() throws {
    let command = OsascriptSleepWatchdog.watchdogLoopBody(
        flagPath: "/tmp/flag", appPID: 1, leasePath: "/tmp/lease")
    #expect(command.contains(#"setAt=$(date +%s 2>/dev/null)"#))
    #expect(command.contains(#"[ -n "$setAt" ] && mkdir"#))
    #expect(command.contains(#"[ -n "$watchdog_start" ]"#))
    let setAtCaptureRange = try #require(command.range(of: #"setAt=$(date +%s"#))
    let mkdirRange = try #require(command.range(of: "mkdir "))
    let debtWriteRange = try #require(command.range(of: "printf 'app_pid=%s"))
    #expect(setAtCaptureRange.upperBound < mkdirRange.lowerBound)
    #expect(mkdirRange.upperBound < debtWriteRange.lowerBound)
    // The committed debt uses the VALIDATED variable, never a fresh,
    // unvalidated inline `$(date +%s)` at commit time.
    #expect(!command.contains(#""$p" "$(date +%s)""#))
    // Important 2's second gap: non-empty alone isn't enough — the loader
    // parses setAt as a number, so a nonnumeric (but non-empty) `date`
    // output must be cleared back to empty before the `-n` check runs.
    let sanitizeRange = try #require(
        command.range(of: #"case "$setAt" in ''|*[!0-9]*) setAt= ;; esac"#))
    #expect(setAtCaptureRange.upperBound < sanitizeRange.lowerBound)
    #expect(sanitizeRange.upperBound < mkdirRange.lowerBound)
}

@Test func harnessRefusesToEngageWhenDateFailsNeverCommittingAnUnvalidatedDebt() throws {
    // Important 2: a failed `date` must never reach the committed debt as an
    // empty `setAt` — `SleepWatchdogDebt.load` would reject it, permanently
    // stranding the recorded prior. The fix validates `setAt` BEFORE the
    // lease is even taken, so this must refuse to engage at all: no lease,
    // no pmset write.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fakeBin = dir.appendingPathComponent("fakebin")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fakeDate = fakeBin.appendingPathComponent("date")
    try "#!/bin/sh\nexit 1\n".write(to: fakeDate, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeDate.path)

    let realPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let ctx = try makeHarness(dir: dir, environment: ["PATH": "\(fakeBin.path):\(realPath)"])
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    try expectNoActionAfterSeveralCycles(ctx)
    #expect(!FileManager.default.fileExists(atPath: ctx.leaseURL.path))  // never even attempted a lease

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessRefusesToEngageWhenDateOutputsNonnumericTextNeverCommittingAnUnparseableSetAt() throws {
    // Important 2's second gap, the one coverage missed: a `date` on PATH
    // that exits 0 but prints something that ISN'T a plain integer (broken
    // or hostile) passed the old bare `[ -n "$setAt" ]` check — non-empty is
    // not the same as numeric. `SleepWatchdogDebt.load` parses setAt as a
    // TimeInterval, so that would commit a debt AFTER pmset is touched that
    // repair can never read, stranding the very prior value it needs. The
    // fix validates setAt is digits-only before ever taking the lease, so
    // this must refuse to engage at all, exactly like the exit-1 case above.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fakeBin = dir.appendingPathComponent("fakebin")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fakeDate = fakeBin.appendingPathComponent("date")
    try "#!/bin/sh\necho not-a-timestamp\nexit 0\n".write(to: fakeDate, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeDate.path)

    let realPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let ctx = try makeHarness(dir: dir, environment: ["PATH": "\(fakeBin.path):\(realPath)"])
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    try expectNoActionAfterSeveralCycles(ctx)
    #expect(!FileManager.default.fileExists(atPath: ctx.leaseURL.path))  // never even attempted a lease

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

// MARK: - Pure classifier: cancellation vs. genuine failure

@Test func classifiesTheCanonicalCancellationCode() {
    #expect(OsascriptSleepWatchdog.isUserCancelledAuthorization(
        stderr: "123:45: execution error: User canceled. (-128)"))
}

@Test func doesNotClassifyFreeTextCancelMentionsAsCancellation() {
    #expect(!OsascriptSleepWatchdog.isUserCancelledAuthorization(
        stderr: "pmset: operation cancelled due to a permissions error"))
    #expect(!OsascriptSleepWatchdog.isUserCancelledAuthorization(
        stderr: "some unrelated failure with code -128 but no parentheses"))
}

// MARK: - start(appPID:): input validation only — never reaches osascript

@Test func startRejectsNonPositivePidsWithoutTouchingOsascript() {
    let watchdog = OsascriptSleepWatchdog(
        flagURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-flag-\(UUID().uuidString)"),
        leaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-lease-\(UUID().uuidString)"))

    for pid: Int32 in [0, -1, -7] {
        switch watchdog.start(appPID: pid) {
        case .failed: break
        case .applied, .cancelled:
            Issue.record("pid \(pid) should have been rejected before touching osascript")
        }
    }
}

// MARK: - Default paths: per-launch flag nonce, stable lease path

@Test func defaultFlagURLIsStableWithinAProcessButNoLongerAFixedName() {
    let first = OsascriptSleepWatchdog.defaultFlagURL
    let second = OsascriptSleepWatchdog.defaultFlagURL
    #expect(first == second)
    #expect(first.lastPathComponent != "sleep-watchdog.flag")
    #expect(first.lastPathComponent.hasSuffix(".flag"))
}

@Test func defaultLeaseURLIsFixedSoALaterRunCanFindIt() {
    let first = OsascriptSleepWatchdog.defaultLeaseURL
    let second = OsascriptSleepWatchdog.defaultLeaseURL
    #expect(first == second)
    #expect(first.lastPathComponent == "sleep-watchdog.lease")
}

// MARK: - Flag lifecycle

@Test func flagLifecycleCreatesAndRemoves() {
    let flag = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-flag-\(UUID().uuidString)/flag")
    let watchdog = OsascriptSleepWatchdog(flagURL: flag)
    defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }

    #expect(!watchdog.isFlagPresent())
    #expect(watchdog.createFlag())
    #expect(watchdog.isFlagPresent())
    #expect(watchdog.removeFlag())
    #expect(!watchdog.isFlagPresent())
}

// MARK: - Critical 2: a failed flag removal must be reported, not forgotten

@Test func removeFlagReportsFailureWhenTheFlagSurvivesRemoval() throws {
    // Forces a REAL, non-thrown removal failure via the BSD user-immutable
    // flag (`chflags uchg`), which blocks unlink even for the owner: `try?`
    // swallows whatever error `removeItem` produces either way, so the only
    // way to prove the flag survives is to make removal genuinely fail and
    // check afterward that the flag is still there — not to trust that some
    // particular error got thrown.
    let flag = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-flag-\(UUID().uuidString)")
    try Data().write(to: flag)
    func chflags(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
    }
    chflags(["uchg", flag.path])
    defer {
        chflags(["nouchg", flag.path])
        try? FileManager.default.removeItem(at: flag)
    }

    let watchdog = OsascriptSleepWatchdog(flagURL: flag)
    #expect(watchdog.isFlagPresent())
    #expect(!watchdog.removeFlag())
    #expect(watchdog.isFlagPresent())  // still there — nothing was silently forgotten
}

@Test func removeFlagTreatsAnInaccessibleStatAsFailureNotAsAbsence() throws {
    // CRITICAL 2, the coverage gap: the old `removeFlag` inferred success
    // from `fileExists`, which returns false on ANY stat failure — not just
    // genuine absence. Locking the flag's PARENT directory (0o000, as its
    // owner, no root involved) makes both the removal AND a `fileExists`
    // stat fail the same way a permissions problem would in the wild. The
    // old code would have read that failed stat as "gone" and reported
    // success; the fix must derive success from the removal attempt's own
    // outcome, not a second, separately-fallible stat.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-flag-locked-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let flag = dir.appendingPathComponent("flag")
    try Data().write(to: flag)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    let watchdog = OsascriptSleepWatchdog(flagURL: flag)
    #expect(!watchdog.removeFlag())  // must report FAILURE, not silently succeed
}

@Test func createFlagIsIdempotent() {
    let flag = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-flag-\(UUID().uuidString)/flag")
    let watchdog = OsascriptSleepWatchdog(flagURL: flag)
    defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }

    #expect(watchdog.createFlag())
    #expect(watchdog.createFlag())
    #expect(watchdog.isFlagPresent())
}

// MARK: - SleepWatchdogDebt: on-disk marker parsing, fail-closed

private let sampleDebtText =
    "app_pid=4242\nwatchdog_pid=55\nwatchdog_start=Thu Jan  1 00:00:00 1970\nprior=1\nsetAt=1700000000\n"

@Test func debtRoundTripsThroughTheOnDiskMarkerFormat() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try sampleDebtText.write(to: url, atomically: true, encoding: .utf8)

    let debt = try #require(SleepWatchdogDebt.load(from: url))
    #expect(debt.appPID == 4242)
    #expect(debt.watchdogPID == 55)
    #expect(debt.watchdogStartedAt == "Thu Jan  1 00:00:00 1970")
    #expect(debt.priorValue == true)
    #expect(debt.setAt == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func debtFailsClosedOnAMissingFile() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)")
    #expect(SleepWatchdogDebt.load(from: url) == nil)
}

@Test func debtFailsClosedOnAMalformedPriorValue() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = sampleDebtText.replacingOccurrences(of: "prior=1", with: "prior=maybe")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(SleepWatchdogDebt.load(from: url) == nil)
}

@Test func debtFailsClosedOnAMissingField() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try "app_pid=1\nprior=0\n".write(to: url, atomically: true, encoding: .utf8)  // no watchdog fields, no setAt
    #expect(SleepWatchdogDebt.load(from: url) == nil)
}

@Test func debtFailsClosedOnANonPositiveAppPID() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = sampleDebtText.replacingOccurrences(of: "app_pid=4242", with: "app_pid=0")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(SleepWatchdogDebt.load(from: url) == nil)
}

@Test func debtFailsClosedOnANonPositiveWatchdogPID() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("debt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = sampleDebtText.replacingOccurrences(of: "watchdog_pid=55", with: "watchdog_pid=-3")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(SleepWatchdogDebt.load(from: url) == nil)
}

// MARK: - SleepWatchdogDebtCheck: detection bound to the WATCHDOG's identity
//
// The marker records the watchdog loop's own pid + start time (not just the
// app's), and liveness must be checked against that — a live app with a
// dead loop must report `.orphaned`, not `.held`.

@Test func debtStatusIsNoneWithoutALeaseOnDisk() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)")
    #expect(SleepWatchdogDebtCheck.status(at: url, isWatchdogAlive: { _, _ in true }) == .none)
}

@Test func debtStatusIsUnreadableWhenTheLeaseExistsButTheRecordDoesNot() throws {
    // A lease directory with no (or a malformed) debt file inside is
    // dangerous, not clean — it must be surfaced, never silently `.none`.
    let leaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: leaseURL) }

    let status = SleepWatchdogDebtCheck.status(at: leaseURL, isWatchdogAlive: { _, _ in true })
    #expect(status == .unreadable)
}

@Test func debtStatusIsUnreadableWhenTheRecordIsMalformed() throws {
    let leaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: leaseURL) }
    try "garbage, not key=value at all".write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let status = SleepWatchdogDebtCheck.status(at: leaseURL, isWatchdogAlive: { _, _ in true })
    #expect(status == .unreadable)
}

@Test func debtStatusIsHeldWhenTheWatchdogIdentityMatches() throws {
    let leaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: leaseURL) }
    try sampleDebtText.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let status = SleepWatchdogDebtCheck.status(
        at: leaseURL,
        isWatchdogAlive: { pid, start in pid == 55 && start == "Thu Jan  1 00:00:00 1970" })
    guard case .held(let debt) = status else {
        Issue.record("expected .held, got \(status)")
        return
    }
    #expect(debt.watchdogPID == 55)
}

@Test func debtStatusIsOrphanedWhenTheWatchdogIdentityDoesNotMatch() throws {
    // This is the exact false-negative the review flagged: even if
    // something else with that pid is alive (e.g. the pid was reused, or a
    // caller mistakenly checks the app's pid instead), a mismatched start
    // time must still report `.orphaned`.
    let leaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: leaseURL) }
    try sampleDebtText.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let status = SleepWatchdogDebtCheck.status(at: leaseURL, isWatchdogAlive: { _, _ in false })
    guard case .orphaned(let debt) = status else {
        Issue.record("expected .orphaned, got \(status)")
        return
    }
    #expect(debt.watchdogPID == 55)
}

@Test func defaultIsWatchdogAliveRejectsNonPositivePids() {
    // Defense in depth at the liveness boundary too, matching the same
    // guard `start(appPID:)` and `KillZeroLiveness` already apply.
    #expect(!SleepWatchdogDebtCheck.defaultIsWatchdogAlive(pid: 0, expectedStart: "anything"))
    #expect(!SleepWatchdogDebtCheck.defaultIsWatchdogAlive(pid: -1, expectedStart: "anything"))
}

@Test func defaultIsWatchdogAliveMatchesTheRealCurrentProcess() {
    // End-to-end against the real `ps`/`kill` (unprivileged): this process
    // is alive and its own start time, read twice, must agree with itself.
    let pid = getpid()
    guard let start = SleepWatchdogDebtCheck.currentProcessStartTime(pid: pid) else {
        Issue.record("could not read this process's own start time via ps")
        return
    }
    #expect(SleepWatchdogDebtCheck.defaultIsWatchdogAlive(pid: pid, expectedStart: start))
    #expect(!SleepWatchdogDebtCheck.defaultIsWatchdogAlive(pid: pid, expectedStart: "not the real start time"))
}

// MARK: - Hermetic, unprivileged, behavioral harness
//
// Runs the REAL generated shell text as an ordinary (never elevated) child
// process, with `pmset` replaced by a recording stub and a fast poll
// interval, and asserts the RECORDED ACTIONS — not the script text. This
// never uses osascript, administrator privileges, sudo, or the real
// `/usr/bin/pmset`; the stub only ever writes to files inside a throwaway
// temp directory, and any process killed here is one this test itself
// spawned as an ordinary child.
//
// Every read here is exact: `log()` and `heartbeatCount()` throw on any
// error other than "the file does not exist yet" (a legitimate, expected
// state before the first write) — nothing is silently swallowed into an
// empty result that could make a "nothing happened" assertion pass for the
// wrong reason. Negative assertions ("never engages") are gated on the
// heartbeat advancing by several full loop cycles first: without that, a
// negative check could pass merely because the worker never ran during a
// short observation window, which is a false pass no timeout fixes.

/// A fake `pmset` that logs every `-a disablesleep N` call, persists state
/// for `-g` reads to mimic real `pmset -g` (a `SleepDisabled` line only
/// appears when it's 1), and can be told to fail or lie in four distinct
/// ways:
/// - `failURL`: `-a` writes are logged but never take effect (simulates a
///   write silently not taking effect).
/// - `unreadableURL`: every `-g` call fails outright (nonzero exit, no
///   output) — simulates `pmset -g` itself being unreadable.
/// - `failOnCallURL`: contains a 1-based call NUMBER; only that specific
///   `-g` invocation fails, letting a test target one exact read (e.g. an
///   engage's own confirm read) without disturbing any other read.
/// - `forceZeroOnCallURL`: contains a 1-based call NUMBER; only that
///   specific `-g` invocation reports "0" REGARDLESS of the real state —
///   lets a test make one exact read diverge from what was just recorded
///   (e.g. an engage confirm reading "0" right after a prior of "1").
private struct PMSetStub {
    let scriptURL: URL
    let logURL: URL
    let stateURL: URL
    let failURL: URL
    let unreadableURL: URL
    let failOnCallURL: URL
    let forceZeroOnCallURL: URL

    static func make(in dir: URL) throws -> PMSetStub {
        let scriptURL = dir.appendingPathComponent("pmset-stub.sh")
        let logURL = dir.appendingPathComponent("log")
        let stateURL = dir.appendingPathComponent("state")
        let failURL = dir.appendingPathComponent("fail")
        let unreadableURL = dir.appendingPathComponent("unreadable")
        let failOnCallURL = dir.appendingPathComponent("fail-on-call")
        let forceZeroOnCallURL = dir.appendingPathComponent("force-zero-on-call")
        let callCountURL = dir.appendingPathComponent("call-count")
        let script = """
            #!/bin/sh
            if [ "$1" = "-g" ]; then
              n=$(( $(cat '\(callCountURL.path)' 2>/dev/null || echo 0) + 1 ))
              echo "$n" > '\(callCountURL.path)'
              if [ -e '\(unreadableURL.path)' ]; then exit 1; fi
              target=$(cat '\(failOnCallURL.path)' 2>/dev/null)
              if [ -n "$target" ] && [ "$n" = "$target" ]; then exit 1; fi
              zeroTarget=$(cat '\(forceZeroOnCallURL.path)' 2>/dev/null)
              if [ -n "$zeroTarget" ] && [ "$n" = "$zeroTarget" ]; then exit 0; fi
              v=$(cat '\(stateURL.path)' 2>/dev/null)
              if [ "$v" = "1" ]; then printf 'SleepDisabled\\t1\\n'; fi
              exit 0
            fi
            if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
              echo "SET $3" >> '\(logURL.path)'
              if [ -e '\(failURL.path)' ]; then exit 1; fi
              printf '%s' "$3" > '\(stateURL.path)'
              exit 0
            fi
            exit 1
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return PMSetStub(
            scriptURL: scriptURL, logURL: logURL, stateURL: stateURL, failURL: failURL,
            unreadableURL: unreadableURL, failOnCallURL: failOnCallURL,
            forceZeroOnCallURL: forceZeroOnCallURL)
    }

    /// Throws on any read failure OTHER than the log not existing yet (the
    /// normal, expected state before the first `pmset -a` call).
    func log() throws -> [String] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        let text = try String(contentsOf: logURL, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }
}

/// Default 30s: generous under machine load, since the loop cycles at
/// `pollInterval` (well under a second) in the common case — this is a
/// ceiling, not a fixed sleep.
///
/// `condition` is `throws`/`rethrows` rather than swallowing failures
/// internally: a genuine read error (as opposed to "the file doesn't exist
/// yet", which `PMSetStub.log()`/`HarnessContext.heartbeatCount()` already
/// treat as a legitimate empty/zero result) must fail the test immediately,
/// not be silently retried as "condition not yet true" for the full
/// timeout — that is exactly the class of false pass this suite exists to
/// rule out.
private func waitUntil(timeout: TimeInterval = 30, _ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try condition()
}

private struct HarnessContext {
    let dir: URL
    let flagURL: URL
    let leaseURL: URL
    let heartbeatURL: URL
    let stub: PMSetStub
    let child: Process
    let harness: Process

    /// Throws on any read failure OTHER than the heartbeat not existing yet
    /// (before the loop's first cycle).
    func heartbeatCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: heartbeatURL.path) else { return 0 }
        let text = try String(contentsOf: heartbeatURL, encoding: .utf8)
        return text.split(separator: "\n").count
    }

    func cleanup() {
        if harness.isRunning { harness.terminate() }
        if child.isRunning { child.terminate() }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Spawns a real (but harmless, unprivileged) child process to stand in for
/// the app, and starts the watchdog loop against it with `pmset` replaced
/// by the recording stub and a fast poll interval. `flagURL`/`leaseURL` can
/// be overridden so a test can point the loop at a path that can never be
/// created (a missing parent), or pre-seed a lease before the loop starts.
private func makeHarness(
    pollInterval: TimeInterval = 0.05,
    dir: URL? = nil,
    flagURL: URL? = nil,
    leaseURL: URL? = nil,
    environment: [String: String]? = nil
) throws -> HarnessContext {
    let dir = try dir ?? {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    let stub = try PMSetStub.make(in: dir)
    let flagURL = flagURL ?? dir.appendingPathComponent("flag")
    let leaseURL = leaseURL ?? dir.appendingPathComponent("lease")
    let heartbeatURL = dir.appendingPathComponent("heartbeat")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 30"]
    try child.run()

    let command = OsascriptSleepWatchdog.watchdogCommand(
        flagPath: flagURL.path, appPID: child.processIdentifier, leasePath: leaseURL.path,
        pmsetPath: stub.scriptURL.path, pollInterval: pollInterval, heartbeatPath: heartbeatURL.path)

    // The generated command backgrounds itself with `&`; appending `wait`
    // makes this outer `sh -c` block until that backgrounded job finishes,
    // so `waitForExit` below has something to wait on.
    let harness = Process()
    harness.executableURL = URL(fileURLWithPath: "/bin/sh")
    harness.arguments = ["-c", command + "\nwait"]
    if let environment { harness.environment = environment }
    try harness.run()

    return HarnessContext(
        dir: dir, flagURL: flagURL, leaseURL: leaseURL, heartbeatURL: heartbeatURL, stub: stub,
        child: child, harness: harness)
}

/// Waits for the harness process to exit. A timeout here is a REAL test
/// failure, not a silently-converted success — a stuck harness usually
/// means the loop's exit condition never fired, which is exactly the kind
/// of regression this suite exists to catch.
private func waitForExit(
    _ process: Process, timeout: TimeInterval = 30,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let completed = waitUntil(timeout: timeout) { !process.isRunning }
    if !completed {
        Issue.record(
            "watchdog harness did not exit within \(timeout)s", sourceLocation: sourceLocation)
    }
    if process.isRunning { process.terminate() }
}

/// Proves the loop actually completed several full cycles (via the
/// heartbeat) BEFORE asserting nothing happened — the false-pass risk the
/// review specifically flagged: a "nothing happened" check that passes
/// merely because the worker never got a turn during a short window.
private func expectNoActionAfterSeveralCycles(
    _ ctx: HarnessContext, minimumCycles: Int = 5, timeout: TimeInterval = 30
) throws {
    let baseline = try ctx.heartbeatCount()
    let advanced = try waitUntil(timeout: timeout) {
        try ctx.heartbeatCount() >= baseline + minimumCycles
    }
    #expect(advanced, "the loop never completed \(minimumCycles) cycles to observe")
    #expect(try ctx.stub.log().isEmpty)
}

@Test func harnessEngagesAndReleasesWhenSleepWasAlreadyEnabled() throws {
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    try? FileManager.default.removeItem(at: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log() == ["SET 1", "SET 0"] })
    #expect(try ctx.stub.log() == ["SET 1", "SET 0"])
    #expect(waitUntil { !FileManager.default.fileExists(atPath: ctx.leaseURL.path) })

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessRestoresToThePriorDisabledValueNotZero() throws {
    // The Critical 1 scenario: sleep was already disabled BY HAND before
    // this run ever engaged. Release must restore to 1, never 0.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try "1".write(to: ctx.stub.stateURL, atomically: true, encoding: .utf8)

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    let debt = try #require(
        SleepWatchdogDebt.load(from: ctx.leaseURL.appendingPathComponent("debt")))
    #expect(debt.priorValue == true)

    try? FileManager.default.removeItem(at: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log() == ["SET 1", "SET 1"] })
    #expect(try ctx.stub.log() == ["SET 1", "SET 1"])  // restored to prior (1), never a hardcoded 0

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessRestoresOnProcessDeathWithoutTheFlagEverBeingRemoved() throws {
    // App death by any route (crash, force-quit, kill -9) must restore
    // sleep even if the app never got to remove its own flag.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    ctx.child.terminate()
    waitForExit(ctx.harness)

    #expect(try ctx.stub.log() == ["SET 1", "SET 0"])
    #expect(!FileManager.default.fileExists(atPath: ctx.leaseURL.path))
}

@Test func harnessNeverEngagesIfTheLeaseCannotBeCreated() throws {
    // Critical 2 / lease mechanics: refuse to engage at all if the lease
    // can't even be `mkdir`'d — never change the system without a
    // recoverable undo record.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ctx = try makeHarness(
        dir: dir, leaseURL: dir.appendingPathComponent("no-such-subdir/lease"))
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    try expectNoActionAfterSeveralCycles(ctx)

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessIgnoresAStaleFlagLeftAtADifferentPathByACrashedRun() throws {
    // Important 1: a leftover flag from a crashed run must not make a NEW
    // watchdog disable sleep though the new run never asked. The per-launch
    // nonce baked into `defaultFlagURL` guarantees every run watches its own
    // distinct path — this exercises that property end to end.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("old-run-abc123.flag"))

    let ctx = try makeHarness(dir: dir, flagURL: dir.appendingPathComponent("this-run-xyz789.flag"))
    defer { ctx.cleanup() }

    try expectNoActionAfterSeveralCycles(ctx)

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessRefusesToEngageWhileAnotherLeaseAlreadyExists() throws {
    // The NEW Critical: run A engaged, recorded prior=0, and was orphaned
    // (crashed) without ever releasing — its lease is still on disk. Run B
    // must NEVER overwrite it, even though B's own read of the current
    // state (1, simulating disablesleep left stuck on by A) differs from
    // what's already recorded.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-watchdog-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let leaseURL = dir.appendingPathComponent("lease")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    let staleDebtText =
        "app_pid=1\nwatchdog_pid=2\nwatchdog_start=Thu Jan  1 00:00:00 1970\nprior=0\nsetAt=1700000000\n"
    try staleDebtText.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let ctx = try makeHarness(dir: dir, leaseURL: leaseURL)
    defer { ctx.cleanup() }

    try "1".write(to: ctx.stub.stateURL, atomically: true, encoding: .utf8)
    try Data().write(to: ctx.flagURL)
    try expectNoActionAfterSeveralCycles(ctx)  // run B must never call pmset at all

    // Run A's original debt record must be completely untouched.
    let debt = try #require(
        SleepWatchdogDebt.load(from: leaseURL.appendingPathComponent("debt")))
    #expect(debt.priorValue == false)  // still A's prior — not clobbered by B's read of 1
    #expect(debt.watchdogPID == 2)  // still A's watchdog identity, not B's

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessRefusesToEngageWhenTheInitialReadIsUnreadable() throws {
    // Critical 2: an unreadable initial read must never be guessed at.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try Data().write(to: ctx.stub.unreadableURL)  // pmset -g always fails
    try Data().write(to: ctx.flagURL)
    try expectNoActionAfterSeveralCycles(ctx)
    #expect(!FileManager.default.fileExists(atPath: ctx.leaseURL.path))  // never even attempted a lease

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessKeepsTheDebtWhenTheReleaseReadBackIsUnreadable() throws {
    // Critical 2: an unreadable read-back during release must be treated as
    // NOT confirmed — never falsely "confirms" success and clears the debt.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    try Data().write(to: ctx.stub.unreadableURL)  // pmset -g starts failing
    try? FileManager.default.removeItem(at: ctx.flagURL)  // trigger a release attempt

    let baseline = try ctx.heartbeatCount()
    #expect(try waitUntil { try ctx.heartbeatCount() >= baseline + 5 })  // several retries
    #expect(FileManager.default.fileExists(atPath: ctx.leaseURL.path))  // debt survives
    let debtDuringOutage = try #require(
        SleepWatchdogDebt.load(from: ctx.leaseURL.appendingPathComponent("debt")))
    #expect(debtDuringOutage.priorValue == false)
    // The first action is the engage; every retry AFTER it during the
    // outage attempted the SAME correct restore action — no wrong action
    // ever snuck in while confirmation was unavailable.
    let logDuringOutage = try ctx.stub.log()
    try #require(logDuringOutage.count > 1)  // proves retries actually happened
    #expect(logDuringOutage[0] == "SET 1")
    #expect(logDuringOutage.dropFirst().allSatisfy { $0 == "SET 0" })

    try? FileManager.default.removeItem(at: ctx.stub.unreadableURL)  // pmset -g recovers
    #expect(waitUntil { !FileManager.default.fileExists(atPath: ctx.leaseURL.path) })
    let finalLog = try ctx.stub.log()
    try #require(finalLog.count > 1)
    #expect(finalLog[0] == "SET 1")
    #expect(finalLog.dropFirst().allSatisfy { $0 == "SET 0" })

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessCommitsAnEngageEvenWhenItsOwnConfirmReadIsUnreadable() throws {
    // Critical 2's third, worst consequence: a SUCCESSFUL engage followed by
    // an unreadable read-back must NOT fall into a "failed engage" cleanup
    // that deletes the debt — that would leave the system possibly at 1
    // with NO record of it. The 1st `-g` call is the initial prior read
    // (must succeed); the 2nd is the engage's own confirm read — target
    // exactly that one call to fail, deterministically, via the stub's
    // one-shot call-count mechanism (a plain sentinel can't isolate a
    // single call within one loop iteration).
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try "2".write(to: ctx.stub.failOnCallURL, atomically: true, encoding: .utf8)

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    let debt = try #require(
        SleepWatchdogDebt.load(from: ctx.leaseURL.appendingPathComponent("debt")))
    #expect(debt.priorValue == false)  // the debt survived the unreadable confirm

    try? FileManager.default.removeItem(at: ctx.flagURL)
    #expect(waitUntil { !FileManager.default.fileExists(atPath: ctx.leaseURL.path) })
    #expect(try ctx.stub.log() == ["SET 1", "SET 0"])  // and it still completes normally afterward

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func harnessKeepsTheLeaseWhenEngageConfirmReadsBackZeroWithPriorOne() throws {
    // The exact discriminating scenario from the round-3 review: prior=1 is
    // recorded (sleep was already disabled by hand), but the engage's OWN
    // confirm read comes back "0" — diverging from what was just recorded.
    // The old code compared the confirm read to a hardcoded "0" and
    // released whenever it matched, destroying the only record that a
    // restore to 1 was owed. The lease and debt must SURVIVE this, with
    // prior=1 intact, and the loop must still complete normally afterward.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try "1".write(to: ctx.stub.stateURL, atomically: true, encoding: .utf8)  // prior=1
    // 1st `-g` call = the initial prior read (must see the real state, 1).
    // 2nd `-g` call = the engage's own confirm read — force it to "0",
    // regardless of the real (unchanged) state, via the stub's dedicated
    // one-shot override (a plain sentinel can't isolate a single call).
    try "2".write(to: ctx.stub.forceZeroOnCallURL, atomically: true, encoding: .utf8)

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    #expect(FileManager.default.fileExists(atPath: ctx.leaseURL.path))  // lease survives
    let debt = try #require(
        SleepWatchdogDebt.load(from: ctx.leaseURL.appendingPathComponent("debt")))
    #expect(debt.priorValue == true)  // still records the correct prior (1), untouched

    // And it still completes normally afterward: release restores to 1.
    try? FileManager.default.removeItem(at: ctx.flagURL)
    #expect(waitUntil { !FileManager.default.fileExists(atPath: ctx.leaseURL.path) })
    #expect(try ctx.stub.log() == ["SET 1", "SET 1"])

    ctx.child.terminate()
    waitForExit(ctx.harness)
}

@Test func debtStatusReportsOrphanedWhenTheWatchdogLoopDiesButTheAppStaysAlive() throws {
    // The exact false-negative the review flagged: liveness bound to the
    // APP's pid would report `.held` here, because the app never dies in
    // this scenario — only its watchdog loop does. Bound to the watchdog's
    // own identity, the detector must report `.orphaned`.
    let ctx = try makeHarness()
    defer { ctx.cleanup() }

    try Data().write(to: ctx.flagURL)
    #expect(try waitUntil { try ctx.stub.log().contains("SET 1") })

    let debt = try #require(
        SleepWatchdogDebt.load(from: ctx.leaseURL.appendingPathComponent("debt")))
    #expect(kill(ctx.child.processIdentifier, 0) == 0)  // the "app" is alive

    // While the loop is genuinely alive, the real (unprivileged) detector
    // must report `.held`.
    #expect(waitUntil { SleepWatchdogDebtCheck.status(at: ctx.leaseURL) == .held(debt) })

    // Kill ONLY the watchdog subshell — identified by its own recorded pid,
    // never the app's — leaving the app process untouched. This is an
    // ordinary, unprivileged signal to a process this test itself spawned
    // (indirectly, as a descendant of the harness), same as `kill -9` from
    // a shell; nothing here touches pmset, osascript, or sudo.
    #expect(kill(debt.watchdogPID, SIGKILL) == 0)
    #expect(waitUntil { kill(debt.watchdogPID, 0) != 0 })  // confirmed dead
    #expect(kill(ctx.child.processIdentifier, 0) == 0)  // the app is STILL alive

    let status = SleepWatchdogDebtCheck.status(at: ctx.leaseURL)
    guard case .orphaned(let orphanedDebt) = status else {
        Issue.record("expected .orphaned (app alive, watchdog dead), got \(status)")
        return
    }
    #expect(orphanedDebt.watchdogPID == debt.watchdogPID)

    ctx.child.terminate()
}

// MARK: - repairCommand: the privileged repair predicate
//
// `letitbrew repair` runs this command (via administrator privileges in
// production, never exercised here) against a lease whose owner is provably
// dead. Every one of these tests runs the REAL generated shell text,
// unprivileged, against the same recording `pmset` stub the harness tests
// above use — no osascript, no sudo, no privilege elevation anywhere in this
// file. Three prior review rounds each broke this predicate in a different
// direction (refuse on any debt at all; treat mere readability as nothing
// owed; grep for a numeric pid instead of a real liveness check), so these
// tests exercise each of the three cases (A: live unreadable, B: debt
// readable, C: debt unreadable) plus the exact readable-debt-with-a-changed-
// live-value regression named below.

private let readableDeadWatchdogPriorZero =
    // watchdog_pid 999999 + a 1970 start time can never match a real
    // process: `kill -0` might in principle find SOME process reusing that
    // pid, but it can never also have started in 1970, so the identity
    // check always reports this watchdog as dead regardless of what's
    // running on the machine that executes this test.
    "app_pid=1\nwatchdog_pid=999999\nwatchdog_start=Thu Jan  1 00:00:00 1970\nprior=0\nsetAt=1700000000\n"
private let readableDeadWatchdogPriorOne =
    "app_pid=1\nwatchdog_pid=999999\nwatchdog_start=Thu Jan  1 00:00:00 1970\nprior=1\nsetAt=1700000000\n"

private func makeRepairFixture() throws -> (dir: URL, stub: PMSetStub, leaseURL: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-repair-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stub = try PMSetStub.make(in: dir)
    let leaseURL = dir.appendingPathComponent("lease")
    try FileManager.default.createDirectory(at: leaseURL, withIntermediateDirectories: true)
    return (dir, stub, leaseURL)
}

private func runRepairCommand(leasePath: String, pmsetPath: String) throws -> Process {
    let command = OsascriptSleepWatchdog.repairCommand(leasePath: leasePath, pmsetPath: pmsetPath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    try process.run()
    process.waitUntilExit()
    return process
}

@Test func repairCommandNeverGrepsForANumericPidAsALivenessCheck() {
    // The exact regression named in round 3: a grep for `watchdog_pid=` is
    // presence, not liveness. The fix must use a real `kill -0` check.
    let command = OsascriptSleepWatchdog.repairCommand(leasePath: "/tmp/lease")
    #expect(!command.contains("grep"))
    #expect(command.contains("kill -0"))
}

// MARK: Case A — the live value is unreadable

@Test func caseARefusesAndDeletesNothingWhenTheLiveValueIsUnreadable() throws {
    // Even a fully readable debt, recording a provably dead watchdog whose
    // prior would trivially match, must not save this lease: the live read
    // is checked FIRST, before the debt is ever parsed.
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: stub.unreadableURL)  // pmset -g always fails
    try readableDeadWatchdogPriorZero.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus != 0)
    #expect(FileManager.default.fileExists(atPath: leaseURL.path))  // NOT removed
    #expect(try stub.log().isEmpty)  // never even attempted a write
}

// MARK: Case B — the debt is readable

@Test func caseBDeletesTheLeaseWhenLiveAlreadyMatchesTheRecordedPriorAndTheWatchdogIsDead() throws {
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    // No state written: pmset -g reports 0, matching prior=0.
    try readableDeadWatchdogPriorZero.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: leaseURL.path))
    #expect(try stub.log().isEmpty)  // nothing owed: no write attempted
}

@Test func caseBRestoresToTheRecordedPriorThenDeletesWhenLiveDiffersAndTheWatchdogIsDead() throws {
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "1".write(to: stub.stateURL, atomically: true, encoding: .utf8)  // live=1, prior=0
    try readableDeadWatchdogPriorZero.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus == 0)
    #expect(try stub.log() == ["SET 0"])  // restored to the recorded prior, not a hardcoded value
    #expect(!FileManager.default.fileExists(atPath: leaseURL.path))
}

@Test func caseBKeepsTheLeaseWhenTheRestoreWriteDoesNotTakeEffect() throws {
    // The write is attempted (and logged) but the stub's `failURL` makes it
    // silently not take effect, so the read-back can never confirm it.
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: stub.failURL)
    try readableDeadWatchdogPriorOne.write(  // live=0 (default), prior=1: a restore is owed
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus != 0)
    #expect(try stub.log() == ["SET 1"])  // the restore WAS attempted
    #expect(FileManager.default.fileExists(atPath: leaseURL.path))  // but the lease survives
    #expect(SleepWatchdogDebt.load(from: leaseURL.appendingPathComponent("debt")) != nil)
}

@Test func caseBRefusesWhenALiveWatchdogActuallyOwnsTheLease() throws {
    // A REAL running process, checked with the real `kill -0` / `ps -o
    // lstart=` the predicate uses — not a grep, not a stub. Any process
    // killed here is one this test itself spawned.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 30"]
    try child.run()
    defer {
        if child.isRunning { child.terminate() }
    }
    let start = try #require(
        SleepWatchdogDebtCheck.currentProcessStartTime(pid: child.processIdentifier))

    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let liveDebtText = "app_pid=1\nwatchdog_pid=\(child.processIdentifier)\n"
        + "watchdog_start=\(start)\nprior=0\nsetAt=1700000000\n"
    try liveDebtText.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus != 0)
    #expect(FileManager.default.fileExists(atPath: leaseURL.path))  // NOT removed
    #expect(try stub.log().isEmpty)  // never wrote to pmset — refused before touching it
}

// MARK: Case C — the debt is unreadable

@Test func caseCDeletesTheLeaseWhenTheDebtIsUnreadableAndLiveIsZero() throws {
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    // No debt file at all: the lease directory exists but nothing was ever
    // recorded inside it. Live left at the default (0).

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: leaseURL.path))
    #expect(try stub.log().isEmpty)  // 0 is already safe: no write needed
}

@Test func caseCRefusesAndNamesTheManualCommandWhenTheDebtIsUnreadableAndLiveIsOne() throws {
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "1".write(to: stub.stateURL, atomically: true, encoding: .utf8)
    try "garbage, not key=value at all".write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let command = OsascriptSleepWatchdog.repairCommand(
        leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    #expect(process.terminationStatus != 0)
    #expect(FileManager.default.fileExists(atPath: leaseURL.path))  // NOT removed
    #expect(try stub.log().isEmpty)  // never guesses at a write when the prior is unknown
    let stderr = String(decoding: stderrData, as: UTF8.self)
    #expect(stderr.contains("sudo pmset -a disablesleep 0"))  // the exact manual recovery command
}

// MARK: Regression — attempt 2's exact bug: readable-with-prior-0 must not
// be treated as "nothing owed" once the live value has moved on.

@Test func regressionReadableDebtWithPriorZeroDoesNotDeleteWhenLiveHasBecomeOneAndTheRestoreFails() throws {
    // This is attempt 2's exact scenario, verbatim: a valid debt with
    // prior=0 (mere readability used to be classified as "nothing owed"),
    // and the live value has since become 1 (as if changed during the
    // administrator prompt). The fix must attempt a restore to 0, not
    // delete on sight — and here that restore fails (`failURL`), so the
    // lease must survive rather than stranding disablesleep=1 with no
    // record. See `repairCommandCaseBKeepsTheLeaseWhenTheRestoreWriteDoesNotTakeEffect`
    // for the same mechanism against prior=1; this test pins the specific
    // prior=0 shape named in the regression.
    let (dir, stub, leaseURL) = try makeRepairFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "1".write(to: stub.stateURL, atomically: true, encoding: .utf8)  // live became 1
    try Data().write(to: stub.failURL)  // the restore write silently does nothing
    try readableDeadWatchdogPriorZero.write(
        to: leaseURL.appendingPathComponent("debt"), atomically: true, encoding: .utf8)

    let process = try runRepairCommand(leasePath: leaseURL.path, pmsetPath: stub.scriptURL.path)

    #expect(process.terminationStatus != 0)  // must not report success
    #expect(try stub.log() == ["SET 0"])  // it DID try to restore, unlike attempt 2's bug
    #expect(FileManager.default.fileExists(atPath: leaseURL.path))  // and the lease survives
    let debt = try #require(
        SleepWatchdogDebt.load(from: leaseURL.appendingPathComponent("debt")))
    #expect(debt.priorValue == false)  // the record of what's owed is intact
}

// MARK: - SleepWatchdogRepair.run: the unprivileged-shortcut / escalation wiring
//
// `clearLeaseUnprivileged` used to run FIRST, unconditionally, before any
// predicate — a plain `rm -rf` can remove even a root-owned lease (deleting
// a directory entry needs write permission on its PARENT, not the entry
// itself), so that shortcut deleted the lease without ever reading the live
// value or the debt. These tests cover the fix: the full predicate decides
// BEFORE either injected action ever runs, so a "delete" verdict tries the
// free path first, a "restore" verdict skips straight to escalation
// (a write needs root regardless), and a "refuse" verdict never touches
// either action — no prompt at all.

/// Records which injected action ran and how many times, so a test can
/// assert "never called" as directly as "called once" — never inferring
/// non-invocation from a missing side effect elsewhere.
private final class RepairActionSpy {
    var deleteCallCount = 0
    var deleteResult = true
    var escalateCallCount = 0
    var escalateResult: SleepSettingResult = .applied

    func unprivilegedDelete() -> Bool {
        deleteCallCount += 1
        return deleteResult
    }

    func escalate() -> SleepSettingResult {
        escalateCallCount += 1
        return escalateResult
    }
}

private let repairSpyDebtPriorZero = SleepWatchdogDebt(
    appPID: 1, watchdogPID: 999_999, watchdogStartedAt: "Thu Jan  1 00:00:00 1970",
    priorValue: false, setAt: Date(timeIntervalSince1970: 1_700_000_000))

@Test func repairShortcutDeletesWithoutEscalatingWhenLiveMatchesRecordedPriorAndWatchdogIsDead() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .orphaned(repairSpyDebtPriorZero), live: false,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    #expect(outcome == .clearedWithoutPrivilege)
    #expect(spy.deleteCallCount == 1)
    #expect(spy.escalateCallCount == 0)  // never escalated: the free delete already succeeded
}

@Test func repairShortcutRefusesToDeleteAndEscalatesWhenLiveDiffersFromRecordedPrior() {
    // The exact bug named in the coordinator's report: a readable debt with
    // prior=0 and a live value of 1 must never take the unprivileged delete
    // path at all — a restore is owed, which needs a `pmset` write, which
    // needs root.
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .orphaned(repairSpyDebtPriorZero), live: true,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    #expect(outcome == .escalated(.applied))
    #expect(spy.deleteCallCount == 0)  // the free shortcut is never even tried
    #expect(spy.escalateCallCount == 1)
}

@Test func repairEscalatesWhenTheUnprivilegedDeleteFailsOnARootOwnedLease() {
    let spy = RepairActionSpy()
    spy.deleteResult = false  // simulates the plain `rm -rf` failing
    let outcome = SleepWatchdogRepair.run(
        status: .orphaned(repairSpyDebtPriorZero), live: false,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    #expect(outcome == .escalated(.applied))
    #expect(spy.deleteCallCount == 1)  // tried first
    #expect(spy.escalateCallCount == 1)  // then escalated because it failed
}

@Test func repairRefusesWithNoPromptWhenALiveWatchdogOwnsTheLease() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .held(repairSpyDebtPriorZero), live: false,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    guard case .refused = outcome else {
        Issue.record("expected .refused, got \(outcome)")
        return
    }
    #expect(spy.deleteCallCount == 0)
    #expect(spy.escalateCallCount == 0)  // no prompt at all
}

@Test func repairRefusesWithNoPromptWhenLiveIsUnreadableForAnOrphanedDebt() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .orphaned(repairSpyDebtPriorZero), live: nil,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    guard case .refused = outcome else {
        Issue.record("expected .refused, got \(outcome)")
        return
    }
    #expect(spy.deleteCallCount == 0)
    #expect(spy.escalateCallCount == 0)
}

@Test func repairRefusesWithNoPromptWhenTheDebtIsUnreadableAndLiveIsAlsoUnreadable() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .unreadable, live: nil,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    guard case .refused = outcome else {
        Issue.record("expected .refused, got \(outcome)")
        return
    }
    #expect(spy.deleteCallCount == 0)
    #expect(spy.escalateCallCount == 0)
}

@Test func repairRefusesWithNoPromptWhenTheDebtIsUnreadableAndLiveIsOne() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .unreadable, live: true,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    guard case .refused(let message) = outcome else {
        Issue.record("expected .refused, got \(outcome)")
        return
    }
    #expect(message.contains("sudo pmset -a disablesleep 0"))  // the exact manual recovery command
    #expect(spy.deleteCallCount == 0)
    #expect(spy.escalateCallCount == 0)
}

@Test func repairUnreadableDebtWithLiveZeroDeletesWithoutEscalating() {
    // The other half of CASE C: an unreadable debt is not automatically a
    // refusal — live 0 is already the safe state, so the free shortcut
    // still applies.
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .unreadable, live: false,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    #expect(outcome == .clearedWithoutPrivilege)
    #expect(spy.deleteCallCount == 1)
    #expect(spy.escalateCallCount == 0)
}

@Test func repairReportsNothingToDoWhenNoLeaseExists() {
    let spy = RepairActionSpy()
    let outcome = SleepWatchdogRepair.run(
        status: .none, live: false,
        unprivilegedDelete: spy.unprivilegedDelete, escalate: spy.escalate)

    #expect(outcome == .nothingToRepair)
    #expect(spy.deleteCallCount == 0)
    #expect(spy.escalateCallCount == 0)
}
