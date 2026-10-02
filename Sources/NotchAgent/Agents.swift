import AppKit

/// Finds agent CLIs running in terminal tabs outside herdr: Codex, Gemini,
/// Cursor, OpenCode, Copilot, Amp, Aider…, and Claude Code sessions that
/// haven't sent a hook yet (idle since before the app started). herdr panes
/// are left to herdr.
///
/// Status comes from CPU use: an agent at its prompt sits near 0%, one that
/// is thinking, streaming or running tools doesn't.
struct ProcessAgent: Sendable {
    let pid: Int32
    let kind: AgentKind
    let cwd: String
    let terminal: TerminalLocation?
    /// Total CPU seconds used so far; busy-ness is its rate of change.
    let cpuTime: Double
}

enum ProcessScanner {
    /// Executable names, and the package paths Node-based CLIs run from.
    private static let executables: [String: String] = [
        "claude": "claude", "codex": "codex", "gemini": "gemini", "cursor-agent": "cursor", "opencode": "opencode", "copilot": "copilot",
        "amp": "amp", "aider": "aider", "grok": "grok", "kimi": "kimi", "droid": "droid", "cline": "cline",
    ]
    private static let packages: [String: String] = [
        "@openai/codex": "codex", "@google/gemini-cli": "gemini", "@github/copilot": "copilot",
        "@sourcegraph/amp": "amp", "opencode-ai": "opencode",
    ]
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    private struct Row {
        let pid: Int32, ppid: Int32
        let tty: String
        let cpu: Double
        let args: String
    }

    static func scan() -> [ProcessAgent] {
        guard let output = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,time=,args="]) else { return [] }
        var rows: [Int32: Row] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            rows[pid] = Row(pid: pid, ppid: ppid, tty: String(fields[2]), cpu: seconds(String(fields[3])), args: String(fields[4]))
        }

        func kind(of row: Row) -> String? {
            let tokens = row.args.split(separator: " ", maxSplits: 2)
            guard let first = tokens.first else { return nil }
            let executable = String(first.split(separator: "/").last ?? first)
            if let kind = executables[executable] { return kind }
            guard interpreters.contains(executable) || executable.hasPrefix("python"), tokens.count > 1 else { return nil }
            let script = String(tokens[1])
            if let kind = packages.first(where: { script.contains($0.key) })?.value { return kind }
            return executables[String(script.split(separator: "/").last ?? "")]
        }

        func ancestors(of pid: Int32) -> [Row] {
            var chain: [Row] = []
            var current = rows[pid]?.ppid
            while let next = current, next > 1, let row = rows[next], chain.count < 40 {
                chain.append(row)
                current = row.ppid
            }
            return chain
        }

        var found: [(Row, String)] = []
        for row in rows.values where row.tty.hasPrefix("ttys") {
            guard let agentKind = kind(of: row) else { continue }
            let chain = ancestors(of: row.pid)
            // One entry per agent: skip its own child processes, and anything
            // running under herdr, which reports those itself.
            if chain.contains(where: { kind(of: $0) == agentKind }) { continue }
            if chain.contains(where: { ($0.args.split(separator: " ").first ?? "").hasSuffix("herdr") }) { continue }
            found.append((row, agentKind))
        }
        guard !found.isEmpty else { return [] }

        // The work often happens in child processes (Codex's Node launcher
        // runs a native binary), so count CPU across the whole tree.
        var children: [Int32: [Int32]] = [:]
        for row in rows.values { children[row.ppid, default: []].append(row.pid) }
        func treeCPU(_ pid: Int32, depth: Int = 0) -> Double {
            guard depth < 20 else { return 0 }
            return (rows[pid]?.cpu ?? 0) + (children[pid] ?? []).reduce(0) { $0 + treeCPU($1, depth: depth + 1) }
        }

        let directories = workingDirectories(of: found.map(\.0.pid))
        return found.map { row, kind in
            let host = ancestors(of: row.pid).lazy.compactMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }.first
            return ProcessAgent(pid: row.pid, kind: AgentKind(id: kind), cwd: directories[row.pid] ?? "",
                                terminal: TerminalLocation(tty: row.tty, program: host.flatMap(program(forBundle:))),
                                cpuTime: treeCPU(row.pid))
        }
    }

    /// ps's "time" column: "M:SS.ss" or "H:MM:SS".
    private static func seconds(_ text: String) -> Double {
        text.replacingOccurrences(of: ",", with: ".").split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// `lsof -d cwd` for all the agents in one call.
    private static func workingDirectories(of pids: [Int32]) -> [Int32: String] {
        guard let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]) else { return [:] }
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            if line.hasPrefix("n"), let pid = current { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    /// The TERM_PROGRAM a terminal app sets, from its bundle id.
    private static func program(forBundle bundle: String) -> String? {
        ["com.apple.Terminal": "Apple_Terminal", "com.googlecode.iterm2": "iTerm.app", "dev.metalterm.Metalterm": "metalterm",
         "com.mitchellh.ghostty": "ghostty", "com.microsoft.VSCode": "vscode", "dev.warp.Warp-Stable": "WarpTerminal",
         "com.github.wez.wezterm": "WezTerm"][bundle] ?? bundle
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Scans every three seconds on a background queue and works out which
/// agents are busy from the CPU time each used since the last scan.
final class ProcessMonitor: @unchecked Sendable {
    typealias Reading = (agent: ProcessAgent, busy: Bool)

    private let queue = DispatchQueue(label: "notch-agent.processes", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previous: [Int32: (cpu: Double, at: Date)] = [:]

    func start(onScan: @escaping @Sendable ([Reading]) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let agents = ProcessScanner.scan()
            let readings = agents.map { agent -> Reading in
                guard let last = self.previous[agent.pid] else { return (agent, false) }
                let share = (agent.cpuTime - last.cpu) / max(0.5, now.timeIntervalSince(last.at))
                // Agents waiting on the network barely use CPU; this is only the
                // fallback for terminals whose screen can't be read.
                return (agent, share > 0.012)
            }
            self.previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.pid, ($0.cpuTime, now)) })
            onScan(readings)
        }
        timer.resume()
        self.timer = timer
    }
}
