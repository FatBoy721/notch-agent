import AppKit

/// What a thread's menu hands out: a summary of its run, the agent's own
/// log file, and the diff of the files it changed (GlassCode's "Copy run
/// summary", "Open Transcript JSONL" and "Copy unified diff").
enum ThreadTools {
    /// Plain text, ready to paste into a note or a chat.
    static func summary(of session: AgentSession) -> String {
        var parts = [session.title, [session.project, session.modelName ?? session.agent].joined(separator: " · ")]
        if let prompt = session.prompt, prompt != session.title { parts.append("Asked: \(prompt)") }
        let files = session.changedFiles
        if !files.isEmpty {
            let names = files.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            parts.append("Changed \(files.count) file\(files.count == 1 ? "" : "s"): \(names)\(files.count > 8 ? ", …" : "")")
        }
        var counts: [String: Int] = [:]
        for item in session.feed where item.kind == .tool { counts[item.tool ?? "Tool", default: 0] += 1 }
        let tools = counts.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }
        if !tools.isEmpty { parts.append("Tools: " + tools.joined(separator: ", ")) }
        if let reply = session.lastReply { parts.append("Reply:\n\(reply)") }
        return parts.joined(separator: "\n\n")
    }

    /// The agent's log: Claude's transcript or Codex's session log. Hermes
    /// keeps its chats on the server, so there's none here.
    static func transcript(of session: AgentSession) -> String? {
        let id = session.agentSessionID ?? session.id
        switch session.kind {
        case .claude: return Transcript.find(sessionID: id, cwd: session.cwd)
        case .codex: return AgentLog.codexLog(sessionID: id)
        default: return nil
        }
    }

    enum DiffFailure: LocalizedError {
        case notARepo(String), noChanges

        var errorDescription: String? {
            switch self {
            case .notARepo(let project): "\(project) isn't a git repository, so there's no diff to copy."
            case .noChanges: "No uncommitted changes in those files."
            }
        }
    }

    /// The unified diff, against the last commit, of the files the agent
    /// changed (new files included). Agents only herdr sees report no
    /// tool calls, so for them it's every uncommitted change in the repo.
    static func diff(of session: AgentSession) throws -> (text: String, files: Int) {
        guard let root = git(["rev-parse", "--show-toplevel"], in: session.cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty else {
            throw DiffFailure.notARepo(session.project)
        }
        let touched = session.changedFiles.filter { $0.hasPrefix(root + "/") }
        let scope = touched.isEmpty ? [] : ["--"] + touched
        // A repo with no commits yet has no HEAD to compare against.
        let tracked = git(["diff", "HEAD"] + scope, in: root) ?? git(["diff"] + scope, in: root) ?? ""
        let untracked = (git(["ls-files", "--others", "--exclude-standard", "--full-name"] + scope, in: root) ?? "")
            .split(separator: "\n").map(String.init)
        // `diff --no-index` exits 1 when the files differ, which they always do.
        let added = untracked.compactMap { git(["diff", "--no-index", "--", "/dev/null", $0], in: root, allowFailure: true) }
        let text = ([tracked] + added).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { throw DiffFailure.noChanges }
        let files = text.components(separatedBy: "\n").filter { $0.hasPrefix("diff --git ") }.count
        return (text, files)
    }

    private static func git(_ arguments: [String], in directory: String, allowFailure: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || allowFailure else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
