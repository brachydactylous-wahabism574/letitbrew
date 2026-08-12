import Foundation

public enum HookSessionUpdater {
    public static func apply(
        event: String,
        payload: HookPayload,
        agentName: String,
        agentPID: Int32?,
        observedAt: Date,
        storage: SessionStorage
    ) throws {
        guard let sessionID = payload.sessionId, !sessionID.isEmpty else { return }
        guard let effect = HookReducer.reduce(
            event: event,
            toolName: payload.toolName,
            notificationType: payload.notificationType
        ) else { return }

        try storage.mutate(
            id: sessionID,
            observedAt: observedAt.timeIntervalSince1970
        ) { previous in
            if let previousObservedAt = previous?.eventObservedAt,
               previousObservedAt > observedAt.timeIntervalSince1970 {
                return .keep
            }

            switch effect {
            case .end:
                return .delete
            case .set(let state, let detail):
                let transition = SessionStateTransition.resolve(
                    previous: previous,
                    newState: state,
                    now: observedAt
                )
                return .replace(SessionRecord(
                    id: sessionID,
                    tool: agentName,
                    state: state,
                    detail: detail,
                    cwd: payload.cwd ?? FileManager.default.currentDirectoryPath,
                    pid: agentPID,
                    updatedAt: observedAt,
                    lastEvent: event,
                    startedAt: SessionTimeline.startedAt(previous: previous, now: observedAt),
                    accumulatedWorkingTime: SessionTimeline.accumulatedWorkingTime(
                        previous: previous,
                        now: observedAt
                    ),
                    stateChangedAt: transition.changedAt,
                    stateTransitionID: transition.id,
                    transcriptPath: SessionTimeline.transcriptPath(
                        previous: previous,
                        supplied: payload.transcriptPath
                    ),
                    eventObservedAt: observedAt.timeIntervalSince1970
                ))
            }
        }
    }
}
