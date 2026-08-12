import Foundation

/// The JSON a hook delivers on stdin. Claude Code and Codex use the same
/// field names, so one decoder serves both.
///
/// Every field is optional and unknown fields are ignored on purpose: both
/// tools add fields over time, and a decode failure here would mean a hook
/// that reports nothing.
public struct HookPayload: Decodable, Equatable, Sendable {
    public var sessionId: String?
    public var cwd: String?
    public var hookEventName: String?
    public var toolName: String?
    public var notificationType: String?
    public var transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case transcriptPath = "transcript_path"
    }

    public init(
        sessionId: String? = nil,
        cwd: String? = nil,
        hookEventName: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.notificationType = notificationType
        self.transcriptPath = transcriptPath
    }
}
