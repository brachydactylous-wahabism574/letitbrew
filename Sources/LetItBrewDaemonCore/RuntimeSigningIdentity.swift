import Foundation
import Security

public enum RuntimeSigningIdentityError: Error, Equatable, Sendable, LocalizedError {
    case copySelfFailed(OSStatus)
    case copyStaticCodeFailed(OSStatus)
    case signatureInvalid(OSStatus)
    case copySigningInformationFailed(OSStatus)
    case missingIdentifier
    case missingTeamIdentifier
    case missingCodeDirectoryHash

    public var errorDescription: String? {
        switch self {
        case .copySelfFailed(let status):
            "SecCodeCopySelf failed with OSStatus \(status)."
        case .copyStaticCodeFailed(let status):
            "SecCodeCopyStaticCode failed with OSStatus \(status)."
        case .signatureInvalid(let status):
            "SecStaticCodeCheckValidity failed with OSStatus \(status)."
        case .copySigningInformationFailed(let status):
            "SecCodeCopySigningInformation failed with OSStatus \(status)."
        case .missingIdentifier:
            "The live code signature has no identifier."
        case .missingTeamIdentifier:
            "The live code signature has no Team ID."
        case .missingCodeDirectoryHash:
            "The live code signature has no Code Directory hash."
        }
    }
}

public struct RuntimeSignedCodeIdentity: Equatable, Sendable {
    public let signingIdentity: RuntimeSigningIdentity
    public let marketingVersion: String?
    public let buildVersion: String?
    public let codeDirectoryHash: String
}

public struct RuntimeSigningIdentity: Equatable, Sendable {
    public let identifier: String
    public let teamIdentifier: String

    public init(identifier: String, teamIdentifier: String) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }

    public static func current() -> RuntimeSigningIdentity? {
        try? validatedCurrent()
    }

    public static func validatedCurrent() throws -> RuntimeSigningIdentity {
        try validatedCurrentCode().signingIdentity
    }

    /// Captures the exact live code object and its signed version metadata. The
    /// daemon calls this before opening its listener, so a later atomic bundle
    /// replacement cannot change the identity returned by its handshake.
    public static func validatedCurrentCode() throws -> RuntimeSignedCodeIdentity {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &code)
        guard copySelfStatus == errSecSuccess, let code else {
            throw RuntimeSigningIdentityError.copySelfFailed(copySelfStatus)
        }

        var staticCode: SecStaticCode?
        let copyStaticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard copyStaticStatus == errSecSuccess, let staticCode else {
            throw RuntimeSigningIdentityError.copyStaticCodeFailed(copyStaticStatus)
        }

        return try validatedCode(staticCode: staticCode)
    }

    /// Validates a signed executable on disk and returns the same signer and
    /// Code Directory identity used for the live daemon. The app uses this for
    /// its embedded daemon before comparing an authenticated XPC handshake.
    public static func validatedCode(
        executableURL: URL
    ) throws -> RuntimeSignedCodeIdentity {
        var staticCode: SecStaticCode?
        let copyStaticStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        )
        guard copyStaticStatus == errSecSuccess, let staticCode else {
            throw RuntimeSigningIdentityError.copyStaticCodeFailed(copyStaticStatus)
        }

        return try validatedCode(staticCode: staticCode)
    }

    private static func validatedCode(
        staticCode: SecStaticCode
    ) throws -> RuntimeSignedCodeIdentity {
        let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard validityStatus == errSecSuccess else {
            throw RuntimeSigningIdentityError.signatureInvalid(validityStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let values = information as? [CFString: Any]
        else {
            throw RuntimeSigningIdentityError.copySigningInformationFailed(informationStatus)
        }
        guard let identifier = values[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty
        else {
            throw RuntimeSigningIdentityError.missingIdentifier
        }
        guard let teamIdentifier = teamIdentifier(from: values) else {
            throw RuntimeSigningIdentityError.missingTeamIdentifier
        }
        guard let codeDirectoryHash = codeDirectoryHash(from: values) else {
            throw RuntimeSigningIdentityError.missingCodeDirectoryHash
        }

        let signingIdentity = RuntimeSigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
        return RuntimeSignedCodeIdentity(
            signingIdentity: signingIdentity,
            marketingVersion: bundleValue(
                "CFBundleShortVersionString",
                from: values
            ),
            buildVersion: bundleValue("CFBundleVersion", from: values),
            codeDirectoryHash: codeDirectoryHash
        )
    }

    private static func bundleValue(
        _ key: String,
        from values: [CFString: Any]
    ) -> String? {
        guard let plist = values[kSecCodeInfoPList] as? NSDictionary,
              let value = plist[key] as? String,
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func codeDirectoryHash(from values: [CFString: Any]) -> String? {
        guard let data = values[kSecCodeInfoUnique] as? Data, !data.isEmpty else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func teamIdentifier(from values: [CFString: Any]) -> String? {
        if let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
           !teamIdentifier.isEmpty {
            return teamIdentifier
        }

        // Entitlement-free command-line tools can omit
        // kSecCodeInfoTeamIdentifier even though the validated Apple signing
        // certificate carries the Team ID in its Organizational Unit.
        guard let certificates = values[kSecCodeInfoCertificates] as? [SecCertificate],
              let leafCertificate = certificates.first,
              let certificateValues = SecCertificateCopyValues(
                leafCertificate,
                [kSecOIDOrganizationalUnitName] as CFArray,
                nil
              ) as? [CFString: Any],
              let organizationalUnit = certificateValues[
                kSecOIDOrganizationalUnitName
              ] as? [CFString: Any],
              let teamIdentifier = organizationalUnit[kSecPropertyKeyValue] as? String,
              !teamIdentifier.isEmpty
        else {
            return nil
        }
        return teamIdentifier
    }

    public func appClientIdentity() -> RuntimeSigningIdentity? {
        let suffix = ".daemon"
        guard identifier.hasSuffix(suffix) else { return nil }
        return RuntimeSigningIdentity(
            identifier: String(identifier.dropLast(suffix.count)),
            teamIdentifier: teamIdentifier
        )
    }

    public var codeSigningRequirement: String {
        "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(Self.escape(teamIdentifier))\""
            + " and identifier \"\(Self.escape(identifier))\""
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
