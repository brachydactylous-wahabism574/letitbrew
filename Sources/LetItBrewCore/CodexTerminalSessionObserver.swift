import Foundation

/// Applies Codex's local terminal events as a conservative fallback when its
/// public lifecycle hook does not emit `Stop` after completion or cancellation.
///
/// Only the outer JSONL envelope (`timestamp`, `type`, and `payload.type`) is
/// decoded. Prompt, response, reasoning, and tool payload fields are ignored,
/// never returned, and never persisted by Let It Brew.
public actor CodexTerminalSessionObserver {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            let type: String?
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct TerminalEdge: Equatable, Sendable {
        let event: String
        let date: Date
        let position: UInt64

        func isLater(than other: TerminalEdge) -> Bool {
            date > other.date || (date == other.date && position > other.position)
        }
    }

    private struct CacheEntry {
        let url: URL
        let snapshot: CodexRolloutFileSnapshot
        let processedOffset: UInt64
        let latestTerminal: TerminalEdge?
    }

    private struct ScanResult {
        let processedOffset: UInt64
        let latestTerminal: TerminalEdge?
    }

    private static let maximumTailBytes: UInt64 = 1_048_576

    private let sessionsRoot: URL
    private let now: @Sendable () -> Date
    private let beforeOpeningRollout: @Sendable (URL) -> Void
    private let decoder = JSONDecoder()
    private let fractionalTimestamp = ISO8601DateFormatter()
    private let wholeSecondTimestamp = ISO8601DateFormatter()
    private var cache: [String: CacheEntry] = [:]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        sessionsRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.now = now
        beforeOpeningRollout = { _ in }
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondTimestamp.formatOptions = [.withInternetDateTime]
    }

    init(
        homeDirectory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        beforeOpeningRollout: @escaping @Sendable (URL) -> Void
    ) {
        sessionsRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.now = now
        self.beforeOpeningRollout = beforeOpeningRollout
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondTimestamp.formatOptions = [.withInternetDateTime]
    }

    /// Returns a presentation/decision snapshot with any newer Codex terminal
    /// edge applied. Hook-owned session files remain untouched, so a later
    /// genuine hook event naturally outranks the fallback by timestamp.
    public func applyingFallback(to sessions: [SessionRecord]) -> [SessionRecord] {
        sessions.map { session in
            guard session.tool.caseInsensitiveCompare("codex") == .orderedSame,
                  session.state != .idle,
                  let file = rolloutFile(for: session),
                  let terminal = latestTerminalEdge(in: file, sessionID: session.id),
                  terminal.date.timeIntervalSince1970
                    > (session.eventObservedAt ?? session.updatedAt.timeIntervalSince1970)
            else { return session }

            var ended = session
            ended.state = .idle
            ended.detail = nil
            ended.updatedAt = terminal.date
            ended.eventObservedAt = terminal.date.timeIntervalSince1970
            ended.stateChangedAt = terminal.date
            switch terminal.event {
            case "task_complete":
                ended.lastEvent = "CodexTaskComplete"
                ended.stateTransitionID = "codex-task-complete:\(terminal.date.timeIntervalSince1970)"
            case "turn_aborted":
                ended.lastEvent = "CodexTurnAborted"
                ended.stateTransitionID = "codex-turn-aborted:\(terminal.date.timeIntervalSince1970)"
            default:
                return session
            }
            return ended
        }
    }

    private func rolloutFile(for session: SessionRecord) -> CodexRolloutFile? {
        if let path = session.transcriptPath,
           let validated = validatedRolloutFile(
               at: URL(fileURLWithPath: path),
               sessionID: session.id
           ) {
            return validated
        }
        return locatedRolloutFile(for: session)
    }

    /// Backward-compatible lookup for records created before Let It Brew retained
    /// `transcript_path`. It examines only likely date directories and exact
    /// filename suffixes; it never recursively walks the user's Codex history.
    private func locatedRolloutFile(for session: SessionRecord) -> CodexRolloutFile? {
        var dates = [session.effectiveStartedAt, session.updatedAt, now()]
        let calendar = Calendar(identifier: .gregorian)
        dates += dates.compactMap { calendar.date(byAdding: .day, value: -1, to: $0) }
        dates += dates.compactMap { calendar.date(byAdding: .day, value: 1, to: $0) }

        var directories: [URL] = []
        var seenPaths: Set<String> = []
        for date in dates {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { continue }
            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            if seenPaths.insert(directory.path).inserted {
                directories.append(directory)
            }
        }

        let suffix = "-\(session.id).jsonl"
        var newest: CodexRolloutFile?
        for directory in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.lastPathComponent.hasSuffix(suffix) {
                guard let file = validatedRolloutFile(at: url, sessionID: session.id) else {
                    continue
                }
                if let existing = newest {
                    if file.snapshot.modifiedAt > existing.snapshot.modifiedAt
                        || (file.snapshot.modifiedAt == existing.snapshot.modifiedAt
                            && file.url.path < existing.url.path) {
                        newest = file
                    }
                } else {
                    newest = file
                }
            }
        }
        return newest
    }

    private func validatedRolloutFile(
        at candidate: URL,
        sessionID: String
    ) -> CodexRolloutFile? {
        let stem = candidate.deletingPathExtension().lastPathComponent
        guard candidate.pathExtension == "jsonl",
              stem == sessionID || stem.hasSuffix("-\(sessionID)")
        else { return nil }
        return CodexRolloutFile(
            sessionsRoot: sessionsRoot,
            candidate: candidate,
            beforeOpening: beforeOpeningRollout
        )
    }

    private func latestTerminalEdge(
        in file: CodexRolloutFile,
        sessionID: String
    ) -> TerminalEdge? {
        let snapshot = file.snapshot
        if let existing = cache[sessionID],
           existing.url == file.url,
           existing.snapshot == snapshot {
            return existing.latestTerminal
        }

        let prior = cache[sessionID]
        let continuesSameFile = prior?.url == file.url
            && prior.map({ snapshot.hasSameFileIdentity(as: $0.snapshot) }) == true
            && snapshot.size > (prior?.snapshot.size ?? 0)
        let retainedTerminal = continuesSameFile ? prior?.latestTerminal : nil
        let unreadStart = continuesSameFile ? (prior?.processedOffset ?? 0) : 0
        let unreadBytes = snapshot.size >= unreadStart
            ? snapshot.size - unreadStart
            : snapshot.size

        let scan: ScanResult?
        if continuesSameFile, unreadBytes <= Self.maximumTailBytes {
            scan = scanCompleteLines(
                in: file,
                startingAt: unreadStart,
                maximumBytes: unreadBytes,
                discardLeadingPartialLine: false
            )
        } else {
            let wantedStart = snapshot.size > Self.maximumTailBytes
                ? snapshot.size - Self.maximumTailBytes
                : 0
            let precedingByte = wantedStart > 0
                ? file.read(from: wantedStart - 1, upToCount: 1)?.first
                : 0x0A
            scan = scanCompleteLines(
                in: file,
                startingAt: wantedStart,
                maximumBytes: snapshot.size - wantedStart,
                discardLeadingPartialLine: wantedStart > 0 && precedingByte != 0x0A
            )
        }

        let scannedTerminal = scan?.latestTerminal
        let latest: TerminalEdge?
        switch (retainedTerminal, scannedTerminal) {
        case let (retained?, scanned?):
            latest = scanned.isLater(than: retained) ? scanned : retained
        case let (retained?, nil):
            latest = retained
        case let (nil, scanned?):
            latest = scanned
        case (nil, nil):
            latest = nil
        }
        cache[sessionID] = CacheEntry(
            url: file.url,
            snapshot: snapshot,
            processedOffset: scan?.processedOffset ?? unreadStart,
            latestTerminal: latest
        )
        return latest
    }

    /// Reads only bytes not processed on a previous scan. The offset advances
    /// through the last complete newline; an incomplete append is reread next
    /// time rather than retained in memory.
    private func scanCompleteLines(
        in file: CodexRolloutFile,
        startingAt offset: UInt64,
        maximumBytes: UInt64,
        discardLeadingPartialLine: Bool
    ) -> ScanResult? {
        guard maximumBytes <= UInt64(Int.max),
              let data = file.read(from: offset, upToCount: Int(maximumBytes))
        else { return nil }
        guard !data.isEmpty else {
            return ScanResult(processedOffset: offset, latestTerminal: nil)
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return ScanResult(processedOffset: offset, latestTerminal: nil)
        }

        let processedOffset = offset + UInt64(data.distance(
            from: data.startIndex,
            to: data.index(after: lastNewline)
        ))
        var completeStart = data.startIndex
        if discardLeadingPartialLine {
            guard let firstNewline = data.firstIndex(of: 0x0A) else {
                return ScanResult(processedOffset: processedOffset, latestTerminal: nil)
            }
            completeStart = data.index(after: firstNewline)
        }

        var latest: TerminalEdge?
        var lineStart = completeStart
        while lineStart <= lastNewline {
            guard let newline = data[lineStart...lastNewline].firstIndex(of: 0x0A) else {
                break
            }
            let line = data[lineStart..<newline]
            let position = offset + UInt64(data.distance(
                from: data.startIndex,
                to: lineStart
            ))
            if !line.isEmpty,
               let envelope = try? decoder.decode(Envelope.self, from: Data(line)),
               envelope.type == "event_msg",
               let event = envelope.payload?.type,
               ["task_complete", "turn_aborted"].contains(event),
               let timestamp = envelope.timestamp,
               let date = parseTimestamp(timestamp) {
                let edge = TerminalEdge(event: event, date: date, position: position)
                if latest.map({ edge.isLater(than: $0) }) ?? true {
                    latest = edge
                }
            }
            lineStart = data.index(after: newline)
        }
        return ScanResult(processedOffset: processedOffset, latestTerminal: latest)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        fractionalTimestamp.date(from: value) ?? wholeSecondTimestamp.date(from: value)
    }
}
