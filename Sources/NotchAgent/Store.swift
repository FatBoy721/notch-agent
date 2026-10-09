import AppKit

enum SessionStatus {
    case working, waiting, idle, ended
}

struct FeedItem: Identifiable, Equatable {
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
    /// Files the tool writes (Edit, Write, MultiEdit, apply_patch…).
    var files: [String] = []
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    var kind: AgentKind = .claude
    var cwd: String
    var terminal: TerminalLocation?
    var herdr: HerdrPane?
    /// The herdr tab's name, e.g. "Helix-IOS(Claude)".
    var herdrTab: String?
    /// Where a chat lives when it isn't a folder: "Telegram" for a Hermes chat.
    var origin: String?
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
    /// Tokens in the agent's context window after its last reply.
    var contextTokens: Int?
    /// The window when the agent reports it (Codex logs it).
    var contextWindow: Int?

    /// Reported, or for Claude from the model: 1M for the Claude 5 family
    /// and "[1m]" models, 200k otherwise. Agents compact near the end.
    var contextLimit: Int {
        if let contextWindow { return contextWindow }
        guard let model else { return 200_000 }
        return model.hasSuffix("[1m]") || model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-sonnet-5")
            ? 1_000_000 : 200_000
    }

    /// Codex counts its fixed prompt (12k tokens) as neither used nor free,
    /// so its "% context left" leaves it out of both; matching that keeps
    /// the ring and Codex's status line in step.
    var contextFraction: Double? {
        let baseline = kind == .codex ? 12_000 : 0
        return contextTokens.map { min(1, Double(max(0, $0 - baseline)) / Double(max(1, contextLimit - baseline))) }
    }

    /// Agents with a compact command the notch can send: Claude Code and
    /// Codex take `/compact`, Hermes its `session.compress`.
    var canCompact: Bool {
        [AgentKind.claude, .codex, .hermes].contains(kind) && replyRoute != .none && status != .ended
    }
    var lastHookAt = Date()
    /// Consecutive terminal readings that disagree with `status`.
    var disagreements = 0
    var status: SessionStatus = .idle {
        didSet { if status != oldValue { waitingSince = status == .waiting ? Date() : nil } }
    }
    /// When it started waiting on the user; nil unless waiting.
    var waitingSince: Date?
    var feed: [FeedItem] = []
    var updatedAt = Date()
    /// The latest prompt, which names the thread.
    var prompt: String?
    var turnStartedAt: Date?
    var finishedAt: Date?

    var project: String {
        origin ?? (cwd.isEmpty ? "Session" : URL(fileURLWithPath: cwd).lastPathComponent)
    }

    var agent: String { kind.name }

    /// Waiting this long without an answer, a thread is probably abandoned:
    /// it sinks below the idle ones so live requests stay on top.
    static let staleWait: TimeInterval = 2 * 3600

    /// Also true when how long it waited is unknown (found waiting, no log).
    var isStaleWait: Bool {
        status == .waiting && (waitingSince.map { Date().timeIntervalSince($0) > Self.staleWait } ?? true)
    }

    /// The name the user gave the thread (right-click › Rename).
    var customTitle: String?

    var title: String {
        customTitle ?? prompt ?? terminalTitle ?? (fromHooks ? "New session in \(project)" : "\(agent) in \(project)")
    }

    /// Every file the agent wrote this session, first-touched first.
    var changedFiles: [String] {
        var seen = Set<String>()
        return feed.flatMap(\.files).filter { seen.insert($0).inserted }
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

    enum ReplyRoute { case herdr, terminal, clipboard, hermes, none }

    /// How a reply reaches the agent: typed by herdr or Terminal/iTerm2, or
    /// for terminals that can't be scripted (Metalterm, Ghostty…), copied
    /// for the user to paste.
    var replyRoute: ReplyRoute {
        if status == .ended { return .none }
        if kind == .hermes { return .hermes }
        if herdr != nil { return .herdr }
        guard let terminal else { return .none }
        return terminal.canReply ? .terminal : .clipboard
    }

    var canReply: Bool { replyRoute != .none }

    var terminalName: String {
        if kind == .hermes { return "Hermes" }
        let app = terminal?.displayName
        if herdr != nil {
            let place = herdrTab ?? "herdr"
            return app.map { "\(place) · \($0)" } ?? place
        }
        return app ?? "terminal"
    }

    var lastTool: FeedItem? { feed.last { $0.kind == .tool } }

    var runningTool: FeedItem? {
        guard let tool = lastTool, !tool.isDone else { return nil }
        return tool
    }

    /// Tool calls since the latest prompt.
    /// Subagents Claude started this turn (its Task / Agent tool), oldest
    /// first; done when the tool returned.
    var subagents: [FeedItem] {
        turnTools.filter { $0.tool == "Task" || $0.tool == "Agent" }
    }

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
    /// Hermes command approvals: for the rest of this chat, or for good.
    case allowForChat, allowAlways
    /// AskUserQuestion: question text → chosen label(s) or typed text.
    case answer([String: String])
    /// ExitPlanMode turned down, with what should change.
    case keepPlanning(String)

    /// Hook output for a PermissionRequest. `.terminal` answers with nothing,
    /// which hands the decision back to the agent's own prompt. Answers ride
    /// on `updatedInput`, which replaces the whole tool input, so the
    /// original questions go back with them.
    func responseBody(input: [String: JSONValue]) -> Data {
        let decision: [String: Any]
        switch self {
        case .terminal: return Data()
        case .allow, .allowForChat, .allowAlways: decision = ["behavior": "allow"]
        case .deny: decision = ["behavior": "deny", "message": "Denied from the notch."]
        case .answer(let answers):
            var updated = input.mapValues(\.foundation)
            updated["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": updated]
        case .keepPlanning(let feedback): decision = ["behavior": "deny", "message": feedback]
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
    let input: [String: JSONValue]
    /// What to show: a diff, questions, a plan, or the plain summary.
    let prompt: PromptKind
    let channel: Channel

    /// Where the answer goes.
    enum Channel {
        /// A Claude Code or Codex hook, waiting on its HTTP request.
        case hook(HookReply)
        /// Hermes, over its live socket: a command approval for a chat, or
        /// a question (`clarify`) by its request id.
        case hermesApproval(stored: String)
        case hermesQuestion(requestID: String)
    }

    var isHermes: Bool {
        if case .hook = channel { return false }
        return true
    }
}

@MainActor
final class Store: ObservableObject {
    /// Published only when something actually changed: herdr, the process
    /// scan and the terminal watcher rewrite it every few seconds, and
    /// redrawing the notch for an identical list made animations hitch.
    private(set) var sessions: [AgentSession] = [] {
        willSet { if newValue != sessions { objectWillChange.send() } }
    }
    @Published private(set) var approvals: [Approval] = []
    @Published var selectedID: String?
    @Published private(set) var hooksInstalled = HookInstaller.isInstalled
    @Published private(set) var hermesConnected = HermesAPI.isConfigured
    /// Hermes chats with a turn running from the notch: their live events
    /// own them, so the 15 s poll leaves them alone until the turn ends.
    private var hermesLive = Set<String>()
    /// When each session's transcript was last read for its context size.
    private var contextReadAt: [String: Date] = [:]
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
            case .waiting where session.fromHooks: 0
            case .waiting: session.isStaleWait ? 3 : 1
            case .idle: 2
            case .ended: 4
            }
        }
        return sessions.sorted { (rank($0), $1.updatedAt) < (rank($1), $0.updatedAt) }
    }

    // MARK: Thread names

    /// Names the user gave threads, by session id. Kept across launches.
    private var titles = UserDefaults.standard.dictionary(forKey: "threadTitles") as? [String: String] ?? [:]

    /// Every new session goes through here, so a renamed thread keeps its
    /// name when its agent comes back (relaunch, herdr rescan).
    private func add(_ session: AgentSession) {
        var session = session
        session.customTitle = titles[session.id]
        sessions.append(session)
    }

    /// An empty name goes back to the automatic one (the latest prompt).
    func rename(_ id: String, to name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        titles[id] = name?.isEmpty == false ? name : nil
        UserDefaults.standard.set(titles, forKey: "threadTitles")
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].customTitle = titles[id] }
    }

    // MARK: Thread tools

    func copySummary(_ id: String) {
        guard let session = session(id) else { return }
        copy(ThreadTools.summary(of: session))
        announce("Copied a summary of \(session.agent)'s run.")
    }

    func copyDiff(_ id: String) {
        guard let session = session(id) else { return }
        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) { try ThreadTools.diff(of: session) }.value
                copy(diff.text)
                announce("Copied the diff of \(diff.files) file\(diff.files == 1 ? "" : "s").")
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func revealTranscript(_ id: String) {
        guard let session = session(id) else { return }
        Task {
            let path = await Task.detached(priority: .userInitiated) { ThreadTools.transcript(of: session) }.value
            guard let path else {
                problem = "Couldn't find \(session.agent)'s log for this thread."
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Hidden threads

    /// Threads the user removed from the list, with when. One comes back
    /// if it does something new after that. Kept across launches.
    @Published private(set) var hidden: [String: Date] = (UserDefaults.standard.dictionary(forKey: "hiddenThreads") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) }

    /// What Threads lists: everything not hidden.
    var listedSessions: [AgentSession] {
        orderedSessions.filter { session in hidden[session.id].map { session.updatedAt > $0 } ?? true }
    }

    var hiddenCount: Int { sessions.count - listedSessions.count }

    func hide(_ ids: [String]) {
        let now = Date()
        for id in ids { hidden[id] = now }
        saveHidden()
    }

    func showHidden() {
        hidden = [:]
        saveHidden()
    }

    private func saveHidden() {
        // Forget entries for sessions that are gone for good.
        let live = Set(sessions.map(\.id))
        hidden = hidden.filter { live.contains($0.key) }
        UserDefaults.standard.set(hidden.mapValues(\.timeIntervalSince1970), forKey: "hiddenThreads")
    }

    /// Ends the agent itself (closes its herdr pane), then drops the thread.
    func closeAgent(_ id: String) {
        guard let pane = session(id)?.herdr else { return }
        Task {
            let closed = await Task.detached { Herdr.closePane(pane) }.value
            if closed { hide([id]) } else { problem = "herdr couldn't close that pane." }
        }
    }

    /// Asks the agent to compact its context: `/compact` typed into Claude
    /// Code or Codex, `session.compress` for Hermes.
    func compactContext(_ id: String) {
        guard let session = session(id), session.canCompact else { return }
        Task {
            do {
                switch session.replyRoute {
                case .hermes:
                    try await HermesLive.shared.compress(String(id.dropFirst("hermes:".count)))
                case .herdr:
                    if let herdr = session.herdr { try await Herdr.prompt("/compact", to: herdr) }
                case .terminal:
                    if let terminal = session.terminal { try await TerminalBridge.send("/compact", to: terminal, cwd: session.cwd) }
                case .clipboard:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("/compact", forType: .string)
                    announce("Copied /compact. Paste it into \(session.terminalName) and press Return.")
                    return
                case .none:
                    return
                }
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    append(FeedItem(kind: .notice, title: "Compacting context"), at: index)
                }
                announce("Compacting \(session.agent)'s context…")
                if session.replyRoute != .hermes { await followCompaction(of: session) }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Sessions without hooks (herdr-only Claude, Codex) say nothing when
    /// compaction ends, so re-read their log until the ring drops; it takes
    /// up to a couple of minutes.
    private func followCompaction(of session: AgentSession) async {
        let before = session.contextTokens ?? 0
        for _ in 0..<18 {
            try? await Task.sleep(for: .seconds(10))
            guard let current = self.session(session.id) else { return }
            await loadExchange(for: current)
            if let tokens = self.session(session.id)?.contextTokens, tokens < before / 2 { return }
        }
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
            if payload.source == "compact" {
                // Claude Code starts over after /compact (its own or ours);
                // the ring has to drop now, not after the next turn.
                append(FeedItem(kind: .notice, title: "Context compacted"), at: index)
                if let path = payload.transcriptPath { readTranscript(for: payload.sessionID, at: path) }
            } else {
                append(FeedItem(kind: .notice, title: "Session started", detail: payload.source), at: index)
            }
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
            var item = FeedItem(kind: .tool, tool: tool, title: summary, detail: detail, toolUseID: payload.toolUseID)
            if case .diff(let diffs) = PromptKind.from(tool: tool, input: payload.toolInput ?? [:], cwd: payload.cwd) {
                item.files = diffs.map(\.path)
            }
            append(item, at: index)
        case "PostToolUse", "PostToolUseFailure":
            settleApprovals(for: payload.sessionID)
            sessions[index].status = .working
            markToolDone(payload, failed: payload.event == "PostToolUseFailure", at: index)
            // Keeps the context ring current through long turns, not just
            // when they end; every 15 s at most.
            if let path = payload.transcriptPath, Date().timeIntervalSince(contextReadAt[payload.sessionID] ?? .distantPast) > 15 {
                contextReadAt[payload.sessionID] = Date()
                readTranscript(for: payload.sessionID, at: path)
            }
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
        add(session)
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
        // Codex's hooks point at its own log, which only has context to give.
        if session(sessionID)?.kind == .codex {
            Task.detached(priority: .utility) {
                let context = AgentLog.context(kind: .codex, path: path)
                await MainActor.run {
                    guard let context, let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                    self.sessions[index].contextTokens = context.tokens
                    self.sessions[index].contextWindow = context.window
                    if let model = context.model { self.sessions[index].model = model }
                }
            }
            return
        }
        Task.detached(priority: .utility) {
            let found = Transcript.summary(at: path)
            await MainActor.run {
                guard let index = self.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
                if let model = found.model { self.sessions[index].model = model }
                if let context = found.context { self.sessions[index].contextTokens = context }
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
        let input = payload.toolInput ?? [:]
        let approval = Approval(sessionID: payload.sessionID, tool: tool, summary: summary, detail: detail,
                                input: input, prompt: PromptKind.from(tool: tool, input: input, cwd: payload.cwd), channel: .hook(reply))
        approvals.append(approval)
        let id = approval.id
        reply.onHangUp { [weak self] in
            Task { @MainActor in self?.removeApproval(id) }
        }
    }

    func decide(_ approval: Approval, _ decision: Decision) {
        switch approval.channel {
        case .hook(let reply):
            reply.send(decision.responseBody(input: approval.input))
        case .hermesApproval(let stored):
            let choice = switch decision {
            case .allowForChat: "session"
            case .allowAlways: "always"
            case .deny: "deny"
            default: "once"
            }
            respondToHermes { try await HermesLive.shared.approve(stored, choice: choice) }
        case .hermesQuestion(let requestID):
            guard case .answer(let answers) = decision else { break }
            let answer = answers.values.first ?? ""
            respondToHermes { try await HermesLive.shared.answer(requestID, with: answer) }
        }
        removeApproval(approval.id)
    }

    private func respondToHermes(_ send: @escaping () async throws -> Void) {
        Task {
            do { try await send() } catch { problem = error.localizedDescription }
        }
    }

    /// The session moved on without us (answered in the terminal, new
    /// prompt, turn ended): release any hook still waiting on the notch.
    private func settleApprovals(for sessionID: String) {
        for approval in approvals where approval.sessionID == sessionID {
            if case .hook(let reply) = approval.channel { reply.send() }
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
            // Sent mid-turn, the agent queues it until it can take it.
            let queued = session.status == .working && session.replyRoute != .hermes
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
                        try await TerminalBridge.send(text, to: terminal, cwd: session.cwd)
                    }
                case .hermes:
                    let stored = String(sessionID.dropFirst("hermes:".count))
                    beginHermesTurn(sessionID, prompt: text)
                    do {
                        try await HermesLive.shared.reply(to: stored, text: text)
                    } catch {
                        endHermesTurn(sessionID)
                        throw error
                    }
                case .none:
                    return
                }
                drafts[sessionID] = nil
                replyAttachments[sessionID] = nil
                problem = nil
                if queued, let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                    append(FeedItem(kind: .notice, title: "Queued: \(typed.isEmpty ? "attachments" : typed)"), at: index)
                }
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
                sessions[index].herdrTab = agent.tabLabel
                if let title { sessions[index].terminalTitle = title }
                if sessions[index].fromHooks {
                    reconcile(index, busy: ["working": true, "idle": false, "done": false][agent.agentStatus])
                } else {
                    applyHerdrStatus(agent.agentStatus, at: index)
                    // No hooks to say how a long turn is going: the ring
                    // follows the log instead, every 15 s at most.
                    if sessions[index].status == .working,
                       Date().timeIntervalSince(contextReadAt[id] ?? .distantPast) > 15 {
                        contextReadAt[id] = Date()
                        let session = sessions[index]
                        Task { await loadExchange(for: session) }
                    }
                }
            } else {
                var session = AgentSession(id: id, kind: kind, cwd: agent.cwd ?? "", herdr: pane)
                session.fromHooks = false
                session.terminalTitle = title
                session.herdrTab = agent.tabLabel
                session.updatedAt = .distantPast
                session.status = Self.status(fromHerdr: agent.agentStatus)
                add(session)
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
        if let context = exchange.context {
            sessions[index].contextTokens = context.tokens
            sessions[index].contextWindow = context.window
            // Codex's log has the model it switched to; Claude's hooks report
            // the id with its "[1m]" window suffix, which the log lacks.
            if let model = context.model, session.kind == .codex || sessions[index].model == nil {
                sessions[index].model = model
            }
        }
        // Found already waiting: it began when the agent last wrote its log.
        // No log at all means its age is unknown (nil), most likely old.
        if sessions[index].status == .waiting, let since = sessions[index].waitingSince {
            if let activity = exchange.activity {
                if activity < since { sessions[index].waitingSince = activity }
            } else {
                sessions[index].waitingSince = nil
            }
        }
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

    // MARK: Hermes

    /// Every 15 s: the Hermes backend's recent chats, as threads. Also
    /// listens for live events from chats started or answered here.
    func watchHermes() {
        Task { [weak self] in
            await HermesLive.shared.onEvent { event in
                Task { @MainActor in self?.handleHermes(event) }
            }
        }
        Task { [weak self] in
            while true {
                await self?.refreshHermes()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func connectHermes() {
        HermesConnectDialog.present { [weak self] in
            self?.hermesConnected = true
            Task { await self?.refreshHermes() }
        }
    }

    func disconnectHermes() {
        hermesConnected = false
        sessions.removeAll { $0.kind == .hermes }
        Task { await HermesAPI.shared.disconnect() }
    }

    private func refreshHermes() async {
        guard HermesAPI.isConfigured else { return }
        do {
            applyHermes(try await HermesAPI.shared.recentChats())
        } catch {
            // Mac mini asleep, Tailscale off: keep the last list.
            EventLog.write("hermes: \(error.localizedDescription)")
        }
    }

    /// Asks Hermes in a new chat; returns its thread id.
    func askHermes(_ text: String) async -> String? {
        do {
            let stored = try await HermesLive.shared.ask(text)
            let id = "hermes:\(stored)"
            if !sessions.contains(where: { $0.id == id }) {
                var session = AgentSession(id: id, kind: .hermes, cwd: "")
                session.fromHooks = false
                session.origin = "Hermes"
                add(session)
            }
            beginHermesTurn(id, prompt: text)
            return id
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    private func beginHermesTurn(_ id: String, prompt: String) {
        hermesLive.insert(id)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        finishRunningTools(at: index)
        sessions[index].prompt = prompt
        sessions[index].lastReply = nil
        sessions[index].status = .working
        sessions[index].turnStartedAt = Date()
        sessions[index].finishedAt = nil
        sessions[index].updatedAt = Date()
        append(FeedItem(kind: .prompt, title: prompt), at: index)
    }

    private func endHermesTurn(_ id: String) {
        hermesLive.remove(id)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        finishRunningTools(at: index)
        sessions[index].status = .idle
    }

    private func handleHermes(_ event: HermesEvent) {
        switch event {
        case .started(let stored):
            guard let index = sessions.firstIndex(where: { $0.id == "hermes:\(stored)" }) else { return }
            sessions[index].status = .working
        case .tool(let stored, let name, let context):
            guard let index = sessions.firstIndex(where: { $0.id == "hermes:\(stored)" }) else { return }
            finishRunningTools(at: index)
            append(FeedItem(kind: .tool, tool: name, title: context ?? ""), at: index)
        case .approval(let stored, let command, let description, let choices):
            let id = "hermes:\(stored)"
            approvals.append(Approval(sessionID: id, tool: "Hermes", summary: command, detail: description, input: [:],
                                      prompt: .command(command, description: description, choices: choices),
                                      channel: .hermesApproval(stored: stored)))
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].status = .waiting }
        case .question(let stored, let requestID, let question):
            let id = "hermes:\(stored)"
            approvals.append(Approval(sessionID: id, tool: "Hermes", summary: question.question, detail: nil, input: [:],
                                      prompt: .questions([question]), channel: .hermesQuestion(requestID: requestID)))
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].status = .waiting }
        case .completed(let stored, let text):
            let id = "hermes:\(stored)"
            settleApprovals(for: id)
            hermesLive.remove(id)
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            finishRunningTools(at: index)
            if !text.isEmpty { sessions[index].lastReply = text }
            sessions[index].updatedAt = Date()
            markStopped(at: index)
            append(FeedItem(kind: .finished, title: "Finished"), at: index)
        case .failed(let stored, let message):
            settleApprovals(for: "hermes:\(stored)")
            endHermesTurn("hermes:\(stored)")
            problem = message
        }
    }

    private func applyHermes(_ chats: [HermesChat]) {
        let ids = Set(chats.map { "hermes:\($0.id)" })
        // Chats running from the notch stay even if they've left the top few.
        sessions.removeAll { $0.kind == .hermes && !ids.contains($0.id) && !hermesLive.contains($0.id) }
        for chat in chats {
            let id = "hermes:\(chat.id)"
            guard !hermesLive.contains(id) else { continue }
            // The list can't say whether a turn is running (Hermes touches a
            // chat again after replying, e.g. to title it), so polled chats
            // show as done; "working" comes only from live events.
            var session = sessions.first { $0.id == id } ?? AgentSession(id: id, kind: .hermes, cwd: "")
            session.fromHooks = false
            session.origin = chat.sourceName
            session.terminalTitle = chat.title
            session.prompt = chat.prompt ?? chat.title
            session.lastReply = chat.reply
            session.model = chat.model
            session.status = .idle
            session.updatedAt = chat.lastActive
            session.finishedAt = chat.lastActive
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index] = session
            } else {
                add(session)
            }
        }
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
                add(session)
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
