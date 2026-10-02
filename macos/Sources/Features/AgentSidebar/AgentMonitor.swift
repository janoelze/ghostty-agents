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
        /// The agent's session id as reported by its hooks, used to match search results.
        let sessionID: String?
        let title: String
        /// The agent's working directory, abbreviated with `~`.
        let directory: String?
        let project: Project
        let state: AgentState
        /// The second line of the row: what the agent is doing, or what it is asking.
        let detail: String
        let since: Date?
        let isFocused: Bool
        /// Waiting on the user, or finished and not looked at since.
        let needsAttention: Bool
    }

    /// The git repository (or plain directory) an agent works in. Rows are grouped by this.
    struct Project: Hashable {
        let path: String
        let name: String
        let branch: String?
    }

    struct Group: Identifiable, Equatable {
        var id: String { project.path }
        let project: Project
        /// The project's color, also used for its tabs. Nil when tab coloring is off.
        let color: TerminalTabColor?
        let agents: [(position: Int, agent: Agent)]

        static func == (lhs: Group, rhs: Group) -> Bool {
            lhs.project == rhs.project && lhs.color == rhs.color && lhs.agents.map(\.agent) == rhs.agents.map(\.agent)
        }
    }

    /// Agents in tab and split order, which is also the order of the ⌃⌘1…9 shortcuts.
    @Published private(set) var agents: [Agent] = []

    /// Agents grouped by project, in order of each project's first agent.
    var groups: [Group] {
        var order: [Project] = []
        var members: [Project: [(Int, Agent)]] = [:]
        for (offset, agent) in agents.enumerated() {
            if members[agent.project] == nil { order.append(agent.project) }
            members[agent.project, default: []].append((offset + 1, agent))
        }
        return order.map {
            Group(
                project: $0,
                color: tabColors.isEnabled ? projectColors[$0.path] : nil,
                agents: members[$0] ?? [])
        }
    }

    /// Colors per project path. See `AgentTabColors`.
    @Published private(set) var projectColors: [String: TerminalTabColor] = [:]

    let tabColors = AgentTabColors()

    func toggleTabColors() {
        tabColors.isEnabled.toggle()
        objectWillChange.send()
        refresh()
    }

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
    private var gitRoots: [String: String?] = [:]
    /// Session titles from the search index, refreshed while a session runs since its AI
    /// title can change.
    private var sessionTitles: [String: (title: String?, fetched: Date)] = [:]
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

    /// Returns keyboard focus to the terminal that last had it (e.g. after leaving search).
    func focusLastTerminal() {
        guard let id = lastFocusedID else { return }
        focus(id)
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

        var tabs: [(window: TerminalWindow, project: String?)] = []

        for controller in Self.controllersInTabOrder() {
            var tabAgents: [Agent] = []
            for surface in controller.surfaceTree.root?.leaves() ?? [] {
                alive.insert(surface.id)
                newSurfaces[surface.id] = Weak(surface)
                if let agent = agent(for: surface, focusedID: focusedID) {
                    tabAgents.append(agent)
                }
            }
            found += tabAgents

            // A tab takes the color of its focused agent, or its first one.
            if let window = controller.window as? TerminalWindow {
                let main = tabAgents.first { $0.id == controller.focusedSurface?.id } ?? tabAgents.first
                tabs.append((window, main?.project.path))
            }
        }

        let colors = AgentTabColors.assign(found.map(\.project))
        if colors != projectColors { projectColors = colors }
        tabColors.apply(tabs, colors: colors)

        surfaces = newSurfaces
        lastViewed = lastViewed.filter { alive.contains($0.key) }

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

        let detail: String
        switch state {
        case .needsInput: detail = status?.message ?? "Waiting for input"
        case .working: detail = status?.activity ?? "Thinking…"
        case .done: detail = "Done"
        case .running: detail = name
        }

        // The agent's own cwd is more accurate than the shell's, which only knows where
        // the agent was started.
        let cwd = status?.cwd ?? surface.pwd.flatMap { $0.isEmpty ? nil : $0 }
        return Agent(
            id: surface.id,
            name: name,
            sessionID: status?.sessionID,
            title: Self.title(
                surface.title,
                sessionTitle: status?.sessionID.flatMap(sessionTitle),
                prompt: status?.lastPrompt,
                name: name),
            directory: cwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
            project: project(for: cwd),
            state: state,
            detail: detail,
            since: since,
            isFocused: isFocused,
            needsAttention: needsAttention)
    }

    // MARK: Ordering and projects

    /// Terminal windows in the order they appear: windows by when they were opened, tabs
    /// left to right within each window.
    private static func controllersInTabOrder() -> [TerminalController] {
        func key(_ controller: TerminalController) -> (Int, Int) {
            guard let window = controller.window else { return (Int.max, Int.max) }
            let tabs = window.tabGroup?.windows ?? [window]
            let group = tabs.map(\.windowNumber).min() ?? window.windowNumber
            return (group, tabs.firstIndex(of: window) ?? 0)
        }
        return TerminalController.all.sorted { key($0) < key($1) }
    }

    private func project(for cwd: String?) -> Project {
        guard let cwd else { return Project(path: "", name: "Other", branch: nil) }
        guard let root = gitRoot(for: cwd) else {
            return Project(path: cwd, name: (cwd as NSString).lastPathComponent, branch: nil)
        }
        return Project(path: root, name: (root as NSString).lastPathComponent, branch: Self.branch(ofRepo: root))
    }

    /// The nearest enclosing directory with a `.git`, cached per directory.
    private func gitRoot(for directory: String) -> String? {
        if let cached = gitRoots[directory] { return cached }
        var current = (directory as NSString).standardizingPath
        var root: String?
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                root = current
                break
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        gitRoots[directory] = root
        return root
    }

    /// The checked out branch, or a short commit hash when detached. Read on every refresh
    /// since it is one small file and branches change.
    private static func branch(ofRepo root: String) -> String? {
        var gitDir = (root as NSString).appendingPathComponent(".git")
        // Worktrees and submodules have a `.git` file pointing at the real git dir.
        if let pointer = try? String(contentsOfFile: gitDir, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        }
        guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        return String(trimmed.prefix(7))
    }

    /// The indexed title of a session, fetched in the background on first use and refreshed
    /// every minute. Returns what is cached so far.
    private func sessionTitle(_ id: String) -> String? {
        let cached = sessionTitles[id]
        if cached == nil || Date().timeIntervalSince(cached!.fetched) > 60 {
            sessionTitles[id] = (cached?.title, Date())
            SessionIndex.shared.title(forSession: id) { [weak self] title in
                guard let self, title != cached?.title else { return }
                self.sessionTitles[id] = (title, Date())
                self.refresh()
            }
        }
        return cached?.title
    }

    /// Agents decorate titles with spinners and status glyphs; strip those. When the
    /// terminal title says nothing useful, use the session's title (known for resumed
    /// sessions), then the last prompt. The directory is never used here; it is already in
    /// the group header.
    private static func title(_ raw: String, sessionTitle: String?, prompt: String?, name: String) -> String {
        let trimmed = String(raw.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = [name.lowercased(), "claude", "claude code", "ghostty", ""]
        if !generic.contains(trimmed.lowercased()) { return trimmed }
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        if let prompt, !prompt.isEmpty { return prompt }
        return name
    }
}
