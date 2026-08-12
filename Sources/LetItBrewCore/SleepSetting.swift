import Foundation

public enum SleepSettingResult: Equatable, Sendable {
    case applied
    /// The user dismissed the administrator prompt. Not an error to nag about.
    case cancelled
    case failed(String)
}

/// Controls the system-wide `pmset disablesleep` flag.
///
/// This is the only lever that keeps a Mac awake with the lid closed and no
/// external display: `IOPMAssertion` cannot override clamshell sleep. Unlike
/// those assertions it is a global setting needing root, and it is not scoped
/// to AC versus battery, so it lives behind its own seam. A daemon-backed
/// implementation slots in here later with no caller changes.
public protocol SleepSettingControlling: AnyObject, Sendable {
    /// Nil when the state could not be read.
    func isSleepDisabled() -> Bool?
}

/// Reads the flag with `pmset -g`.
///
/// Not `@MainActor`, and callers must keep it off the main thread: a
/// synchronous `Process.waitUntilExit` spins the main run loop, where a
/// re-entrant display-driver callback can crash the process.
public final class PMSetSleepControl: SleepSettingControlling, @unchecked Sendable {
    public init() {}

    public func isSleepDisabled() -> Bool? {
        PMSet.parseSleepDisabled(from: Self.run("/usr/bin/pmset", ["-g"]))
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // A Pipe() nothing reads can fill up and deadlock the child if it
        // writes enough to stderr; discard it instead.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
