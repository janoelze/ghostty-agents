import AppKit

/// Starts agent sessions in terminals: resuming or forking a session, in a new tab, a split,
/// or a terminal that already exists. Used by search results, the context menus, and resuming
/// agents after a restart.
@MainActor
enum AgentLauncher {
    /// A session that can be resumed.
    struct Session: Codable, Equatable {
        let agent: SessionDocument.Agent
        let id: String
        let cwd: String?
        /// For Claude Code: the config dir the session belongs to (`~/.claude`, a profile, …).
        let configDir: String?

        /// The Claude Code config dir of a transcript: `<config>/projects/<project>/<id>.jsonl`.
        static func configDir(ofTranscript path: String?) -> String? {
            guard let path, path.hasSuffix(".jsonl") else { return nil }
            let projects = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            guard projects.lastPathComponent == "projects" else { return nil }
            return projects.deletingLastPathComponent().path
        }
    }

    enum Mode {
        case resume
        /// A new session that starts from a copy of the old one; the original stays as it was.
        case fork
    }

    enum Placement {
        case newTab
        /// A split to the right of the focused terminal.
        case split
    }

    /// The shell command that resumes or forks a session.
    static func command(for session: Session, mode: Mode = .resume) -> String {
        let id = shellQuoted(session.id)
        switch session.agent {
        case .claude:
            var command = "claude --resume \(id)"
            if mode == .fork { command += " --fork-session" }
            let defaultDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude").resolvingSymlinksInPath().path
            if let dir = session.configDir, !dir.isEmpty,
               URL(fileURLWithPath: dir).resolvingSymlinksInPath().path != defaultDir {
                command = "CLAUDE_CONFIG_DIR=\(shellQuoted(dir)) " + command
            }
            return command
        case .codex:
            return mode == .fork ? "codex fork \(id)" : "codex resume \(id)"
        }
    }

    /// Opens a terminal in the session's folder and runs the command there. The command is
    /// typed into the user's shell rather than run as the terminal's command, so shell
    /// functions and wrappers around `claude` / `codex` apply as usual.
    static func open(_ session: Session, mode: Mode = .resume, placement: Placement = .newTab) {
        open(command: command(for: session, mode: mode), in: session.cwd, placement: placement)
    }

    /// Opens a new tab or split in `directory`, optionally running a command.
    static func open(command: String?, in directory: String?, placement: Placement = .newTab) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        if let directory, FileManager.default.fileExists(atPath: directory) {
            config.workingDirectory = directory
        }
        if let command { config.initialInput = command + "\n" }

        switch placement {
        case .split:
            if let surface = AgentMonitor.shared.lastFocusedSurface,
               let controller = surface.window?.windowController as? BaseTerminalController,
               controller.newSplit(at: surface, direction: .right, baseConfig: config) != nil {
                return
            }
            fallthrough
        case .newTab:
            let parent = AgentMonitor.shared.lastFocusedSurface?.window
                ?? (NSApp.keyWindow?.windowController as? TerminalController)?.window
                ?? TerminalController.all.first?.window
            _ = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
        }
    }

    /// Types a command into an existing terminal and presses Return.
    static func run(_ command: String, in surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        model.sendText(command)
        // A real Return key: with bracketed paste a pasted newline wouldn't run the command.
        for action in [Ghostty.Input.Action.press, .release] {
            model.sendKeyEvent(Ghostty.Input.KeyEvent(
                synthesizing: .enter,
                action: action,
                mods: [],
                translationMods: []))
        }
    }

    // MARK: Small actions for context menus

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openInFinder(_ directory: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    private static func shellQuoted(_ text: String) -> String {
        if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
