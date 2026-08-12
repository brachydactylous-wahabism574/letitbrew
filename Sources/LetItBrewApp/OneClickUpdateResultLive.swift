import LetItBrewAppCore
import Darwin
import Foundation

struct UpdateCompletionReport: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case success
        case failure
    }

    let outcome: Outcome
    let message: String
    let diagnostic: String?
    let workspace: URL
    let logFile: URL?

    var id: String { "\(workspace.path):\(outcome)" }
}

enum PendingUpdateResultScan: Sendable {
    case none
    case waiting(URL)
    case report(UpdateCompletionReport)
}

final class LiveUpdateResultStore: @unchecked Sendable {
    private let fileManager = FileManager.default

    func scan() -> PendingUpdateResultScan {
        guard let base = updateBaseURL,
              privateOwnedDirectory(base),
              let entries = try? fileManager.contentsOfDirectory(
                  at: base,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: []
              )
        else { return .none }

        let workspaces = entries
            .filter {
                $0.lastPathComponent.hasPrefix("Update.")
                    && $0.deletingLastPathComponent().standardizedFileURL == base
                    && privateOwnedDirectory($0)
            }
            .sorted { modificationDate($0) > modificationDate($1) }

        guard let workspace = workspaces.first else { return .none }
        let resultURL = workspace.appendingPathComponent("result.json")
        guard fileManager.fileExists(atPath: resultURL.path) || isSymbolicLink(resultURL)
        else { return .waiting(workspace) }
        let parsed: DetachedUpdateResult
        do {
            parsed = try DetachedUpdateResultParser.parse(
                readPrivateFile(resultURL, maximumBytes: 4 * 1_024)
            )
        } catch {
            return .report(UpdateCompletionReport(
                outcome: .failure,
                message: "Let It Brew could not verify whether the update finished. Inspect the diagnostic before trying again.",
                diagnostic: "result.json: \(error.localizedDescription)",
                workspace: workspace,
                logFile: safeLogURL(in: workspace)
            ))
        }

        switch parsed.outcome {
        case .success:
            // The result is published only after the upgrade transaction,
            // rollback traps, and relaunch have completed. A strict success
            // record therefore proves this per-run download workspace is
            // disposable; the transaction's own recovery directory is
            // separate and is never touched here.
            try? fileManager.removeItem(at: workspace)
            return .report(UpdateCompletionReport(
                outcome: .success,
                message: "Let It Brew was updated successfully.",
                diagnostic: nil,
                workspace: workspace,
                logFile: nil
            ))
        case .failure:
            let logURL = safeLogURL(in: workspace)
            let log: String
            if let logURL,
               let data = try? readPrivateFile(logURL, maximumBytes: 1_024 * 1_024) {
                log = String(decoding: data, as: UTF8.self)
            } else {
                log = "The updater log was missing or unsafe."
            }
            return .report(UpdateCompletionReport(
                outcome: .failure,
                message: "The update did not finish. Let It Brew restored the previous app when recovery succeeded.",
                diagnostic: "runner exit \(parsed.exitCode)\n\(log)",
                workspace: workspace,
                logFile: logURL
            ))
        }
    }

    func timedOutReport(for workspace: URL) -> UpdateCompletionReport {
        UpdateCompletionReport(
            outcome: .failure,
            message: "Let It Brew did not receive a final result from the detached updater.",
            diagnostic: "No result.json appeared within the 60-second relaunch window.",
            workspace: workspace,
            logFile: safeLogURL(in: workspace)
        )
    }

    func dismiss(_ report: UpdateCompletionReport) {
        // Failure evidence is retained until this explicit dismissal. Success
        // normally removed the workspace during scan, but dismissal retries a
        // transient cleanup failure so the same success is not shown again on
        // every later launch.
        guard let base = updateBaseURL,
              report.workspace.deletingLastPathComponent().standardizedFileURL == base,
              report.workspace.lastPathComponent.hasPrefix("Update."),
              privateOwnedDirectory(report.workspace)
        else { return }
        try? fileManager.removeItem(at: report.workspace)
    }

    private var updateBaseURL: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.ruban24.letitbrew", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .standardizedFileURL
    }

    private func safeLogURL(in workspace: URL) -> URL? {
        let log = workspace.appendingPathComponent("update.log")
        return (try? privateFileStatus(log, maximumBytes: 1_024 * 1_024)) != nil
            ? log
            : nil
    }

    private func readPrivateFile(_ url: URL, maximumBytes: Int64) throws -> Data {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { Darwin.close(descriptor) }
        try privateFileStatus(descriptor: descriptor, maximumBytes: maximumBytes)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var result = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard Int64(result.count) + Int64(chunk.count) <= maximumBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            result.append(chunk)
        }
        return result
    }

    private func privateFileStatus(_ url: URL, maximumBytes: Int64) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        try privateFileStatus(descriptor: descriptor, maximumBytes: maximumBytes)
    }

    private func privateFileStatus(descriptor: Int32, maximumBytes: Int64) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.getuid(),
              Int(status.st_mode & 0o777) == 0o600,
              status.st_size >= 0,
              status.st_size <= maximumBytes
        else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func privateOwnedDirectory(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString({ Darwin.lstat($0, &status) }) == 0
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == Darwin.getuid()
            && Int(status.st_mode & 0o077) == 0
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString({ Darwin.lstat($0, &status) }) == 0
            && (status.st_mode & S_IFMT) == S_IFLNK
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
