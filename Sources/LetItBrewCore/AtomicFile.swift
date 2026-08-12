import Foundation

/// Thrown when the target file changed between a caller's read and this
/// write — another process or a hand edit landed in that window. With no
/// lock file and no diffing, refusing is the only safe option; overwriting
/// could silently discard whatever the other write just did.
public struct ConcurrentModification: Error {
    public let path: String
    public init(path: String) { self.path = path }
}

/// An atomic, concurrent-edit-aware file write, shared by every command that
/// rewrites a user's config file (Claude Code's `settings.json`, Codex's
/// `hooks.json`).
public enum AtomicFile {
    /// The modification date of `url`, or `nil` if it does not exist (or any
    /// other stat failure — folded into `nil` the same way a missing file
    /// is, since a `nil` prior can never accidentally equal a later real
    /// date, so it always demands the concurrent-edit check below rather
    /// than risking a false "unchanged" match).
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Writes `data` to `url`, but refuses if `url`'s modification date no
    /// longer matches `priorModified` — captured by the caller at read time.
    ///
    /// The check runs TWICE: once up front (fails fast, before doing any
    /// I/O, for the common case where nothing raced) and once again
    /// immediately before the rename that actually replaces `url` — after
    /// the new content has already been written to a temporary file on the
    /// same volume. Checking only up front, before the whole write, leaves
    /// the entire duration of that write as an unguarded window: an edit
    /// landing while the temp file is being written would still be silently
    /// overwritten by the rename. Re-checking right before the rename
    /// narrows that window to as small as it can be made without a lock
    /// file — just the time between the second read and the rename itself.
    ///
    /// `beforeRename` is a test-only seam (default a no-op) that runs after
    /// the temp file is written but before the second check, letting a test
    /// deterministically land a "concurrent" edit exactly inside the window
    /// this fix closes, without relying on real thread timing.
    public static func write(
        _ data: Data, to url: URL, ifUnchangedSince priorModified: Date?,
        beforeRename: () -> Void = {}
    ) throws {
        guard modificationDate(of: url) == priorModified else {
            throw ConcurrentModification(path: url.path)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        beforeRename()

        guard modificationDate(of: url) == priorModified else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ConcurrentModification(path: url.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }
}
