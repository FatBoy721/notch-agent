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

        // An agent's folder doesn't change, so `lsof` only runs for agents
        // seen for the first time (it was every scan, every 3 s).
        let pids = Set(found.map(\.0.pid))
        cwdCache = cwdCache.filter { pids.contains($0.key) }
        let unknown = pids.subtracting(cwdCache.keys)
        if !unknown.isEmpty { cwdCache.merge(workingDirectories(of: Array(unknown))) { $1 } }
        let directories = cwdCache
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

    /// Working folder per agent pid. Only touched from the scan queue.
    private nonisolated(unsafe) static var cwdCache: [Int32: String] = [:]

    /// `lsof -d cwd` for all the agents in one call.
    static func workingDirectories(of pids: [Int32]) -> [Int32: String] {
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
         "com.github.wez.wezterm": "WezTerm", "org.alacritty": "alacritty", "net.kovidgoyal.kitty": "kitty",
         "co.zeit.hyper": "Hyper", "org.tabby": "Tabby", "com.raphaelamorim.rio": "rio", "dev.commandline.waveterm": "WaveTerm",
         "dev.zed.Zed": "zed"][bundle] ?? bundle
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
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

/// Which Codex session runs in each herdr pane. herdr guesses, and guesses
/// wrong (a resumed session's pane got the newest session from another
/// folder, which left that folder's pane with none). The Codex process
/// knows: herdr starts it with `HERDR_PANE_ID`, and it either runs
/// `resume <id>` or began a log in its folder after it started.
enum CodexPanes {
    /// herdr pane id → Codex session id.
    static func sessions() -> [String: String] {
        guard let output = ProcessScanner.run("/bin/ps", ["-axo", "pid=,ppid=,etime=,args="]) else { return [:] }
        struct Row { let pid: Int32, ppid: Int32, started: Date, args: String }
        let now = Date()
        var rows: [Int32: Row] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            rows[pid] = Row(pid: pid, ppid: ppid, started: now.addingTimeInterval(-elapsed(String(fields[2]))), args: String(fields[3]))
        }
        // Launchers only: Node's `codex` runs the native `codex` as its child.
        let launchers = rows.values.filter { isCodex($0.args) && !(rows[$0.ppid].map { isCodex($0.args) } ?? false) }
        guard !launchers.isEmpty else { return [:] }
        let panes = paneIDs(of: launchers.map(\.pid))

        var result: [String: String] = [:]
        var fresh: [Row] = []
        for row in launchers {
            guard let pane = panes[row.pid] else { continue }
            if let match = row.args.firstMatch(of: resumeID) {
                result[pane] = String(match.1)
            } else {
                fresh.append(row)
            }
        }
        guard !fresh.isEmpty else { return result }

        // Newest process first, each taking the most recently written log
        // its folder started after it did that no other pane has.
        let folders = ProcessScanner.workingDirectories(of: fresh.map(\.pid))
        let logs = recentLogs(since: fresh.map(\.started).min() ?? now)
        var claimed = Set(result.values)
        for row in fresh.sorted(by: { $0.started > $1.started }) {
            guard let pane = panes[row.pid], result[pane] == nil, let folder = folders[row.pid] else { continue }
            let pick = logs
                .filter { $0.cwd == folder && $0.created >= row.started.addingTimeInterval(-5) && !claimed.contains($0.id) }
                .max { $0.modified < $1.modified }
            if let pick {
                result[pane] = pick.id
                claimed.insert(pick.id)
            }
        }
        return result
    }

    private static let resumeID = #/\bresume\s+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/#

    /// The interactive CLI, not its background servers (`codex app-server`,
    /// `exec-server`, `mcp-server`), which inherit the pane's environment.
    private static func isCodex(_ args: String) -> Bool {
        let tokens = args.split(separator: " ")
        guard let first = tokens.first else { return false }
        let rest: ArraySlice<Substring>
        if first == "codex" || first.hasSuffix("/codex") {
            rest = tokens.dropFirst()
        } else if first == "node" || first.hasSuffix("/node"), tokens.count > 1,
                  tokens[1].hasSuffix("/codex") || tokens[1].contains("@openai/codex") {
            rest = tokens.dropFirst(2)
        } else {
            return false
        }
        return !["app-server", "exec-server", "mcp-server", "exec"].contains(rest.first ?? "")
    }

    /// `HERDR_PANE_ID` from each process's environment (ps -E shows it for
    /// the user's own processes).
    private static func paneIDs(of pids: [Int32]) -> [Int32: String] {
        guard let output = ProcessScanner.run("/bin/ps", ["-Eww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        else { return [:] }
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let pid = Int32(trimmed.prefix { $0 != " " }),
                  let match = trimmed.firstMatch(of: #/\bHERDR_PANE_ID=(\S+)/#) else { continue }
            result[pid] = String(match.1)
        }
        return result
    }

    private struct Log { let id: String, cwd: String, created: Date, modified: Date }

    /// Logs in the day folders from `since` to today
    /// (~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl).
    private static func recentLogs(since: Date) -> [Log] {
        let root = NSHomeDirectory() + "/.codex/sessions"
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: since)
        var logs: [Log] = []
        while day <= Date() {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = String(format: "%@/%04d/%02d/%02d", root, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                let path = folder + "/" + name
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let created = attributes[.creationDate] as? Date,
                      let modified = attributes[.modificationDate] as? Date,
                      let cwd = sessionFolder(path) else { continue }
                logs.append(Log(id: String(name.dropLast(".jsonl".count).suffix(36)), cwd: cwd, created: created, modified: modified))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return logs
    }

    /// The `cwd` in the log's first line (`session_meta`).
    private static func sessionFolder(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        return head.firstMatch(of: #/"cwd":"([^"]*)"/#).map { String($0.1) }
    }

    /// ps's "etime": "[[DD-]HH:]MM:SS".
    private static func elapsed(_ text: String) -> TimeInterval {
        let dayParts = text.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86_400 + clock
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
