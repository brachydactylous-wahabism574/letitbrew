import Foundation

/// Marker-scoped operations on a decoded hooks tree, shared by every agent
/// integration.
///
/// Both Claude Code and Codex store hooks as `event -> [group]`, where a group
/// holds an array of entries under a `hooks` key and each entry has a
/// `command` string. Only the surrounding file rules differ, so the scanning,
/// stripping, and classifying live here once and take the marker as a
/// parameter. Every operation is keyed on the caller's marker, so one
/// integration can never touch another's entries.
///
/// Everything is `[String: Any]` rather than typed models on purpose: these
/// trees come from files the user owns, and a typed round trip would silently
/// drop keys we do not model.
public enum HookFile {
    /// The exact trailing comment that marks a command as ours. Matching the
    /// full sentinel rather than the bare marker is what keeps one integration
    /// from owning another's entries when one marker is a prefix of another.
    public static func ownershipComment(marker: String) -> String { ": # \(marker)" }

    /// Whether one entry is ours. The sole definition of ownership: every
    /// other operation here routes through this rather than matching the
    /// marker a second way.
    ///
    /// Anchored with `hasSuffix`, not `contains`: the sentinel is a trailing
    /// shell comment, so nothing meaningful ever follows it. `contains` alone
    /// would still let `__marker_v2`'s sentinel match a `__marker` lookup,
    /// since one sentinel string is a literal prefix of the other; requiring
    /// it at the very end of the command closes that gap.
    public static func isOurs(_ entry: Any, marker: String) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?
            .hasSuffix(ownershipComment(marker: marker)) ?? false
    }

    /// Our command strings across a group array.
    public static func ourCommands(in groups: [Any], marker: String) -> [String] {
        groups.flatMap { group -> [String] in
            guard let group = group as? [String: Any],
                  let entries = group["hooks"] as? [Any] else { return [] }
            return entries
                .filter { isOurs($0, marker: marker) }
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    /// Removes our entries from a group array, dropping a group only when
    /// removing our entries is what left it empty. A group we did not touch —
    /// because none of its entries were ours, or because its shape is one we
    /// do not recognize — passes through completely unchanged: it belongs to
    /// someone else and is not ours to prune or normalize.
    public static func strip(_ groups: [Any], marker: String) -> [Any] {
        groups.compactMap { group -> Any? in
            guard var group = group as? [String: Any],
                  let entries = group["hooks"] as? [Any] else { return group }
            let kept = entries.filter { !isOurs($0, marker: marker) }
            if kept.count == entries.count { return group }
            if kept.isEmpty { return nil }
            group["hooks"] = kept
            return group
        }
    }

    /// Clears our entries from every event, pruning events left empty.
    ///
    /// An event with no owned entry is left completely untouched — including
    /// one whose group array is empty or holds only foreign shapes — because
    /// we never emptied it and it is not ours to prune. Sweeping every event
    /// rather than only the ones about to be rewritten is what makes reinstall
    /// self-healing: an entry left under an event an older version installed
    /// is still ours and still fires, and repair is just a reinstall.
    public static func sweep(_ hooks: [String: Any], marker: String) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            guard !ourCommands(in: groups, marker: marker).isEmpty else { continue }
            let kept = strip(groups, marker: marker)
            if kept.isEmpty { result.removeValue(forKey: event) } else { result[event] = kept }
        }
        return result
    }

    /// One group holding a single command entry, with an optional tool matcher.
    public static func entry(command: String, timeout: Int, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [
                ["type": "command", "command": command, "timeout": timeout] as [String: Any],
            ],
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    /// Classifies an install event by event. `expectedCommand` returns the
    /// command this build would write for a given event, which is how a drifted
    /// path is told apart from a healthy one.
    public static func report(
        hooks: [String: Any]?,
        events: [String],
        marker: String,
        expectedCommand: (String) -> String
    ) -> HookInstallReport {
        var report = HookInstallReport()
        guard let hooks else {
            report.missing = Set(events)
            return report
        }

        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let ours = ourCommands(in: groups, marker: marker)
            guard !ours.isEmpty else { continue }
            guard events.contains(event) else {
                report.orphaned.insert(event)
                continue
            }
            if ours.count > 1 {
                report.duplicated.insert(event)
            } else if ours[0] != expectedCommand(event) {
                report.stale.insert(event)
            } else {
                report.healthy.insert(event)
            }
        }

        report.missing = Set(events)
            .subtracting(report.healthy)
            .subtracting(report.stale)
            .subtracting(report.duplicated)
        return report
    }
}
