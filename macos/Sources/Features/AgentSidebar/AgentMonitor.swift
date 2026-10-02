import AppKit
import Combine
import SwiftUI

/// App-wide model behind the agent sidebar. Every terminal window shows the same list,
/// so this is a singleton that polls all surfaces once a second.
@MainActor
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    struct Agent: Identifiable, Equatable {
        /// The surface UUID. Also the AppleScript `id` of the terminal.
        let id: UUID
        let name: String
        let title: String
        let directory: String?
        let state: AgentState
        let detail: String?
        let since: Date?
        let isFocused: Bool
        /// Waiting on the user, or finished and not looked at since.
        let needsAttention: Bool
    }

    @Published private(set) var agents: [Agent] = []

    @Published var isSidebarVisible: Bool {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: Self.visibleKey) }
    }

    @Published var sidebarWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey) }
    }

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 480
    private static let visibleKey = "GhosttyAgentsSidebarVisible"
    private static let widthKey = "GhosttyAgentsSidebarWidth"

    private var timer: Timer?
    private var watcher: AgentChangeWatcher?
    /// The last terminal that had focus. Kept while Ghostty is in the background so the
    /// sidebar still shows where you were.
    private var lastFocusedID: UUID?
    private var surfaces: [UUID: Weak<Ghostty.SurfaceView>] = [:]
    private var firstSeen: [UUID: Date] = [:]
    private var lastViewed: [UUID: Date] = [:]

    private init() {
        let defaults = UserDefaults.standard
        isSidebarVisible = defaults.object(forKey: Self.visibleKey) as? Bool ?? true
        let width = defaults.double(forKey: Self.widthKey)
        sidebarWidth = width > 0 ? CGFloat(width) : 240
    }

    /// Starts polling. Safe to call repeatedly; called by each sidebar as it appears.
    func start() {
        guard timer == nil else { return }
        AgentMenu.install()
        refresh()
        watcher = AgentChangeWatcher { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Called by the status file watcher.
    func statusDidChange() {
        refresh()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    // MARK: Navigation

    /// Focuses the terminal of an agent, switching window and tab as needed.
    func focus(_ id: UUID) {
        guard let surface = surfaces[id]?.value,
              let controller = TerminalController.all.first(where: { $0.surfaceTree.contains(surface) })
        else { return }
        lastViewed[id] = Date()
        controller.focusSurface(surface)
    }

    /// Focuses the agent at a 1-based position in the sidebar.
    func focus(position: Int) {
        guard position >= 1, position <= agents.count else { return }
        focus(agents[position - 1].id)
    }

    /// Cycles through agents needing attention: waiting on input first, then finished ones,
    /// oldest first within each group.
    func focusNextNeedingAttention() {
        let candidates = agents
            .filter(\.needsAttention)
            .sorted { ($0.state, $0.since ?? .distantPast) < ($1.state, $1.since ?? .distantPast) }
        guard !candidates.isEmpty else { NSSound.beep(); return }

        if let current = candidates.firstIndex(where: \.isFocused) {
            focus(candidates[(current + 1) % candidates.count].id)
        } else {
            focus(candidates[0].id)
        }
    }

    // MARK: Polling

    func refresh() {
        if let current = (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface?.id {
            lastFocusedID = current
        }
        let focusedID = lastFocusedID
        if let focusedID, NSApp.isActive { lastViewed[focusedID] = Date() }

        var found: [Agent] = []
        var alive: Set<UUID> = []
        var newSurfaces: [UUID: Weak<Ghostty.SurfaceView>] = [:]

        for controller in TerminalController.all {
            for surface in controller.surfaceTree.root?.leaves() ?? [] {
                alive.insert(surface.id)
                newSurfaces[surface.id] = Weak(surface)
                if let agent = agent(for: surface, focusedID: focusedID) {
                    found.append(agent)
                }
            }
        }

        surfaces = newSurfaces
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        lastViewed = lastViewed.filter { alive.contains($0.key) }
        for agent in found where firstSeen[agent.id] == nil {
            firstSeen[agent.id] = Date()
        }
        found.sort { (firstSeen[$0.id] ?? .distantPast) < (firstSeen[$1.id] ?? .distantPast) }

        if found != agents { agents = found }
        AgentMenu.update(agents: agents)

        // Clean up after agents that exited without a SessionEnd hook.
        if !alive.isEmpty { AgentStatusStore.prune(keeping: alive) }
    }

    private func agent(for surface: Ghostty.SurfaceView, focusedID: UUID?) -> Agent? {
        guard let pid = surface.surfaceModel?.foregroundPID else { return nil }

        let name: String
        var status = AgentStatusStore.status(for: surface.id)
        switch AgentProcess.classify(pid: pid) {
        case .shell:
            // The agent exited back to the shell.
            return nil
        case .agent(let detected):
            name = detected
        case .other:
            // An agent we can't recognize by name, but whose hooks report for this surface.
            guard let status else { return nil }
            name = status.agent.map { AgentProcess.knownAgents[$0] ?? $0 } ?? "Agent"
        }

        // Ignore status left behind by an earlier agent in the same surface.
        if let started = AgentProcess.startDate(pid: pid), let current = status, current.updatedAt < started {
            status = nil
        }

        let state = status?.state ?? .running
        let since = status?.updatedAt
        let isFocused = surface.id == focusedID
        let viewed = lastViewed[surface.id] ?? .distantPast
        let inView = isFocused && NSApp.isActive
        let needsAttention = !inView && (state == .needsInput || (state == .done && viewed < (since ?? .distantPast)))

        let directory = surface.pwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).abbreviatingWithTildeInPath }
        return Agent(
            id: surface.id,
            name: name,
            title: Self.title(surface.title, prompt: status?.lastPrompt, directory: directory, name: name),
            directory: directory,
            state: state,
            detail: state == .needsInput ? status?.message : status?.lastPrompt,
            since: since,
            isFocused: isFocused,
            needsAttention: needsAttention)
    }

    /// Agents decorate titles with spinners and status glyphs; strip those and fall back to
    /// the last prompt or the directory when the title says nothing useful.
    private static func title(_ raw: String, prompt: String?, directory: String?, name: String) -> String {
        let trimmed = String(raw.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = [name.lowercased(), "claude", "claude code", "ghostty", ""]
        if !generic.contains(trimmed.lowercased()) { return trimmed }
        if let prompt, !prompt.isEmpty { return prompt }
        if let directory { return (directory as NSString).lastPathComponent }
        return name
    }
}
