import Darwin
import Foundation

/// Whether a process still exists. Injected so eviction is testable.
public protocol ProcessLiveness: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct KillZeroLiveness: ProcessLiveness {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user.
        return errno == EPERM
    }
}

public enum SessionStore {
    /// Filters raw records down to sessions that still exist.
    ///
    /// Liveness is the primary test because freshness cannot work here: a
    /// session running a long build is legitimately silent for many minutes,
    /// so any TTL short enough to catch a killed agent also evicts real work.
    /// The TTL survives only as a backstop against pid reuse, where holding
    /// awake slightly too long is the safe failure.
    public static func live(
        records: [SessionRecord],
        now: Date,
        ttl: TimeInterval,
        liveness: ProcessLiveness
    ) -> [SessionRecord] {
        records
            .filter { record in
                guard now.timeIntervalSince(record.updatedAt) < ttl else { return false }
                guard let pid = record.pid else { return true }
                return liveness.isAlive(pid: pid)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
