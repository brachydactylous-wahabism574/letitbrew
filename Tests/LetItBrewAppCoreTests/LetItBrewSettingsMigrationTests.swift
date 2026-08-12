import Testing
@testable import LetItBrewAppCore

private final class MigrationStore: LetItBrewSettingsMigrationPersisting, @unchecked Sendable {
    var migrationCompleted: Bool
    var explicitPause: Bool?
    var explicitClosedLid: Bool?
    var legacySystemMode: String?
    var legacyClosedLidMode: String?
    var pauseWrites: [Bool] = []
    var closedLidWrites: [Bool] = []
    var completionWrites = 0
    var discardedLegacyValues = false

    init(
        migrationCompleted: Bool = false,
        explicitPause: Bool? = nil,
        explicitClosedLid: Bool? = nil,
        legacySystemMode: String? = nil,
        legacyClosedLidMode: String? = nil
    ) {
        self.migrationCompleted = migrationCompleted
        self.explicitPause = explicitPause
        self.explicitClosedLid = explicitClosedLid
        self.legacySystemMode = legacySystemMode
        self.legacyClosedLidMode = legacyClosedLidMode
    }

    func loadMigrationCompleted() -> Bool { migrationCompleted }
    func loadExplicitPause() -> Bool? { explicitPause }
    func loadExplicitClosedLidEnabled() -> Bool? { explicitClosedLid }
    func loadLegacySystemMode() -> String? { legacySystemMode }
    func loadLegacyClosedLidMode() -> String? { legacyClosedLidMode }

    func savePause(_ isPaused: Bool) {
        pauseWrites.append(isPaused)
        explicitPause = isPaused
    }

    func saveClosedLidEnabled(_ isEnabled: Bool) {
        closedLidWrites.append(isEnabled)
        explicitClosedLid = isEnabled
    }

    func discardLegacyHoldModes() {
        discardedLegacyValues = true
        legacySystemMode = nil
        legacyClosedLidMode = nil
    }

    func markMigrationCompleted() {
        completionWrites += 1
        migrationCompleted = true
    }
}

@Test func freshInstallDefaultsToAutomaticSystemHoldsAndClosedLidEnabled() {
    let store = MigrationStore()

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(result == LetItBrewSettingsMigrationResult(
        isPaused: false,
        isClosedLidEnabled: true,
        didMigrate: true
    ))
    #expect(store.pauseWrites == [false])
    #expect(store.closedLidWrites == [true])
    #expect(store.completionWrites == 1)
    #expect(store.discardedLegacyValues)
}

@Test(arguments: [
    (legacy: "Off", expectedPause: true),
    (legacy: "Auto", expectedPause: false),
    (legacy: "Always", expectedPause: false)
])
func legacySystemModeMigratesToPauseOrAutomatic(
    legacy: String,
    expectedPause: Bool
) {
    let store = MigrationStore(legacySystemMode: legacy)

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(result.isPaused == expectedPause)
    #expect(store.explicitPause == expectedPause)
}

@Test(arguments: [
    (legacy: "Off", expectedEnabled: false),
    (legacy: "Auto", expectedEnabled: true),
    (legacy: "Always", expectedEnabled: true)
])
func legacyClosedLidModeMigratesToBooleanChoice(
    legacy: String,
    expectedEnabled: Bool
) {
    let store = MigrationStore(legacyClosedLidMode: legacy)

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(result.isClosedLidEnabled == expectedEnabled)
    #expect(store.explicitClosedLid == expectedEnabled)
}

@Test func explicitModernChoicesWinOverConflictingLegacyModes() {
    let store = MigrationStore(
        explicitPause: false,
        explicitClosedLid: true,
        legacySystemMode: "Off",
        legacyClosedLidMode: "Off"
    )

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(!result.isPaused)
    #expect(result.isClosedLidEnabled)
    #expect(store.pauseWrites.isEmpty)
    #expect(store.closedLidWrites.isEmpty)
    #expect(store.discardedLegacyValues)
    #expect(store.migrationCompleted)
}

@Test func complementaryModernChoicesAlsoWinOverLegacyModes() {
    let store = MigrationStore(
        explicitPause: true,
        explicitClosedLid: false,
        legacySystemMode: "Always",
        legacyClosedLidMode: "Always"
    )

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(result.isPaused)
    #expect(!result.isClosedLidEnabled)
    #expect(store.pauseWrites.isEmpty)
    #expect(store.closedLidWrites.isEmpty)
    #expect(store.discardedLegacyValues)
    #expect(store.migrationCompleted)
}

@Test func completedMigrationNeverReappliesChangedLegacyModes() {
    let store = MigrationStore(
        migrationCompleted: true,
        explicitPause: false,
        explicitClosedLid: true,
        legacySystemMode: "Off",
        legacyClosedLidMode: "Off"
    )

    let result = LetItBrewSettingsMigrator.migrateIfNeeded(using: store)

    #expect(result == LetItBrewSettingsMigrationResult(
        isPaused: false,
        isClosedLidEnabled: true,
        didMigrate: false
    ))
    #expect(store.pauseWrites.isEmpty)
    #expect(store.closedLidWrites.isEmpty)
    #expect(store.completionWrites == 0)
    #expect(!store.discardedLegacyValues)
}
