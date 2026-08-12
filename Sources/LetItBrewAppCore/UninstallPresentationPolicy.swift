public enum UninstallConfirmationPresentationPolicy {
    public static func isPresented(
        state: UninstallState,
        inProgress: Bool
    ) -> Bool {
        state == .awaitingConfirmation && !inProgress
    }

    public static func shouldCancel(
        presented: Bool,
        state: UninstallState,
        inProgress: Bool
    ) -> Bool {
        !presented && state == .awaitingConfirmation && !inProgress
    }
}

public enum UninstallPauseRestorationPolicy {
    public static func canBegin(state: UninstallState) -> Bool {
        state == .idle
    }

    public static func shouldResumeAfterCancellation(
        wasPausedBeforeUninstall: Bool?
    ) -> Bool {
        wasPausedBeforeUninstall == false
    }
}

public enum UninstallStatusItemPresentationPolicy {
    public static func isInserted(
        state: UninstallState,
        reportIsPresented: Bool
    ) -> Bool {
        switch state {
        case .report:
            !reportIsPresented
        default:
            true
        }
    }
}
