public protocol DaemonHandshakeChecking: Sendable {
    func checkHandshake() async -> DaemonHandshakeResult

    /// Must prepare the same authenticated stale-daemon session that produced
    /// the refreshable handshake. A fresh connection is not equivalent because
    /// it would reopen the acquisition race before unregistration.
    func prepareForRefresh() async -> DaemonRecoveryPreparationResult
}

public protocol DaemonServiceControlling: Sendable {
    func stopServiceForRefresh() async -> DaemonServiceOperationResult
    func startService() async -> DaemonServiceOperationResult
}

public protocol DaemonRecoveryPersisting: Sendable {
    func loadRecoverySnapshot() -> DaemonRecoveryPersistenceLoadResult

    /// Must be durably written before an automatic unregister/register attempt.
    func recordAutomaticRefreshAttempt(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult

    /// Called only after an exact build/protocol match and healthy reconciliation.
    func recordHealthyIdentity(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult
}

public struct DaemonRecoveryContext: Equatable, Sendable {
    public let expectedIdentity: DaemonRecoveryIdentity
    public let closedLidEnabled: Bool
    public let mayManageService: Bool
    public let ineligibleMessage: String

    public init(
        expectedIdentity: DaemonRecoveryIdentity,
        closedLidEnabled: Bool,
        mayManageService: Bool,
        ineligibleMessage: String = "Run the correctly signed Let It Brew app directly from /Applications."
    ) {
        self.expectedIdentity = expectedIdentity
        self.closedLidEnabled = closedLidEnabled
        self.mayManageService = mayManageService
        self.ineligibleMessage = ineligibleMessage
    }
}

/// Executes one serialized recovery decision. All system behavior is injected;
/// AppCore itself never touches XPC, ServiceManagement, processes, or power state.
public actor DaemonRecoveryCoordinator {
    public typealias StateObserver = @Sendable (DaemonRecoveryState) -> Void

    private let handshakeChecker: any DaemonHandshakeChecking
    private let serviceController: any DaemonServiceControlling
    private let persistence: any DaemonRecoveryPersisting
    private let stateObserver: StateObserver

    public init(
        handshakeChecker: any DaemonHandshakeChecking,
        serviceController: any DaemonServiceControlling,
        persistence: any DaemonRecoveryPersisting,
        stateObserver: @escaping StateObserver = { _ in }
    ) {
        self.handshakeChecker = handshakeChecker
        self.serviceController = serviceController
        self.persistence = persistence
        self.stateObserver = stateObserver
    }

    @discardableResult
    public func run(
        context: DaemonRecoveryContext,
        trigger: DaemonRecoveryTrigger = .automaticLaunch
    ) async -> DaemonRecoveryState {
        guard context.mayManageService else {
            return emit(.ineligible(message: context.ineligibleMessage))
        }

        emit(.checking)
        let initialHandshake = await handshakeChecker.checkHandshake()

        if isExactAndHealthy(initialHandshake, expected: context.expectedIdentity) {
            return finishHealthy(expected: context.expectedIdentity)
        }

        // The explicit off preference may still benefit from a successful
        // handshake, but it prevents persistence reads and all service mutation
        // after a failed/mismatched check.
        guard context.closedLidEnabled else {
            return emit(.deferredUntilEnabled)
        }

        if case .approvalRequired(let message) = initialHandshake {
            return emit(.approvalRequired(message: message))
        }

        let snapshot: DaemonRecoveryPersistenceSnapshot
        switch persistence.loadRecoverySnapshot() {
        case .loaded(let loaded):
            snapshot = loaded
        case .failed(let message):
            return emit(.retryableFailure(.persistenceFailed(message: message)))
        }

        let decision = DaemonRecoveryPolicy.decide(
            expected: context.expectedIdentity,
            closedLidEnabled: context.closedLidEnabled,
            trigger: trigger,
            persistence: snapshot,
            handshake: initialHandshake
        )

        switch decision {
        case .acceptHealthy:
            return finishHealthy(expected: context.expectedIdentity)
        case .deferUntilEnabled:
            return emit(.deferredUntilEnabled)
        case .approvalRequired(let message):
            return emit(.approvalRequired(message: message))
        case .fail(let failure):
            return emit(.retryableFailure(failure))
        case .requestAutomaticRefresh:
            switch persistence.recordAutomaticRefreshAttempt(context.expectedIdentity) {
            case .succeeded:
                return await refresh(context: context)
            case .failed(let message):
                return emit(.retryableFailure(.persistenceFailed(message: message)))
            }
        case .requestExplicitRefresh:
            return await refresh(context: context)
        case .requestExplicitSetup:
            return await startAndVerify(context: context)
        }
    }

    private func refresh(context: DaemonRecoveryContext) async -> DaemonRecoveryState {
        emit(.finishingUpdate)
        switch await handshakeChecker.prepareForRefresh() {
        case .prepared:
            break
        case .failed(let message):
            return emit(.retryableFailure(.upgradePreparationFailed(
                message: message
            )))
        }
        switch await serviceController.stopServiceForRefresh() {
        case .succeeded:
            return await startAndVerify(context: context)
        case .approvalRequired(let message):
            return emit(.approvalRequired(message: message))
        case .failed(let message):
            return emit(.retryableFailure(.serviceStopFailed(message: message)))
        case .ineligible(let message):
            return emit(.ineligible(message: message))
        }
    }

    private func startAndVerify(context: DaemonRecoveryContext) async -> DaemonRecoveryState {
        emit(.restartingSupport)
        switch await serviceController.startService() {
        case .succeeded:
            break
        case .approvalRequired(let message):
            return emit(.approvalRequired(message: message))
        case .failed(let message):
            return emit(.retryableFailure(.serviceStartFailed(message: message)))
        case .ineligible(let message):
            return emit(.ineligible(message: message))
        }

        let verification = await handshakeChecker.checkHandshake()
        guard isExactAndHealthy(verification, expected: context.expectedIdentity) else {
            if case .approvalRequired(let message) = verification {
                return emit(.approvalRequired(message: message))
            }
            return emit(.retryableFailure(DaemonRecoveryPolicy.failure(
                for: verification,
                expected: context.expectedIdentity
            )))
        }
        return finishHealthy(expected: context.expectedIdentity)
    }

    private func finishHealthy(expected: DaemonRecoveryIdentity) -> DaemonRecoveryState {
        switch persistence.recordHealthyIdentity(expected) {
        case .succeeded:
            return emit(.ready)
        case .failed(let message):
            return emit(.retryableFailure(.persistenceFailed(message: message)))
        }
    }

    private func isExactAndHealthy(
        _ result: DaemonHandshakeResult,
        expected: DaemonRecoveryIdentity
    ) -> Bool {
        guard case .responded(let evidence) = result else { return false }
        return evidence.protocolVersion == expected.protocolVersion
            && evidence.daemonBuild == expected.daemonBuild
            && evidence.reconciliation == .healthy
    }

    @discardableResult
    private func emit(_ state: DaemonRecoveryState) -> DaemonRecoveryState {
        stateObserver(state)
        return state
    }
}
