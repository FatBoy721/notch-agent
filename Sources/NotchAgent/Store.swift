import AppKit

enum SessionStatus {
    case working, waiting, idle, ended
}

struct FeedItem: Identifiable {
    enum Kind { case prompt, tool, notice, finished }

    let id = UUID()
    let time = Date()
    let kind: Kind
    var tool: String? = nil
    let title: String
    var detail: String? = nil
    var toolUseID: String? = nil
    var isDone = false
    var failed = false
    /// What the tool produced, briefly: "188 lines", "+14 −3".
    var result: String? = nil
}

struct AgentSession: Identifiable {
    let id: String
    var kind: AgentKind = .claude
    var cwd: String
    var terminal: TerminalLocation?
    var herdr: HerdrPane?
    /// Seen through Claude Code hooks. Sessions known only from herdr take
    /// their status from herdr instead.
    var fromHooks = true
    var terminalTitle: String?
    /// Claude Code's thinking verb for this turn, and the live status line
    /// read off its terminal when available.
    var verb = ThinkingVerbs.random()
    var screenLine: ScreenStatus.Line?
    /// The agent's reply at the end of its last turn.
    var lastReply: String?
    /// The agent's own session id (herdr reports it), for finding its log.
    var agentSessionID: String?
    /// The model id, e.g. "claude-opus-5-5".
    var model: String?
    var lastHookAt = Date()
    /// Consecutive terminal readings that disagree with `status`.
    var disagreements = 0
    var status: SessionStatus = .idle
    var feed: [FeedItem] = []
    var updatedAt = Date()
    /// The latest prompt, which names the thread.
    var prompt: String?
    var turnStartedAt: Date?
    var finishedAt: Date?

    var project: String {
        cwd.isEmpty ? "Session" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    var agent: String { kind.name }

    var title: String {
        prompt ?? terminalTitle ?? (fromHooks ? "New session in \(project)" : "\(agent) in \(project)")
    }

    var activity: Activity {
        if let tool = runningTool { return .tool(tool.tool ?? "Tool") }
        // Only Claude has a thinking verb; other agents are just "Working".
        guard kind == .claude else { return .thinking(kind, verb: "Working", detail: nil) }
        return .thinking(kind, verb: screenLine?.verb ?? verb, detail: screenLine?.detail)
    }

    var modelName: String? {
        model.map { $0.hasPrefix("claude") ? UsageReport.modelName($0) : CodexModels.displayName($0) }
    }

    enum ReplyRoute { case herdr, terminal, clipboard, none }

    /// How a reply reaches the agent: typed by herdr or Terminal/iTerm2, or
    /// for terminals that can't be scripted (Metalterm, Ghostty…), copied
    /// for the user to paste.
    var replyRoute: ReplyRoute {
        if status == .ended { return .none }
        if herdr != nil { return .herdr }
        guard let terminal else { return .none }
        return terminal.canReply ? .terminal : .clipboard
    }

    var canReply: Bool { replyRoute != .none }

    var terminalName: String {
        let app = terminal?.displayName
        if herdr != nil { return app.map { "herdr · \($0)" } ?? "herdr" }
        return app ?? "terminal"
    }

    var lastTool: FeedItem? { feed.last { $0.kind == .tool } }

    var runningTool: FeedItem? {
        guard let tool = lastTool, !tool.isDone else { return nil }
        return tool
    }

    /// Tool calls since the latest prompt.
    var turnTools: [FeedItem] {
        let start = feed.lastIndex { $0.kind == .prompt } ?? -1
        return feed[(start + 1)...].filter { $0.kind == .tool }
    }

    var isBusy: Bool { status == .working || status == .waiting }
}

/// What the closed notch says about the agents.
enum TabStatus: Hashable {
    case quiet
    case running(kind: AgentKind, project: String, activity: Activity)
    case needsYou(kind: AgentKind, project: String)
    case done
    case many([AgentKind])
}

enum Decision {
    case allow, deny, terminal

    /// Hook output for a PermissionRequest. `.terminal` answers with nothing,
    /// which hands the decision back to the agent's own prompt.
    var responseBody: Data {
        let decision: [String: Any]
        switch self {
        case .terminal: return Data()
        case .allow: decision = ["behavior": "allow"]
        case .deny: decision = ["behavior": "deny", "message": "Denied from the notch."]
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }
}

struct Approval: Identifiable {
    let id = UUID()
    let sessionID: String
    let tool: String
    let summary: String
    let detail: String?
    let reply: HookReply
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var approvals: [Approval] = []
    @Published var selectedID: String?
    @Published private(set) var hooksInstalled = HookInstaller.isInstalled
    @Published var problem: String?
    /// A passing, non-error message ("Copied, paste with ⌘V").
    @Published private(set) var notice: String?
    /// Unsent replies, per session, so collapsing the notch doesn't lose them.
    @Published var drafts: [String: String] = [:]
    /// Files and screenshots waiting to go with each session's next reply.
    @Published var replyAttachments: [String: [Attachment]] = [:]
    @Published private(set) var sendingReply = false
    /// A session that just finished, shown as "Done" in the closed notch for a moment.
    @Published private(set) var justFinished: String?
    /// A finished turn to drop the notch down for (the card with the reply).
    @Published private(set) var drop: Drop?

    struct Drop: Identifiable, Equatable {
        let id = UUID()
        let sessionID: String
        /// Others that finished while this card was still down (e.g. while
        /// you were away), most recent first.
        var others: [String] = []
    }

    static let dropOnFinishKey = "dropOnFinish"

    func dismissDrop() { drop = nil }

    private static let feedLimit = 200
    private static let endedSessionLifetime: TimeInterval = 10 * 60

    /// Working and waiting-on-you first, then idle, then ended; most
    /// recently active first within each.
    var orderedSessions: [AgentSession] {
        func rank(_ session: AgentSession) -> Int {
            switch session.status {
            case .working: 0
            case .waiting: session.fromHooks ? 0 : 1
            case .idle: 2
            case .ended: 3
            }
        }
        return sessions.sorted { (rank($0), $1.updatedAt) < (rank($1), $0.updatedAt) }
    }

    var selected: AgentSession? {
        sessions.first { $0.id == selectedID } ?? orderedSessions.first
    }

    var overallStatus: SessionStatus {
        if !approvals.isEmpty { return .waiting }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return sessions.contains(where: { $0.status != .ended }) ? .idle : .ended
    }

    var tabStatus: TabStatus {
        if let approval = approvals.first {
            let session = session(approval.sessionID)
            return .needsYou(kind: session?.kind ?? .claude, project: session?.project ?? "Agent")
        }
        if justFinished != nil { return .done }
        // A herdr-only agent "blocked" may have been waiting for days; only
        // hook-driven waits (with a real approval) count as busy here.
        let busy = sessions.filter { $0.status == .working || ($0.status == .waiting && $0.fromHooks) }
        if busy.count > 1 { return .many(busy.map(\.kind)) }
        if let session = busy.first {
            return .running(kind: session.kind, project: session.project, activity: session.activity)
        }
        return .quiet
    }

    func session(_ id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    // MARK: Hook events

    func handle(_ payload: HookPayload, reply: HookReply) {
        pruneEndedSessions()
        let index = sessionIndex(for: payload)
        sessions[index].updatedAt = Date()
        sessions[index].lastHookAt = Date()
        sessions[index].disagreements = 0

        if ["UserPromptSubmit", "Stop", "PermissionRequest", "SessionStart", "SessionEnd"].contains(payload.event) {
            EventLog.write("hook \(payload.event) from \(payload.sessionID.prefix(8)) (\(URL(fileURLWithPath: payload.cwd ?? "?").lastPathComponent))")
        }
        switch payload.event {
        case "SessionStart":
            sessions[index].status = .idle
            if let model = payload.model { sessions[index].model = model }
            if let title = payload.sessionTitle, !title.isEmpty { sessions[index].terminalTitle = title }
            append(FeedItem(kind: .notice, title: "Session started", detail: payload.source), at: index)
        case "UserPromptSubmit":
            settleApprovals(for: payload.sessionID)
            finishRunningTools(at: index)
            sessions[index].status = .working
            sessions[index].prompt = payload.prompt
            sessions[index].lastReply = nil
            sessions[index].verb = ThinkingVerbs.random()
            sessions[index].screenLine = nil
            sessions[index].turnStartedAt = Date()
            sessions[index].finishedAt = nil
            append(FeedItem(kind: .prompt, title: payload.prompt ?? ""), at: index)
        case "PreToolUse":
            let tool = payload.toolName ?? "Tool"
            let (summary, detail) = ToolSummary.describe(tool, payload.toolInput)
            sessions[index].status = .working
            append(FeedItem(kind: .tool, tool: tool, title: summary, detail: detail, toolUseID: payload.toolUseID), at: index)
        case "PostToolUse", "PostToolUseFailure":
            settleApprovals(for: payload.sessionID)
            sessions[index].status = .working
            markToolDone(payload, failed: payload.event == "PostToolUseFailure", at: index)
        case "PermissionRequest":
            enqueueApproval(payload, reply: reply)
            sessions[index].status = .waiting
        case "Notification":
            // Permission notices duplicate the approval card.
            if let message = payload.message, !message.hasPrefix("Claude needs your permission") {
                append(FeedItem(kind: .notice, title: message), at: index)
            }
        case "Stop":
            settleApprovals(for: payload.sessionID)
            if let reply = payload.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
                sessions[index].lastReply = reply
            }
            markStopped(at: index)
            append(FeedItem(kind: .finished, title: "Finished"), at: index)
            if let path = payload.transcriptPath { readTranscript(for: payload.sessionID, at: path) }
        case "SessionEnd":
            settleApprovals(for: payload.sessionID)
            sessions[index].status = .ended
        default:
            break
        }
    }

    private func sessionIndex(for payload: HookPayload) -> Int {
        if let index = sessions.firstIndex(where: { $0.id == payload.sessionID }) {
            if let cwd = payload.cwd { sessions[index].cwd = cwd }
            if let terminal = payload.terminal { sessions[index].terminal = terminal }
            if let herdr = payload.herdr { sessions[index].herdr = herdr }
            if let model = payload.model, !model.isEmpty { sessions[index].model = model }
            sessions[index].kind = payload.agent
            sessions[index].fromHooks = true
            return index
        }
        // Its first hook replaces any entry the process scan or herdr made
        // for the same tab or pane.
        if let tty = payload.terminal?.ttyPath {
            sessions.removeAll { $0.id.hasPrefix("process:") && $0.kind == payload.agent && $0.terminal?.ttyPath == tty }
        }
        if let pane = payload.herdr {
            sessions.removeAll { !$0.fromHooks && $0.id.hasPrefix("herdr:") && $0.herdr == pane }
        }
        var session = AgentSession(id: payload.sessionID, kind: payload.agent, cwd: payload.cwd ?? "", terminal: payload.terminal, herdr: payload.herdr)
        session.model = payload.model
        sessions.append(session)
        if payload.event != "UserPromptSubmit", let path = payload.transcriptPath {
            recoverPrompt(for: payload.sessionID, transcript: path)
        }
        return sessions.count - 1
    }

    private func append(_ item: FeedItem, at index: Int) {
        sessions[index].feed.append(item)
        if sessions[index].feed.count > Self.feedLimit {
            sessions[index].feed.removeFirst(sessions[index].feed.count - Self.feedLimit)
        }
    }

    private func markToolDone(_ payload: HookPayload, failed: Bool, at index: Int) {
        let feed = sessions[index].feed
        let match = payload.toolUseID.flatMap { id in feed.lastIndex { $0.toolUseID == id } }
            ?? feed.lastIndex { $0.kind == .tool && !$0.isDone && $0.tool == payload.toolName }
        guard let match else { return }
        sessions[index].feed[match].isDone = true
        sessions[index].feed[match].failed = failed
        sessions[index].feed[match].result = failed ? "failed" : ToolSummary.result(payload.toolResponse)
    }

    /// A session that was already running when the app started has no
    /// prompt yet; take its latest one from the transcript.
    private func recoverPrompt(for sessionID: String, transcript path: String) {
        readTranscript(for: sessionID, at: path)
    }

    /// Fills in what hooks don't say: the latest prompt (for sessions that
    /// were running before the app started) and the model in use.
    private func readTranscript(for sessionID: String, at path: String) {
        Task.detached(priority: .utility) {
            let found = Transcript.summary(at: path)
            await MainActor.run {
                guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                if let model = found.model { self.sessions[index].model = model }
                guard self.sessions[index].prompt == nil, let prompt = found.prompt else { return }
                self.sessions[index].prompt = prompt.text
                if self.sessions[index].isBusy, self.sessions[index].turnStartedAt == nil {
                    self.sessions[index].turnStartedAt = prompt.date
                }
            }
        }
    }

    private func finishRunningTools(at index: Int) {
        for item in sessions[index].feed.indices where sessions[index].feed[item].kind == .tool && !sessions[index].feed[item].isDone {
            sessions[index].feed[item].isDone = true
        }
    }

    private func markStopped(at index: Int) {
        finishRunningTools(at: index)
        sessions[index].status = .idle
        sessions[index].screenLine = nil
        sessions[index].finishedAt = Date()
        flashFinished(sessions[index].id)
    }

    /// Hooks can go missing (the app restarted mid-turn, a hook timed out),
    /// which would leave a thread "working" forever. The terminal says what
    /// Claude is really doing, so after two readings that disagree with us,
    /// and no hook for a few seconds, believe the terminal.
    private func reconcile(_ index: Int, busy: Bool?) {
        guard let busy, sessions[index].fromHooks else { return }
        let status = sessions[index].status
        let disagrees = (status == .working && !busy) || (status == .idle && busy)
        sessions[index].disagreements = disagrees ? sessions[index].disagreements + 1 : 0
        guard sessions[index].disagreements >= 2, Date().timeIntervalSince(sessions[index].lastHookAt) > 3 else { return }
        sessions[index].disagreements = 0
        if busy {
            sessions[index].status = .working
            sessions[index].turnStartedAt = sessions[index].turnStartedAt ?? Date()
            sessions[index].finishedAt = nil
            sessions[index].verb = ThinkingVerbs.random()
        } else {
            // The finish was seen without its Stop hook, so no reply came
            // with it: read it from the agent's log.
            let session = sessions[index]
            markStopped(at: index)
            if session.lastReply == nil { Task { await loadExchange(for: session) } }
        }
    }

    func announce(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == text { notice = nil }
        }
    }

    private func flashFinished(_ sessionID: String) {
        justFinished = sessionID
        if UserDefaults.standard.object(forKey: Self.dropOnFinishKey) as? Bool ?? true {
            var others: [String] = []
            if let current = drop {
                others = ([current.sessionID] + current.others).filter { $0 != sessionID }
            }
            drop = Drop(sessionID: sessionID, others: others)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if justFinished == sessionID { justFinished = nil }
        }
    }

    private func pruneEndedSessions() {
        let cutoff = Date().addingTimeInterval(-Self.endedSessionLifetime)
        sessions.removeAll { $0.status == .ended && $0.updatedAt < cutoff }
    }

    // MARK: Approvals

    private func enqueueApproval(_ payload: HookPayload, reply: HookReply) {
        let tool = payload.toolName ?? "Tool"
        let (summary, detail) = ToolSummary.describe(tool, payload.toolInput)
        let approval = Approval(sessionID: payload.sessionID, tool: tool, summary: summary, detail: detail, reply: reply)
        approvals.append(approval)
        let id = approval.id
        reply.onHangUp { [weak self] in
            Task { @MainActor in self?.removeApproval(id) }
        }
    }

    func decide(_ approval: Approval, _ decision: Decision) {
        approval.reply.send(decision.responseBody)
        removeApproval(approval.id)
    }

    /// The session moved on without us (answered in the terminal, new
    /// prompt, turn ended): release any hook still waiting on the notch.
    private func settleApprovals(for sessionID: String) {
        for approval in approvals where approval.sessionID == sessionID {
            approval.reply.send()
        }
        approvals.removeAll { $0.sessionID == sessionID }
    }

    private func removeApproval(_ id: UUID) {
        guard let approval = approvals.first(where: { $0.id == id }) else { return }
        approvals.removeAll { $0.id == id }
        let sessionID = approval.sessionID
        if !approvals.contains(where: { $0.sessionID == sessionID }),
           let index = sessions.firstIndex(where: { $0.id == sessionID }),
           sessions[index].status == .waiting {
            sessions[index].status = .working
        }
    }

    // MARK: Replies

    /// Types the session's draft into its terminal. The prompt then shows up
    /// in the feed through the normal UserPromptSubmit hook.
    /// Sends the session's draft and attachments into its terminal. If the
    /// draft talks about "my screen" and no screenshot is attached, one is
    /// taken first. The prompt then shows up in the feed through the hooks.
    func sendReply(to sessionID: String, ui: NotchUI) {
        guard let session = session(sessionID), session.canReply, !sendingReply else { return }
        let typed = drafts[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var attachments = replyAttachments[sessionID] ?? []
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        sendingReply = true
        Task {
            defer { sendingReply = false }
            if Attachments.mentionsScreen(typed), !attachments.contains(where: \.isScreenshot) {
                do {
                    attachments.append(try await ScreenCapture.capture(hiding: ui, reopen: true))
                } catch {
                    problem = error.localizedDescription
                    return
                }
            }
            let text = Attachments.compose(typed.isEmpty ? "Take a look:" : typed, with: attachments)
            do {
                switch session.replyRoute {
                case .clipboard:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    TerminalBridge.focus(session.terminal, herdr: nil)
                    announce("Copied. Press ⌘V then Return in \(session.terminalName) to send it.")
                case .herdr:
                    // herdr types into its pane whatever terminal it runs in.
                    if let herdr = session.herdr { try await Herdr.prompt(text, to: herdr) }
                    // Without hooks nothing else records the question.
                    if !session.fromHooks, let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                        sessions[index].prompt = text
                        sessions[index].lastReply = nil
                    }
                case .terminal:
                    if let terminal = session.terminal {
                        try await TerminalBridge.send(text, to: terminal)
                    }
                case .none:
                    return
                }
                drafts[sessionID] = nil
                replyAttachments[sessionID] = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: herdr

    /// Folds herdr's agent list in: panes for sessions the hooks already
    /// know, and sessions of their own for agents only herdr sees.
    func applyHerdr(_ snapshot: HerdrMonitor.Snapshot) {
        var seen = Set<String>()
        for (pane, agent) in snapshot {
            guard let kind = agent.kind else { continue }
            // herdr may list a pane before it knows the agent's session id;
            // if hooks already report that pane, it's the same session.
            let hookedPane = sessions.first { $0.fromHooks && $0.herdr == pane }?.id
            let id = agent.agentSession?.value ?? hookedPane ?? "herdr:\(pane.socket ?? "default"):\(pane.paneID)"
            seen.insert(id)
            let title = agent.terminalTitle.flatMap(Self.cleanTitle)
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].herdr = pane
                if let title { sessions[index].terminalTitle = title }
                if sessions[index].fromHooks {
                    reconcile(index, busy: ["working": true, "idle": false, "done": false][agent.agentStatus])
                } else {
                    applyHerdrStatus(agent.agentStatus, at: index)
                }
            } else {
                var session = AgentSession(id: id, kind: kind, cwd: agent.cwd ?? "", herdr: pane)
                session.fromHooks = false
                session.terminalTitle = title
                session.updatedAt = .distantPast
                session.status = Self.status(fromHerdr: agent.agentStatus)
                sessions.append(session)
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    sessions[index].agentSessionID = agent.agentSession?.value
                    let session = sessions[index]
                    Task { await loadExchange(for: session) }
                }
            }
        }
        // Only herdr's own sessions; agents found by the process scan aren't in its list.
        sessions.removeAll { !$0.fromHooks && $0.herdr != nil && !seen.contains($0.id) }
    }

    private static func status(fromHerdr status: String) -> SessionStatus {
        switch status {
        case "working": .working
        case "blocked": .waiting
        default: .idle
        }
    }

    private func applyHerdrStatus(_ herdrStatus: String, at index: Int) {
        let status = Self.status(fromHerdr: herdrStatus)
        let previous = sessions[index].status
        guard status != previous else { return }
        sessions[index].status = status
        sessions[index].updatedAt = Date()
        if status == .working {
            sessions[index].turnStartedAt = Date()
            sessions[index].verb = ThinkingVerbs.random()
        } else if previous == .working {
            sessions[index].finishedAt = Date()
            sessions[index].screenLine = nil
            guard status == .idle else { return }
            // No hook brought the reply: read it from the agent's own log,
            // then drop the card with it.
            let session = sessions[index]
            Task {
                await loadExchange(for: session)
                flashFinished(session.id)
            }
        }
    }

    /// The latest question and answer of a session the hooks don't cover,
    /// from Claude's transcript or Codex's session log.
    private func loadExchange(for session: AgentSession) async {
        // Hook sessions are keyed by the agent's own session id.
        guard let sessionID = session.agentSessionID ?? (session.fromHooks ? session.id : nil) else { return }
        let kind = session.kind, cwd = session.cwd
        let exchange = await Task.detached(priority: .userInitiated) {
            AgentLog.lastExchange(kind: kind, sessionID: sessionID, cwd: cwd)
        }.value
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if let prompt = exchange.prompt { sessions[index].prompt = prompt }
        if let reply = exchange.reply { sessions[index].lastReply = reply }
    }

    /// "✳ Fix the login bug" -> "Fix the login bug"; Codex's "Task | folder" -> "Task".
    private static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if let first = title.first, "·✢✳✶✻✽◐◓◑◒⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".contains(first) {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let bar = title.range(of: " | ") { title = String(title[..<bar.lowerBound]) }
        let generic = ["Claude Code", "codex", "Codex", NSUserName()]
        return title.isEmpty || generic.contains(title) ? nil : title
    }

    // MARK: Other agent CLIs

    /// Agents found running in terminal tabs (Codex, Gemini, Cursor…), one
    /// session per process, kept while the process lives.
    func applyProcesses(_ readings: [ProcessMonitor.Reading]) {
        var seen = Set<String>()
        let hookTTYs = Set(sessions.filter(\.fromHooks).compactMap { session in
            session.terminal.map { "\(session.kind.id)|\($0.ttyPath)" }
        })
        for (agent, busy) in readings {
            // A session the hooks already report needs no second entry.
            if let tty = agent.terminal?.ttyPath, hookTTYs.contains("\(agent.kind.id)|\(tty)") { continue }
            let id = "process:\(agent.pid)"
            seen.insert(id)
            let status: SessionStatus = busy ? .working : .idle
            // In Terminal the screen says whether it's busy (watchTerminals);
            // CPU is only for terminals that can't be read.
            let screenReadable = agent.terminal?.app == .terminal
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                if !agent.cwd.isEmpty { sessions[index].cwd = agent.cwd }
                sessions[index].terminal = agent.terminal
                if !screenReadable { setProcessStatus(busy, at: index) }
            } else {
                var session = AgentSession(id: id, kind: agent.kind, cwd: agent.cwd, terminal: agent.terminal)
                session.fromHooks = false
                session.status = status
                session.updatedAt = busy ? Date() : .distantPast
                if busy { session.turnStartedAt = Date() }
                sessions.append(session)
            }
        }
        sessions.removeAll { $0.id.hasPrefix("process:") && !seen.contains($0.id) }
    }

    private func setProcessStatus(_ busy: Bool, at index: Int) {
        let status: SessionStatus = busy ? .working : .idle
        guard sessions[index].status != status else { return }
        sessions[index].status = status
        sessions[index].updatedAt = Date()
        if busy {
            sessions[index].turnStartedAt = Date()
        } else {
            sessions[index].finishedAt = Date()
            flashFinished(sessions[index].id)
        }
    }

    // MARK: Live status lines

    /// Every 1.5s: check Terminal.app tab titles against what the hooks
    /// told us, and for agents that are thinking, read the live status line
    /// Claude Code shows ("✻ Ruminating… ↓ 4.1k tokens").
    func watchTerminals() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }

                if self.sessions.contains(where: { $0.herdr == nil && $0.terminal?.app == .terminal && $0.status != .ended }) {
                    let titles = await Task.detached(priority: .utility) { ScreenStatus.terminalTitles() }.value
                    for index in self.sessions.indices where self.sessions[index].herdr == nil {
                        guard let tty = self.sessions[index].terminal?.ttyPath, let title = titles[tty] else { continue }
                        if self.sessions[index].fromHooks {
                            self.reconcile(index, busy: ScreenStatus.busy(fromTitle: title))
                        } else if let clean = Self.cleanTitle(title) {
                            self.sessions[index].terminalTitle = clean
                        }
                    }
                }

                // Agents found by the process scan, in Terminal: busy while
                // their screen says "esc to interrupt".
                for session in self.sessions where session.id.hasPrefix("process:") && session.terminal?.app == .terminal {
                    guard let tty = session.terminal?.ttyPath else { continue }
                    let busy = await Task.detached(priority: .utility) {
                        ScreenStatus.terminalScreen(tty: tty).map(ScreenStatus.showsBusy)
                    }.value
                    if let busy, let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        self.setProcessStatus(busy, at: index)
                    }
                }

                let thinking = self.sessions.filter { $0.status == .working && $0.runningTool == nil && $0.kind == .claude }
                for session in thinking {
                    let herdr = session.herdr
                    let tty = session.terminal?.app == .terminal ? session.terminal?.ttyPath : nil
                    guard herdr != nil || tty != nil else { continue }
                    let line = await Task.detached(priority: .utility) { () -> ScreenStatus.Line? in
                        let screen = herdr.flatMap(Herdr.screen(of:)) ?? tty.flatMap(ScreenStatus.terminalScreen(tty:))
                        return screen.flatMap(ScreenStatus.parse)
                    }.value
                    if let index = self.sessions.firstIndex(where: { $0.id == session.id }),
                       let line, self.sessions[index].screenLine != line {
                        self.sessions[index].screenLine = line
                    }
                }
            }
        }
    }

    // MARK: Hooks setup

    func setHooksInstalled(_ install: Bool) {
        do {
            try install ? HookInstaller.install() : HookInstaller.uninstall()
            problem = nil
        } catch {
            problem = "Couldn't update \(HookInstaller.settingsPath): \(error.localizedDescription)"
        }
        hooksInstalled = HookInstaller.isInstalled
    }
}

/// Claude Code's own spinner verbs.
enum ThinkingVerbs {
    static func random() -> String { all.randomElement() ?? "Thinking" }

    static let all = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'", "Befuddling",
        "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping", "Bootstrapping", "Brewing",
        "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating",
        "Channeling", "Choreographing", "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Composing",
        "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching",
        "Crystallizing", "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying", "Discombobulating",
        "Doing", "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning",
        "Fermenting", "Fiddle-faddling", "Finagling", "Flambéing", "Flibbertigibbeting", "Flowing", "Flummoxing",
        "Fluttering", "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping", "Garnishing",
        "Generating", "Gesticulating", "Germinating", "Gitifying", "Grooving", "Gusting", "Harmonizing", "Hashing",
        "Hatching", "Herding", "Honking", "Hullaballooing", "Hyperspacing", "Ideating", "Imagining", "Improvising",
        "Incubating", "Inferring", "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kerfuffling", "Kneading",
        "Leavening", "Levitating", "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting",
        "Moonwalking", "Moseying", "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Newspapering", "Noodling",
        "Nucleating", "Onioning", "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing",
        "Philosophizing", "Photosynthesizing", "Polishing", "Pollinating", "Pondering", "Pontificating", "Pouncing",
        "Precipitating", "Prestidigitating", "Processing", "Proofing", "Propagating", "Puttering", "Puzzling",
        "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating", "Roosting", "Ruminating",
        "Sautéing", "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
        "Skedaddling", "Sketching", "Slithering", "Smooshing", "Sock-hopping", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering", "Thinking",
        "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying", "Transfiguring", "Transmogrifying", "Transmuting",
        "Twisting", "Undulating", "Unfurling", "Unraveling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whatchamacalliting", "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting",
        "Zigzagging",
    ]
}

/// Turns a tool call into a one-line summary plus optional detail (a command,
/// a diff, a prompt) for the feed and the approval card.
enum ToolSummary {
    static func describe(_ tool: String, _ input: [String: JSONValue]?) -> (summary: String, detail: String?) {
        let input = input ?? [:]
        func value(_ key: String) -> String? { input[key]?.string }

        switch tool {
        case "Bash":
            let command = value("command") ?? ""
            return (firstLine(command), command.contains("\n") ? command : value("description"))
        case "Edit":
            let diff = [value("old_string").map { prefixLines($0, "- ") },
                        value("new_string").map { prefixLines($0, "+ ") }]
                .compactMap { $0 }.joined(separator: "\n")
            return (path(value("file_path")), diff.isEmpty ? nil : clip(diff))
        case "Write":
            return (path(value("file_path")), value("content").map { clip($0) })
        case "Read":
            return (path(value("file_path")), nil)
        case "NotebookEdit":
            return (path(value("notebook_path")), value("new_source").map { clip($0) })
        case "Grep", "Glob":
            return (value("pattern") ?? "", value("path").map { path($0) })
        case "WebFetch":
            return (value("url") ?? "", value("prompt"))
        case "WebSearch":
            return (value("query") ?? "", nil)
        case "Task", "Agent":
            return (value("description") ?? "", value("prompt").map { clip($0) })
        default:
            let first = input.sorted { $0.key < $1.key }.lazy.compactMap { $0.value.string }.first
            return (first.map { firstLine($0) } ?? "", nil)
        }
    }

    static func result(_ response: JSONValue?) -> String? {
        guard case .object(let fields)? = response else { return nil }
        if case .array(let hunks)? = fields["structuredPatch"], !hunks.isEmpty {
            var added = 0, removed = 0
            for case .object(let hunk) in hunks {
                guard case .array(let lines)? = hunk["lines"] else { continue }
                for case .string(let line) in lines {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
            }
            return "+\(added) −\(removed)"
        }
        if fields["type"]?.string == "create", let content = fields["content"]?.string {
            return "+" + plural(lineCount(content), "line")
        }
        if case .object(let file)? = fields["file"], case .number(let lines)? = file["numLines"] {
            return plural(Int(lines), "line")
        }
        if case .number(let files)? = fields["numFiles"] { return plural(Int(files), "file") }
        if case .number(let status)? = fields["code"] { return "HTTP \(Int(status))" }
        if let stdout = fields["stdout"]?.string {
            let lines = lineCount(stdout)
            return lines == 0 ? nil : plural(lines, "line")
        }
        return nil
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func path(_ path: String?) -> String {
        guard let path else { return "" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.count < text.count ? line + " …" : line
    }

    private static func prefixLines(_ text: String, _ prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }

    private static func clip(_ text: String, _ limit: Int = 2000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
