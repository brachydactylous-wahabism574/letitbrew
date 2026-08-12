import Foundation
import Testing
@testable import LetItBrewAppCore

@Test func discoveryIncludesCommonUserInstallLocationsWithoutShellProfiles() {
    let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
    let candidates = CodexExecutableDiscovery.candidateURLs(
        home: home,
        environment: ["PATH": "/custom/bin:/second/bin"],
        applicationURLs: [URL(fileURLWithPath: "/Applications/ChatGPT.app")]
    ).map(\.path)

    #expect(candidates.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
    #expect(candidates.contains("/tmp/test-home/.local/bin/codex"))
    #expect(candidates.contains("/tmp/test-home/.volta/bin/codex"))
    #expect(candidates.contains("/tmp/test-home/Library/pnpm/codex"))
    #expect(candidates.contains("/custom/bin/codex"))
}

@Test func discoveryFindsAnNVMInstallFromATemporaryHome() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let executable = home.appendingPathComponent(
        ".nvm/versions/node/v22.0.0/bin/codex"
    )
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path
    )
    defer { try? FileManager.default.removeItem(at: home) }

    let located = CodexExecutableDiscovery.locate(
        home: home,
        environment: [:],
        applicationURLs: [],
        isExecutable: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                == executable.resolvingSymlinksInPath()
        }
    )

    #expect(located?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
}
