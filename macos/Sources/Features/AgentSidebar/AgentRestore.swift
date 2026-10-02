import AppKit

/// Brings agents back after Ghostty restarts (an update, a reboot, a crash).
///
/// While Ghostty runs, the sessions of running agents are written to
/// `~/Library/Application Support/ghostty-agents/running-agents*.json`, keyed by terminal. On the
/// next launch, Ghostty's window restoration brings back the terminals with the same ids; each
/// one that had an agent gets its session resumed. Sessions whose terminal didn't come back
/// (window restoration off, or a crash before it saved) are resumed in new tabs.
///
/// The file is kept current while agents start and stop, and frozen once Ghostty starts
/// quitting, so closing windows on the way out doesn't erase it.
@MainActor
final class AgentRestore {
    static let shared = AgentRestore()

    struct Entry: Codable, Equatable {
        let surface: String
        let session: AgentLauncher.Session
        let savedAt: Date
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "GhosttyAgentsResumeAfterRestart"
    /// Older sessions are not brought back; Ghostty was probably closed on purpose.
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    /// How long to wait for restored terminals to appear and start their shells.
    private static let restoreWindow: TimeInterval = 15

    private var saved: [Entry] = []
    private var pending: [Entry] = []
    private var restoreStarted: Date?
    private var terminating = false
    private var started = false

    /// One file per app location, so a dev build running next to the installed app doesn't
    /// overwrite its list.
    private static var fileURL: URL {
        let bundle = Bundle.main.bundlePath
        let name: String
        if bundle == "/Applications/Ghostty.app" {
            name = "running-agents.json"
        } else {
            var hash: UInt32 = 2_166_136_261
            for byte in bundle.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            name = "running-agents-\(String(hash, radix: 16)).json"
        }
        return CatSprite.directory.appendingPathComponent(name)
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil)

        let previous = Self.load()
        saved = previous
        guard isEnabled else { return }
        pending = previous.filter { Date().timeIntervalSince($0.savedAt) < Self.maxAge }
        if !pending.isEmpty { restoreStarted = Date() }
    }

    @objc private func willTerminate(_ notification: Notification) {
        terminating = true
    }

    /// Called on every sidebar refresh: records running agents and continues a pending
    /// restore.
    func update(agents: [AgentMonitor.Agent], monitor: AgentMonitor) {
        continueRestore(monitor: monitor)

        guard !terminating else { return }
        let now = Date()
        var entries = agents.compactMap { agent -> Entry? in
            guard let session = agent.session else { return nil }
            let previous = saved.first { $0.surface == agent.id.uuidString && $0.session == session }
            return Entry(surface: agent.id.uuidString, session: session, savedAt: previous?.savedAt ?? now)
        }
        // Keep sessions that are still waiting to be restored.
        entries += pending.filter { entry in !entries.contains { $0.surface == entry.surface } }
        guard entries != saved else { return }
        saved = entries
        Self.save(entries)
    }

    private func continueRestore(monitor: AgentMonitor) {
        guard let started = restoreStarted, !pending.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(started)
        // Give window restoration a moment before deciding which terminals came back.
        guard elapsed > 1.5 else { return }

        var stillPending: [Entry] = []
        var missing: [Entry] = []
        for entry in pending {
            guard let id = UUID(uuidString: entry.surface), let surface = monitor.surface(for: id) else {
                missing.append(entry)
                continue
            }
            guard let pid = surface.surfaceModel?.foregroundPID else {
                // The shell hasn't started yet.
                stillPending.append(entry)
                continue
            }
            switch AgentProcess.classify(pid: pid) {
            case .shell:
                AgentLauncher.run(AgentLauncher.command(for: entry.session), in: surface)
            case .agent:
                // Something already runs there; leave it alone.
                break
            case .other:
                stillPending.append(entry)
            }
        }

        if elapsed < Self.restoreWindow {
            pending = stillPending + missing
            return
        }

        // Terminals that never came back get new tabs.
        for entry in missing { AgentLauncher.open(entry.session) }
        pending = []
        restoreStarted = nil
    }

    private static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
