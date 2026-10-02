import AppKit
import UserNotifications

/// Tells you when an agent needs you while you are looking elsewhere: a notification when an
/// agent asks for input or finishes (clicking it opens that terminal), a bounce of the Dock
/// icon for input requests, and a Dock badge with the number of agents waiting on you.
///
/// Notifications go through Ghostty's own `showUserNotification`, so they only appear when
/// the agent's terminal isn't focused and clicking one focuses it. The plainer notifications
/// agents send themselves (bell, OSC 9/777) for the same terminal are removed once ours is
/// delivered, so you get one notification with the agent's title, project and question.
@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsKey)
            if notificationsEnabled { requestAuthorization() }
        }
    }

    var badgeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(badgeEnabled, forKey: Self.badgeKey)
            if !badgeEnabled { clearBadge() }
        }
    }

    private static let notificationsKey = "GhosttyAgentsNotifications"
    private static let badgeKey = "GhosttyAgentsDockBadge"

    private var previousStates: [UUID: AgentState]?
    /// The badge this class set, so it never clears Ghostty's own bell badge.
    private var ourBadge: String?

    private init() {
        let defaults = UserDefaults.standard
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        badgeEnabled = defaults.object(forKey: Self.badgeKey) as? Bool ?? true
        if notificationsEnabled { requestAuthorization() }
    }

    /// Called on every sidebar refresh.
    func update(agents: [AgentMonitor.Agent], monitor: AgentMonitor) {
        notifyTransitions(agents, monitor: monitor)
        updateBadge(agents)
    }

    // MARK: Notifications

    private func notifyTransitions(_ agents: [AgentMonitor.Agent], monitor: AgentMonitor) {
        let states = Dictionary(agents.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        defer { previousStates = states }
        // The first refresh only learns the current states; nothing has changed yet.
        guard let previous = previousStates, notificationsEnabled else { return }

        for agent in agents {
            let before = previous[agent.id]
            guard agent.state != before, let surface = monitor.surface(for: agent.id) else { continue }

            let body: String
            switch agent.state {
            case .needsInput:
                body = agent.detail
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            case .done where before == .working:
                body = "Finished"
            default:
                continue
            }

            let title = [agent.title, agent.project.name].joined(separator: " · ")
            surface.showUserNotification(title: title, body: body, requireFocus: true)
            removeDuplicates(for: agent.id, keepingTitle: title, body: body)
        }
    }

    /// Removes other notifications for the same terminal from the last few seconds: those
    /// are the agent's own bell or OSC notifications about the same event.
    private func removeDuplicates(for surface: UUID, keepingTitle title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let surfaceID = surface.uuidString
        // Agents often notify a moment after their hooks fire; look again shortly after.
        for delay in [0.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                center.getDeliveredNotifications { notifications in
                    let cutoff = Date().addingTimeInterval(-10)
                    let duplicates = notifications.filter { notification in
                        let content = notification.request.content
                        return content.userInfo["surface"] as? String == surfaceID
                            && notification.date > cutoff
                            && !(content.title == title && content.body == body)
                    }
                    center.removeDeliveredNotifications(withIdentifiers: duplicates.map(\.request.identifier))
                }
            }
        }
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Dock badge

    private func updateBadge(_ agents: [AgentMonitor.Agent]) {
        guard badgeEnabled else { return }
        let count = agents.filter(\.needsAttention).count
        let label = count > 0 ? String(count) : nil
        let dockTile = NSApp.dockTile

        if let label {
            // Re-applied on every refresh: Ghostty resets the badge when its bell state changes.
            if dockTile.badgeLabel != label {
                dockTile.badgeLabel = label
                dockTile.display()
            }
            ourBadge = label
        } else if let ours = ourBadge {
            if dockTile.badgeLabel == ours {
                dockTile.badgeLabel = nil
                dockTile.display()
            }
            ourBadge = nil
        }
    }

    private func clearBadge() {
        if let ours = ourBadge, NSApp.dockTile.badgeLabel == ours {
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.display()
        }
        ourBadge = nil
    }
}
