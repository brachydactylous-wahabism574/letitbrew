public enum LetItBrewLaunchMode: String, CaseIterable, Equatable, Sendable {
    case ordinary
    case registerDaemon
    case unregisterDaemon
    case probeDaemon
    case prepareUpdate
    case prepareDaemonUpgrade
    case holdDaemon
    case probeLidDisplay
    case designPreview
    case designPreviewSettings

    public init(
        arguments: [String],
        allowsDesignPreview: Bool
    ) {
        if arguments.contains("--register-daemon") {
            self = .registerDaemon
        } else if arguments.contains("--unregister-daemon") {
            self = .unregisterDaemon
        } else if arguments.contains("--probe-daemon") {
            self = .probeDaemon
        } else if arguments.contains("--prepare-update") {
            self = .prepareUpdate
        } else if arguments.contains("--prepare-daemon-upgrade") {
            self = .prepareDaemonUpgrade
        } else if arguments.contains("--hold-daemon") {
            self = .holdDaemon
        } else if arguments.contains("--probe-lid-display") {
            self = .probeLidDisplay
        } else if allowsDesignPreview,
                  arguments.contains("--design-preview-settings") {
            self = .designPreviewSettings
        } else if allowsDesignPreview,
                  arguments.contains("--design-preview") {
            self = .designPreview
        } else {
            self = .ordinary
        }
    }

    /// Only an ordinary launch is allowed to construct the menu-bar and
    /// Settings scenes. Command and design-preview modes own their lifecycle.
    public var constructsOrdinaryScenes: Bool {
        self == .ordinary
    }
}
