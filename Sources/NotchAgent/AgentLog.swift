import Foundation

/// Reads the latest exchange straight from an agent's log, for sessions
/// whose hooks don't run (herdr panes started before the hooks, or Codex
/// before its hooks are trusted).
enum AgentLog {
    /// Also when the log was last written: for a session already waiting
    /// when the notch started, about when it began to wait.
    static func lastExchange(kind: AgentKind, sessionID: String, cwd: String)
        -> (prompt: String?, reply: String?, activity: Date?, context: Context?) {
        let file: String?
        switch kind {
        case .claude: file = Transcript.find(sessionID: sessionID, cwd: cwd)
        case .codex: file = codexLog(sessionID: sessionID)
        default: file = nil
        }
        guard let file else { return (nil, nil, nil, nil) }
        let (prompt, reply) = kind == .codex ? codex(path: file) : claude(path: file)
        let activity = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        return (prompt, reply, activity, context(kind: kind, path: file))
    }

    /// How full an agent's context window is: tokens in it, and the window
    /// when the log says (Codex does; Claude's is inferred from the model).
    struct Context: Sendable {
        let tokens: Int
        let window: Int?
        /// The model in use; for Claude it decides the window.
        var model: String?
    }

    static func context(kind: AgentKind, path: String) -> Context? {
        if kind == .codex { return codexContext(path: path) }
        let summary = Transcript.summary(at: path)
        return summary.context.map { Context(tokens: $0, window: nil, model: summary.model) }
    }

    /// Codex's newest `token_count` event (the last request's
    /// `total_tokens` and `model_context_window`), and the model from the
    /// newest `turn_context`.
    /// Compacted since then: Codex logs no count until its next turn, so the
    /// kept history's size stands in (about 4 bytes a token).
    private static func codexContext(path: String) -> Context? {
        let countMarker = Data(#""token_count""#.utf8)
        let compactedMarker = Data(#""type":"compacted""#.utf8)
        let turnMarker = Data(#""type":"turn_context""#.utf8)
        var compacted: Int?
        var found: (tokens: Int, window: Int?)?
        var model: String?
        for line in lines(path) {
            if found == nil, compacted == nil, line.range(of: compactedMarker) != nil {
                compacted = line.count / 4
            } else if found == nil, line.range(of: countMarker) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = entry["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] {
                let total = (last["total_tokens"] as? Int)
                    ?? ((last["input_tokens"] as? Int) ?? 0) + ((last["output_tokens"] as? Int) ?? 0)
                found = (compacted ?? total, info["model_context_window"] as? Int)
            } else if model == nil, line.range(of: turnMarker) != nil,
                      let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = entry["payload"] as? [String: Any] {
                model = payload["model"] as? String
            }
            if found != nil && model != nil { break }
        }
        guard let tokens = found?.tokens ?? compacted else { return nil }
        return Context(tokens: tokens, window: found?.window, model: model)
    }

    private static func lines(_ path: String) -> [Data] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return [] }
        return data.split(separator: 0x0A).reversed()
    }

    private static func claude(path: String) -> (prompt: String?, reply: String?) {
        var prompt: String?, reply: String?
        for line in lines(path) {
            guard prompt == nil || reply == nil,
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            if reply == nil, entry["type"] as? String == "assistant", let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { reply = text }
            }
            if prompt == nil, entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
               let text = message["content"] as? String, !text.hasPrefix("<") {
                prompt = text
                break  // the prompt comes before its reply, so we're done
            }
        }
        return (prompt, reply)
    }

    private static func codex(path: String) -> (prompt: String?, reply: String?) {
        var prompt: String?, reply: String?
        for line in lines(path) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any] else { continue }
            if reply == nil, payload["type"] as? String == "task_complete", let text = payload["last_agent_message"] as? String {
                reply = text
            }
            if prompt == nil, entry["type"] as? String == "response_item", payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !text.hasPrefix("<") { prompt = text; break }
            }
        }
        return (prompt, reply)
    }

    /// ~/.codex/sessions/YYYY/MM/DD/rollout-…-<session id>.jsonl
    static func codexLog(sessionID: String) -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent.hasSuffix("\(sessionID).jsonl") { return url.path }
        return nil
    }
}

enum Transcript {
    /// Where Claude Code keeps a session's transcript: the project folder is
    /// the working directory with every non-alphanumeric character as "-".
    static func path(sessionID: String, cwd: String) -> String {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NSHomeDirectory() + "/.claude/projects/\(folder)/\(sessionID).jsonl"
    }

    /// The transcript if it exists: where `path` says, or in any project
    /// folder (the session may have started in another directory).
    static func find(sessionID: String, cwd: String) -> String? {
        let expected = path(sessionID: sessionID, cwd: cwd)
        if FileManager.default.fileExists(atPath: expected) { return expected }
        let projects = NSHomeDirectory() + "/.claude/projects"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return folders.lazy.map { "\(projects)/\($0)/\(sessionID).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The newest prompt the user typed, searching from the end of the file.
    /// Transcripts can be large (screenshots are stored inline), so the file
    /// is memory-mapped rather than read.
    /// Also how full the context window is: the newest assistant message's
    /// input (fresh, cache write and cache read) plus its output, which is
    /// what the next request starts from. A `/compact` since then resets it
    /// to the size Claude Code logged for the compacted conversation.
    static func summary(at path: String) -> (prompt: (text: String, date: Date?)?, model: String?, context: Int?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return (nil, nil, nil) }
        let userMarker = Data(#""type":"user""#.utf8)
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let boundaryMarker = Data(#""subtype":"compact_boundary""#.utf8)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var prompt: (text: String, date: Date?)?
        var model: String?
        var context: Int?
        for line in data.split(separator: 0x0A).reversed() {
            if model == nil, context == nil, line.range(of: boundaryMarker) != nil,
               let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                let metadata = entry["compactMetadata"] as? [String: Any]
                context = (metadata?["postTokens"] as? Int) ?? 0
            }
            if model == nil, line.range(of: assistantMarker) != nil,
               let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let message = entry["message"] as? [String: Any],
               let id = message["model"] as? String, id.hasPrefix("claude") {
                model = id
                if context == nil, let usage = message["usage"] as? [String: Any] {
                    context = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                        .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                }
            }
            if prompt == nil, line.range(of: userMarker) != nil,
               let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
               let message = entry["message"] as? [String: Any],
               let text = message["content"] as? String, // tool results are arrays
               !text.hasPrefix("<") {                    // command/system wrappers
                prompt = (text, (entry["timestamp"] as? String).flatMap(parser.date(from:)))
            }
            if prompt != nil && model != nil { break }
        }
        return (prompt, model, context)
    }
}
