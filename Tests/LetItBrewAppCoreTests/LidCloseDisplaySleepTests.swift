import Foundation
import Testing
@testable import LetItBrewAppCore

private final class RecordingDisplaySleepCommand: DisplaySleepCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    var result: DisplaySleepCommandResult = .succeeded

    var count: Int {
        lock.withLock { recordedCount }
    }

    func sleepDisplays() -> DisplaySleepCommandResult {
        lock.withLock { recordedCount += 1 }
        return result
    }
}

@Test func observedOpenToClosedEdgeSleepsDisplaysOnce() {
    var coordinator = LidCloseDisplaySleepCoordinator()

    #expect(coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func closedAtStartupDoesNotCreateAnEdge() {
    var coordinator = LidCloseDisplaySleepCoordinator()

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)

    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)
}

@Test func disconnectingTheLastExternalDisplayWhileClosedSleepsDisplaysOnce() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: true
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func eachExternalDisplayDisconnectWhileClosedSleepsDisplaysOnce() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func externalDisplayDisconnectIsObservedWhenTheFirstLidSampleIsClosed() {
    var coordinator = LidCloseDisplaySleepCoordinator()

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .sleepDisplays)
}

@Test func externalDisplayDisconnectWithoutALetItBrewHoldIsConsumedSafely() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .closed,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: false
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: false
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func noLetItBrewHoldConsumesTheEdgeWithoutTakingActionLater() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: false
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: false
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func unreadableClamshellBreaksEdgeContinuityInsteadOfGuessing() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )
    _ = coordinator.evaluate(
        clamshell: .unreadable,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func unreadableDisplayTopologyConsumesTheEdgeSafely() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .unreadable,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func unreadableDisplayTopologyCannotSynthesizeADisconnect() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    _ = coordinator.evaluate(
        clamshell: .closed,
        displays: .externalDisplayActive,
        letitbrewOwnsOrNeedsLidHold: true
    )
    _ = coordinator.evaluate(
        clamshell: .closed,
        displays: .unreadable,
        letitbrewOwnsOrNeedsLidHold: true
    )

    #expect(coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    ) == .none)
}

@Test func commandFailureIsReportedAndDoesNotRepeatForTheSameEdge() {
    var coordinator = LidCloseDisplaySleepCoordinator()
    let command = RecordingDisplaySleepCommand()
    command.result = .failed(message: "pmset failed")
    let executor = LidCloseDisplaySleepExecutor(command: command)
    _ = coordinator.evaluate(
        clamshell: .open,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )

    let first = coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )
    #expect(executor.perform(first) == .failed(message: "pmset failed"))

    let repeated = coordinator.evaluate(
        clamshell: .closed,
        displays: .noExternalDisplay,
        letitbrewOwnsOrNeedsLidHold: true
    )
    #expect(executor.perform(repeated) == nil)
    #expect(command.count == 1)
}

@Test func noActionNeverInvokesTheCommand() {
    let command = RecordingDisplaySleepCommand()
    let executor = LidCloseDisplaySleepExecutor(command: command)

    #expect(executor.perform(.none) == nil)
    #expect(command.count == 0)
}

@Test func displaySleepCommandUsesTheAbsolutePmsetExecutableWithoutAShell() {
    #expect(DisplaySleepCommandSpecification.executablePath == "/usr/bin/pmset")
    #expect(DisplaySleepCommandSpecification.arguments == ["displaysleepnow"])
}
