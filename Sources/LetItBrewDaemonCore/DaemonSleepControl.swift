import Foundation
import LetItBrewCore

public protocol DaemonSleepSettingControlling: AnyObject {
    func readDisabled() -> Bool?
    func writeDisabled(_ disabled: Bool) -> Bool
}

/// The privileged daemon's only system mutation.
public final class PMSetDaemonSleepControl: DaemonSleepSettingControlling {
    public init() {}

    public func readDisabled() -> Bool? {
        PMSet.parseSleepDisabled(from: run(["-g"]))
    }

    public func writeDisabled(_ disabled: Bool) -> Bool {
        run(["-a", "disablesleep", disabled ? "1" : "0"]) != nil
    }

    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            // A successful pmset write is normally silent, so success must
            // not be inferred from output being nonempty.
            if arguments.first != "-g" { return "ok" }
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
