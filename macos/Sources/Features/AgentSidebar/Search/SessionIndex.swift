import CoreServices
import Foundation

/// One search result: a past (or running) agent session.
struct SessionHit: Identifiable, Equatable {
    var id: String { sessionID }
    let sessionID: String
    let agent: SessionDocument.Agent
    let path: String
    let configDir: String?
    let cwd: String?
    let branch: String?
    let title: String
    let updatedAt: Date?
    /// The best matching passage, with matches wrapped in \u{1} … \u{2}.
    let snippet: String?
    /// Words to highlight in the title: the query terms and their fuzzy matches.
    let highlightTerms: [String]
    /// True when the session only matched through typo tolerance.
    let isFuzzy: Bool
}

/// Progress of the transcript index, shown under the search field.
struct SessionIndexState: Equatable {
    var isIndexing = false
    var done = 0
    var total = 0
    var sessions = 0
}

/// A full-text index over Claude Code and Codex transcripts, kept in SQLite FTS5.
///
/// Indexing runs on its own queue with its own connection; searches use a second, read-only
/// connection, so typing never waits on indexing. Transcripts are re-read only when their
/// size or modification date changes, and FSEvents keeps the index current.
final class SessionIndex: @unchecked Sendable {
    static let shared = SessionIndex()

    /// Bump when the schema changes. The parser has its own version; either one changing
    /// rebuilds the index.
    private static let schemaVersion = 1

    /// Called on the main queue whenever indexing progresses or finishes.
    var onStateChange: ((SessionIndexState) -> Void)?

    private let indexQueue = DispatchQueue(label: "ghostty-agents.session-index", qos: .utility)
    private let searchQueue = DispatchQueue(label: "ghostty-agents.session-search", qos: .userInitiated)
    private var writer: SQLiteConnection?
    private var reader: SQLiteConnection?
    private var stream: FSEventStreamRef?
    private var started = false

    // Index queue state.
    private var state = SessionIndexState()

    // Search queue state.
    private var vocabulary: Vocabulary?
    private var vocabularyGeneration = -1

    // Shared between queues, guarded by `lock`.
    private let lock = NSLock()
    private var _indexGeneration = 0
    private var passQueued = false

    /// Changes whenever the index has new content; the search side reloads its vocabulary.
    private var indexGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return _indexGeneration
    }

    private func bumpGeneration() {
        lock.lock(); _indexGeneration += 1; lock.unlock()
    }

    static var databaseURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ghostty-agents", isDirectory: true)
            .appendingPathComponent("sessions.sqlite")
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        indexQueue.async { [self] in
            do {
                try openWriter()
            } catch {
                Ghostty.logger.warning("session index unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        requestIndexPass()
        DispatchQueue.main.async { self.startWatching() }
    }

    /// Drops the index and reads every transcript again.
    func rebuild() {
        indexQueue.async { [self] in
            do {
                try openWriter()
                try writer?.transaction { try dropSchema(); try createSchema() }
                state = SessionIndexState()
                bumpGeneration()
            } catch {
                Ghostty.logger.warning("session index rebuild failed: \(String(describing: error), privacy: .public)")
            }
        }
        requestIndexPass()
    }

    private func openWriter() throws {
        guard writer == nil else { return }
        try FileManager.default.createDirectory(
            at: Self.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: Self.databaseURL.path)
        try connection.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        writer = connection

        try connection.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        var version: String?
        try connection.query("SELECT value FROM meta WHERE key = 'version'") { version = $0.string(0) }
        let expected = "\(Self.schemaVersion).\(TranscriptParser.version)"
        if version != expected {
            try connection.transaction {
                try dropSchema()
                try createSchema()
                try connection.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('version', ?)", [expected])
            }
        }
    }

    private func createSchema() throws {
        guard let writer else { return }
        try writer.execute("""
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER, mtime REAL);
            CREATE TABLE IF NOT EXISTS sessions(
                rowid INTEGER PRIMARY KEY, id TEXT, agent TEXT, path TEXT UNIQUE, config_dir TEXT,
                cwd TEXT, branch TEXT, title TEXT, first_prompt TEXT, started REAL, updated REAL);
            CREATE INDEX IF NOT EXISTS sessions_id ON sessions(id);
            CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
                title, prompts, responses, tools, idents,
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
                text, session UNINDEXED, kind UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE IF NOT EXISTS vocab USING fts5vocab(session_fts, 'row');
            """)
    }

    private func dropSchema() throws {
        try writer?.execute("""
            DROP TABLE IF EXISTS vocab;
            DROP TABLE IF EXISTS message_fts;
            DROP TABLE IF EXISTS session_fts;
            DROP TABLE IF EXISTS sessions;
            DROP TABLE IF EXISTS files;
            """)
    }

    // MARK: Watching

    private func startWatching() {
        let paths = Self.roots().map(\.directory.path)
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let index = Unmanaged<SessionIndex>.fromOpaque(info).takeUnretainedValue()
            index.requestIndexPass()
        }

        // Running sessions write constantly; a few seconds of latency batches that up.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // MARK: Indexing (index queue)

    private struct TranscriptRoot {
        let agent: SessionDocument.Agent
        let directory: URL
        let configDir: String?
    }

    private struct TranscriptFile {
        let url: URL
        let root: TranscriptRoot
        let size: Int64
        let mtime: Double
    }

    /// Where transcripts live: every Claude Code config dir (the default, `CLAUDE_CONFIG_DIR`
    /// and `~/.claude-profiles/*`) and Codex's sessions dir.
    private static func roots() -> [TranscriptRoot] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment

        var claudeDirs = [home.appendingPathComponent(".claude")]
        if let dir = env["CLAUDE_CONFIG_DIR"] { claudeDirs.append(URL(fileURLWithPath: dir)) }
        let profiles = home.appendingPathComponent(".claude-profiles")
        for profile in (try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
            claudeDirs.append(profile)
        }

        var seen: Set<String> = []
        var roots: [TranscriptRoot] = []
        for dir in claudeDirs {
            let resolved = dir.resolvingSymlinksInPath()
            let projects = resolved.appendingPathComponent("projects")
            guard seen.insert(projects.path).inserted, fm.fileExists(atPath: projects.path) else { continue }
            roots.append(TranscriptRoot(agent: .claude, directory: projects, configDir: resolved.path))
        }

        let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let codexSessions = codexHome.appendingPathComponent("sessions")
        if fm.fileExists(atPath: codexSessions.path) {
            roots.append(TranscriptRoot(agent: .codex, directory: codexSessions, configDir: nil))
        }
        return roots
    }

    private static func transcriptFiles() -> [TranscriptFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var files: [TranscriptFile] = []

        func add(_ url: URL, _ root: TranscriptRoot) {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return }
            files.append(TranscriptFile(
                url: url,
                root: root,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }

        for root in roots() {
            switch root.agent {
            case .claude:
                // projects/<project>/<session>.jsonl; deeper files are subagent logs.
                let projects = (try? fm.contentsOfDirectory(at: root.directory, includingPropertiesForKeys: nil)) ?? []
                for project in projects {
                    let sessions = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? []
                    for url in sessions { add(url, root) }
                }
            case .codex:
                let enumerator = fm.enumerator(at: root.directory, includingPropertiesForKeys: keys)
                while let url = enumerator?.nextObject() as? URL { add(url, root) }
            }
        }
        return files
    }

    /// Queues an index pass unless one is already waiting. FSEvents fire in bursts; they
    /// collapse into a single pass, and a pass that is running picks up changes next time.
    func requestIndexPass() {
        lock.lock()
        let alreadyQueued = passQueued
        passQueued = true
        lock.unlock()
        guard !alreadyQueued else { return }

        indexQueue.async { [self] in
            lock.lock(); passQueued = false; lock.unlock()
            indexPass()
        }
    }

    private func indexPass() {
        guard let writer else { return }
        let files = Self.transcriptFiles()

        var known: [String: (size: Int64, mtime: Double)] = [:]
        try? writer.query("SELECT path, size, mtime FROM files") { row in
            if let path = row.string(0) { known[path] = (row.int(1), row.double(2)) }
        }

        let changed = files.filter { file in
            guard let entry = known[file.url.path] else { return true }
            return entry.size != file.size || abs(entry.mtime - file.mtime) > 0.001
        }
        let present = Set(files.map(\.url.path))
        let removed = known.keys.filter { !present.contains($0) }

        if !removed.isEmpty {
            try? writer.transaction {
                for path in removed {
                    try deleteSession(path: path)
                    try writer.run("DELETE FROM files WHERE path = ?", [path])
                }
            }
        }

        guard !changed.isEmpty else {
            if !removed.isEmpty || state.sessions == 0 { finishPass() }
            return
        }

        state.isIndexing = true
        state.done = 0
        state.total = changed.count
        publishState()

        // Parse in parallel, write serially. Small batches keep the index searchable
        // (each commit is visible to the search connection) while a large pass runs.
        let batchSize = 16
        var offset = 0
        while offset < changed.count {
            let batch = Array(changed[offset..<min(offset + batchSize, changed.count)])
            var documents = [SessionDocument?](repeating: nil, count: batch.count)
            documents.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                    let file = batch[index]
                    switch file.root.agent {
                    case .claude:
                        buffer[index] = TranscriptParser.parseClaude(url: file.url, configDir: file.root.configDir ?? "")
                    case .codex:
                        buffer[index] = TranscriptParser.parseCodex(url: file.url)
                    }
                }
            }

            try? writer.transaction {
                for (file, document) in zip(batch, documents) {
                    try deleteSession(path: file.url.path)
                    if let document { try insert(document) }
                    try writer.run(
                        "INSERT OR REPLACE INTO files(path, size, mtime) VALUES (?, ?, ?)",
                        [file.url.path, file.size, file.mtime])
                }
            }

            offset += batch.count
            state.done = offset
            bumpGeneration()
            publishState()
        }

        finishPass()
    }

    private func finishPass() {
        guard let writer else { return }
        var count = 0
        try? writer.query("SELECT count(*) FROM sessions") { count = Int($0.int(0)) }
        try? writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
        state = SessionIndexState(isIndexing: false, done: state.total, total: state.total, sessions: count)
        bumpGeneration()
        publishState()
    }

    private func publishState() {
        let snapshot = state
        DispatchQueue.main.async { self.onStateChange?(snapshot) }
    }

    private func deleteSession(path: String) throws {
        guard let writer else { return }
        var rowid: Int64?
        try writer.query("SELECT rowid FROM sessions WHERE path = ?", [path]) { rowid = $0.int(0) }
        guard let rowid else { return }
        try writer.run("DELETE FROM session_fts WHERE rowid = ?", [rowid])
        try writer.run("DELETE FROM message_fts WHERE session = ?", [rowid])
        try writer.run("DELETE FROM sessions WHERE rowid = ?", [rowid])
    }

    private func insert(_ doc: SessionDocument) throws {
        guard let writer else { return }
        try writer.run("""
            INSERT INTO sessions(id, agent, path, config_dir, cwd, branch, title, first_prompt, started, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                doc.id, doc.agent.rawValue, doc.path, doc.configDir, doc.cwd, doc.branch, doc.title,
                doc.firstPrompt.map { String($0.prefix(500)) },
                doc.startedAt?.timeIntervalSince1970, doc.updatedAt?.timeIntervalSince1970,
            ])
        let rowid = writer.lastInsertRowID

        let everything = doc.prompts + doc.responses + doc.tools + [doc.title ?? "", doc.cwd ?? ""]
        try writer.run(
            "INSERT INTO session_fts(rowid, title, prompts, responses, tools, idents) VALUES (?, ?, ?, ?, ?, ?)",
            [
                rowid,
                [doc.title, doc.cwd.map { ($0 as NSString).lastPathComponent }, doc.branch]
                    .compactMap { $0 }.joined(separator: " "),
                doc.prompts.joined(separator: "\n"),
                doc.responses.joined(separator: "\n"),
                doc.tools.joined(separator: "\n"),
                Self.identifierParts(everything),
            ])

        for (kind, texts) in [("p", doc.prompts), ("r", doc.responses), ("t", doc.tools)] {
            for text in texts {
                try writer.run("INSERT INTO message_fts(text, session, kind) VALUES (?, ?, ?)", [text, rowid, kind])
            }
        }
    }

    /// The parts of compound identifiers, so `monitor` finds `AgentMonitor`,
    /// `agent_monitor`, `agent-monitor.swift` and `src/monitor/index.ts`.
    private static func identifierParts(_ texts: [String]) -> String {
        var parts: Set<String> = []
        for text in texts {
            var token: [Character] = []
            func flush() {
                defer { token.removeAll(keepingCapacity: true) }
                guard token.count >= 4 else { return }
                var piece = ""
                var pieces: [String] = []
                var previous: Character?
                for char in token {
                    let boundary = !char.isLetter && !char.isNumber
                    let camel = char.isUppercase && (previous?.isLowercase ?? false)
                    if boundary || camel {
                        if !piece.isEmpty { pieces.append(piece) }
                        piece = boundary ? "" : String(char)
                    } else {
                        piece.append(char)
                    }
                    previous = char
                }
                if !piece.isEmpty { pieces.append(piece) }
                guard pieces.count > 1 else { return }
                for part in pieces where part.count >= 3 { parts.insert(part.lowercased()) }
            }
            for char in text {
                if char.isLetter || char.isNumber || char == "_" || char == "-" || char == "." || char == "/" {
                    token.append(char)
                } else {
                    flush()
                }
            }
            flush()
        }
        return parts.joined(separator: " ")
    }

    // MARK: Searching (search queue)

    /// Searches on a background queue and calls `completion` on the main queue.
    func search(_ text: String, completion: @escaping ([SessionHit]) -> Void) {
        searchQueue.async { [self] in
            let hits = (try? performSearch(text)) ?? []
            DispatchQueue.main.async { completion(hits) }
        }
    }

    private func performSearch(_ text: String) throws -> [SessionHit] {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return [] }

        if reader == nil {
            guard FileManager.default.fileExists(atPath: Self.databaseURL.path) else { return [] }
            reader = try SQLiteConnection(path: Self.databaseURL.path)
        }
        guard let reader else { return [] }

        // The vocabulary drives typo tolerance; reload it when the index has changed.
        let generation = indexGeneration
        if vocabulary == nil || vocabularyGeneration != generation {
            vocabulary = Vocabulary(connection: reader)
            vocabularyGeneration = generation
        }

        let expansions = query.terms.map { vocabulary?.expansions(of: $0) ?? [] }

        // Tier 1: every term as typed (prefix match). Tier 2: typo-tolerant, only if tier 1
        // came up short. Tier 1 results always rank first.
        var ranked = try match(query.expression(expansions: nil), reader: reader, fuzzy: false)
        if ranked.count < 40, expansions.contains(where: { !$0.isEmpty }) {
            let seen = Set(ranked.map(\.rowid))
            let fuzzy = try match(query.expression(expansions: expansions), reader: reader, fuzzy: true)
            ranked += fuzzy.filter { !seen.contains($0.rowid) }
        }

        // One result per session: resumed sessions can span several files.
        var seenIDs: Set<String> = []
        ranked = ranked.filter { seenIDs.insert($0.sessionID).inserted }

        let highlight = query.terms + expansions.flatMap { $0 }
        let snippetExpression = query.anyTermExpression(expansions: expansions)
        return Array(ranked.prefix(60)).map { candidate in
            var snippet: String?
            try? reader.query("""
                SELECT snippet(message_fts, 0, char(1), char(2), '…', 18) FROM message_fts
                WHERE message_fts MATCH ? AND session = ? ORDER BY rank LIMIT 1
                """, [snippetExpression, candidate.rowid]) { snippet = $0.string(0) }

            return SessionHit(
                sessionID: candidate.sessionID,
                agent: candidate.agent,
                path: candidate.path,
                configDir: candidate.configDir,
                cwd: candidate.cwd,
                branch: candidate.branch,
                title: candidate.title,
                updatedAt: candidate.updatedAt,
                snippet: snippet?.replacingOccurrences(of: "\n", with: " "),
                highlightTerms: highlight,
                isFuzzy: candidate.isFuzzy)
        }
    }

    private struct Candidate {
        let rowid: Int64
        let sessionID: String
        let agent: SessionDocument.Agent
        let path: String
        let configDir: String?
        let cwd: String?
        let branch: String?
        let title: String
        let updatedAt: Date?
        let score: Double
        let isFuzzy: Bool
    }

    private func match(_ expression: String, reader: SQLiteConnection, fuzzy: Bool) throws -> [Candidate] {
        guard !expression.isEmpty else { return [] }
        var candidates: [Candidate] = []
        let now = Date().timeIntervalSince1970
        // Column weights: title, prompts, responses, tools, identifier parts. What you typed
        // and what the session is called matter more than what the agent said.
        try reader.query("""
            SELECT s.rowid, s.id, s.agent, s.path, s.config_dir, s.cwd, s.branch,
                   coalesce(s.title, s.first_prompt, ''), s.updated,
                   bm25(session_fts, 10.0, 5.0, 1.0, 2.0, 1.5)
            FROM session_fts JOIN sessions s ON s.rowid = session_fts.rowid
            WHERE session_fts MATCH ?
            ORDER BY bm25(session_fts, 10.0, 5.0, 1.0, 2.0, 1.5)
            LIMIT 300
            """, [expression]) { row in
            let updated = row.isNull(8) ? nil : row.double(8)
            // Recent sessions get up to 60% more weight, fading over a few weeks.
            let ageDays = updated.map { max(0, now - $0) / 86400 } ?? 365
            let recency = 1 + 0.6 * exp(-ageDays / 21)
            candidates.append(Candidate(
                rowid: row.int(0),
                sessionID: row.string(1) ?? "",
                agent: SessionDocument.Agent(rawValue: row.string(2) ?? "") ?? .claude,
                path: row.string(3) ?? "",
                configDir: row.string(4),
                cwd: row.string(5),
                branch: row.string(6),
                title: Self.oneLine(row.string(7) ?? ""),
                updatedAt: updated.map { Date(timeIntervalSince1970: $0) },
                score: -row.double(9) * recency,
                isFuzzy: fuzzy))
        }
        return candidates.sorted { $0.score > $1.score }
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}

// MARK: - Query

/// A parsed search: terms (prefix-matched, typo-tolerant), "quoted phrases" (exact) and
/// -excluded terms. All terms and phrases must appear somewhere in the session.
struct SearchQuery {
    private(set) var terms: [String] = []
    private(set) var phrases: [String] = []
    private(set) var excluded: [String] = []

    var isEmpty: Bool { terms.isEmpty && phrases.isEmpty }

    init(_ text: String) {
        var rest = text
        // "quoted phrases"
        while let open = rest.firstIndex(of: "\"") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "\"") else { break }
            let words = Self.words(String(rest[afterOpen..<close]))
            if !words.isEmpty { phrases.append(words.joined(separator: " ")) }
            rest.removeSubrange(open...close)
        }
        for token in rest.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("-"), token.count > 1 {
                excluded += Self.words(String(token.dropFirst()))
            } else {
                terms += Self.words(String(token))
            }
        }
    }

    /// Splits like the FTS tokenizer: lowercase, diacritics folded, on non-alphanumerics.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The FTS5 expression. Without expansions each term is a prefix match; with them each
    /// term also accepts its typo-tolerant variants.
    func expression(expansions: [[String]]?) -> String {
        var parts: [String] = []
        for (index, term) in terms.enumerated() {
            let base = Self.prefixed(term)
            let variants = expansions?[index] ?? []
            parts.append(variants.isEmpty ? base : "(" + ([base] + variants.map(Self.quoted)).joined(separator: " OR ") + ")")
        }
        parts += phrases.map(Self.quoted)
        guard !parts.isEmpty else { return "" }
        var expression = parts.joined(separator: " AND ")
        for term in excluded { expression += " NOT " + Self.prefixed(term) }
        return expression
    }

    /// Any term matching, for picking the passage to show.
    func anyTermExpression(expansions: [[String]]) -> String {
        var parts = phrases.map(Self.quoted)
        for (index, term) in terms.enumerated() {
            parts.append(Self.prefixed(term))
            parts += expansions[index].map(Self.quoted)
        }
        return parts.joined(separator: " OR ")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Words under three letters match too much as a prefix ("am" → "amplitude"); they
    /// must match a whole word.
    private static func prefixed(_ term: String) -> String {
        term.count >= 3 ? quoted(term) + "*" : quoted(term)
    }
}

// MARK: - Typo tolerance

/// The index vocabulary, used to find words within a small edit distance of a query term.
private final class Vocabulary {
    private struct Entry {
        let term: String
        let bytes: [UInt8]
        let documents: Int
    }

    private var byLength: [Int: [Entry]] = [:]
    private var maxLength = 0

    /// A prefix found in at least this many sessions is taken as intended.
    private static let typoThreshold = 3

    init(connection: SQLiteConnection) {
        try? connection.query("SELECT term, doc FROM vocab") { row in
            guard let term = row.string(0) else { return }
            let bytes = Array(term.utf8)
            guard bytes.count >= 3, bytes.count <= 40 else { return }
            byLength[bytes.count, default: []].append(Entry(term: term, bytes: bytes, documents: Int(row.int(1))))
            maxLength = max(maxLength, bytes.count)
        }
    }

    /// Words that are probably what was meant: within one edit (two for long words, counting
    /// swapped letters as one), or — while still typing — whose beginning is one edit away.
    /// Words that already start with the term are left out; the prefix match covers them.
    func expansions(of term: String) -> [String] {
        let query = Array(term.utf8)
        guard query.count >= 4 else { return [] }
        let maxDistance = query.count >= 8 ? 2 : 1

        // Only guess at typos when what was typed is rare as a prefix. "agen" starts plenty
        // of real words (agent, agenda), so variants like "amend" would just be noise;
        // "sidbar" starts none, so it is probably a misspelling.
        var prefixDocuments = 0
        for length in stride(from: query.count, through: maxLength, by: 1) {
            for entry in byLength[length] ?? [] where entry.bytes.starts(with: query) {
                prefixDocuments += entry.documents
            }
            if prefixDocuments >= Self.typoThreshold { return [] }
        }

        var found: [(term: String, distance: Int, documents: Int)] = []
        let lower = max(3, query.count - maxDistance)
        let upper = min(maxLength, query.count + maxDistance)
        for length in stride(from: lower, through: upper, by: 1) {
            for entry in byLength[length] ?? [] where !entry.bytes.starts(with: query) {
                let distance = Self.distance(query, entry.bytes[...], limit: maxDistance)
                if distance <= maxDistance { found.append((entry.term, distance, entry.documents)) }
            }
        }

        // As-you-type: "sidba" should still find "sidebar".
        if query.count + 1 <= maxLength {
            for length in (query.count + 1)...maxLength {
                for entry in byLength[length] ?? [] where !entry.bytes.starts(with: query) {
                    let distance = Self.distance(query, entry.bytes[..<query.count], limit: 1)
                    if distance <= 1 { found.append((entry.term, distance + 1, entry.documents)) }
                }
            }
        }

        var seen: Set<String> = []
        return found
            .sorted { ($0.distance, -$0.documents) < ($1.distance, -$1.documents) }
            .filter { seen.insert($0.term).inserted }
            .prefix(12)
            .map(\.term)
    }

    /// Optimal string alignment distance (Levenshtein plus adjacent swaps), giving up as soon
    /// as it must exceed `limit`.
    private static func distance(_ a: [UInt8], _ b: ArraySlice<UInt8>, limit: Int) -> Int {
        let b = Array(b)
        let n = a.count, m = b.count
        if abs(n - m) > limit { return limit + 1 }
        guard n > 0, m > 0 else { return max(n, m) }
        var previous2 = [Int](repeating: 0, count: m + 1)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            var rowMin = current[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[m]
    }
}
