import AppKit
import Network

/// Claude Code hooks reach the app through a tiny loopback HTTP server.
/// Each hook is a `curl` command that POSTs the hook's JSON input here and
/// prints whatever we answer, which Claude Code then reads as the hook output.
enum HookBridge {
    static let port: UInt16 = 47823
    /// Custom header the hook command sends. Browsers can't add it to a
    /// cross-origin request without a CORS preflight we never answer, so a
    /// web page can't inject fake approvals.
    static let header = "x-notch-agent"
}

// MARK: - Payload

enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

struct HookPayload: Decodable, Sendable {
    let sessionID: String
    let event: String
    let cwd: String?
    let transcriptPath: String?
    let toolName: String?
    let toolInput: [String: JSONValue]?
    let toolUseID: String?
    let toolResponse: JSONValue?
    let prompt: String?
    let message: String?
    let source: String?
    /// SessionStart only.
    let model: String?
    let sessionTitle: String?
    /// Stop only: Claude's reply for the turn that just ended.
    let lastAssistantMessage: String?
    /// Not part of the hook JSON: filled in from the request headers.
    var terminal: TerminalLocation?
    var agent: AgentKind = .claude
    var herdr: HerdrPane?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case event = "hook_event_name"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case toolResponse = "tool_response"
        case prompt, message, source, model
        case sessionTitle = "session_title"
        case lastAssistantMessage = "last_assistant_message"
    }
}

// MARK: - Reply

/// One pending HTTP exchange. Answering it ends the hook's `curl`, so for a
/// PermissionRequest the hook stays blocked until `send` is called.
final class HookReply: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var finished = false
    private var hangUpHandler: (@Sendable () -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// An empty body means "no opinion": Claude Code carries on as if the hook weren't there.
    func send(_ body: Data = Data()) {
        guard markFinished() else { return }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    /// Calls `handler` if the hook goes away before we answer: the user hit
    /// Esc, answered in the terminal, or the hook timed out.
    func onHangUp(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { hangUpHandler = handler }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self, isComplete || error != nil, self.markFinished() else { return }
            self.connection.cancel()
            self.lock.withLock { self.hangUpHandler }?()
        }
    }

    private func markFinished() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }
}

// MARK: - Server

final class HookServer: @unchecked Sendable {
    typealias Handler = @Sendable (HookPayload, HookReply) -> Void

    private let queue = DispatchQueue(label: "notch-agent.hooks")
    private let handler: Handler
    private var listener: NWListener?
    /// `GET /debug` answers with this: a JSON snapshot of the notch's state,
    /// for checking the app from scripts. Loopback only, read-only.
    var debugSnapshot: (@Sendable () -> Data)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: HookBridge.port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                self?.dispatch(request, on: connection)
            } else if isComplete || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                self?.read(connection, buffer: buffer)
            }
        }
    }

    private func dispatch(_ request: Request, on connection: NWConnection) {
        let reply = HookReply(connection: connection)
        if request.line.hasPrefix("GET /debug"), let debugSnapshot {
            reply.send(debugSnapshot())
            return
        }
        guard request.headers[HookBridge.header] != nil else {
            reply.send()
            return
        }
        var payload: HookPayload
        do {
            payload = try JSONDecoder().decode(HookPayload.self, from: request.body)
        } catch {
            EventLog.write("undecodable hook (\(request.headers["x-agent"] ?? "claude")): \(error) · \(String(decoding: request.body.prefix(300), as: UTF8.self))")
            reply.send()
            return
        }
        payload.terminal = TerminalLocation(tty: request.headers["x-tty"], program: request.headers["x-term"])
        if let agent = request.headers["x-agent"], !agent.isEmpty { payload.agent = AgentKind(id: agent) }
        if let pane = request.headers["x-herdr-pane"], !pane.isEmpty {
            let socket = request.headers["x-herdr-socket"].flatMap { $0.isEmpty ? nil : $0 }
            payload.herdr = HerdrPane(paneID: pane, socket: socket == NSHomeDirectory() + "/.config/herdr/herdr.sock" ? nil : socket)
        }
        // Only permission requests wait on the user; everything else is
        // answered at once so the agent never stalls on us.
        if payload.event != "PermissionRequest" { reply.send() }
        handler(payload, reply)
    }
}

/// Just enough HTTP/1.1 to read a POST with a Content-Length body.
private struct Request {
    let line: String
    let headers: [String: String]
    let body: Data

    init?(_ buffer: Data) {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var headers: [String: String] = [:]
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        self.line = lines.first ?? ""
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}

// MARK: - Installer

/// Adds or removes our hooks in ~/.claude/settings.json. Runs through
/// python3 so the user's file keeps its key order; a backup is written first.
enum HookInstaller {
    static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    /// Codex reads hooks in the same format; it asks you once to trust new
    /// ones (Codex's own safety check), then runs them.
    static let codexHooksPath = NSHomeDirectory() + "/.codex/hooks.json"
    private static let codexConfigPath = NSHomeDirectory() + "/.codex/config.toml"
    private static let marker = "# notch-agent"

    static var isInstalled: Bool {
        (try? String(contentsOfFile: settingsPath, encoding: .utf8))?.contains(marker) ?? false
    }

    private static var codexPresent: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex")
    }

    static func install() throws {
        try run("install", path: settingsPath, agent: "claude")
        if codexPresent {
            try run("install", path: codexHooksPath, agent: "codex")
            enableCodexHooks()
        }
    }

    static func uninstall() throws {
        try run("uninstall", path: settingsPath, agent: "claude")
        if FileManager.default.fileExists(atPath: codexHooksPath) { try run("uninstall", path: codexHooksPath, agent: "codex") }
    }

    /// Hooks are behind `[features] hooks = true` in Codex's config.
    private static func enableCodexHooks() {
        var text = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        guard let section = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) else {
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "\n[features]\nhooks = true\n"
            try? text.write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
            return
        }
        let sectionEnd = lines[(section + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
        if lines[(section + 1)..<sectionEnd].contains(where: { $0.replacingOccurrences(of: " ", with: "").hasPrefix("hooks=") }) { return }
        var updated = lines
        updated.insert("hooks = true", at: section + 1)
        try? updated.joined(separator: "\n").write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
    }

    private static func run(_ action: String, path: String, agent: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, action, path, String(HookBridge.port), marker, agent]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "HookInstaller", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "python3 failed" : message])
        }
    }

    private static let script = #"""
import json, os, shutil, sys

action, path, port, marker, agent = sys.argv[1:6]
events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PermissionRequest", "Notification", "Stop", "SessionEnd"]
if agent == "codex":
    # The events Codex fires; its hook groups take no matcher.
    events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
              "PermissionRequest", "Stop", "SessionEnd"]

data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
    shutil.copy(path, path + ".notch-agent.bak")

hooks = data.setdefault("hooks", {})
for event in list(hooks):
    groups = []
    for group in hooks[event]:
        kept = [h for h in group.get("hooks", []) if marker not in h.get("command", "")]
        if kept:
            group["hooks"] = kept
            groups.append(group)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]

if action == "install":
    for event in events:
        waits = event == "PermissionRequest"
        # X-TTY is the agent's terminal (the hook's parent process) so the
        # notch can type replies into the right tab.
        command = (f"curl -sf -m {590 if waits else 2} -X POST -H 'Content-Type: application/json' "
                   f"-H 'Expect:' -H 'X-Notch-Agent: 1' -H 'X-Agent: {agent}' "
                   f"-H \"X-TTY: $(ps -o tty= -p $PPID 2>/dev/null)\" -H \"X-Term: $TERM_PROGRAM\" "
                   f"-H \"X-Herdr-Pane: $HERDR_PANE_ID\" -H \"X-Herdr-Socket: $HERDR_SOCKET_PATH\" --data-binary @- "
                   f"http://127.0.0.1:{port}/hook 2>/dev/null || true {marker}")
        group = {"hooks": [{"type": "command", "command": command, "timeout": 600 if waits else 5}]}
        if agent == "claude":
            group = {"matcher": "*", **group}
        hooks.setdefault(event, []).append(group)

if not hooks:
    del data["hooks"]

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
"""#
}

// MARK: - Replies

/// The terminal tab an agent runs in, as reported by its hooks.
struct TerminalLocation: Equatable, Sendable {
    enum App: Equatable, Sendable {
        case terminal, iTerm, other(String)
    }

    let ttyPath: String
    let app: App

    init?(tty: String?, program: String?) {
        guard let tty = tty?.trimmingCharacters(in: .whitespaces), tty.hasPrefix("ttys") else { return nil }
        ttyPath = "/dev/" + tty
        switch program {
        case "Apple_Terminal": app = .terminal
        case "iTerm.app": app = .iTerm
        default: app = .other(program?.isEmpty == false ? program! : "this terminal")
        }
    }

    var canReply: Bool {
        if case .other = app { return false }
        return true
    }

    /// The app to bring forward to show this terminal.
    var bundleIdentifier: String? {
        switch app {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .other(let program):
            ["metalterm": "dev.metalterm.Metalterm", "Metalterm": "dev.metalterm.Metalterm", "ghostty": "com.mitchellh.ghostty",
             "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable", "WezTerm": "com.github.wez.wezterm"][program]
        }
    }

    var displayName: String {
        switch app {
        case .terminal: return "Terminal"
        case .iTerm: return "iTerm2"
        case .other(let program):
            let known = ["ghostty": "Ghostty", "vscode": "VS Code", "WarpTerminal": "Warp", "WezTerm": "WezTerm",
                         "metalterm": "Metalterm", "Metalterm": "Metalterm", "tmux": "tmux", "zed": "Zed"]
            return known[program] ?? program
        }
    }
}

/// Types a reply into the agent's own terminal tab via AppleScript, so the
/// running session receives it exactly as if the user had typed it there.
enum TerminalBridge {
    enum Failure: LocalizedError {
        case unsupported(String), tabNotFound, script(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let app): "Replies from the notch work in Terminal, iTerm2 and herdr panes, not \(app)."
            case .tabNotFound: "Couldn't find the agent's terminal tab. Was it closed?"
            case .script(let message): "The terminal refused the reply: \(message)"
            }
        }
    }

    /// Brings the agent's terminal forward: its herdr pane first, then the
    /// app, and in Terminal the exact tab.
    static func focus(_ location: TerminalLocation?, herdr: HerdrPane?) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let herdr { Herdr.focus(herdr) }
            if let location, location.app == .terminal, herdr == nil {
                let script = """
                on run argv
                    tell application "Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is (item 1 of argv) then
                                    set selected of t to true
                                    set index of w to 1
                                end if
                            end repeat
                        end repeat
                        activate
                    end tell
                end run
                """
                _ = try? osascriptSync(script, arguments: [location.ttyPath])
                return
            }
            if herdr != nil, let host = Herdr.hostApplication() {
                host.activate()
                return
            }
            guard let bundle = location?.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func osascriptSync(_ script: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// The reply goes in as a bracketed paste: agent TUIs (Claude Code,
    /// Codex) otherwise guess where a burst of typed text ends and swallow a
    /// Return that comes too soon. With explicit paste markers the newline
    /// `do script` / `write text` adds afterwards submits right away.
    static func send(_ text: String, to location: TerminalLocation) async throws {
        let script: String
        switch location.app {
        case .terminal: script = terminalScript
        case .iTerm: script = iTermScript
        case .other(let name): throw Failure.unsupported(name)
        }
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
        let output = try await osascript(script, arguments: [location.ttyPath, line])
        guard output == "ok" else { throw Failure.tabNotFound }
    }

    private static func osascript(_ script: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script] + arguments
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: Failure.script(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    private static let terminalScript = """
    on run argv
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is (item 1 of argv) then
                        set esc to (ASCII character 27)
                        do script (esc & "[200~" & (item 2 of argv) & esc & "[201~") in t
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """

    private static let iTermScript = """
    on run argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is (item 1 of argv) then
                            set esc to (ASCII character 27)
                            tell s to write text (esc & "[200~" & (item 2 of argv) & esc & "[201~")
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """
}
