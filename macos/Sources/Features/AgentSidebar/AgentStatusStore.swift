import Foundation

/// Reads the status files written by agent hooks (see `ghostty-agents/hooks/`).
///
/// Layout on disk, one directory per Ghostty surface:
///
///     $DARWIN_USER_TEMP_DIR/ghostty-agents/<surface-uuid>/<HookEventName>.json
///
/// Each file is `{"agent": "claude", "ts": <unix seconds>, "event": <hook payload>}`. The
/// surface UUID reaches the hook through the `GHOSTTY_AGENTS_SURFACE_ID` environment variable
/// that every Ghostty Agents surface is started with, so no process inspection is needed on
/// the hook side (which matters when the agent runs inside a sandbox).
enum AgentStatusStore {
    /// Environment variable that carries the surface UUID into the terminal's processes.
    static let surfaceIDEnvKey = "GHOSTTY_AGENTS_SURFACE_ID"

    /// The root directory for status files. Uses the per-user temp dir so it is shared
    /// between Ghostty and sandboxed agents, and cleared on reboot.
    static let directory: URL = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let base = length > 0
            ? URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            : FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ghostty-agents", isDirectory: true)
    }()

    /// The latest hook-reported state for one surface.
    struct Status {
        var state: AgentState
        var agent: String?
        var sessionID: String?
        var lastPrompt: String?
        var message: String?
        /// What the agent is doing right now, e.g. "Editing AgentMonitor.swift".
        var activity: String?
        /// The agent's working directory as it reports it.
        var cwd: String?
        var updatedAt: Date
    }

    /// Reads the status for a surface, or nil if no hook has reported for it.
    static func status(for surfaceID: UUID) -> Status? {
        let dir = directory.appendingPathComponent(surfaceID.uuidString, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let events: [Event] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { Event(url: $0) }
            .sorted { $0.date < $1.date }
        guard let latest = events.last(where: { $0.state != nil }) else { return nil }

        let promptEvent = events.last { $0.name == "UserPromptSubmit" }
        let prompt = promptEvent?.payload["prompt"] as? String

        // The tool call in progress, if it belongs to the current prompt.
        var activity: String?
        if let tool = events.last(where: { $0.name == "PreToolUse" }),
           tool.date >= (promptEvent?.date ?? .distantPast) {
            activity = describeTool(tool.payload)
        }

        return Status(
            state: latest.state ?? .running,
            agent: latest.agent,
            sessionID: latest.payload["session_id"] as? String,
            lastPrompt: prompt.map(firstLine),
            message: (latest.payload["message"] as? String).map(firstLine),
            activity: activity,
            cwd: events.last { $0.payload["cwd"] is String }?.payload["cwd"] as? String,
            updatedAt: latest.date)
    }

    /// Removes status for surfaces that no longer exist and haven't reported in a day.
    /// `SessionEnd` normally cleans up; this catches agents that crashed. The age check keeps
    /// two running builds (e.g. a dev build next to the installed one) from deleting each
    /// other's status.
    static func prune(keeping alive: Set<UUID>) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !alive.contains(id) else { continue }
            let modified = try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// A short description of a tool call from a `PreToolUse` payload.
    private static func describeTool(_ payload: [String: Any]) -> String? {
        guard let tool = payload["tool_name"] as? String else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        func file(_ key: String = "file_path") -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }

        switch tool {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty {
                return firstLine(description)
            }
            return (input["command"] as? String).map { firstLine($0) }
        case "Edit", "MultiEdit": return file().map { "Editing \($0)" }
        case "Write": return file().map { "Writing \($0)" }
        case "Read": return file().map { "Reading \($0)" }
        case "NotebookEdit": return file("notebook_path").map { "Editing \($0)" }
        case "Grep", "Glob": return (input["pattern"] as? String).map { "Searching \($0)" }
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host }
            return host.map { "Fetching \($0)" } ?? "Fetching"
        case "WebSearch": return (input["query"] as? String).map { "Searching the web: \($0)" }
        case "Task", "Agent": return (input["description"] as? String).map { "Subagent: \($0)" }
        case "TodoWrite": return "Updating todos"
        default:
            // MCP tools are named mcp__<server>__<tool>.
            if tool.hasPrefix("mcp__") {
                return tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().joined(separator: " ")
            }
            return tool
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }

    private struct Event {
        let name: String
        let agent: String?
        /// When the hook wrote this event. File mtimes have sub-second precision, which
        /// matters because several hooks often fire within the same second.
        let date: Date
        let payload: [String: Any]

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["event"] as? [String: Any] else { return nil }
            self.name = payload["hook_event_name"] as? String ?? url.deletingPathExtension().lastPathComponent
            self.agent = root["agent"] as? String
            let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            self.date = mtime ?? Date(timeIntervalSince1970: (root["ts"] as? NSNumber)?.doubleValue ?? 0)
            self.payload = payload
        }

        /// The state this event implies. Nil for events that carry no state on their own.
        var state: AgentState? {
            switch name {
            case "SessionStart", "Stop":
                return .done
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact":
                return .working
            case "Notification":
                // Claude Code sends an idle reminder after a turn finished; that isn't new
                // information beyond `Stop`. Everything else (permission prompts, questions)
                // needs the user.
                if payload["notification_type"] as? String == "idle_prompt" { return .done }
                return .needsInput
            default:
                return nil
            }
        }
    }
}

/// The coarse state of an agent, as shown in the sidebar.
enum AgentState: Int, Comparable {
    /// The agent is waiting on the user (permission prompt, question).
    case needsInput
    /// The agent finished its turn and is waiting for the next prompt.
    case done
    /// The agent is working on a prompt.
    case working
    /// The agent process is running but no hook has reported a state.
    case running

    static func < (lhs: AgentState, rhs: AgentState) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .done: return "Done"
        case .working: return "Working"
        case .running: return "Running"
        }
    }
}
