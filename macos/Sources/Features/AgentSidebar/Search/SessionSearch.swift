import AppKit
import Combine

/// State behind the sidebar's session search: the query, results, keyboard selection, and
/// the confirm step before a session is resumed.
@MainActor
final class SessionSearch: ObservableObject {
    static let shared = SessionSearch()

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    @Published private(set) var results: [SessionHit] = []
    @Published private(set) var hasSearched = false
    /// The highlighted result (arrow keys, hover-independent).
    @Published var selection: String?
    /// The result waiting for a second click or Return to resume.
    @Published var confirming: String?
    @Published private(set) var indexState = SessionIndexState()
    /// Incremented to move keyboard focus into the search field.
    @Published private(set) var focusRequest = 0

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchToken = 0
    private var pendingSearch: DispatchWorkItem?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        SessionIndex.shared.onStateChange = { state in
            Task { @MainActor in SessionSearch.shared.indexStateDidChange(state) }
        }
        SessionIndex.shared.start()
    }

    func focusField() {
        AgentMonitor.shared.isSidebarVisible = true
        focusRequest += 1
    }

    func rebuildIndex() {
        SessionIndex.shared.rebuild()
    }

    // MARK: Searching

    private func scheduleSearch() {
        pendingSearch?.cancel()
        guard isActive else {
            results = []
            hasSearched = false
            selection = nil
            confirming = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.runSearch() }
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func runSearch() {
        searchToken += 1
        let token = searchToken
        SessionIndex.shared.search(query) { hits in
            Task { @MainActor in
                let search = SessionSearch.shared
                guard token == search.searchToken else { return }
                search.results = hits
                search.hasSearched = true
                if !hits.contains(where: { $0.id == search.selection }) { search.selection = hits.first?.id }
                if !hits.contains(where: { $0.id == search.confirming }) { search.confirming = nil }
            }
        }
    }

    private func indexStateDidChange(_ state: SessionIndexState) {
        let progressed = state.done != indexState.done || state.isIndexing != indexState.isIndexing
        indexState = state
        // Results improve while the first index is built; refresh them as batches land.
        if progressed && isActive { runSearch() }
    }

    // MARK: Keyboard and clicks

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : results.count)
        let next = min(max(current + delta, 0), results.count - 1)
        selection = results[next].id
        confirming = nil
    }

    /// Return: first press asks for confirmation, second press resumes.
    func confirmSelection() {
        guard let hit = results.first(where: { $0.id == selection }) ?? results.first else { return }
        activate(hit)
    }

    /// Click: same two steps as Return.
    func activate(_ hit: SessionHit) {
        selection = hit.id
        if confirming == hit.id {
            resume(hit)
        } else {
            confirming = hit.id
        }
    }

    /// Escape: backs out one step: confirmation, then the query, then back to the terminal.
    func cancel() {
        if confirming != nil {
            confirming = nil
        } else if isActive {
            query = ""
        } else {
            AgentMonitor.shared.focusLastTerminal()
        }
    }

    // MARK: Resuming

    /// The agent of a running session, if the session is open in a terminal right now.
    func liveAgent(for hit: SessionHit) -> AgentMonitor.Agent? {
        AgentMonitor.shared.agents.first { $0.sessionID == hit.sessionID }
    }

    func resume(_ hit: SessionHit) {
        confirming = nil
        if let agent = liveAgent(for: hit) {
            query = ""
            AgentMonitor.shared.focus(agent.id)
            return
        }

        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        if let cwd = hit.cwd, FileManager.default.fileExists(atPath: cwd) {
            config.workingDirectory = cwd
        }
        // Typed into the user's shell rather than run as the tab's command, so shell
        // functions and wrappers around `claude` / `codex` apply as usual.
        config.initialInput = Self.resumeCommand(for: hit) + "\n"

        let parent = (NSApp.keyWindow?.windowController as? TerminalController)?.window
            ?? TerminalController.all.first?.window
        _ = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
        query = ""
    }

    static func resumeCommand(for hit: SessionHit) -> String {
        switch hit.agent {
        case .claude:
            let command = "claude --resume \(shellQuoted(hit.sessionID))"
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude").resolvingSymlinksInPath().path
            if let dir = hit.configDir, !dir.isEmpty, dir != defaultDir {
                return "CLAUDE_CONFIG_DIR=\(shellQuoted(dir)) \(command)"
            }
            return command
        case .codex:
            return "codex resume \(shellQuoted(hit.sessionID))"
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        if text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
