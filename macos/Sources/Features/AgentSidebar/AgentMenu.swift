import AppKit

/// The "Agents" menu in the main menu bar. It is added at runtime (rather than in
/// MainMenu.xib) so the fork doesn't need to modify upstream's menu definition.
///
/// Shortcuts:
/// - ⌃⌘S  Show/Hide Agent Sidebar (the standard macOS sidebar shortcut)
/// - ⌃⌘J  Next Agent Needing Attention
/// - ⌃⌘1…9  Go to the agent at that position
/// - ⌃⌘K  Search past sessions
///
/// These are ordinary menu key equivalents, so a Ghostty keybind on the same key takes
/// precedence, and they can be remapped in System Settings → Keyboard → App Shortcuts.
@MainActor
enum AgentMenu {
    private static let menu = NSMenu(title: "Agents")
    private static let target = Target()
    private static var agentItemsSignature: [String] = []
    private static let agentItemTag = 7_100

    static func install() {
        guard let mainMenu = NSApp.mainMenu, menu.supermenu == nil else { return }

        let toggle = NSMenuItem(title: "Hide Agent Sidebar", action: #selector(Target.toggleSidebar(_:)), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.control, .command]
        toggle.target = target
        menu.addItem(toggle)

        let next = NSMenuItem(title: "Next Agent Needing Attention", action: #selector(Target.nextNeedingAttention(_:)), keyEquivalent: "j")
        next.keyEquivalentModifierMask = [.control, .command]
        next.target = target
        menu.addItem(next)

        let searchItem = NSMenuItem(title: "Search Sessions…", action: #selector(Target.searchSessions(_:)), keyEquivalent: "k")
        searchItem.keyEquivalentModifierMask = [.control, .command]
        searchItem.target = target
        menu.addItem(searchItem)

        let rebuild = NSMenuItem(title: "Rebuild Search Index", action: #selector(Target.rebuildIndex(_:)), keyEquivalent: "")
        rebuild.target = target
        menu.addItem(rebuild)

        menu.addItem(.separator())

        let cats = NSMenuItem(title: "Cat Mode", action: #selector(Target.toggleCatMode(_:)), keyEquivalent: "")
        cats.target = target
        menu.addItem(cats)

        let colors = NSMenuItem(title: "Color Tabs by Project", action: #selector(Target.toggleTabColors(_:)), keyEquivalent: "")
        colors.target = target
        menu.addItem(colors)

        menu.addItem(.separator())

        let item = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        item.submenu = menu

        // Place it right before the Window menu, like other app-specific menus.
        if let windowsMenu = NSApp.windowsMenu, let index = mainMenu.items.firstIndex(where: { $0.submenu == windowsMenu }) {
            mainMenu.insertItem(item, at: index)
        } else {
            mainMenu.addItem(item)
        }
    }

    /// Rebuilds the per-agent items when the list of agents changes.
    static func update(agents: [AgentMonitor.Agent]) {
        let signature = agents.map { "\($0.id)|\($0.title)" }
        guard signature != agentItemsSignature, menu.supermenu != nil else { return }
        agentItemsSignature = signature

        for item in menu.items where item.tag == agentItemTag {
            menu.removeItem(item)
        }

        if agents.isEmpty {
            let empty = NSMenuItem(title: "No Agents Running", action: nil, keyEquivalent: "")
            empty.tag = agentItemTag
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for (offset, agent) in agents.enumerated() {
            let position = offset + 1
            let item = NSMenuItem(
                title: agent.title,
                action: #selector(Target.goToAgent(_:)),
                keyEquivalent: position <= 9 ? "\(position)" : "")
            item.keyEquivalentModifierMask = [.control, .command]
            item.representedObject = agent.id
            item.target = target
            item.tag = agentItemTag
            item.toolTip = agent.directory
            menu.addItem(item)
        }
    }

    @MainActor
    private final class Target: NSObject, NSMenuItemValidation {
        @objc func toggleSidebar(_ sender: Any?) {
            AgentMonitor.shared.toggleSidebar()
        }

        @objc func nextNeedingAttention(_ sender: Any?) {
            AgentMonitor.shared.focusNextNeedingAttention()
        }

        @objc func goToAgent(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            AgentMonitor.shared.focus(id)
        }

        @objc func searchSessions(_ sender: Any?) {
            SessionSearch.shared.focusField()
        }

        @objc func rebuildIndex(_ sender: Any?) {
            SessionSearch.shared.rebuildIndex()
        }

        @objc func toggleCatMode(_ sender: Any?) {
            AgentMonitor.shared.toggleCatMode()
        }

        @objc func toggleTabColors(_ sender: Any?) {
            AgentMonitor.shared.toggleTabColors()
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(toggleSidebar(_:)) {
                menuItem.title = AgentMonitor.shared.isSidebarVisible ? "Hide Agent Sidebar" : "Show Agent Sidebar"
            } else if menuItem.action == #selector(toggleTabColors(_:)) {
                menuItem.state = AgentMonitor.shared.tabColors.isEnabled ? .on : .off
            } else if menuItem.action == #selector(toggleCatMode(_:)) {
                menuItem.state = AgentMonitor.shared.catMode ? .on : .off
                guard CatSprite.isAvailable else {
                    menuItem.toolTip = "Put cat sprite sheets (cat-<color>.png) in \(CatSprite.directory.path)"
                    return false
                }
                menuItem.toolTip = nil
            }
            return true
        }
    }
}
