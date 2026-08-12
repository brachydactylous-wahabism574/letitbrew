import Darwin
import Foundation
import LetItBrewCore

/// The absolute path to write into hook commands: this binary's real location,
/// with symlinks resolved so a Homebrew shim does not get baked in.
///
/// Both `ClaudeHooks.hookCommand` and `CodexHooks.hookCommand` throw on a
/// relative path, so this must always resolve to one starting with `/` —
/// under every invocation shape, including a bare PATH-resolved command
/// name (`letitbrew`, exactly how a Homebrew install runs). `argv[0]` is not
/// reliable for that: for a bare name, it is just the name as typed, with
/// no directory component at all, and resolving *that* through
/// `URL(fileURLWithPath:)` would silently resolve against the current
/// directory rather than wherever PATH actually found it — baking a path
/// that does not exist into every installed hook. `_NSGetExecutablePath`
/// asks the OS for the path it actually resolved and exec'd, which is
/// correct regardless of how the process was launched.
func resolvedCLIPath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [Int8](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buffer, &size)
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

/// Thrown when the settings path is a symlink whose target does not exist.
/// `Data(contentsOf:)` surfaces a dangling symlink as the identical "no such
/// file" error a genuinely missing path produces, so left unchecked it would
/// be treated as absence and silently replaced from `{}` — destroying the
/// user's dotfile-managed link. Refuse instead; this is the user's setup to
/// fix, not ours to paper over.
struct DanglingSymlink: Error {
    let path: String
}

/// Resolves `url` to the file that should actually be read and written: if
/// `url` is a symlink (or a chain of them), the file at the end of the
/// chain — so a dotfile-managed config gets updated THROUGH the link,
/// never replaced by swapping the link itself out (which is what an atomic
/// `rename` onto the symlink's own path would otherwise do). A path that
/// is not a symlink at all is returned unchanged, present or not — that
/// "genuinely missing" case is handled elsewhere, same as before this fix.
/// A symlink (chain) that bottoms out at a target which does not exist is a
/// DIFFERENT case — not "missing", but broken — and throws
/// ``DanglingSymlink`` rather than being silently treated as absence.
private func resolveWriteTarget(_ url: URL) throws -> URL {
    var current = url
    var hops = 0
    while let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
        hops += 1
        guard hops <= 32 else { throw DanglingSymlink(path: url.path) }  // ELOOP-style guard
        current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent())
            .standardizedFileURL
    }
    guard hops == 0 || FileManager.default.fileExists(atPath: current.path) else {
        throw DanglingSymlink(path: url.path)
    }
    return current
}

/// Testing-only override: when `LETITBREW_TEST_HOME` is set, both Claude
/// Code's settings.json and Codex's hooks.json are derived beneath this
/// directory instead of the real home directory — unconditionally,
/// including in the presence of an ambient `CODEX_HOME` (see
/// `codexEnvironment()`). It wins outright, with nothing able to defeat it.
///
/// Without this, every CLI operation targets the live
/// `~/.claude/settings.json` unconditionally — `CodexHooks` has
/// `CODEX_HOME` to redirect it, but Claude Code had no equivalent, so
/// exercising a real failure path (a malformed file, a permissions error)
/// meant doing it against the user's actual, in-use config. That is
/// exactly what caused a real incident during this command's own
/// development. Not meant for end users; not documented outside `--help`.
///
/// Requires validation before use — see `invalidTestHomeError()`, called at
/// the top of every command that reads this. A relative or empty value
/// would silently defeat the safety purpose rather than failing loudly, so
/// this function assumes it has already been refused if invalid.
private func configHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["LETITBREW_TEST_HOME"] {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// The environment `CodexHooks.hooksURL` should read `CODEX_HOME` from.
/// Ordinarily the real process environment, so `CODEX_HOME` keeps working
/// normally. But `hooksURL` checks `CODEX_HOME` *before* its `home:`
/// parameter — so once `LETITBREW_TEST_HOME` is set, leaving a real,
/// ambient `CODEX_HOME` in place would silently send Codex's path to it
/// while Claude Code correctly redirected, recreating exactly the hazard
/// `LETITBREW_TEST_HOME` exists to eliminate. An empty environment forces
/// `hooksURL` to fall through to `home:` — the override wins outright.
private func codexEnvironment() -> [String: String] {
    ProcessInfo.processInfo.environment["LETITBREW_TEST_HOME"] == nil
        ? ProcessInfo.processInfo.environment
        : [:]
}

/// `LETITBREW_TEST_HOME` must be a non-empty absolute path when set. A
/// relative path, or an empty string, would silently defeat the safety
/// purpose the override exists for — it must fail loudly instead of
/// guessing or repairing a bad value. Returns the refusal message when the
/// value is invalid, `nil` when it's fine (or unset).
private func invalidTestHomeError() -> String? {
    guard let value = ProcessInfo.processInfo.environment["LETITBREW_TEST_HOME"] else { return nil }
    guard !value.isEmpty, value.hasPrefix("/") else {
        return """
        LETITBREW_TEST_HOME is set to '\(value)', which is not an absolute path.
        Set it to an absolute directory path (e.g. /tmp/letitbrew-test-home), or unset it.
        """
    }
    return nil
}

/// Prints the refusal and returns the exit code to use if
/// `LETITBREW_TEST_HOME` is set but invalid; `nil` if the caller should
/// proceed normally.
private func refuseIfTestHomeInvalid() -> Int32? {
    guard let error = invalidTestHomeError() else { return nil }
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    return 1
}

/// Which `letitbrew` command is currently reporting an error, so the
/// suggested next step matches what actually failed — a failed uninstall
/// telling the user to reinstall would send them the wrong way. `doctor`
/// never writes anything, so its hint points at `install`, the command
/// that would actually fix what doctor found.
private enum Operation {
    case install, uninstall, doctor

    var retryHint: String {
        switch self {
        case .install: return "run `letitbrew install` again"
        case .uninstall: return "run `letitbrew uninstall` again"
        case .doctor: return "run `letitbrew install` to repair"
        }
    }
}

enum HookAgent: String, CaseIterable, Sendable {
    case claude
    case codex
}

/// Shared between Claude and Codex: both go through the same symlink-aware,
/// concurrent-edit-aware write path (`resolveWriteTarget`/`writeAtomically`),
/// so both need to recognize its two refusal errors identically. Returns
/// `nil` for anything else, so callers fall through to their own
/// tool-specific description.
private func describeWriteSafetyError(_ error: Error, operation: Operation) -> String? {
    if let error = error as? DanglingSymlink {
        return """
        \(error.path) is a symlink whose target does not exist.
        Fix or remove the symlink so it points at a real file, then \(operation.retryHint).
        """
    }
    if let error = error as? ConcurrentModification {
        return """
        \(error.path) changed while this command was running. Nothing was written, so no edit was \
        lost; \(operation.retryHint).
        """
    }
    return nil
}

/// Turns a `ClaudeHooks` failure into a message naming what is wrong and
/// what to do about it. A bare "install failed" leaves the user no path
/// forward; these errors carry the offending event or path precisely so the
/// CLI can be specific.
private func describeClaudeError(_ error: Error, url: URL, operation: Operation) -> String {
    if let message = describeWriteSafetyError(error, operation: operation) { return message }
    if let error = error as? ClaudeHooks.SettingsUnreadable {
        if let event = error.event {
            return """
            \(url.path) has an unusable value under hooks.\(event) (expected an array of hook groups).
            Fix or remove that key by hand, then \(operation.retryHint).
            """
        }
        return """
        \(url.path) exists but could not be read or parsed as JSON (or its "hooks" value isn't an object).
        Check that the file is readable and its contents are valid JSON, then \(operation.retryHint).
        """
    }
    if let error = error as? ClaudeHooks.RelativeCLIPath {
        return "internal error: CLI path '\(error.cliPath)' is not absolute. Please file a bug."
    }
    return "\(error)"
}

/// Same as `describeClaudeError`, for `CodexHooks`'s distinct error type and
/// its extra failure modes (an invalid top-level key breaks the whole file;
/// an I/O failure is not a JSON problem at all).
private func describeCodexError(_ error: Error, url: URL, operation: Operation) -> String {
    if let message = describeWriteSafetyError(error, operation: operation) { return message }
    if let error = error as? CodexHooks.HooksUnreadable {
        switch error.reason {
        case .unparseable:
            return """
            \(url.path) exists but could not be parsed as JSON.
            Fix or move the file, then \(operation.retryHint).
            """
        case .ioFailure(let description):
            return """
            \(url.path) could not be read (\(description)).
            Check that the path is accessible and readable — not a directory, not permission-denied —
            then \(operation.retryHint).
            """
        case .invalidTopLevelKey:
            let key = error.key.map { "'\($0)'" } ?? "a value"
            return """
            \(url.path) has an unexpected top-level key or type for \(key) (Codex allows only "description" and "hooks").
            Codex already refuses to load ANY hooks from this file, including your own.
            Fix or remove it by hand, then \(operation.retryHint).
            """
        case .malformedEventValue:
            return """
            \(url.path) has an unusable value under hooks.\(error.key ?? "?") (expected an array of hook groups).
            Fix or remove that key by hand, then \(operation.retryHint).
            """
        }
    }
    if let error = error as? CodexHooks.RelativeCLIPath {
        return "internal error: CLI path '\(error.cliPath)' is not absolute. Please file a bug."
    }
    return "\(error)"
}

func runInstall(agents: Set<HookAgent> = Set(HookAgent.allCases)) -> Int32 {
    if let failure = refuseIfTestHomeInvalid() { return failure }
    let cliPath = resolvedCLIPath()
    var failures = 0
    var installedTools = 0

    if agents.contains(.claude) {
        let claudeURL = ClaudeHooks.settingsURL(home: configHome())
        do {
            let target = try resolveWriteTarget(claudeURL)
            let priorModified = AtomicFile.modificationDate(of: target)
            let existing = try ClaudeHooks.read(at: target)
            try AtomicFile.write(
                try ClaudeHooks.install(into: existing, cliPath: cliPath), to: target,
                ifUnchangedSince: priorModified)
            print("Claude Code: installed \(ClaudeHooks.events.count) hooks in \(claudeURL.path)")
            installedTools += 1
        } catch {
            FileHandle.standardError.write(Data(
                "Claude Code: \(describeClaudeError(error, url: claudeURL, operation: .install))\n".utf8))
            failures += 1
        }
    }

    if agents.contains(.codex) {
        let codexURL = CodexHooks.hooksURL(home: configHome(), environment: codexEnvironment())
        do {
            let target = try resolveWriteTarget(codexURL)
            let priorModified = AtomicFile.modificationDate(of: target)
            let existing = try CodexHooks.read(at: target)
            try AtomicFile.write(
                try CodexHooks.install(into: existing, cliPath: cliPath), to: target,
                ifUnchangedSince: priorModified)
            print("Codex: installed \(CodexHooks.events.count) hooks in \(codexURL.path)")
            print("  Note: \(CodexHooks.needsUserApprovalNote)")
            installedTools += 1
        } catch {
            FileHandle.standardError.write(Data(
                "Codex: \(describeCodexError(error, url: codexURL, operation: .install))\n".utf8))
            failures += 1
        }
    }

    if installedTools > 0 {
        print("""
        Important: restart any already-running agent sessions. Existing sessions keep their old hook set, \
        emit an incomplete event stream, and can remain stuck at `working`.
        """)
    }

    return failures == 0 ? 0 : 1
}

func runUninstall(agents: Set<HookAgent> = Set(HookAgent.allCases)) -> Int32 {
    if let failure = refuseIfTestHomeInvalid() { return failure }
    var failures = 0

    if agents.contains(.claude) {
        let claudeURL = ClaudeHooks.settingsURL(home: configHome())
        do {
            let target = try resolveWriteTarget(claudeURL)
            let priorModified = AtomicFile.modificationDate(of: target)
            if let existing = try ClaudeHooks.read(at: target) {
                try AtomicFile.write(
                    try ClaudeHooks.remove(from: existing), to: target, ifUnchangedSince: priorModified)
            }
            print("Claude Code: hooks removed")
        } catch {
            FileHandle.standardError.write(Data(
                "Claude Code: \(describeClaudeError(error, url: claudeURL, operation: .uninstall))\n".utf8))
            failures += 1
        }
    }

    if agents.contains(.codex) {
        let codexURL = CodexHooks.hooksURL(home: configHome(), environment: codexEnvironment())
        do {
            let target = try resolveWriteTarget(codexURL)
            let priorModified = AtomicFile.modificationDate(of: target)
            if let existing = try CodexHooks.read(at: target) {
                try AtomicFile.write(
                    try CodexHooks.remove(from: existing), to: target, ifUnchangedSince: priorModified)
            }
            print("Codex: hooks removed")
        } catch {
            FileHandle.standardError.write(Data(
                "Codex: \(describeCodexError(error, url: codexURL, operation: .uninstall))\n".utf8))
            failures += 1
        }
    }

    return failures == 0 ? 0 : 1
}

private func describe(_ report: HookInstallReport, tool: String) -> String {
    if report.isAbsent { return "\(tool): not installed" }
    if report.isHealthy { return "\(tool): healthy (\(report.healthy.count) events)" }

    var lines = ["\(tool): needs repair"]
    func line(_ label: String, _ events: Set<String>) {
        guard !events.isEmpty else { return }
        lines.append("  \(label): \(events.sorted().joined(separator: ", "))")
    }
    line("missing", report.missing)
    line("stale path", report.stale)
    line("duplicated", report.duplicated)
    line("orphaned", report.orphaned)
    lines.append("  Run `letitbrew install` to repair.")
    return lines.joined(separator: "\n")
}

/// Prints a validation failure as its own state, distinct from both
/// "healthy" and "not installed" — a corrupt or malformed config file is
/// neither, and telling the user "not installed" when their file is
/// actually broken sends them nowhere useful.
private func printInvalid(_ tool: String, _ message: String) {
    print("\(tool): configuration invalid")
    for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
        print("  \(line)")
    }
}

/// Reports Claude Code's install health and returns whether it is healthy.
///
/// `ClaudeHooks.report(for:cliPath:)` alone cannot distinguish "no file"
/// from "a file that exists but fails validation" — both collapse into
/// "missing" by design, so a status display always has *something* to
/// render (see the doc comment on `report`). That collapse is correct for
/// `report` as a low-level building block, but wrong for `doctor`'s
/// user-facing output: it would print "not installed" for a settings file
/// that is actually corrupt, discarding the offending event/key these
/// errors exist specifically to name. So `remove` — which runs the exact
/// same parse/shape validation `install` does, and needs no `cliPath` to
/// do it — is run here first, purely as a dry validation check; its result
/// is thrown away and nothing is written to disk.
private func doctorClaude(cliPath: String) -> Bool {
    let url = ClaudeHooks.settingsURL(home: configHome())
    do {
        let data = try ClaudeHooks.read(at: url)
        _ = try ClaudeHooks.remove(from: data)
        let report = ClaudeHooks.report(for: data, cliPath: cliPath)
        print(describe(report, tool: "Claude Code"))
        return report.isHealthy
    } catch {
        printInvalid("Claude Code", describeClaudeError(error, url: url, operation: .doctor))
        return false
    }
}

/// Same as `doctorClaude`, for Codex. See its doc comment for why
/// validation runs separately from `report` here.
private func doctorCodex(cliPath: String) -> Bool {
    let url = CodexHooks.hooksURL(home: configHome(), environment: codexEnvironment())
    do {
        let data = try CodexHooks.read(at: url)
        _ = try CodexHooks.remove(from: data)
        let report = CodexHooks.report(for: data, cliPath: cliPath)
        print(describe(report, tool: "Codex"))
        if !report.isAbsent { print("  \(CodexHooks.needsUserApprovalNote)") }
        return report.isHealthy
    } catch {
        printInvalid("Codex", describeCodexError(error, url: url, operation: .doctor))
        return false
    }
}

/// Reports the sleep-watchdog lease used by `watch --lid-closed`. A `.held`
/// lease (a live watchdog currently owns it) is healthy and normal; `.none`
/// (nothing engaged) is healthy too. `.orphaned` and `.unreadable` are not:
/// both mean `watch --lid-closed` will refuse to start until `letitbrew
/// repair` runs — see the fail-closed design on `SleepWatchdogDebtCheck`.
/// `.unreadable` is surfaced explicitly rather than folded into `.none`,
/// since it may represent a real, unrestored `disablesleep`.
private func doctorLease() -> Bool {
    let status = SleepWatchdogDebtCheck.status(at: OsascriptSleepWatchdog.defaultLeaseURL)
    switch status {
    case .none:
        print("Lid-closed watchdog: no active lease")
        return true
    case .held(let debt):
        print("Lid-closed watchdog: held (watchdog pid \(debt.watchdogPID), armed by app pid \(debt.appPID))")
        return true
    case .orphaned(let debt):
        print("""
        Lid-closed watchdog: ORPHANED — watchdog pid \(debt.watchdogPID) died without restoring \
        disablesleep to \(debt.priorValue ? "1" : "0").
          Run `letitbrew repair` to fix.
        """)
        return false
    case .unreadable:
        print("""
        Lid-closed watchdog: UNREADABLE lease — its record could not be read, so the prior \
        disablesleep value is unknown.
          Run `letitbrew repair`, then verify by hand with `pmset -g | grep -i sleepdisabled`.
        """)
        return false
    }
}

func runDoctor() -> Int32 {
    if let failure = refuseIfTestHomeInvalid() { return failure }
    let cliPath = resolvedCLIPath()
    print("CLI path: \(cliPath)")

    let claudeHealthy = doctorClaude(cliPath: cliPath)
    let codexHealthy = doctorCodex(cliPath: cliPath)
    let leaseHealthy = doctorLease()

    return (claudeHealthy && codexHealthy && leaseHealthy) ? 0 : 1
}
