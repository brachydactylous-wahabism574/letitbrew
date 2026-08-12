import Foundation

/// What an install actually looks like on disk, event by event.
///
/// An install drifts in ways a boolean cannot express: the app moves and the
/// baked path stops resolving, a settings sync drops some events, a version
/// adds an event the file has never had, an older install leaves an entry
/// under an event no longer used. Each leaves a file that still "has Let It Brew
/// hooks in it" while doing the wrong thing, or nothing.
public struct HookInstallReport: Equatable, Sendable {
    /// Exactly one of ours, running the command this build would write.
    public var healthy: Set<String> = []
    /// None of ours under this event.
    public var missing: Set<String> = []
    /// Ours, but running a command this build would not write (drifted path).
    public var stale: Set<String> = []
    /// More than one of ours: the hook fires once per copy.
    public var duplicated: Set<String> = []
    /// Ours, under an event this version no longer installs.
    public var orphaned: Set<String> = []

    public init() {}

    public var isHealthy: Bool {
        missing.isEmpty && stale.isEmpty && duplicated.isEmpty && orphaned.isEmpty
    }

    /// Nothing of ours anywhere: never installed, or fully removed.
    public var isAbsent: Bool {
        healthy.isEmpty && stale.isEmpty && duplicated.isEmpty && orphaned.isEmpty
    }
}
