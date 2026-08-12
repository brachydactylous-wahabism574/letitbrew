import Darwin
import Foundation

public struct StagedJSONLineRequest: Equatable, Sendable {
    public let input: Data
    public let responseID: Int

    public init(input: Data, responseID: Int) {
        self.input = input
        self.responseID = responseID
    }
}

public struct StagedJSONLineProcessResult: Equatable, Sendable {
    public let status: Int32
    public let output: Data
    public let completedResponseIDs: Set<Int>
    public let stageTimedOut: Bool
    public let launchError: String?
    public let processIdentifier: Int32?
    public let wasForceKilled: Bool
}

private final class JSONLineResponseCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var output = Data()
    private var pending = Data()
    private var responseIDs: Set<Int> = []
    private var reachedEnd = false

    func append(_ data: Data) {
        condition.lock()
        output.append(data)
        pending.append(data)
        parseCompleteLines()
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        if !pending.isEmpty {
            parseResponseID(from: pending)
            pending.removeAll(keepingCapacity: false)
        }
        reachedEnd = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: Int, until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        refreshResponseIDsFromOutput()
        while !responseIDs.contains(id), !reachedEnd {
            guard condition.wait(until: deadline) else { break }
            refreshResponseIDsFromOutput()
        }
        return responseIDs.contains(id)
    }

    func snapshot() -> (output: Data, responseIDs: Set<Int>) {
        condition.lock()
        defer { condition.unlock() }
        return (output, responseIDs)
    }

    private func parseCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            parseResponseID(from: pending[..<newline])
            pending.removeSubrange(...newline)
        }
    }

    private func parseResponseID<T: DataProtocol>(from bytes: T) {
        let data = Data(bytes)
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? NSNumber
        else { return }
        responseIDs.insert(id.intValue)
    }

    /// Re-scanning complete output lines keeps stage recognition resilient to
    /// arbitrary FileHandle chunk boundaries, including a delimiter arriving
    /// in a separate read from the JSON object it terminates.
    private func refreshResponseIDsFromOutput() {
        for line in output.split(separator: 0x0A) {
            parseResponseID(from: line)
        }
    }
}

/// Runs newline-delimited JSON request stages against a long-lived child.
/// Each next stage is withheld until the prior response id has actually been
/// observed. All stages share one overall deadline; cleanup always closes
/// stdin, then escalates TERM to KILL if the process does not exit, and reaps.
public enum StagedJSONLineProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        stages: [StagedJSONLineRequest],
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.25
    ) -> StagedJSONLineProcessResult {
        let overallDeadline = Date().addingTimeInterval(max(0, timeout))
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let outputStarted = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        let collector = JSONLineResponseCollector()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputHandle = outputPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            outputStarted.signal()
            while true {
                let chunk = outputHandle.availableData
                guard !chunk.isEmpty else { break }
                collector.append(chunk)
            }
            collector.finish()
            outputFinished.signal()
        }
        outputStarted.wait()

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            _ = outputFinished.wait(timeout: .now() + 0.25)
            return StagedJSONLineProcessResult(
                status: -1,
                output: collector.snapshot().output,
                completedResponseIDs: [],
                stageTimedOut: false,
                launchError: error.localizedDescription,
                processIdentifier: nil,
                wasForceKilled: false
            )
        }

        let processIdentifier = process.processIdentifier
        var completedResponseIDs: Set<Int> = []
        var stageTimedOut = false
        var executionError: String?

        for stage in stages {
            guard Date() < overallDeadline else {
                stageTimedOut = true
                break
            }
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: stage.input)
            } catch {
                executionError = error.localizedDescription
                break
            }
            guard collector.waitForResponse(
                id: stage.responseID,
                until: overallDeadline
            ) else {
                stageTimedOut = true
                break
            }
            completedResponseIDs.insert(stage.responseID)
        }
        try? inputPipe.fileHandleForWriting.close()

        // Give a cooperative app-server a brief opportunity to observe EOF.
        let cooperativeExitDeadline = min(
            overallDeadline,
            Date().addingTimeInterval(max(0, terminationGrace))
        )
        while process.isRunning, Date() < cooperativeExitDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        var wasForceKilled = false
        if process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGTERM)
            let terminateDeadline = Date().addingTimeInterval(max(0, terminationGrace))
            while process.isRunning, Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                wasForceKilled = true
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        if outputFinished.wait(timeout: .now() + 2) == .timedOut {
            try? outputHandle.close()
            _ = outputFinished.wait(timeout: .now() + 0.25)
        }
        let snapshot = collector.snapshot()

        return StagedJSONLineProcessResult(
            status: process.terminationStatus,
            output: snapshot.output,
            completedResponseIDs: completedResponseIDs,
            stageTimedOut: stageTimedOut,
            launchError: executionError,
            processIdentifier: processIdentifier,
            wasForceKilled: wasForceKilled
        )
    }
}
