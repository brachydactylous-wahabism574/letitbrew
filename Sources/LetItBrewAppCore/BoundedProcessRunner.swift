import Darwin
import Foundation

public struct BoundedProcessResult: Equatable, Sendable {
    public let status: Int32
    public let output: Data
    public let outputTruncated: Bool
    public let timedOut: Bool
    public let launchError: String?
    public let processIdentifier: Int32?

    public var succeeded: Bool {
        !outputTruncated && !timedOut && launchError == nil && status == 0
    }
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var value = Data()
    private var truncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ data: Data) {
        lock.lock()
        let remaining = max(0, maximumBytes - value.count)
        if data.count > remaining {
            value.append(data.prefix(remaining))
            truncated = true
        } else {
            value.append(data)
        }
        lock.unlock()
    }

    func load() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (value, truncated)
    }
}

/// Runs a child process without allowing a full output pipe or a hung child to
/// block Let It Brew's agent orchestration indefinitely.
public enum BoundedProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        input: Data? = nil,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.25,
        maximumOutputBytes: Int = 1_024 * 1_024
    ) -> BoundedProcessResult {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let outputStarted = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        let outputBox = ProcessOutputBox(maximumBytes: maximumOutputBytes)

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
            while let chunk = try? outputHandle.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty {
                outputBox.append(chunk)
            }
            outputFinished.signal()
        }
        outputStarted.wait()

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            return BoundedProcessResult(
                status: -1,
                output: Data(),
                outputTruncated: false,
                timedOut: false,
                launchError: error.localizedDescription,
                processIdentifier: nil
            )
        }

        do {
            if let input { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
        }

        let processIdentifier = process.processIdentifier
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let timedOut = process.isRunning
        if timedOut {
            if process.isRunning { process.terminate() }
            let graceDeadline = Date().addingTimeInterval(max(0, terminationGrace))
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            if process.isRunning {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        // `waitUntilExit` is the final reap. After SIGKILL it cannot depend on
        // child cooperation, and prevents a zombie from escaping this call.
        process.waitUntilExit()

        if outputFinished.wait(timeout: .now() + 2) == .timedOut {
            // A descendant should not keep Let It Brew's reader alive after the
            // launched process is reaped. Closing the descriptor unblocks it.
            try? outputHandle.close()
            _ = outputFinished.wait(timeout: .now() + 0.25)
        }

        let capturedOutput = outputBox.load()
        return BoundedProcessResult(
            status: process.terminationStatus,
            output: capturedOutput.data,
            outputTruncated: capturedOutput.truncated,
            timedOut: timedOut,
            launchError: nil,
            processIdentifier: processIdentifier
        )
    }
}
