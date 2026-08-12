import Foundation

/// The boundary around every Service Management call.
///
/// Background Task Management associates a service with the app copy that
/// contacted it. Even inspecting service state from DerivedData can move that
/// association away from the installed app, so callers must pass this check
/// before constructing or using an `SMAppService`.
public enum BackgroundServiceEligibility {
    public static let productionAppIdentifier = "com.ruban24.letitbrew"
    public static let developmentAppIdentifier = "com.ruban24.letitbrew.dev"
    public static let expectedTeamIdentifier = "MV2UL94MDC"

    public static func mayManageBackgroundServices(
        bundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL

        guard resolved.deletingLastPathComponent() == applications,
              resolved.pathExtension == "app"
        else { return false }

        return bundleIdentifier == productionAppIdentifier
            || bundleIdentifier == developmentAppIdentifier
    }

    /// The stronger gate used immediately before any Service Management call.
    /// Location and an allow-listed identifier are insufficient on their own:
    /// the live caller must also prove that its validated Apple signature has
    /// the same identifier and Let It Brew's expected Team ID.
    public static func mayManageBackgroundServices(
        bundleURL: URL,
        bundleIdentifier: String?,
        signingIdentity: RuntimeSigningIdentity
    ) -> Bool {
        guard mayManageBackgroundServices(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        ), let bundleIdentifier else {
            return false
        }
        return signingIdentity.identifier == bundleIdentifier
            && signingIdentity.teamIdentifier == expectedTeamIdentifier
    }
}
