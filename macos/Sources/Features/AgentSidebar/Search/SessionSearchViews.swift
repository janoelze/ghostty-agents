import AppKit
import SwiftUI

/// The search field at the top of the sidebar. AppKit, so ↑/↓, Return and Escape can drive
/// the result list while typing.
struct SessionSearchField: NSViewRepresentable {
    @ObservedObject var search: SessionSearch
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(search: search) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search sessions"
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search past agent sessions")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if field.stringValue != search.query { field.stringValue = search.query }
        if context.coordinator.focusRequest != search.focusRequest {
            context.coordinator.focusRequest = search.focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let search: SessionSearch
        var focusRequest: Int

        init(search: SessionSearch) {
            self.search = search
            focusRequest = search.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                search.moveSelection(by: 1)
            case #selector(NSResponder.moveUp(_:)):
                search.moveSelection(by: -1)
            case #selector(NSResponder.insertNewline(_:)):
                search.confirmSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                search.cancel()
            default:
                return false
            }
            return true
        }
    }
}

/// Search results, shown in place of the agent list while there is a query.
struct SessionResultsView: View {
    @ObservedObject var search: SessionSearch
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        if search.results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(search.hasSearched ? "No sessions match" : "Searching…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if search.hasSearched {
                    Text("Words can be in different messages and may be misspelled. Use \"quotes\" for exact phrases, -word to exclude.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(search.results) { hit in
                            SessionResultRow(
                                hit: hit,
                                isSelected: search.selection == hit.id,
                                isConfirming: search.confirming == hit.id,
                                isLive: search.liveAgent(for: hit) != nil,
                                search: search)
                                .id(hit.id)
                                .onTapGesture { search.activate(hit) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: search.selection) { selection in
                    guard let selection else { return }
                    proxy.scrollTo(selection)
                }
            }
        }
    }
}

private struct SessionResultRow: View {
    let hit: SessionHit
    let isSelected: Bool
    let isConfirming: Bool
    let isLive: Bool
    let search: SessionSearch

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isLive {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .help("Running in a terminal now")
                }
                Text(Highlight.words(in: hit.title, matching: hit.highlightTerms))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let date = hit.updatedAt {
                    Text(Self.age(date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Text(location)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let snippet = hit.snippet {
                Text(Highlight.snippet(snippet))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(isSelected ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isConfirming {
                confirmBar
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.12 : hovering ? 0.06 : 0)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isConfirming ? 0.7 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(hit.cwd ?? hit.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var location: String {
        var parts: [String] = []
        if hit.agent == .codex { parts.append("Codex") }
        if let cwd = hit.cwd { parts.append((cwd as NSString).lastPathComponent) }
        if let branch = hit.branch { parts.append(branch) }
        if hit.isFuzzy { parts.append("similar words") }
        return parts.joined(separator: " · ")
    }

    private var confirmBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(isLive ? "Switch to Session" : "Resume in New Tab") { search.resume(hit) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { search.confirming = nil }
                    .controlSize(.small)
            }
            Text(isLive ? "↩ switch · esc cancel" : "↩ resume · esc cancel")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if !isLive, let cwd = hit.cwd, !FileManager.default.fileExists(atPath: cwd) {
                Text("The folder no longer exists; the session opens in your home folder.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func age(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<3600: return "\(max(1, seconds / 60))m"
        case ..<86400: return "\(seconds / 3600)h"
        case ..<(86400 * 30): return "\(seconds / 86400)d"
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(seconds < 86400 * 300 ? "MMMd" : "MMMyy")
            return formatter.string(from: date)
        }
    }
}

/// Builds highlighted text for results.
private enum Highlight {
    static func apply(_ range: Range<AttributedString.Index>, in text: inout AttributedString) {
        text[range].foregroundColor = .primary
        text[range].font = .system(size: 11, weight: .semibold)
        text[range].backgroundColor = Color.accentColor.opacity(0.22)
    }

    /// A snippet from SQLite, with matches between \u{1} and \u{2}.
    static func snippet(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var inMatch = false
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var part = AttributedString(current)
            if inMatch { apply(part.startIndex..<part.endIndex, in: &part) }
            result += part
            current = ""
        }
        for char in raw {
            if char == "\u{1}" { flush(); inMatch = true } else if char == "\u{2}" { flush(); inMatch = false } else { current.append(char) }
        }
        flush()
        return result
    }

    /// Highlights words in a title that start with one of the terms.
    static func words(in title: String, matching terms: [String]) -> AttributedString {
        var result = AttributedString(title)
        let folded = terms.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let ns = title as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard folded.contains(where: { key.hasPrefix($0) }),
                  let attributedRange = Range(range, in: result)
            else { return }
            result[attributedRange].backgroundColor = Color.accentColor.opacity(0.22)
        }
        return result
    }
}

/// The search index state, shown at the right end of the empty search field: a progress
/// ring while transcripts are indexed, the number of searchable sessions once done.
struct SearchIndexBadge: View {
    let state: SessionIndexState

    var body: some View {
        Group {
            if state.isIndexing && state.total > 0 {
                let progress = Double(state.done) / Double(max(state.total, 1))
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.2), value: progress)
                    }
                    .frame(width: 10, height: 10)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                .help("Indexing session transcripts: \(state.done) of \(state.total)")
            } else if state.sessions > 0 {
                Text("\(state.sessions)")
                    .monospacedDigit()
                    .help("\(state.sessions) sessions searchable. Agents → Rebuild Search Index to start over.")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
    }
}

/// The line at the bottom of the sidebar: a summary of the running agents.
struct SidebarStatusLine: View {
    @ObservedObject var monitor: AgentMonitor
    @ObservedObject var search: SessionSearch
    let divider: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(agentSummary)
                .lineLimit(1)

            Spacer(minLength: 6)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(divider).frame(height: 1) }
        .contextMenu {
            Button("Search Sessions…") { search.focusField() }
            Button("Rebuild Search Index") { search.rebuildIndex() }
        }
    }

    private var agentSummary: String {
        let count = monitor.agents.count
        guard count > 0 else { return "No agents" }
        let waiting = monitor.agents.filter { $0.state == .needsInput }.count
        let working = monitor.agents.filter { $0.state == .working }.count
        var parts = ["\(count) agent\(count == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }
}
