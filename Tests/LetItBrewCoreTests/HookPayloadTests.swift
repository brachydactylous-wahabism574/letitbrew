import Testing
import Foundation
@testable import LetItBrewCore

@Test func decodesSnakeCaseFields() throws {
    let json = Data("""
    {"session_id":"abc","cwd":"/tmp/repo","hook_event_name":"Stop","tool_name":"Bash",
     "notification_type":"idle_prompt",
     "message":"private notification prose",
     "last_assistant_message":"private assistant prose",
     "transcript_path":"/Users/me/.codex/sessions/rollout-abc.jsonl"}
    """.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.sessionId == "abc")
    #expect(payload.cwd == "/tmp/repo")
    #expect(payload.hookEventName == "Stop")
    #expect(payload.toolName == "Bash")
    #expect(payload.notificationType == "idle_prompt")
    #expect(payload.transcriptPath == "/Users/me/.codex/sessions/rollout-abc.jsonl")
}

@Test func ignoresUnknownFieldsAndMissingFields() throws {
    let json = Data(#"{"session_id":"abc","brand_new_field":{"nested":1}}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.sessionId == "abc")
    #expect(payload.toolName == nil)
    #expect(payload.notificationType == nil)
}

@Test func decodesEmptyObject() throws {
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data("{}".utf8))
    #expect(payload.sessionId == nil)
}
