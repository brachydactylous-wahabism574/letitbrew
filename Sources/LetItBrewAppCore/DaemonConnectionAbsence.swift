import Foundation

/// Whether a first-connect transport failure is safe to treat as "no daemon
/// registered". Only `.affirmativelyAbsent` may let an uninstall gate proceed
/// as if there is nothing to reconcile; every other result must block,
/// because a live daemon holding unreconciled `SleepDisabled` debt looks
/// exactly like "unreachable" from the outside if this gets it wrong.
public enum DaemonConnectionAbsence: Equatable, Sendable {
    case affirmativelyAbsent
    case mustBlock
}

/// Classifies a `DaemonConnection.connect()` transport failure using only the
/// underlying `NSError`'s `domain`/`code` — never its free-form description
/// text, which Apple does not guarantee stable across releases.
///
/// Empirically verified against a real macOS system (both a genuinely
/// unregistered mach service and a registered-but-authentication-rejecting
/// one — see the fix report for the exact reproduction):
///
/// - A mach service with **no registered launchd job at all** fails
///   immediately, before the client's `interruptionHandler` ever fires, with
///   `NSCocoaErrorDomain` code `NSXPCConnectionInvalid` (4099) — Foundation's
///   own `NSDebugDescription` for this case reads "...Connection init failed
///   at lookup with error 3 - No such process." This is the only case this
///   classifier treats as absence.
/// - A **registered** daemon that exists but crashes, is killed, or rejects
///   the connection during code-signing authentication instead interrupts
///   the connection first (`interruptionHandler` fires, proving a peer was
///   reached), and the resulting error carries `NSXPCConnectionInterrupted`
///   (4097) — a live peer that stopped talking, never "was never there".
/// - A registered daemon that is mid-crash-loop and currently down is queued
///   by launchd rather than rejected outright, so it surfaces through
///   `DaemonConnection`'s own explicit handshake timeout instead of either
///   signature above — this classifier is never even consulted for that case.
public enum DaemonConnectionAbsenceClassifier {
    public static func classify(domain: String, code: Int) -> DaemonConnectionAbsence {
        guard domain == NSCocoaErrorDomain, code == NSXPCConnectionInvalid else {
            return .mustBlock
        }
        return .affirmativelyAbsent
    }
}
