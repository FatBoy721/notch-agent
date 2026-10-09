import AppKit

/// herdr (a terminal workspace manager for agents) runs each agent in a
/// pane it can list, read and type into over its socket API. That gives the
/// notch agents it would otherwise not see (Codex, sessions started before
/// the hooks), replies that work in any terminal herdr runs in, and the
/// agent's live screen.
struct HerdrPane: Hashable, Sendable {
    let paneID: String
    /// nil for herdr's default session.
    let socket: String?
}

struct HerdrAgent: Decodable, Sendable {
    let agent: String
    let agentStatus: String
    let cwd: String?
    let paneID: String
    let terminalTitle: String?
    var agentSession: AgentSessionID?
    let tabID: String?
    /// The name of the herdr tab the agent runs in, from `herdr tab list`.
    var tabLabel: String?

    struct AgentSessionID: Decodable, Sendable {
        var value: String?
    }

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case cwd
        case paneID = "pane_id"
        case terminalTitle = "terminal_title_stripped"
        case agentSession = "agent_session"
        case tabID = "tab_id"
    }

    /// Every agent herdr recognizes (claude, codex, gemini, cursor, opencode,
    /// copilot, amp, …); plain shells report no agent.
    var kind: AgentKind? {
        agent.isEmpty || agent == "shell" || agent == "unknown" ? nil : AgentKind(id: agent)
    }
}

enum Herdr {
    static let binary: String? = {
        let candidates = [NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Sockets of every running herdr session (the default one included).
    static func runningSockets() -> [String?] {
        guard let output = run(["session", "list"], socket: nil) else { return [] }
        let defaultSocket = NSHomeDirectory() + "/.config/herdr/herdr.sock"
        return output.split(separator: "\n").dropFirst().compactMap { line -> String?? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 4, columns[1] == "running" else { return nil }
            let socket = String(columns.last!)
            return socket == defaultSocket ? .some(nil) : .some(socket)
        }
    }

    static func agents(socket: String?) -> [HerdrAgent] {
        struct Reply: Decodable {
            struct Result: Decodable { let agents: [HerdrAgent] }
            let result: Result
        }
        guard let output = run(["agent", "list"], socket: socket),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else { return [] }
        let labels = cachedTabLabels(socket: socket)
        return reply.result.agents.filter { $0.kind != nil }.map { agent in
            var agent = agent
            agent.tabLabel = agent.tabID.flatMap { labels[$0] }
            return agent
        }
    }

    /// Tab names change rarely: refreshed every 10 s rather than on every
    /// 2 s agent poll, which saves a herdr process launch each time.
    private nonisolated(unsafe) static var labelCache: [String: (labels: [String: String], at: Date)] = [:]

    private static func cachedTabLabels(socket: String?) -> [String: String] {
        let key = socket ?? ""
        if let cached = labelCache[key], Date().timeIntervalSince(cached.at) < 10 { return cached.labels }
        let labels = tabLabels(socket: socket)
        labelCache[key] = (labels, Date())
        return labels
    }

    /// Tab id → the tab's name as shown in herdr's sidebar.
    private static func tabLabels(socket: String?) -> [String: String] {
        struct Reply: Decodable {
            struct Result: Decodable { let tabs: [Tab] }
            struct Tab: Decodable { let tab_id: String; let label: String? }
            let result: Result
        }
        guard let output = run(["tab", "list"], socket: socket),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else { return [:] }
        return reply.result.tabs.reduce(into: [:]) { labels, tab in
            if let label = tab.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty { labels[tab.tab_id] = label }
        }
    }

    /// The terminal app the herdr client is running in (Metalterm, Ghostty…),
    /// found by walking up from the client process to the first app bundle.
    static func hostApplication() -> NSRunningApplication? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        do { try ps.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        var parent: [Int32: Int32] = [:]
        var clients: [Int32] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            parent[pid] = ppid
            let args = fields[2]
            if args.hasSuffix("/herdr") || args == "herdr" || args.contains("/herdr --session") { clients.append(pid) }
        }
        for client in clients {
            var pid = client
            while let next = parent[pid], next > 1 {
                if let app = NSRunningApplication(processIdentifier: next), app.bundleIdentifier != nil { return app }
                pid = next
            }
        }
        return nil
    }

    /// Opens a tab in the default herdr session without switching to it,
    /// and returns its pane.
    static func createTab(cwd: String, label: String) -> String? {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable { let pane_id: String }
                let root_pane: Pane
            }
            let result: Result
        }
        guard let output = run(["tab", "create", "--cwd", cwd, "--label", label, "--no-focus"], socket: nil),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else { return nil }
        return reply.result.root_pane.pane_id
    }

    /// Types a command and Enter into a pane's shell.
    static func runInPane(_ pane: String, command: String) -> Bool {
        run(["pane", "run", pane, command], socket: nil) != nil
    }

    static var isRunning: Bool {
        binary != nil && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/herdr/herdr.sock")
    }

    static func focus(_ pane: HerdrPane) {
        _ = run(["agent", "focus", pane.paneID], socket: pane.socket)
    }

    static func screen(of pane: HerdrPane) -> String? {
        run(["pane", "read", pane.paneID], socket: pane.socket)
    }

    static func prompt(_ text: String, to pane: HerdrPane) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard run(["agent", "prompt", pane.paneID, text], socket: pane.socket) != nil else {
                throw TerminalBridge.Failure.script("herdr couldn't reach pane \(pane.paneID)")
            }
        }.value
    }

    /// Closes the pane, ending the agent in it.
    static func closePane(_ pane: HerdrPane) -> Bool {
        run(["pane", "close", pane.paneID], socket: pane.socket) != nil
    }

    /// Runs the herdr CLI synchronously; call off the main thread.
    private static func run(_ arguments: [String], socket: String?) -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let socket { environment["HERDR_SOCKET_PATH"] = socket } else { environment.removeValue(forKey: "HERDR_SOCKET_PATH") }
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Polls herdr on a background queue and hands snapshots to the main actor.
final class HerdrMonitor: @unchecked Sendable {
    typealias Snapshot = [(pane: HerdrPane, agent: HerdrAgent)]

    private let queue = DispatchQueue(label: "notch-agent.herdr", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sockets: [String?] = []
    private var tick = 0
    /// pane id → Codex session id, re-checked every 10 s (see `CodexPanes`).
    private var codexSessions: [String: String] = [:]

    func start(onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        guard Herdr.binary != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Sessions come and go rarely; agents change all the time.
            if self.tick % 10 == 0 { self.sockets = Herdr.runningSockets() }
            self.tick += 1
            var snapshot: Snapshot = []
            for socket in self.sockets {
                for agent in Herdr.agents(socket: socket) {
                    snapshot.append((HerdrPane(paneID: agent.paneID, socket: socket), agent))
                }
            }
            if snapshot.contains(where: { $0.agent.kind == .codex }) {
                if self.tick % 5 == 1 { self.codexSessions = CodexPanes.sessions() }
                let resolved = Set(self.codexSessions.values)
                for index in snapshot.indices where snapshot[index].agent.kind == .codex {
                    if let id = self.codexSessions[snapshot[index].pane.paneID] {
                        snapshot[index].agent.agentSession = .init(value: id)
                    } else if let guess = snapshot[index].agent.agentSession?.value, resolved.contains(guess) {
                        // herdr's guess is another pane's session.
                        snapshot[index].agent.agentSession = nil
                    }
                }
            }
            onSnapshot(snapshot)
        }
        timer.resume()
        self.timer = timer
    }
}

/// Reads what a working agent's terminal shows, to pick up Claude Code's
/// live status line ("✻ Ruminating… (2m 10s · ↓ 4.1k tokens)").
enum ScreenStatus {
    struct Line: Equatable, Sendable {
        let verb: String
        let detail: String?
    }

    private static let spinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*"]

    static func parse(_ screen: String) -> Line? {
        for raw in screen.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let glyph = line.first, spinnerGlyphs.contains(glyph) else { continue }
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // Working lines end the verb with "…"; finished ones ("✻ Worked for 5s") don't.
            guard let ellipsis = rest.firstIndex(of: "…") else { continue }
            let verb = String(rest[..<ellipsis])
            guard let first = verb.first, first.isUppercase, verb.split(separator: " ").count <= 2 else { continue }
            var detail: String?
            if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
                // "2m 10s · ↓ 4.1k tokens · esc to interrupt": keep the token count.
                let parts = rest[rest.index(after: open)..<close].components(separatedBy: " · ")
                detail = parts.first { $0.contains("tokens") }
            }
            return Line(verb: verb, detail: detail)
        }
        return nil
    }

    /// Claude Code titles its terminal with a turning half-circle (◐ ◓ ◑ ◒)
    /// while it works and ✳ when it's waiting for you.
    static func busy(fromTitle title: String) -> Bool? {
        guard let glyph = title.trimmingCharacters(in: .whitespaces).first else { return nil }
        if "◐◓◑◒".contains(glyph) { return true }
        if glyph == "✳" { return false }
        return nil
    }

    /// Agent TUIs show this while they work (Claude, Codex, Gemini…).
    static func showsBusy(_ screen: String) -> Bool {
        // Terminal pads unused rows with spaces; skip those before taking the bottom.
        let bottom = screen.split(separator: "\n")
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .suffix(14).joined(separator: "\n").lowercased()
        return bottom.contains("esc to interrupt") || bottom.contains("esc to cancel")
    }

    /// Every Terminal.app tab's title, by tty, in one AppleScript call.
    static func terminalTitles() -> [String: String] {
        let script = """
        set out to ""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (tty of t) & (ASCII character 9) & (custom title of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let output = osascript(script, arguments: []) else { return [:] }
        var titles: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { titles[String(parts[0])] = String(parts[1]) }
        }
        return titles
    }

    /// The screen of a Terminal.app tab, by its tty.
    static func terminalScreen(tty: String) -> String? {
        // Indexed on purpose: inside `repeat with t in tabs`, "contents of t"
        // is AppleScript's dereference operator and returns the tab reference,
        // not the tab's text.
        let script = """
        on run argv
            tell application "Terminal"
                repeat with w from 1 to count windows
                    repeat with i from 1 to count tabs of window w
                        if tty of tab i of window w is (item 1 of argv) then return contents of tab i of window w
                    end repeat
                end repeat
            end tell
            return ""
        end run
        """
        return osascript(script, arguments: [tty])
    }

    private static func osascript(_ script: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
