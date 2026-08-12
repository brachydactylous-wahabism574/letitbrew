import CoreGraphics
import Foundation
import IOKit
import LetItBrewAppCore

struct IOKitClamshellMonitor: ClamshellMonitoring, Sendable {
    func currentClamshellState() -> ClamshellStateReading {
        guard let matching = IOServiceMatching("IOPMrootDomain") else {
            return .unreadable
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return .unreadable }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
        let closed = property as? Bool
        else { return .unreadable }

        return closed ? .closed : .open
    }
}

struct CoreGraphicsActiveDisplayMonitor: ActiveDisplayMonitoring, Sendable {
    func currentDisplayTopology() -> ActiveDisplayTopologyReading {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return .unreadable
        }
        guard count > 0 else { return .noExternalDisplay }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let error = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard error == .success else { return .unreadable }

        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
            ? .externalDisplayActive
            : .noExternalDisplay
    }
}

struct PMSetDisplaySleepCommand: DisplaySleepCommanding, Sendable {
    func sleepDisplays() -> DisplaySleepCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(
            fileURLWithPath: DisplaySleepCommandSpecification.executablePath
        )
        process.arguments = DisplaySleepCommandSpecification.arguments
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let message = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                let detail = message.isEmpty
                    ? "pmset exited with status \(process.terminationStatus)."
                    : message
                return .failed(message: detail)
            }
            return .succeeded
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}
