import ServiceManagement
import LetItBrewAppCore

/// Explicit main-app login registration. Deliberately has no status reader:
/// Let It Brew treats Background Task Management inspection as a mutating API and
/// never probes it from arbitrary builds.
struct LoginItemRegistration: LaunchAtLoginRegistering {
    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    @MainActor
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
