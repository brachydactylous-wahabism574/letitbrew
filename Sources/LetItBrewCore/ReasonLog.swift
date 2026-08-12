import Foundation

/// Decides when `letitbrew watch` should print a line for the current
/// decision reason.
///
/// During the idle grace, `decide()`'s reason embeds a countdown
/// ("all idle, releasing in 214s") that decrements every tick, so comparing
/// the raw reason string logs once a second — roughly 300 lines over a
/// single 5-minute grace period. Genuine transitions (holding ↔ released,
/// working ↔ idle, a guard tripping) must still log immediately;
/// only a change confined to that countdown number should be throttled.
public enum ReasonLog {
    /// Whether `reason` should be printed now, given the last reason that
    /// WAS printed and when. Nothing printed yet (`lastLogged == nil`)
    /// always logs.
    public static func shouldLog(
        reason: String, lastLogged: String?, lastLoggedAt: Date, now: Date,
        throttle: TimeInterval = 30
    ) -> Bool {
        guard let lastLogged else { return true }
        if reason == lastLogged { return false }
        if shape(reason) != shape(lastLogged) { return true }
        return now.timeIntervalSince(lastLoggedAt) >= throttle
    }

    /// `reason` with its countdown number (if any) blanked out, so two
    /// reasons that differ only in that number compare equal while any
    /// other change — including a different session count or a different
    /// guard — still compares different.
    static func shape(_ reason: String) -> String {
        guard let range = reason.range(of: #"releasing in \d+s"#, options: .regularExpression) else {
            return reason
        }
        return reason.replacingCharacters(in: range, with: "releasing in Ns")
    }
}
