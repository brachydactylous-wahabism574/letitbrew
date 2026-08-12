import Darwin
import Foundation
import Testing
@testable import LetItBrewAppCore

private func stagedProcessStub(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("stub.sh")
    try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: url.path
    )
    return url
}

private func runSmallControlStubSynchronously(
    executableURL: URL,
    input: Data
) throws -> (status: Int32, output: Data) {
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.executableURL = executableURL
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try process.run()
    try inputPipe.fileHandleForWriting.write(contentsOf: input)
    try inputPipe.fileHandleForWriting.close()

    // This control stub emits only two short lines. Reading it synchronously
    // makes process EOF the barrier and avoids depending on an unrelated global
    // dispatch reader being scheduled within an arbitrary wall-clock timeout.
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

private let initializeLine = Data("{\"id\":1,\"method\":\"initialize\"}\n".utf8)
private let initializedAndHooksLines = Data(
    "{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"hooks/list\"}\n".utf8
)

private func strictHandshakeStub() throws -> URL {
    try stagedProcessStub("""
    IFS= read -r initialize
    if IFS= read -r -t 1 premature; then
      printf '{"id":1,"result":{"ready":true}}\\n'
      printf '{"dropped":true}\\n'
      exit 0
    fi
    printf '{"id":1,"result":{"ready":true}}\\n'
    IFS= read -r initialized
    IFS= read -r hooks
    case "$initialized:$hooks" in
      *initialized*:*hooks/list*) ;;
      *) exit 3 ;;
    esac
    i=0
    while [ "$i" -lt 4096 ]; do
      printf '{"log":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\\n'
      i=$((i + 1))
    done
    printf '{"id":2,"result":{"hooks":[]}}\\n'
    """)
}

@Test func strictStubDropsHooksThatArriveBeforeInitializeCompletes() throws {
    let stub = try strictHandshakeStub()
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }
    var batched = initializeLine
    batched.append(initializedAndHooksLines)

    let result = try runSmallControlStubSynchronously(
        executableURL: stub,
        input: batched
    )
    let output = String(decoding: result.output, as: UTF8.self)

    #expect(result.status == 0)
    #expect(output.contains(#""id":1"#))
    #expect(output.contains(#""dropped":true"#))
    #expect(!output.contains(#""id":2"#))
}

@Test func stagedExchangeWaitsForInitializeAndDrainsOutputBeforeHooksResponse() throws {
    let stub = try strictHandshakeStub()
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let result = StagedJSONLineProcessRunner.run(
        executableURL: stub,
        stages: [
            StagedJSONLineRequest(input: initializeLine, responseID: 1),
            StagedJSONLineRequest(input: initializedAndHooksLines, responseID: 2),
        ],
        // The stub deliberately emits enough data to fill a pipe. Under the
        // full parallel suite, unrelated process-heavy tests can starve its
        // reader for several seconds; that scheduler delay is not the timeout
        // behavior this test is asserting. Keep a generous outer bound while
        // the dedicated timeout tests below retain short, exact deadlines.
        timeout: 20
    )

    #expect(result.completedResponseIDs == [1, 2])
    #expect(!result.stageTimedOut)
    #expect(result.launchError == nil)
    #expect(result.output.count > 200_000)
    #expect(String(decoding: result.output, as: UTF8.self).contains(#""id":2"#))
}

@Test func stagedExchangeTimeoutKillsAndReapsTheProcess() throws {
    let stub = try stagedProcessStub("""
    IFS= read -r initialize
    trap '' TERM
    while :; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let started = Date()
    let result = StagedJSONLineProcessRunner.run(
        executableURL: stub,
        stages: [StagedJSONLineRequest(input: initializeLine, responseID: 1)],
        timeout: 0.5,
        terminationGrace: 0.1
    )

    #expect(result.stageTimedOut)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(result.processIdentifier != nil)
    if let pid = result.processIdentifier {
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}

@Test func completedExchangeStillKillsAndReapsANonCooperativeServer() throws {
    let stub = try stagedProcessStub("""
    IFS= read -r initialize
    printf '{"id":1,"result":{"ready":true}}\\n'
    IFS= read -r initialized
    IFS= read -r hooks
    # The response is the observable barrier: once the parent sees id 2, this
    # process has already installed its non-cooperative TERM disposition.
    trap '' TERM
    printf '{"id":2,"result":{"hooks":[]}}\\n'
    while :; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: stub.deletingLastPathComponent()) }

    let result = StagedJSONLineProcessRunner.run(
        executableURL: stub,
        stages: [
            StagedJSONLineRequest(input: initializeLine, responseID: 1),
            StagedJSONLineRequest(input: initializedAndHooksLines, responseID: 2),
        ],
        // Completion/cleanup is the behavior under test. Scheduler contention
        // before the responses must not turn this into a stage-timeout test.
        timeout: 20,
        terminationGrace: 0.1
    )

    #expect(result.completedResponseIDs == [1, 2])
    #expect(!result.stageTimedOut)
    #expect(result.wasForceKilled)
    if let pid = result.processIdentifier {
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
