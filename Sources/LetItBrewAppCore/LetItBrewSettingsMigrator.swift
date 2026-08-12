/// Storage boundary for the one-time migration from the removed three-state
/// hold controls to Let It Brew's explicit pause and closed-lid choices.
public protocol LetItBrewSettingsMigrationPersisting: Sendable {
    func loadMigrationCompleted() -> Bool
    func loadExplicitPause() -> Bool?
    func loadExplicitClosedLidEnabled() -> Bool?
    func loadLegacySystemMode() -> String?
    func loadLegacyClosedLidMode() -> String?
    func savePause(_ isPaused: Bool)
    func saveClosedLidEnabled(_ isEnabled: Bool)
    func discardLegacyHoldModes()
    func markMigrationCompleted()
}

public struct LetItBrewSettingsMigrationResult: Equatable, Sendable {
    public let isPaused: Bool
    public let isClosedLidEnabled: Bool
    public let didMigrate: Bool

    public init(
        isPaused: Bool,
        isClosedLidEnabled: Bool,
        didMigrate: Bool
    ) {
        self.isPaused = isPaused
        self.isClosedLidEnabled = isClosedLidEnabled
        self.didMigrate = didMigrate
    }
}

public enum LetItBrewSettingsMigrator {
    /// Migrates legacy values exactly once. Explicit modern choices always win.
    /// Missing values use the beta defaults: automatic system holds and
    /// closed-lid support enabled.
    public static func migrateIfNeeded(
        using persistence: any LetItBrewSettingsMigrationPersisting
    ) -> LetItBrewSettingsMigrationResult {
        let explicitPause = persistence.loadExplicitPause()
        let explicitClosedLid = persistence.loadExplicitClosedLidEnabled()

        guard !persistence.loadMigrationCompleted() else {
            return LetItBrewSettingsMigrationResult(
                isPaused: explicitPause ?? false,
                isClosedLidEnabled: explicitClosedLid ?? true,
                didMigrate: false
            )
        }

        let isPaused = explicitPause
            ?? (persistence.loadLegacySystemMode() == "Off")
        let isClosedLidEnabled = explicitClosedLid
            ?? (persistence.loadLegacyClosedLidMode() != "Off")

        if explicitPause == nil {
            persistence.savePause(isPaused)
        }
        if explicitClosedLid == nil {
            persistence.saveClosedLidEnabled(isClosedLidEnabled)
        }

        persistence.discardLegacyHoldModes()
        persistence.markMigrationCompleted()

        return LetItBrewSettingsMigrationResult(
            isPaused: isPaused,
            isClosedLidEnabled: isClosedLidEnabled,
            didMigrate: true
        )
    }
}
