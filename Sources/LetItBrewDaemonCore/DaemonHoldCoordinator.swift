import Foundation

public enum DaemonReconciliationResult: Equatable, Sendable {
    case clean
    case clearedAlreadyRestored(priorValue: Bool)
    case restored(priorValue: Bool)
    case blocked(String)

    public var succeeded: Bool {
        switch self {
        case .clean, .clearedAlreadyRestored, .restored: true
        case .blocked: false
        }
    }
}

public enum DaemonHoldResult: Equatable, Sendable {
    case applied
    case failed(String)

    public var reply: (succeeded: Bool, message: String?) {
        switch self {
        case .applied: (true, nil)
        case .failed(let message): (false, message)
        }
    }
}

public enum DaemonReconciliationReadiness: Equatable, Sendable {
    case ready
    case blocked(String)

    public var reply: (ready: Bool, message: String?) {
        switch self {
        case .ready: (true, nil)
        case .blocked(let message): (false, message)
        }
    }
}

public enum DaemonUpgradePreparationResult: Equatable, Sendable {
    case ready(baseline: Bool)
    case failed(String)

    public var reply: (succeeded: Bool, message: String?, baseline: Int) {
        switch self {
        case .ready(let baseline): (true, nil, baseline ? 1 : 0)
        case .failed(let message): (false, message, -1)
        }
    }
}

/// Serializes all clients around the single global `disablesleep` setting.
/// A connection identifier may acquire at most one hold, holds union across
/// clients, and the last release reconciles the durable debt.
public final class DaemonHoldCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let debtStore: DaemonSleepDebtStoring
    private let sleepControl: DaemonSleepSettingControlling
    private let now: () -> Date
    private var holders: Set<UUID> = []
    /// Non-nil only after a successful upgrade preparation. The daemon then
    /// remains quiesced until exit, closing the race between the baseline reply
    /// and service unregistration.
    private var preparedUpgradeBaseline: Bool?

    public init(
        debtStore: DaemonSleepDebtStoring,
        sleepControl: DaemonSleepSettingControlling,
        now: @escaping () -> Date = Date.init
    ) {
        self.debtStore = debtStore
        self.sleepControl = sleepControl
        self.now = now
    }

    public var holdCount: Int {
        withLock { holders.count }
    }

    /// Called before the XPC listener starts. A valid marker is authoritative:
    /// it records exactly what this daemon promised to restore before the
    /// previous boot ended.
    @discardableResult
    public func reconcileAtLaunch() -> DaemonReconciliationResult {
        withLock { reconcileDebt() }
    }

    /// Rechecks unresolved launch debt for each authenticated handshake. Active
    /// holders imply that acquisition already completed reconciliation while
    /// holding this same lock, so their intentional debt must not be restored.
    public func reconciliationReadiness() -> DaemonReconciliationReadiness {
        withLock {
            guard holders.isEmpty else { return .ready }
            switch reconcileDebt() {
            case .clean, .clearedAlreadyRestored, .restored:
                return .ready
            case .blocked(let message):
                return .blocked(message)
            }
        }
    }

    /// Returns the exact live baseline only after all owned debt is reconciled.
    /// Existing holders are rejected before any read, write, or debt mutation.
    public func prepareForUpgrade() -> DaemonUpgradePreparationResult {
        withLock {
            if let preparedUpgradeBaseline {
                return .ready(baseline: preparedUpgradeBaseline)
            }
            guard holders.isEmpty else {
                return .failed(
                    "Cannot prepare the daemon upgrade while a client still owns a lid-closed hold."
                )
            }

            switch reconcileDebt() {
            case .clean, .clearedAlreadyRestored, .restored:
                break
            case .blocked(let message):
                return .failed(message)
            }

            guard let baseline = sleepControl.readDisabled() else {
                return .failed(
                    "Could not read disablesleep after reconciling the daemon restore record."
                )
            }
            preparedUpgradeBaseline = baseline
            return .ready(baseline: baseline)
        }
    }

    public func setHold(_ enabled: Bool, for connectionID: UUID) -> DaemonHoldResult {
        withLock {
            enabled
                ? acquire(for: connectionID)
                : release(for: connectionID)
        }
    }

    @discardableResult
    public func connectionInvalidated(_ connectionID: UUID) -> DaemonHoldResult {
        setHold(false, for: connectionID)
    }

    private func acquire(for connectionID: UUID) -> DaemonHoldResult {
        guard preparedUpgradeBaseline == nil else {
            return .failed(
                "The daemon is quiescing for an upgrade and cannot acquire a new hold."
            )
        }
        if holders.contains(connectionID) { return .applied }
        if !holders.isEmpty {
            holders.insert(connectionID)
            return .applied
        }

        let pending = reconcileDebt()
        guard pending.succeeded else {
            if case .blocked(let message) = pending { return .failed(message) }
            return .failed("The previous lid-closed hold could not be reconciled.")
        }

        guard let priorValue = sleepControl.readDisabled() else {
            return .failed("Could not read the current disablesleep value.")
        }

        let debt = DaemonSleepDebt(priorValue: priorValue, setAt: now())
        guard debtStore.save(debt) else {
            return .failed("Could not persist the disablesleep restore record.")
        }

        if !priorValue {
            guard sleepControl.writeDisabled(true), sleepControl.readDisabled() == true else {
                let cleanup = reconcileDebt()
                if !cleanup.succeeded {
                    return .failed(
                        "Could not confirm disablesleep=1; the restore record remains for recovery."
                    )
                }
                return .failed("Could not confirm disablesleep=1.")
            }
        }

        holders.insert(connectionID)
        return .applied
    }

    private func release(for connectionID: UUID) -> DaemonHoldResult {
        guard holders.remove(connectionID) != nil else { return .applied }
        guard holders.isEmpty else { return .applied }

        let result = reconcileDebt()
        switch result {
        case .clean, .clearedAlreadyRestored, .restored:
            return .applied
        case .blocked(let message):
            return .failed(message)
        }
    }

    private func reconcileDebt() -> DaemonReconciliationResult {
        switch debtStore.load() {
        case .none:
            return .clean

        case .unreadable:
            guard let live = sleepControl.readDisabled() else {
                return .blocked(
                    "The restore record and current disablesleep value are unreadable."
                )
            }
            guard !live else {
                return .blocked(
                    "The restore record is unreadable while disablesleep=1; refusing to guess ownership."
                )
            }
            guard debtStore.remove() else {
                return .blocked("Could not remove the unreadable restore record.")
            }
            return .clearedAlreadyRestored(priorValue: false)

        case .valid(let debt):
            guard let live = sleepControl.readDisabled() else {
                return .blocked("Could not read disablesleep while reconciling its restore record.")
            }

            if live != debt.priorValue {
                guard sleepControl.writeDisabled(debt.priorValue),
                      sleepControl.readDisabled() == debt.priorValue
                else {
                    return .blocked(
                        "Could not restore disablesleep to \(debt.priorValue ? 1 : 0); the restore record remains."
                    )
                }
                guard debtStore.remove() else {
                    return .blocked(
                        "disablesleep was restored, but its restore record could not be removed."
                    )
                }
                return .restored(priorValue: debt.priorValue)
            }

            guard debtStore.remove() else {
                return .blocked("Could not remove the completed disablesleep restore record.")
            }
            return .clearedAlreadyRestored(priorValue: debt.priorValue)
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
