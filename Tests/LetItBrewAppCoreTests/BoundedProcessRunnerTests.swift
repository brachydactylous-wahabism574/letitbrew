import Darwin
import Foundation
import Testing
@testable import LetItBrewAppCore

private func processStub(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("stub.sh")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: url.path
    )
    return url
}

@Test func processOutputIsDrainedWhileTheProcessIsRunning() throws {
    let stub = try processStub("yes x | head -c 262144\nprintf '\\nfinished\\n'")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let result = BoundedProcessRunner.run(
        executableURL: stub,
        timeout: 10
    )

    #expect(result.succeeded)
    #expect(!result.timedOut)
    #expect(String(decoding: result.output, as: UTF8.self).hasSuffix("finished\n"))
}

@Test func timedOutProcessIsKilledAndReaped() throws {
    let stub = try processStub("trap '' TERM\nwhile :; do :; done")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let started = Date()
    let result = BoundedProcessRunner.run(
        executableURL: stub,
        timeout: 0.5,
        terminationGrace: 0.1
    )

    #expect(result.timedOut)
    #expect(Date().timeIntervalSince(started) < 2)
    let pid = result.processIdentifier
    #expect(pid != nil)
    if let pid {
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}

@Test func excessOutputIsDrainedButTruncatedAndRefused() throws {
    let stub = try processStub("yes x | head -c 262144\nprintf '\\nfinished\\n'")
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let result = BoundedProcessRunner.run(
        executableURL: stub,
        timeout: 10,
        maximumOutputBytes: 4_096
    )

    #expect(!result.succeeded)
    #expect(result.status == 0)
    #expect(result.outputTruncated)
    #expect(result.output.count == 4_096)
}
