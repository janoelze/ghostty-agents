import AppKit
import SwiftUI

/// Places the agent sidebar to the left of a window's terminal content.
///
/// This is the only view the rest of the app knows about: `TerminalController` wraps its
/// `TerminalView` in it. Everything else in this folder is self-contained.
struct AgentSidebarLayout<Content: View>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject private var monitor = AgentMonitor.shared
    private let content: Content

    init(ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.ghostty = ghostty
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if monitor.isSidebarVisible && ghostty.readiness == .ready {
                let style = AgentSidebarStyle(config: ghostty.config)
                AgentSidebarView(monitor: monitor, style: style)
                    .frame(width: monitor.sidebarWidth)
                AgentSidebarResizeHandle(width: $monitor.sidebarWidth, color: style.divider)
            }

            content
        }
        .onAppear { monitor.start() }
    }
}

/// Colors derived from the Ghostty config so the sidebar follows the terminal theme,
/// including background opacity and light/dark themes independent of the system appearance.
struct AgentSidebarStyle {
    let background: Color
    let divider: Color
    let colorScheme: ColorScheme

    init(config: Ghostty.Config) {
        let terminal = NSColor(config.backgroundColor)
        let isLight = terminal.isLightColor
        // A shade off the terminal background, like a source list next to an editor.
        background = Color(terminal.darken(by: isLight ? 0.03 : 0.12)).opacity(config.backgroundOpacity)
        divider = config.splitDividerColor
        colorScheme = isLight ? .light : .dark
    }
}

struct AgentSidebarView: View {
    @ObservedObject var monitor: AgentMonitor
    let style: AgentSidebarStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if monitor.agents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(monitor.agents.enumerated()), id: \.element.id) { offset, agent in
                            AgentRow(agent: agent, position: offset + 1)
                                .onTapGesture { monitor.focus(agent.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.background.ignoresSafeArea())
        .environment(\.colorScheme, style.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            let waiting = monitor.agents.filter(\.needsAttention).count
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .help("Agents needing attention (⌃⌘J to jump)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No agents running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Start claude, codex or another agent in any tab and it shows up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
}

private struct AgentRow: View {
    let agent: AgentMonitor.Agent
    let position: Int

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentStatusDot(state: agent.state, emphasized: agent.needsAttention)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.title)
                        .font(.system(size: 12, weight: agent.needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if hovering && position <= 9 {
                        Text("⌃⌘\(position)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 4) {
                    Text(agent.state.label)
                        .foregroundStyle(agent.state == .needsInput ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    if let since = agent.since {
                        Text("·")
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text(Self.shortAge(since, now: context.date))
                        }
                    }
                    if let directory = agent.directory {
                        Text("·")
                        Text((directory as NSString).lastPathComponent)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let detail = agent.detail, detail != agent.title {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(agent.isFocused ? 0.12 : hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help([agent.name, agent.directory].compactMap { $0 }.joined(separator: " — "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name): \(agent.title), \(agent.state.label)")
        .accessibilityAddTraits(.isButton)
    }

    private static func shortAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

private struct AgentStatusDot: View {
    let state: AgentState
    let emphasized: Bool

    @State private var pulse = false

    var body: some View {
        ZStack {
            switch state {
            case .working:
                Circle()
                    .fill(Color.accentColor)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .needsInput:
                Circle().fill(Color.orange)
            case .done:
                if emphasized {
                    Circle().fill(Color.green)
                } else {
                    Circle().strokeBorder(Color.green.opacity(0.7), lineWidth: 1.5)
                }
            case .running:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// A divider that can be dragged to resize the sidebar. The hit area is wider than the line.
struct AgentSidebarResizeHandle: View {
    @Binding var width: CGFloat
    let color: Color

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                width = min(max(start + value.translation.width, AgentMonitor.minWidth), AgentMonitor.maxWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .onTapGesture(count: 2) { width = 240 }
            )
            .accessibilityHidden(true)
    }
}
