import Foundation

/// Reads the latest exchange straight from an agent's log, for sessions
/// whose hooks don't run (herdr panes started before the hooks, or Codex
/// before its hooks are trusted).
enum AgentLog {
    static func lastExchange(kind: AgentKind, sessionID: String, cwd: String) -> (prompt: String?, reply: String?) {
        switch kind {
        case .claude: claude(path: Transcript.path(sessionID: sessionID, cwd: cwd))
        case .codex: codexLog(sessionID: sessionID).map(codex) ?? (nil, nil)
        default: (nil, nil)
        }
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
    private static func codexLog(sessionID: String) -> String? {
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

    /// The newest prompt the user typed, searching from the end of the file.
    /// Transcripts can be large (screenshots are stored inline), so the file
    /// is memory-mapped rather than read.
    static func summary(at path: String) -> (prompt: (text: String, date: Date?)?, model: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return (nil, nil) }
        let userMarker = Data(#""type":"user""#.utf8)
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var prompt: (text: String, date: Date?)?
        var model: String?
        for line in data.split(separator: 0x0A).reversed() {
            if model == nil, line.range(of: assistantMarker) != nil,
               let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let message = entry["message"] as? [String: Any],
               let id = message["model"] as? String, id.hasPrefix("claude") {
                model = id
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
        return (prompt, model)
    }
}
