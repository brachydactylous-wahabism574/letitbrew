import Foundation

/// Boundary around the system registration side effect. Tests supply a fake
/// so they never contact Background Task Management.
public protocol LaunchAtLoginRegistering: Sendable {
    func setEnabled(_ enabled: Bool) throws
}

public protocol LaunchAtLoginChoicePersisting: Sendable {
    func loadChoice() -> Bool?
    func saveChoice(_ enabled: Bool)
}

public struct LaunchAtLoginRequestFailure: Equatable, Sendable {
    public let message: String
    public let diagnostic: String

    public init(message: String, diagnostic: String) {
        self.message = message
        self.diagnostic = diagnostic
    }
}

public enum LaunchAtLoginRequestResult: Equatable, Sendable {
    case succeeded(enabled: Bool)
    case failed(LaunchAtLoginRequestFailure)
}

public struct LaunchAtLoginRequester: Sendable {
    private let registration: any LaunchAtLoginRegistering
    private let persistence: any LaunchAtLoginChoicePersisting
    private let operatingSystemMajorVersion: Int

    public init(
        registration: any LaunchAtLoginRegistering,
        persistence: any LaunchAtLoginChoicePersisting,
        operatingSystemMajorVersion: Int = ProcessInfo.processInfo
            .operatingSystemVersion.majorVersion
    ) {
        self.registration = registration
        self.persistence = persistence
        self.operatingSystemMajorVersion = operatingSystemMajorVersion
    }

    public func request(_ enabled: Bool) -> LaunchAtLoginRequestResult {
        do {
            try registration.setEnabled(enabled)
            persistence.saveChoice(enabled)
            return .succeeded(enabled: enabled)
        } catch {
            let error = error as NSError
            if Self.isAlreadyDisabled(
                enabled: enabled,
                savedChoice: persistence.loadChoice(),
                operatingSystemMajorVersion: operatingSystemMajorVersion,
                error: error
            ) {
                persistence.saveChoice(false)
                return .succeeded(enabled: false)
            }
            return .failed(LaunchAtLoginRequestFailure(
                message: error.localizedDescription,
                diagnostic: Self.diagnostic(for: error)
            ))
        }
    }

    private static func diagnostic(for error: NSError) -> String {
        var result = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += "; underlying: \(diagnostic(for: underlying))"
        }
        return result
    }

    private static func isAlreadyDisabled(
        enabled: Bool,
        savedChoice: Bool?,
        operatingSystemMajorVersion: Int,
        error: NSError
    ) -> Bool {
        guard !enabled else { return false }

        // The documented idempotent result from SMAppService.unregister().
        if error.domain == "kSMErrorDomainFramework", error.code == 6 {
            return true
        }

        // macOS 26 currently collapses Background Task Management's
        // `record not found (-95)` into this generic SMAppService error for
        // a main-app login item. Limit the workaround to apps that never
        // recorded an enabled choice (or already recorded a disabled one),
        // so the same generic error remains visible when a login item was
        // expected to exist.
        return operatingSystemMajorVersion == 26
            && savedChoice != true
            && error.domain == "SMAppServiceErrorDomain"
            && error.code == 1
    }
}
