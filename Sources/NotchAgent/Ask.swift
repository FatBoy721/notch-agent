import AppKit
import SwiftUI

/// Starting a new agent from the notch: a prompt plus where and how to run
/// it. The agent opens in a new herdr tab (or a Terminal window) and then
/// shows up in Threads like any other session.
@MainActor
final class AskModel: ObservableObject {
    enum Target: String, CaseIterable { case herdr = "herdr", terminal = "Terminal" }

    @Published var prompt = ""
    @Published var agent: AgentKind = .claude {
        didSet {
            guard agent != oldValue else { return }
            model = Choice.models(for: agent)[0]
            effort = Choice.efforts[0]
        }
    }
    @Published var folder = NSHomeDirectory()
    @Published var model = Choice.claudeModels[0]
    @Published var mode = Choice.modes[0]
    @Published var effort = Choice.efforts[0]
    @Published var target: Target = Herdr.isRunning ? .herdr : .terminal
    @Published private(set) var launching = false

    @Published var attachments: [Attachment] = []

    /// Agent CLIs installed on this Mac, Claude first.
    static let installedAgents: [AgentKind] = {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin",
                       NSHomeDirectory() + "/.bun/bin", NSHomeDirectory() + "/.cargo/bin"]
        let candidates = ["claude", "codex", "gemini", "cursor", "opencode", "copilot", "amp", "aider", "grok", "kimi", "droid", "cline"]
        return candidates.map { AgentKind(id: $0) }.filter { kind in
            folders.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(executable(for: kind))") }
        }
    }()

    nonisolated static func executable(for kind: AgentKind) -> String {
        kind.id == "cursor" ? "cursor-agent" : kind.id
    }

    /// Claude, Codex and Gemini take the first prompt as an argument; other
    /// CLIs are started first and get the prompt typed in once they're up.
    nonisolated static func takesPromptArgument(_ kind: AgentKind) -> Bool {
        [AgentKind.claude, .codex, .gemini].contains(kind)
    }

    func launch(store: Store, ui: NotchUI, done: @escaping () -> Void) {
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !launching else { return }
        launching = true
        let folder = folder, target = target, agent = agent, model = model, mode = mode, effort = effort
        Task {
            defer { launching = false }
            // "look at my screen…" with no screenshot attached: take one.
            if Attachments.mentionsScreen(typed), !attachments.contains(where: \.isScreenshot) {
                do {
                    attachments.append(try await ScreenCapture.capture(hiding: ui, reopen: false))
                } catch {
                    store.problem = error.localizedDescription
                    return
                }
            }
            let text = Attachments.compose(typed, with: attachments)
            let command = Self.command(agent: agent, model: model, mode: mode, effort: effort, prompt: text)
            let started = await Task.detached { () -> Bool in
                let inline = Self.takesPromptArgument(agent)
                switch target {
                case .herdr:
                    let label = URL(fileURLWithPath: folder).lastPathComponent
                    guard let pane = Herdr.createTab(cwd: folder, label: label),
                          Herdr.runInPane(pane, command: command) else { return false }
                    if !inline {
                        try? await Task.sleep(for: .seconds(5))
                        try? await Herdr.prompt(text, to: HerdrPane(paneID: pane, socket: nil))
                    }
                    return true
                case .terminal:
                    let line = Self.appleScriptString("cd \(Self.shellQuote(folder)) && \(command)")
                    guard let tty = MusicBridge.run("tell application \"Terminal\" to return tty of (do script \(line))"),
                          tty.hasPrefix("/dev/") else { return false }
                    if !inline, let location = TerminalLocation(tty: String(tty.dropFirst(5)), program: "Apple_Terminal") {
                        try? await Task.sleep(for: .seconds(5))
                        try? await TerminalBridge.send(text, to: location)
                    }
                    return true
                }
            }.value
            if started {
                prompt = ""
                attachments = []
                store.announce("Started \(agent.name) in \(URL(fileURLWithPath: folder).lastPathComponent) (\(target.rawValue))")
                done()
            } else {
                store.problem = "Couldn't start \(agent.name) in \(target.rawValue)."
            }
        }
    }

    nonisolated static func command(agent: AgentKind, model: Choice, mode: Choice, effort: Choice = Choice.efforts[0],
                                    prompt: String) -> String {
        switch agent {
        case .claude:
            var parts = ["claude"]
            if let value = model.value { parts += ["--model", value] }
            if let value = effort.value { parts += ["--effort", value] }
            if let value = mode.value { parts += ["--permission-mode", value] }
            return (parts + [shellQuote(prompt)]).joined(separator: " ")
        case .codex:
            var parts = ["codex"]
            if let value = model.value { parts += ["-m", value] }
            if let value = effort.value { parts += ["-c", "model_reasoning_effort=\(value)"] }
            return (parts + [shellQuote(prompt)]).joined(separator: " ")
        case .gemini:
            return "gemini -i " + shellQuote(prompt)
        default:
            return executable(for: agent)
        }
    }

    nonisolated static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct Choice: Hashable {
    let label: String
    /// The flag's value; nil leaves the agent's own default.
    let value: String?
    /// Menu section ("Opus", "Sonnet"…).
    var group: String? = nil
    /// Shown beside the choice, e.g. Fable needing usage credits.
    var note: String? = nil

    /// Every Claude model Claude Code accepts with --model, newest first in
    /// each family. How Fable is billed depends on the account (FableAccess).
    static let claudeModels: [Choice] = [Choice(label: "Model", value: nil)] + [
        ("Opus", "Opus 5.5", "claude-opus-5-5"), ("Opus", "Opus 5", "claude-opus-5"), ("Opus", "Opus 4.8", "claude-opus-4-8"),
        ("Opus", "Opus 4.7", "claude-opus-4-7"), ("Opus", "Opus 4.6", "claude-opus-4-6"),
        ("Sonnet", "Sonnet 5.5", "claude-sonnet-5-5"), ("Sonnet", "Sonnet 5", "claude-sonnet-5"), ("Sonnet", "Sonnet 4.6", "claude-sonnet-4-6"),
        ("Haiku", "Haiku 4.5", "claude-haiku-4-5"),
    ].map { Choice(label: $0.1, value: $0.2, group: $0.0) } + [
        Choice(label: "Fable 5.1", value: "claude-fable-5-1", group: "Fable"),
        Choice(label: "Fable 5", value: "claude-fable-5", group: "Fable"),
    ]

    static var codexModels: [Choice] {
        [Choice(label: "Model", value: nil)] + CodexModels.load().map { Choice(label: $0.name, value: $0.slug, group: "Codex") }
    }

    static func models(for agent: AgentKind) -> [Choice] {
        switch agent {
        case .claude: claudeModels
        case .codex: codexModels
        default: [Choice(label: "Model", value: nil)]
        }
    }

    static let efforts = [Choice(label: "Effort", value: nil), Choice(label: "Low", value: "low"),
                          Choice(label: "Medium", value: "medium"), Choice(label: "High", value: "high"),
                          Choice(label: "X-High", value: "xhigh"), Choice(label: "Max", value: "max")]

    /// Codex's reasoning levels for the chosen model (or the common ones).
    static func codexEfforts(model: Choice) -> [Choice] {
        let levels = CodexModels.load().first { $0.slug == model.value }?.efforts ?? ["low", "medium", "high"]
        return [Choice(label: "Effort", value: nil)] + levels.map { Choice(label: $0 == "xhigh" ? "X-High" : $0.capitalized, value: $0) }
    }

    static let modes = [Choice(label: "Mode", value: nil), Choice(label: "Ask first", value: "default"),
                        Choice(label: "Accept", value: "acceptEdits"), Choice(label: "Plan", value: "plan"),
                        Choice(label: "Bypass", value: "bypassPermissions")]
}

struct AskPage: View {
    @ObservedObject var ask: AskModel
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    @ObservedObject var limits: LimitsStore
    let done: () -> Void
    @FocusState private var focused: Bool

    /// Folders of recent sessions, newest first, plus home.
    private var folders: [String] {
        var seen = Set<String>()
        return (store.orderedSessions.map(\.cwd) + [NSHomeDirectory()]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What's on the go: working, waiting on you, or done in the last half hour.
    private var active: [AgentSession] {
        store.orderedSessions.filter { session in
            session.status == .working || (session.status == .waiting && session.fromHooks)
                || (session.finishedAt.map { Date().timeIntervalSince($0) < 1800 } ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Agents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.mute)
                Text("\(active.count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: Capsule())
                Spacer()
                Button { ui.page = .threads } label: {
                    HStack(spacing: 4) {
                        Text("View All \(store.sessions.count)")
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                HeaderIcons(store: store, ui: ui, limits: limits)
            }
            if !active.isEmpty {
                VStack(spacing: 0) {
                    ForEach(active.prefix(3)) { session in
                        AgentLine(session: session, needsYou: store.approvals.contains { $0.sessionID == session.id }) {
                            ui.page = .thread(session.id)
                        }
                        .transition(Motion.row)
                    }
                }
                .padding(.vertical, 4)
                .background(Palette.faint, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06), lineWidth: 1))
            }

            HStack(spacing: 8) {
                AgentGlyph(kind: ask.agent, busy: ask.launching, size: 15)
                TextField("Ask \(ask.agent.name) to build something", text: $ask.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { ask.launch(store: store, ui: ui, done: done) }
                Button { ask.launch(store: store, ui: ui, done: done) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ask.prompt.isEmpty ? .white.opacity(0.25) : ask.agent.color)
                .disabled(ask.prompt.isEmpty || ask.launching)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.faint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ask.agent.color.opacity(focused ? 0.6 : 0.25), lineWidth: 1))

            AttachmentChips(attachments: ask.attachments) { item in ask.attachments.removeAll { $0.id == item.id } }

            // Full labels when they fit, icons only when they don't.
            ViewThatFits(in: .horizontal) {
                optionsRow(compact: false)
                optionsRow(compact: true)
            }
            if ask.model.group == "Fable", let detail = limits.fable.detail {
                let included = if case .included = limits.fable { true } else { false }
                Label(detail, systemImage: included ? "checkmark.seal" : "creditcard")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(included ? Palette.ok : Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.row)
            }
        }
        .onAppear { focused = true }
    }

    private func optionsRow(compact: Bool) -> some View {
        HStack(spacing: 5) {
            ChipMenu(icon: nil, label: ask.agent == .claude ? "Claude" : ask.agent.name) {
                ForEach(AskModel.installedAgents, id: \.self) { kind in
                    Button(kind.name) { ask.agent = kind }
                }
            }
            ChipMenu(icon: "folder.fill", label: URL(fileURLWithPath: ask.folder).lastPathComponent, tint: Palette.warn) {
                ForEach(folders, id: \.self) { folder in
                    Button((folder as NSString).abbreviatingWithTildeInPath) { ask.folder = folder }
                }
                Divider()
                Button("Choose…") { chooseFolder() }
            }
            if ask.agent == .claude || ask.agent == .codex {
                option("cpu", ask.model, Choice.models(for: ask.agent), compact: compact, help: "Model") { ask.model = $0 }
                option("gauge.with.dots.needle.67percent", ask.effort,
                       ask.agent == .codex ? Choice.codexEfforts(model: ask.model) : Choice.efforts,
                       compact: compact, help: ask.agent == .codex ? "Reasoning" : "Effort") { ask.effort = $0 }
            }
            if ask.agent == .claude {
                option("hand.raised.fill", ask.mode, Choice.modes, compact: compact, help: "Permission mode") { ask.mode = $0 }
            }
            Spacer(minLength: 0)
            AttachButtons(screenshot: takeScreenshot) { ask.attachments += ScreenCapture.chooseFiles() }
            ChipMenu(icon: "rectangle.split.3x1", label: nil) {
                if Herdr.isRunning { Button("New herdr tab") { ask.target = .herdr } }
                Button("New Terminal window") { ask.target = .terminal }
            }
            .help(ask.target == .herdr ? "Starts in a new herdr tab" : "Starts in a new Terminal window")
        }
    }

    /// A picker chip: the icon alone while it's on its default (or when
    /// space is short), the choice's name otherwise.
    private func option(_ icon: String, _ current: Choice, _ choices: [Choice], compact: Bool, help: String,
                        select: @escaping (Choice) -> Void) -> some View {
        ChipMenu(icon: icon, label: compact || current.value == nil ? nil : current.label) {
            let ungrouped = choices.filter { $0.group == nil }
            ForEach(ungrouped, id: \.self) { choice in item(choice, current: current, select: select) }
            let groups = choices.compactMap(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(choices.filter { $0.group == group }, id: \.self) { choice in
                        item(choice, current: current, select: select)
                    }
                }
            }
        }
        .help(current.value == nil ? help : "\(help): \(current.label)")
    }

    /// A menu item, ticked when chosen, with its note (e.g. "Needs usage
    /// credits") at the side.
    @ViewBuilder
    private func item(_ choice: Choice, current: Choice, select: @escaping (Choice) -> Void) -> some View {
        Button { select(choice) } label: {
            if choice == current {
                Label(choice.label, systemImage: "checkmark")
            } else {
                Text(choice.label)
            }
        }
        .badge((choice.group == "Fable" ? limits.fable.badge : choice.note).map { Text($0) })
    }

    private func takeScreenshot() {
        Task {
            do {
                ask.attachments.append(try await ScreenCapture.capture(hiding: ui, reopen: true))
            } catch {
                store.problem = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: ask.folder)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { ask.folder = url.path }
    }
}

/// One compact row in Ask's agent list.
private struct AgentLine: View {
    let session: AgentSession
    let needsYou: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                AgentGlyph(kind: session.kind, busy: session.status == .working, size: 13)
                Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: 210, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                status.fixedSize()
                Text("· \(session.agent) · \(session.terminalName)").foregroundStyle(Palette.mute).lineLimit(1)
                Spacer(minLength: 6)
                if session.status == .working {
                    ActivityGrid(color: session.kind.color)
                    if let start = session.turnStartedAt { Elapsed(since: start) }
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.3))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(height: 30)
            .background(.white.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var status: some View {
        if needsYou || session.status == .waiting {
            Text("Needs you").fontWeight(.semibold).foregroundStyle(Palette.warn)
        } else if session.status == .working {
            switch session.activity {
            case .tool(let name): Text("Running \(name)").fontWeight(.semibold).foregroundStyle(session.kind.color)
            case .thinking(_, let verb, _): Text(verb).fontWeight(.semibold).foregroundStyle(session.kind.color)
            }
        } else {
            Text("Done").fontWeight(.semibold).foregroundStyle(Palette.ok)
        }
    }
}

private struct ChipMenu<Content: View>: View {
    let icon: String?
    let label: String?
    var tint: Color = .white
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint) }
                if let label { Text(label).lineLimit(1).frame(maxWidth: 90) }
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Palette.mute)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
        }
        // The button style keeps the custom pill label; the default
        // borderless style redraws it as plain text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
