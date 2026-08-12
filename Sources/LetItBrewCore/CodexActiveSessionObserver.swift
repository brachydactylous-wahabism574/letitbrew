import Foundation

/// Discovers active Codex tasks that do not emit lifecycle hooks, including
/// compacted continuations and Codex-managed subagents.
///
/// Only structural rollout fields are decoded: session id, working directory,
/// envelope timestamp, and lifecycle event type. Prompt, response, reasoning,
/// tool input, and tool output fields are never decoded or retained.
public actor CodexActiveSessionObserver {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            let id: String?
            let sessionID: String?
            let cwd: String?
            let type: String?

            enum CodingKeys: String, CodingKey {
                case id, cwd, type
                case sessionID = "session_id"
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct ActiveRollout: Sendable {
        let id: String
        let cwd: String
        let startedAt: Date
        let url: URL
    }

    private struct CacheEntry {
        let snapshot: CodexRolloutFileSnapshot
        let active: ActiveRollout?
    }

    private struct LifecycleEdge {
        let date: Date
        let isActive: Bool
        let position: UInt64

        func isLater(than other: LifecycleEdge) -> Bool {
            date > other.date || (date == other.date && position > other.position)
        }
    }

    private struct ParsedStructure {
        var id: String?
        var cwd: String?
        var latestLifecycle: LifecycleEdge?

        mutating func merge(_ other: ParsedStructure) {
            id = id ?? other.id
            cwd = cwd ?? other.cwd
            guard let candidate = other.latestLifecycle else { return }
            if latestLifecycle.map({ candidate.isLater(than: $0) }) ?? true {
                latestLifecycle = candidate
            }
        }
    }

    private static let maximumSegmentBytes = 1_048_576
    private static let maximumCandidateFiles = 128
    private static let maximumAge: TimeInterval = 12 * 3_600

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

    public func applyingFallback(to sessions: [SessionRecord]) -> [SessionRecord] {
        var records = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for active in activeRollouts() {
            if var existing = records[active.id] {
                let hookEdge = existing.eventObservedAt
                    ?? existing.updatedAt.timeIntervalSince1970
                if active.startedAt.timeIntervalSince1970 > hookEdge {
                    if existing.state == .working {
                        existing.accumulatedWorkingTime = SessionTimeline.accumulatedWorkingTime(
                            previous: existing,
                            now: active.startedAt
                        )
                    } else {
                        existing.state = .working
                        existing.detail = nil
                        existing.lastEvent = "CodexTaskStarted"
                        existing.stateChangedAt = active.startedAt
                        existing.stateTransitionID = "codex-task-started:\(active.startedAt.timeIntervalSince1970)"
                    }
                    existing.updatedAt = active.startedAt
                    existing.eventObservedAt = active.startedAt.timeIntervalSince1970
                }
                existing.cwd = active.cwd
                existing.transcriptPath = active.url.path
                records[active.id] = existing
            } else {
                records[active.id] = SessionRecord(
                    id: active.id,
                    tool: "codex",
                    state: .working,
                    detail: nil,
                    cwd: active.cwd,
                    pid: nil,
                    updatedAt: active.startedAt,
                    lastEvent: "CodexTaskStarted",
                    startedAt: active.startedAt,
                    accumulatedWorkingTime: 0,
                    stateChangedAt: active.startedAt,
                    stateTransitionID: "codex-task-started:\(active.startedAt.timeIntervalSince1970)",
                    transcriptPath: active.url.path,
                    eventObservedAt: active.startedAt.timeIntervalSince1970
                )
            }
        }
        return records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func activeRollouts() -> [ActiveRollout] {
        let observedAt = now()
        // Discovery is deliberately bounded to the 128 most recently modified
        // rollout files; path order breaks equal-timestamp ties deterministically.
        var candidates: [CodexRolloutFile] = []
        for url in candidateURLs(around: observedAt) {
            guard let file = validatedRolloutFile(at: url),
                  observedAt.timeIntervalSince(file.snapshot.modifiedAt) < Self.maximumAge
            else { continue }
            candidates.append(file)
            candidates.sort(by: candidatePrecedes)
            if candidates.count > Self.maximumCandidateFiles {
                candidates.removeLast()
            }
        }

        let candidatePaths = Set(candidates.map { $0.url.path })
        cache = cache.filter { candidatePaths.contains($0.key) }
        return candidates.compactMap(activeRollout(in:))
    }

    private func candidatePrecedes(_ lhs: CodexRolloutFile, _ rhs: CodexRolloutFile) -> Bool {
        if lhs.snapshot.modifiedAt != rhs.snapshot.modifiedAt {
            return lhs.snapshot.modifiedAt > rhs.snapshot.modifiedAt
        }
        return lhs.url.path < rhs.url.path
    }

    private func candidateURLs(around date: Date) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let dates = [-1, 0, 1].compactMap {
            calendar.date(byAdding: .day, value: $0, to: date)
        }
        var result: [URL] = []
        for candidate in dates {
            let components = calendar.dateComponents([.year, .month, .day], from: candidate)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { continue }
            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            result.append(contentsOf: urls.filter { $0.pathExtension == "jsonl" })
        }
        return result
    }

    private func validatedRolloutFile(at url: URL) -> CodexRolloutFile? {
        CodexRolloutFile(
            sessionsRoot: sessionsRoot,
            candidate: url,
            beforeOpening: beforeOpeningRollout
        )
    }

    private func activeRollout(in file: CodexRolloutFile) -> ActiveRollout? {
        let snapshot = file.snapshot
        if let cached = cache[file.url.path], cached.snapshot == snapshot {
            return cached.active
        }

        let first = structure(
            in: file,
            offset: 0,
            length: Self.maximumSegmentBytes
        )
        let tailOffset = snapshot.size > UInt64(Self.maximumSegmentBytes)
            ? snapshot.size - UInt64(Self.maximumSegmentBytes)
            : 0
        let tail = tailOffset == 0
            ? ParsedStructure()
            : structure(
                in: file,
                offset: tailOffset,
                length: Self.maximumSegmentBytes,
                discardLeadingPartialLine: true
            )
        var parsed = first
        parsed.merge(tail)

        let stem = file.url.deletingPathExtension().lastPathComponent
        let active: ActiveRollout?
        if let id = parsed.id,
           !id.isEmpty,
           stem == id || stem.hasSuffix("-\(id)"),
           let cwd = parsed.cwd,
           cwd.hasPrefix("/"),
           let lifecycle = parsed.latestLifecycle,
           lifecycle.isActive {
            active = ActiveRollout(
                id: id,
                cwd: cwd,
                startedAt: lifecycle.date,
                url: file.url
            )
        } else {
            active = nil
        }
        cache[file.url.path] = CacheEntry(snapshot: snapshot, active: active)
        return active
    }

    private func structure(
        in file: CodexRolloutFile,
        offset: UInt64,
        length: Int,
        discardLeadingPartialLine: Bool = false
    ) -> ParsedStructure {
        guard var data = file.read(from: offset, upToCount: length), !data.isEmpty else {
            return ParsedStructure()
        }

        var absoluteStart = offset
        if discardLeadingPartialLine, offset > 0,
           file.read(from: offset - 1, upToCount: 1)?.first != 0x0A {
            guard let firstNewline = data.firstIndex(of: 0x0A) else {
                return ParsedStructure()
            }
            let removedCount = data.distance(
                from: data.startIndex,
                to: data.index(after: firstNewline)
            )
            data = Data(data[data.index(after: firstNewline)...])
            absoluteStart += UInt64(removedCount)
        }

        var result = ParsedStructure()
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            guard let newline = data[lineStart...].firstIndex(of: 0x0A) else {
                break
            }
            let line = data[lineStart..<newline]
            let position = absoluteStart + UInt64(data.distance(
                from: data.startIndex,
                to: lineStart
            ))
            if !line.isEmpty,
               let envelope = try? decoder.decode(Envelope.self, from: Data(line)) {
                if envelope.type == "session_meta" {
                    result.id = result.id ?? envelope.payload?.id ?? envelope.payload?.sessionID
                    result.cwd = result.cwd ?? envelope.payload?.cwd
                }
                if envelope.type == "event_msg",
                   let event = envelope.payload?.type,
                   ["task_started", "task_complete", "turn_aborted"].contains(event),
                   let timestamp = envelope.timestamp,
                   let date = parseTimestamp(timestamp) {
                    let edge = LifecycleEdge(
                        date: date,
                        isActive: event == "task_started",
                        position: position
                    )
                    if result.latestLifecycle.map({ edge.isLater(than: $0) }) ?? true {
                        result.latestLifecycle = edge
                    }
                }
            }
            lineStart = data.index(after: newline)
        }
        return result
    }

    private func parseTimestamp(_ value: String) -> Date? {
        fractionalTimestamp.date(from: value) ?? wholeSecondTimestamp.date(from: value)
    }
}
