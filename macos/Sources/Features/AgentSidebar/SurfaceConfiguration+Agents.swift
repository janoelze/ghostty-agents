import Foundation

extension Ghostty.SurfaceConfiguration {
    /// Returns a copy that exports the surface UUID to the terminal's processes, so agent
    /// hooks can report status for the exact split they run in. See `AgentStatusStore`.
    func withAgentSurfaceID(_ id: UUID) -> Self {
        var config = self
        config.environmentVariables[AgentStatusStore.surfaceIDEnvKey] = id.uuidString
        return config
    }
}
