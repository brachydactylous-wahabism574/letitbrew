import Foundation

/// Decides what to do about the global `disablesleep` flag on each tick.
///
/// The flag is system-wide, so several things can hold it and Let It Brew cannot
/// tell them apart: a hold the user set by hand and one another app set look
/// identical. The rule that falls out is **never clear what we did not take**.
/// Our own crashes are covered by the watchdog, not by clearing foreign state.
public enum LidHold {
    public enum Action: Equatable, Sendable {
        case none
        case take
        case release
    }

    public static func next(desired: Bool, systemDisabled: Bool, weOwn: Bool) -> Action {
        switch (desired, weOwn, systemDisabled) {
        case (true, true, _):
            return .none                 // already ours
        case (true, false, true):
            return .none                 // someone else holds it; leave it be
        case (true, false, false):
            return .take
        case (false, true, _):
            return .release              // give back exactly what we took
        case (false, false, _):
            return .none                 // not ours to clear
        }
    }
}
