import Foundation

/// The searchable parts of one agent session, read from its transcript file.
struct SessionDocument {
    enum Agent: String {
        case claude
        case codex
    }

    var id: String
    let agent: Agent
    let path: String
    /// For Claude Code: the config dir the transcript lives in (`~/.claude`, a profile, …).
    let configDir: String?
    var cwd: String?
    var branch: String?
    var title: String?
    var startedAt: Date?
    var updatedAt: Date?
    var prompts: [String] = []
    var responses: [String] = []
    var tools: [String] = []

    var firstPrompt: String? { prompts.first }
    var isEmpty: Bool { prompts.isEmpty && responses.isEmpty }
}

/// Reads Claude Code and Codex transcripts (JSONL). Only what a person would remember is
/// kept: titles, prompts, replies and tool calls (commands, file paths, descriptions).
/// Tool results and thinking are skipped; they are most of the bytes and mostly noise.
///
/// Transcript formats are internal to each tool and change between versions, so parsing is
/// deliberately loose: every line is real JSON parsing (no byte patterns that break on a
/// whitespace change), roles are inferred from several places, and if the known layout
/// yields nothing, a generic walker still collects the text. Bump `version` whenever the
/// output changes; the index then re-reads every transcript.
enum TranscriptParser {
    static let version = 1

    /// Single texts are capped so a huge paste doesn't dominate the index.
    private static let maxTextLength = 20_000

    /// Lines longer than this are only parsed if they don't look like tool output. Tool
    /// results (file contents, command output) can be megabytes each.
    private static let largeLine = 200_000

    // MARK: Claude Code

    static func parseClaude(url: URL, configDir: String) -> SessionDocument? {
        var doc = SessionDocument(
            id: url.deletingPathExtension().lastPathComponent,
            agent: .claude,
            path: url.path,
            configDir: configDir)
        var customTitle: String?

        forEachObject(in: url) { object in
            let type = object["type"] as? String

            switch type {
            case "ai-title":
                if let title = object["aiTitle"] as? String { doc.title = title }
                return
            case "custom-title":
                if let title = object["customTitle"] as? String { customTitle = title }
                return
            case "summary":
                if doc.title == nil, let summary = object["summary"] as? String { doc.title = summary }
                return
            default:
                break
            }

            // Subagent internals and injected meta messages aren't part of the conversation.
            if object["isSidechain"] as? Bool == true || object["isMeta"] as? Bool == true { return }

            readCommonMetadata(object, into: &doc)

            guard let message = object["message"] as? [String: Any] else { return }
            let role = message["role"] as? String ?? type
            let content = message["content"]

            switch role {
            case "user":
                // Tool results come back as user messages; only text blocks are prompts.
                if let cleaned = text(of: content).map(cleanClaudePrompt), !cleaned.isEmpty {
                    doc.prompts.append(cap(cleaned))
                }
            case "assistant":
                if let string = content as? String, !string.isEmpty {
                    doc.responses.append(cap(string))
                }
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty { doc.responses.append(cap(text)) }
                    case "tool_use", "server_tool_use":
                        if let tool = describeTool(block["input"]) { doc.tools.append(cap(tool)) }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        if let customTitle { doc.title = customTitle }
        if doc.isEmpty { fallback(url, into: &doc) }
        return doc.isEmpty ? nil : doc
    }

    /// Removes the wrappers Claude Code adds around prompts (system reminders, command
    /// output) and turns slash command markup into `/command args`.
    private static func cleanClaudePrompt(_ text: String) -> String {
        var result = text
        for tag in ["system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat", "command-message", "bash-stdout", "bash-stderr"] {
            result = result.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>",
                with: " ",
                options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "</?(command-name|command-args|bash-input)>", with: " ", options: .regularExpression)
        if result.hasPrefix("Caveat: The messages below") { return "" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Codex

    static func parseCodex(url: URL) -> SessionDocument? {
        var doc = SessionDocument(id: "", agent: .codex, path: url.path, configDir: nil)
        // Codex logs user text twice (as an event and as a model input item that also
        // carries environment context); prefer the events and fall back to the items.
        var itemPrompts: [String] = []
        var itemResponses: [String] = []

        forEachObject(in: url) { object in
            let payload = object["payload"] as? [String: Any] ?? object
            readCommonMetadata(object, into: &doc)
            readCommonMetadata(payload, into: &doc)

            switch (object["type"] as? String, payload["type"] as? String) {
            case ("session_meta", _):
                if let id = payload["id"] as? String { doc.id = id }
                if let branch = (payload["git"] as? [String: Any])?["branch"] as? String { doc.branch = branch }
            case (_, "user_message"):
                if let text = payload["message"] as? String, !text.isEmpty { doc.prompts.append(cap(text)) }
            case (_, "agent_message"):
                if let text = payload["message"] as? String, !text.isEmpty { doc.responses.append(cap(text)) }
            case (_, "message"):
                guard let text = text(of: payload["content"]), !text.isEmpty else { return }
                switch payload["role"] as? String {
                case "user": if !text.hasPrefix("<") { itemPrompts.append(cap(text)) }
                case "assistant": itemResponses.append(cap(text))
                default: break
                }
            case (_, "function_call"), (_, "custom_tool_call"), (_, "local_shell_call"):
                var input = payload["arguments"] ?? payload["input"] ?? payload["action"]
                if let string = input as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(string.utf8)) {
                    input = parsed
                }
                if let tool = describeTool(input) { doc.tools.append(cap(tool)) }
            default:
                break
            }
        }

        if doc.prompts.isEmpty { doc.prompts = itemPrompts }
        if doc.responses.isEmpty { doc.responses = itemResponses }
        if doc.id.isEmpty {
            // rollout-<date>-<uuid>.jsonl
            let name = url.deletingPathExtension().lastPathComponent
            doc.id = String(name.suffix(36))
        }
        if doc.isEmpty { fallback(url, into: &doc) }
        return doc.isEmpty ? nil : doc
    }

    // MARK: Shared extraction

    /// Metadata that both tools (and likely future versions) store under obvious names.
    private static func readCommonMetadata(_ object: [String: Any], into doc: inout SessionDocument) {
        if doc.agent == .claude, let id = (object["sessionId"] ?? object["session_id"]) as? String { doc.id = id }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { doc.cwd = cwd }
        if let branch = (object["gitBranch"] ?? object["branch"]) as? String, !branch.isEmpty, branch != "HEAD" {
            doc.branch = branch
        }
        if let date = ((object["timestamp"] ?? object["created_at"]) as? String).flatMap(parseDate) {
            if doc.startedAt == nil { doc.startedAt = date }
            doc.updatedAt = date
        }
    }

    /// The text of a message's content: a string, or the text blocks of a block array
    /// (`text`, `input_text`, `output_text`, …). Tool results, images and thinking are skipped.
    private static func text(of content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "text" || type.hasSuffix("_text") else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// The memorable parts of a tool call's input: what it ran, on which files, and why.
    private static func describeTool(_ input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        let keys = ["description", "command", "cmd", "file_path", "notebook_path", "path", "pattern", "url", "query", "prompt", "skill"]
        let parts = keys.compactMap { key -> String? in
            if let values = input[key] as? [String] { return values.last }
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            // Subagent prompts can be long; their gist is in the first lines.
            return key == "prompt" ? String(value.prefix(400)) : value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Used when the known layout yields nothing, e.g. after a tool changed its format.
    /// Collects strings under text-like keys anywhere in each line, skipping subtrees that
    /// hold tool output or internal state. The first one is treated as the prompt.
    private static func fallback(_ url: URL, into doc: inout SessionDocument) {
        let textKeys: Set<String> = ["text", "message", "prompt", "content", "aiTitle", "summary"]
        let skipKeys: Set<String> = [
            "toolUseResult", "tool_result", "output", "result", "results", "snapshot", "thinking",
            "signature", "encrypted_content", "attachment", "base_instructions", "instructions",
        ]

        func walk(_ value: Any, key: String?, into texts: inout [String]) {
            if let key, skipKeys.contains(key) { return }
            if let dict = value as? [String: Any] {
                if dict["type"] as? String == "tool_result" { return }
                for (childKey, child) in dict { walk(child, key: childKey, into: &texts) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, key: key, into: &texts) }
            } else if let string = value as? String, let key, textKeys.contains(key),
                      string.count >= 2, !string.hasPrefix("{") {
                texts.append(cap(string))
            }
        }

        var texts: [String] = []
        forEachObject(in: url) { walk($0, key: nil, into: &texts) }
        guard let first = texts.first else { return }
        doc.prompts = [first]
        doc.responses = Array(texts.dropFirst())
    }

    // MARK: Helpers

    private static let toolOutputMarkers = [
        Data("tool_result".utf8), Data("function_call_output".utf8), Data("file-history".utf8),
    ]

    /// Calls `body` with each JSON object line. Very large lines that look like tool output
    /// are skipped without parsing; everything else is parsed for real.
    private static func forEachObject(in url: URL, _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            guard end > start else { continue }
            let line = data[start..<end]
            if line.count > largeLine, toolOutputMarkers.contains(where: { line.range(of: $0) != nil }) { continue }
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                body(object)
            }
        }
    }

    private static func cap(_ text: String) -> String {
        text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter = ISO8601DateFormatter()

    private static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string) ?? plainDateFormatter.date(from: string)
    }
}
