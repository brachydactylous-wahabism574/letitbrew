public enum AgentConfigRecoveryGuidance {
    public static func details(agentName: String, path: String) -> [String] {
        [
            "\(agentName)’s configuration at \(path) couldn’t be read safely. Let It Brew left it unchanged.",
            "Fix or restore that file, then choose Check Again.",
        ]
    }
}
