import Foundation
import Testing
@testable import LetItBrewAppCore

private let expectedCodexEvents: Set<String> = [
    "sessionStart", "userPromptSubmit", "preToolUse", "postToolUse",
    "permissionRequest", "stop", "sessionEnd",
]

private func hook(
    event: String,
    trust: String = "trusted",
    enabled: Bool = true,
    command: String = "run; : # __letitbrew_codex_hook",
    sourcePath: String = "/Users/test/.codex/hooks.json"
) -> [String: Any] {
    [
        "eventName": event,
        "trustStatus": trust,
        "enabled": enabled,
        "command": command,
        "sourcePath": sourcePath,
    ]
}

private func response(
    hooks: [[String: Any]],
    errors: [[String: Any]] = []
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": 2,
        "result": [
            "data": [[
                "cwd": "/Users/test",
                "errors": errors,
                "hooks": hooks,
                "warnings": [],
            ]],
        ],
    ])
}

@Test func trustedEnabledLetItBrewHooksAreConnected() throws {
    let hooks = expectedCodexEvents.map { hook(event: $0) }
    let result = CodexHookTrust.classify(
        responseData: try response(hooks: hooks),
        expectedEvents: expectedCodexEvents,
        expectedSourcePath: "/Users/test/.codex/hooks.json",
        ownershipSuffix: ": # __letitbrew_codex_hook"
    )
    #expect(result == .trusted)
}

@Test func managedHooksAreAlsoConnected() throws {
    let hooks = expectedCodexEvents.map { hook(event: $0, trust: "managed") }
    let result = CodexHookTrust.classify(
        responseData: try response(hooks: hooks),
        expectedEvents: expectedCodexEvents,
        expectedSourcePath: "/Users/test/.codex/hooks.json",
        ownershipSuffix: ": # __letitbrew_codex_hook"
    )
    #expect(result == .trusted)
}

@Test func untrustedModifiedOrDisabledHooksNeedApproval() throws {
    for changed in [
        hook(event: "stop", trust: "untrusted"),
        hook(event: "stop", trust: "modified"),
        hook(event: "stop", enabled: false),
    ] {
        var hooks = expectedCodexEvents.subtracting(["stop"]).map { hook(event: $0) }
        hooks.append(changed)
        let result = CodexHookTrust.classify(
            responseData: try response(hooks: hooks),
            expectedEvents: expectedCodexEvents,
            expectedSourcePath: "/Users/test/.codex/hooks.json",
            ownershipSuffix: ": # __letitbrew_codex_hook"
        )
        #expect(result == .approvalRequired)
    }
}

@Test func foreignHooksAreIgnoredAndCannotMakeLetItBrewLookConnected() throws {
    let foreign = expectedCodexEvents.map {
        hook(event: $0, command: "foreign", sourcePath: "/tmp/foreign-hooks.json")
    }
    let result = CodexHookTrust.classify(
        responseData: try response(hooks: foreign),
        expectedEvents: expectedCodexEvents,
        expectedSourcePath: "/Users/test/.codex/hooks.json",
        ownershipSuffix: ": # __letitbrew_codex_hook"
    )
    #expect(result == .couldNotVerify)
}

@Test func missingDuplicatedUnknownOrErroredHooksCannotLookConnected() throws {
    let complete = expectedCodexEvents.map { hook(event: $0) }
    let cases: [Data] = [
        try response(hooks: Array(complete.dropFirst())),
        try response(hooks: complete + [hook(event: "stop")]),
        try response(hooks: expectedCodexEvents.map { hook(event: $0, trust: "future-state") }),
        try response(hooks: complete, errors: [["message": "bad hooks", "path": "/tmp/hooks.json"]]),
        Data("not json".utf8),
    ]

    for data in cases {
        let result = CodexHookTrust.classify(
            responseData: data,
            expectedEvents: expectedCodexEvents,
            expectedSourcePath: "/Users/test/.codex/hooks.json",
            ownershipSuffix: ": # __letitbrew_codex_hook"
        )
        #expect(result == .couldNotVerify)
    }
}

@Test func appServerOutputSelectsTheHooksListResponseByRequestID() throws {
    let initialization = Data(#"{"id":1,"result":{"userAgent":"codex"}}"#.utf8)
    let trust = try response(hooks: expectedCodexEvents.map { hook(event: $0) })
    var output = initialization
    output.append(Data("\n".utf8))
    output.append(trust)
    output.append(Data("\n".utf8))

    let result = CodexHookTrust.classifyAppServerOutput(
        output,
        expectedEvents: expectedCodexEvents,
        expectedSourcePath: "/Users/test/.codex/hooks.json",
        ownershipSuffix: ": # __letitbrew_codex_hook"
    )
    #expect(result == .trusted)
}
