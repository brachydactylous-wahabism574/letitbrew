import Foundation

public enum ClamshellStateReading: String, Equatable, Sendable {
    case open
    case closed
    case unreadable
}

public enum ActiveDisplayTopologyReading: String, Equatable, Sendable {
    case noExternalDisplay
    case externalDisplayActive
    case unreadable
}

public protocol ClamshellMonitoring: Sendable {
    func currentClamshellState() -> ClamshellStateReading
}

public protocol ActiveDisplayMonitoring: Sendable {
    func currentDisplayTopology() -> ActiveDisplayTopologyReading
}

public enum LidCloseDisplaySleepAction: Equatable, Sendable {
    case none
    case sleepDisplays
}

/// Detects observed transitions into closed-lid operation without an external
/// display and decides whether Let It Brew should immediately sleep displays. The
/// command fires once when the lid closes in that topology or when the last
/// external display disconnects while the lid remains closed. Startup and
/// unreadable samples never synthesize a transition.
public struct LidCloseDisplaySleepCoordinator: Sendable {
    private var previousClamshellState: ClamshellStateReading?
    private var previousDisplayTopology: ActiveDisplayTopologyReading?

    public init() {}

    public mutating func evaluate(
        clamshell: ClamshellStateReading,
        displays: ActiveDisplayTopologyReading,
        letitbrewOwnsOrNeedsLidHold: Bool
    ) -> LidCloseDisplaySleepAction {
        switch clamshell {
        case .unreadable:
            previousClamshellState = nil
            previousDisplayTopology = nil
            return .none
        case .open:
            previousClamshellState = .open
            previousDisplayTopology = readable(displays)
            return .none
        case .closed:
            let observedCloseEdge = previousClamshellState == .open
            let observedExternalDisconnect = previousClamshellState == .closed
                && previousDisplayTopology == .externalDisplayActive
                && displays == .noExternalDisplay
            previousClamshellState = .closed
            previousDisplayTopology = readable(displays)
            guard observedCloseEdge || observedExternalDisconnect,
                  letitbrewOwnsOrNeedsLidHold,
                  displays == .noExternalDisplay
            else { return .none }
            return .sleepDisplays
        }
    }

    private func readable(
        _ displays: ActiveDisplayTopologyReading
    ) -> ActiveDisplayTopologyReading? {
        displays == .unreadable ? nil : displays
    }
}

public enum DisplaySleepCommandResult: Equatable, Sendable {
    case succeeded
    case failed(message: String)
}

public protocol DisplaySleepCommanding: Sendable {
    func sleepDisplays() -> DisplaySleepCommandResult
}

public enum DisplaySleepCommandSpecification {
    public static let executablePath = "/usr/bin/pmset"
    public static let arguments = ["displaysleepnow"]
}

public struct LidCloseDisplaySleepExecutor: Sendable {
    private let command: any DisplaySleepCommanding

    public init(command: any DisplaySleepCommanding) {
        self.command = command
    }

    public func perform(_ action: LidCloseDisplaySleepAction) -> DisplaySleepCommandResult? {
        guard action == .sleepDisplays else { return nil }
        return command.sleepDisplays()
    }
}
