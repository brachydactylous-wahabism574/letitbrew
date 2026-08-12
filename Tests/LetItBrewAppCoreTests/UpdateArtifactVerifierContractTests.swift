import Foundation
import Testing

@Test func artifactVerifierNeverExecutesCandidateCodeForMetadata() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repository.appendingPathComponent("scripts/verify-artifact.sh"),
        encoding: .utf8
    )

    #expect(source.contains("embedded_plist_string \"$HELPER\" CFBundleShortVersionString"))
    #expect(source.contains("embedded_plist_string \"$HELPER\" CFBundleVersion"))
    #expect(!source.contains("\"$HELPER\" --version"),
            "Mounted or staged candidate executables must never run during verification.")
}
