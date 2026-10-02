import AppKit

/// Gives each project a color and tints the tabs its agents run in, using upstream's tab
/// colors (`TerminalWindow.tabColor`). Tabs the user colored by hand are never touched.
@MainActor
final class AgentTabColors {
    /// Orange and green are left out: in the sidebar they mean "needs input" and "done".
    static let palette: [TerminalTabColor] = [.blue, .purple, .pink, .teal, .yellow, .red, .graphite]

    private static let enabledKey = "GhosttyAgentsColorTabs"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { clearAll() }
        }
    }

    /// Tabs this class colored, and the color it set. A tab whose color no longer matches
    /// was recolored by the user and is left alone from then on.
    private var applied: [ObjectIdentifier: (window: Weak<TerminalWindow>, color: TerminalTabColor)] = [:]

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Assigns colors to projects. Each project prefers a color derived from its name, so it
    /// keeps that color across launches; if another visible project has it, it takes the
    /// next free one.
    static func assign(_ projects: [AgentMonitor.Project]) -> [String: TerminalTabColor] {
        var used: Set<TerminalTabColor> = []
        var result: [String: TerminalTabColor] = [:]
        for project in projects where !project.path.isEmpty && result[project.path] == nil {
            let start = Int(stableHash(project.name) % UInt64(palette.count))
            let candidates = (0..<palette.count).map { palette[(start + $0) % palette.count] }
            let color = candidates.first { !used.contains($0) } ?? palette[start]
            used.insert(color)
            result[project.path] = color
        }
        return result
    }

    /// Colors each tab by the project of its agent; tabs without an agent lose the color
    /// this class gave them.
    func apply(_ tabs: [(window: TerminalWindow, project: String?)], colors: [String: TerminalTabColor]) {
        for (window, project) in tabs {
            let id = ObjectIdentifier(window)
            let desired = isEnabled ? project.flatMap { colors[$0] } : nil

            if let previous = applied[id]?.color {
                guard window.tabColor == previous else {
                    // Recolored by the user.
                    applied[id] = nil
                    continue
                }
            } else if window.tabColor != .none && window.tabColor != desired {
                // The user's own color (or one restored from a previous launch that no
                // longer fits). Restored colors that still fit are adopted below.
                continue
            }

            if let desired {
                window.tabColor = desired
                applied[id] = (Weak(window), desired)
            } else if applied[id] != nil {
                window.tabColor = .none
                applied[id] = nil
            }
        }

        applied = applied.filter { $0.value.window.value != nil }
    }

    private func clearAll() {
        for entry in applied.values {
            if let window = entry.window.value, window.tabColor == entry.color {
                window.tabColor = .none
            }
        }
        applied = [:]
    }

    /// FNV-1a. Swift's `hashValue` is seeded per launch, which would reshuffle colors.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
