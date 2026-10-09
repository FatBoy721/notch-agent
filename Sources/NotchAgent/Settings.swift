import AppKit
import Carbon.HIToolbox
import CoreServices
import SwiftUI

/// The Settings window, in GlassCode's look: frosted glass behind two
/// floating rounded panels (sections, then the page), hairline borders,
/// uppercase section labels over cards. One window, reused.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var store: Store?
    private var services: Services?

    /// Called once at launch with the app's models.
    func configure(store: Store, services: Services) {
        self.store = store
        self.services = services
    }

    enum Tab: String, CaseIterable {
        case general, agents, servers, music, about

        var title: String {
            switch self {
            case .general: "General"
            case .agents: "Agents"
            case .servers: "Agent servers"
            case .music: "Music"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .agents: "sparkles"
            case .servers: "server.rack"
            case .music: "music.note"
            case .about: "info.circle"
            }
        }
    }

    func show(_ tab: Tab = .general) {
        guard let store, let services else { return }
        let root = SettingsView(store: store, music: services.music, tab: tab)
        if let hosting = hostingView {
            hosting.rootView = root
        }
        if window == nil {
            window = Self.glassWindow(title: "Notch Agent Settings", size: NSSize(width: 780, height: 600), root: root)
        }
        focus()
    }

    private var hostingView: NSHostingView<SettingsView>? { Self.hosting(in: window) }

    /// A window in GlassCode's look: no title bar, dark, its whole content
    /// on glass (Liquid Glass on macOS 26 and later, frosted before). The
    /// setup window uses it too.
    static func glassWindow<Root: View>(title: String, size: NSSize, root: Root) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.contentView = hosting
            window.contentView = glass
        } else {
            let glass = NSVisualEffectView()
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            hosting.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: glass.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            window.contentView = glass
        }
        window.center()
        return window
    }

    /// The SwiftUI view inside a window `glassWindow` made.
    static func hosting<Root: View>(in window: NSWindow?) -> NSHostingView<Root>? {
        if #available(macOS 26.0, *), let glass = window?.contentView as? NSGlassEffectView {
            return glass.contentView as? NSHostingView<Root>
        }
        return window?.contentView?.subviews.first as? NSHostingView<Root>
    }

    /// Brings Settings forward with the keyboard, so typing (and recording
    /// a shortcut) reaches it. `activate()` is the macOS 14 call; the old
    /// `activate(ignoringOtherApps:)` is ignored there, which left the
    /// window up but without the keyboard.
    func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// GlassCode's palette: neutral, no brand accent.
enum Theme {
    static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.82)
    static let card = Color.white.opacity(0.03)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.13)
    static let hairline = Color.white.opacity(0.06)
    static let text = Color(red: 0xE8 / 255, green: 0xEA / 255, blue: 0xF0 / 255)
    static let secondary = Color(red: 0x6B / 255, green: 0x6F / 255, blue: 0x7C / 255)
    static let active = Color.white.opacity(0.06)
    static let hover = Color.white.opacity(0.04)
    /// Neutral: switches and the one main button per row.
    static let control = Color.white.opacity(0.62)
}

/// A rounded panel floating on the window's glass, with GlassCode's rim
/// (bright along the top edge) and soft shadow.
struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .glassRim(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 8)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var music: MusicStore
    @State var tab: SettingsWindow.Tab

    var body: some View {
        HStack(spacing: 8) {
            GlassPanel { Sidebar(tab: $tab) }
            GlassPanel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        switch tab {
                        case .general: GeneralSettingsPage(store: store)
                        case .agents: AgentsSettingsPage(store: store)
                        case .servers: ServersSettingsPage(store: store)
                        case .music: MusicSettingsPage(music: music)
                        case .about: AboutSettingsPage()
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.top)
                .softTopEdge()
                .id(tab)
            }
        }
        .padding(8)
        .frame(width: 780, height: 600)
        .foregroundStyle(Theme.text)
        .tint(Theme.control)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Building blocks

struct SettingsLogo: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: BrandImage.bundled("notch-agent") ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.2, height: size * 1.2)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

private struct Sidebar: View {
    @Binding var tab: SettingsWindow.Tab
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                SettingsLogo(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notch Agent").font(.system(size: 13, weight: .semibold))
                    Text("Settings").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 20)
            SectionLabel("Preferences").padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(SettingsWindow.Tab.allCases, id: \.self) { item in
                NavRow(tab: item, selected: tab == item, selection: selection) {
                    withAnimation(Motion.glide) { tab = item }
                }
            }
            Spacer()
            Text("Version \(Updates.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(12)
        }
        .padding(.horizontal, 8)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct NavRow: View {
    let tab: SettingsWindow.Tab
    let selected: Bool
    /// One highlight gliding between rows, as in GlassCode's sidebar.
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .frame(width: 18)
                Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.active)
                        .glassRim(RoundedRectangle(cornerRadius: 7))
                        .matchedGeometryEffect(id: "sidebar-selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "■ SESSIONS": a small square (or the service's logo) and letter-spaced
/// caps.
struct SectionLabel: View {
    let text: String
    var logo: NSImage?

    init(_ text: String, logo: NSImage? = nil) {
        self.text = text
        self.logo = logo
    }

    var body: some View {
        HStack(spacing: 7) {
            if let logo {
                Image(nsImage: logo).resizable().interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Rectangle().fill(Theme.secondary).frame(width: 6, height: 6)
            }
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(Theme.secondary)
        }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
}

/// A labelled card of rows. Each row draws a hairline under itself; the
/// card clips the last one.
struct SettingsSection<Content: View>: View {
    let title: String
    var logo: NSImage?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title, logo: logo)
            VStack(spacing: 0) { content }
                .padding(.bottom, -1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .glassRim(RoundedRectangle(cornerRadius: 10))
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

extension SettingsRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, trailing: trailing)
    }
}

/// A numbered step's circle, for setup lists.
struct StepNumber: View {
    let number: Int
    let done: Bool
    var tint: Color = .white.opacity(0.85)

    var body: some View {
        ZStack {
            Circle().fill(done ? tint.opacity(0.2) : .white.opacity(0.07))
            if done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            } else {
                Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct PillButtonStyleSettings: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(prominent ? Color.white.opacity(0.88) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(prominent ? .clear : Theme.border, lineWidth: 1))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Theme.text)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// A plain text link in the accent color.
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text.opacity(0.85))
    }
}

/// A colored dot and a word.
struct Status: View {
    enum State { case good, warning, off }
    let state: State
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .good: .green
        case .warning: .orange
        case .off: .white.opacity(0.25)
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - General

private struct GeneralSettingsPage: View {
    @ObservedObject var store: Store
    @State private var opensAtLogin = LoginItem.isEnabled
    @AppStorage(Store.dropOnFinishKey) private var dropOnFinish = true

    var body: some View {
        PageHeader(title: "General", subtitle: "How the notch starts, behaves and opens.")
        SettingsSection(title: "Startup") {
            SettingsRow(title: "Open at login",
                        subtitle: LoginItem.isAvailable ? "Start Notch Agent when you log in." : "Only for the installed app in Applications.") {
                Toggle("", isOn: Binding(get: { opensAtLogin }, set: { enable in
                    do {
                        try LoginItem.set(enable)
                    } catch {
                        store.problem = "Couldn't change Open at login: \(error.localizedDescription)"
                    }
                    opensAtLogin = LoginItem.isEnabled
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!LoginItem.isAvailable)
            }
        }
        SettingsSection(title: "Notch") {
            SettingsRow(title: "Drop down when an agent finishes",
                        subtitle: "Shows the reply for 6 seconds; hover to keep it.") {
                Toggle("", isOn: $dropOnFinish).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
        SettingsSection(title: "Shortcut", footer: "Works from any app. Use ⌘, ⌥ or ⌃ with a key (or an F-key) so it can't fire while typing.") {
            SettingsRow(title: "Ask an agent", subtitle: "Opens the notch on Ask, ready to type.") {
                ShortcutRecorder()
            }
        }
    }
}

/// Click, then press the new keys; Esc cancels.
struct ShortcutRecorder: View {
    /// Brings the recorder's window forward with the keyboard.
    var focus: @MainActor () -> Void = { SettingsWindow.shared.focus() }
    @State private var shortcut = Shortcut.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { recording ? stop() : start() }) {
                HStack(spacing: 4) {
                    if recording {
                        Text("Press keys…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    } else {
                        ForEach(shortcut.symbols, id: \.self) { Kbd($0) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minWidth: 96)
                .background(.white.opacity(recording ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? Theme.borderStrong : Theme.border, lineWidth: recording ? 1.5 : 1))
            }
            .buttonStyle(.plain)
            .help(recording ? "Press the new shortcut, or Esc to cancel" : "Click to change")
            if shortcut != .standard && !recording {
                LinkButton(title: "Reset") {
                    Shortcut.current = .standard
                    shortcut = .standard
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.paused = true
        focus()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if let new = Shortcut(event: event) {
                Shortcut.current = new
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKey.paused = false
    }
}

// MARK: - Agents

/// A supported agent CLI: how to tell it's installed and signed in, and
/// how to get it.
struct AgentEntry: Identifiable {
    let kind: AgentKind
    /// Copy-paste install command, when the agent has a standard one.
    let install: String?
    let website: String
    /// Files under the home folder that only exist once signed in; nil when
    /// the agent signs in some other way (API keys, its own app).
    let credentials: [String]?
    let signIn: String
    /// A desktop app that counts as installed too.
    var app: String?

    var id: String { kind.id }

    static let main: [AgentEntry] = [
        AgentEntry(kind: .claude, install: "npm install -g @anthropic-ai/claude-code", website: "https://claude.com/claude-code",
                   credentials: [".claude/.credentials.json"], signIn: "Run claude, then /login"),
        AgentEntry(kind: .codex, install: "npm install -g @openai/codex", website: "https://github.com/openai/codex",
                   credentials: [".codex/auth.json"], signIn: "Run codex login"),
        AgentEntry(kind: .gemini, install: "npm install -g @google/gemini-cli", website: "https://github.com/google-gemini/gemini-cli",
                   credentials: [".gemini/oauth_creds.json", ".gemini/google_accounts.json"], signIn: "Run gemini and sign in with Google"),
        AgentEntry(kind: AgentKind(id: "cursor"), install: "curl https://cursor.com/install -fsS | bash", website: "https://cursor.com/cli",
                   credentials: nil, signIn: "Run cursor-agent login"),
        AgentEntry(kind: AgentKind(id: "grok"), install: "curl -fsSL https://x.ai/cli/install.sh | bash", website: "https://x.ai/cli",
                   credentials: nil, signIn: "Run grok and log in (needs SuperGrok or X Premium+)"),
        AgentEntry(kind: AgentKind(id: "muse"), install: "curl -fsSL https://dev.meta.ai/install.sh | bash",
                   website: "https://developer.meta.com/ai/products/muse-code/",
                   credentials: nil, signIn: "Run muse; it signs in with your Meta developer account"),
        AgentEntry(kind: AgentKind(id: "zcode"), install: nil, website: "https://zcode.z.ai",
                   credentials: nil, signIn: "Open ZCode and sign in with Z.ai", app: "/Applications/ZCode.app"),
        AgentEntry(kind: AgentKind(id: "opencode"), install: "npm install -g opencode-ai", website: "https://opencode.ai",
                   credentials: [".local/share/opencode/auth.json"], signIn: "Run opencode auth login"),
        AgentEntry(kind: AgentKind(id: "copilot"), install: "npm install -g @github/copilot", website: "https://github.com/features/copilot/cli",
                   credentials: nil, signIn: "Run copilot, then /login"),
        AgentEntry(kind: AgentKind(id: "kimi"), install: nil, website: "https://www.kimi.com/code",
                   credentials: [".kimi-code/credentials"], signIn: "Run kimi login"),
    ]

    /// Less common ones, folded away.
    static let more: [AgentEntry] = [
        AgentEntry(kind: AgentKind(id: "aider"), install: "python3 -m pip install aider-install && aider-install", website: "https://aider.chat",
                   credentials: nil, signIn: "Set your model provider's API key"),
        AgentEntry(kind: AgentKind(id: "amp"), install: "npm install -g @sourcegraph/amp", website: "https://ampcode.com",
                   credentials: nil, signIn: "Run amp and follow the login link"),
        AgentEntry(kind: AgentKind(id: "droid"), install: nil, website: "https://factory.ai", credentials: nil, signIn: "Run droid and sign in"),
        AgentEntry(kind: AgentKind(id: "cline"), install: nil, website: "https://cline.bot", credentials: nil, signIn: "See its website"),
    ]
}

/// What Settings found for one agent.
struct AgentState: Sendable {
    let installed: Bool
    /// nil: can't tell (the agent signs in some other way).
    let signedIn: Bool?

    /// Every agent Settings lists, by id. Off the main thread: file checks
    /// plus one Keychain lookup (Claude Code keeps its login there, not in
    /// a file).
    static func scan() async -> [String: AgentState] {
        let entries = (AgentEntry.main + AgentEntry.more).map { ($0.id, AskModel.executable(for: $0.kind), $0.credentials, $0.app) }
        return await Task.detached { () -> [String: AgentState] in
            let home = NSHomeDirectory()
            var result: [String: AgentState] = [:]
            for (id, executable, credentials, app) in entries {
                let installed = AskModel.installedPath(of: executable) != nil || app.map { FileManager.default.fileExists(atPath: $0) } == true
                var signedIn = credentials.map { $0.contains { FileManager.default.fileExists(atPath: "\(home)/\($0)") } }
                if id == "claude", signedIn == false { signedIn = KeychainProbe.exists(service: "Claude Code-credentials") }
                result[id] = AgentState(installed: installed, signedIn: signedIn)
            }
            return result
        }.value
    }
}

private struct AgentsSettingsPage: View {
    @ObservedObject var store: Store
    @State private var states: [String: AgentState] = [:]
    @State private var copied: String?
    @State private var showsMore = false

    var body: some View {
        PageHeader(title: "Agents", subtitle: "Coding agents the notch can show, start and talk to.")
        SettingsSection(title: "Live status",
                        footer: "Hooks give Claude Code and Codex live status, approvals and replies (Codex asks once, inside Codex, to trust them). Agents in herdr panes show up on their own.") {
            SettingsRow(title: "Claude Code and Codex hooks") {
                HStack(spacing: 10) {
                    Status(state: store.hooksInstalled ? .good : .off, text: store.hooksInstalled ? "Installed" : "Not installed")
                    Button(store.hooksInstalled ? "Remove" : "Install") { store.setHooksInstalled(!store.hooksInstalled) }
                        .buttonStyle(PillButtonStyleSettings(prominent: !store.hooksInstalled))
                }
            }
            SettingsRow(title: "herdr", subtitle: "Terminal workspace for agents") {
                Status(state: Herdr.binary != nil ? .good : .off,
                       text: Herdr.binary != nil ? (Herdr.isRunning ? "Running" : "Installed") : "Not found")
            }
        }
        SettingsSection(title: "Coding agents") {
            ForEach(AgentEntry.main) { row($0) }
        }
        SettingsSection(title: "More agents") {
            Button { withAnimation(Motion.calm) { showsMore.toggle() } } label: {
                SettingsRow(title: "Aider, Amp, Droid and Cline", subtitle: "Less common agents") {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(showsMore ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsMore {
                ForEach(AgentEntry.more) { row($0) }
            }
        }
        .task { states = await AgentState.scan() }
    }

    private func row(_ agent: AgentEntry) -> some View {
        let state = states[agent.id]
        let subtitle: String? = switch (state?.installed, state?.signedIn) {
        case (true?, false?): agent.signIn
        default: nil
        }
        return SettingsRow(title: agent.kind.name, subtitle: subtitle) {
            AgentGlyph(kind: agent.kind, size: 14).frame(width: 22)
        } trailing: {
            HStack(spacing: 12) {
                if let state, !state.installed {
                    if let install = agent.install {
                        LinkButton(title: copied == agent.id ? "Copied ✓" : "Copy install") {
                            copy(install)
                            copied = agent.id
                        }
                        .help(install)
                    }
                    LinkButton(title: "Website ↗") { NSWorkspace.shared.open(URL(string: agent.website)!) }
                }
                if let state {
                    if !state.installed {
                        Status(state: .off, text: "Not installed")
                    } else if let signedIn = state.signedIn {
                        Status(state: signedIn ? .good : .warning, text: signedIn ? "Signed in" : "Not signed in")
                    } else {
                        Status(state: .good, text: "Installed")
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

/// Whether a Keychain item exists, without reading its secret.
enum KeychainProbe {
    static func exists(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Agent servers

private struct ServersSettingsPage: View {
    @ObservedObject var store: Store
    @State private var copied = false
    @State private var openClawInstalled: Bool?

    private static let alwaysOn = "Runs best on an always-on machine (a Mac mini or a server), not on this Mac, so its chats keep working while this Mac sleeps."

    var body: some View {
        PageHeader(title: "Agent servers", subtitle: "Personal agents that live on another machine and chat with you on Telegram and more.")
        SettingsSection(title: "Hermes", logo: BrandImage.bundled("hermes"), footer: "Chats appear in Threads; ask and reply from the notch. Replies to Telegram chats stay in Hermes. Installing Hermes on this Mac isn't recommended. " + Self.alwaysOn) {
            SettingsRow(title: "Connection", subtitle: store.hermesConnected ? UserDefaults.standard.string(forKey: HermesAPI.urlKey) : "Your Hermes backend (`hermes serve`)") {
                AgentGlyph(kind: .hermes, size: 14).frame(width: 22)
            } trailing: {
                HStack(spacing: 10) {
                    Status(state: store.hermesConnected ? .good : .off, text: store.hermesConnected ? "Connected" : "Not connected")
                    if store.hermesConnected {
                        Button("Disconnect") { store.disconnectHermes() }.buttonStyle(PillButtonStyleSettings())
                    } else {
                        Button("Connect…") { store.connectHermes() }.buttonStyle(PillButtonStyleSettings(prominent: true))
                    }
                }
            }
            if store.hermesConnected, let user = UserDefaults.standard.string(forKey: HermesAPI.userKey) {
                SettingsRow(title: "Signed in as") { Text(user).foregroundStyle(Theme.secondary) }
            }
            SettingsRow(title: "Set up Hermes") {
                LinkButton(title: "Guide ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/NousResearch/hermes-agent")!) }
            }
        }
        SettingsSection(title: "OpenClaw", logo: BrandImage.bundled("openclaw"), footer: "Showing OpenClaw chats in the notch is coming. " + Self.alwaysOn) {
            SettingsRow(title: "OpenClaw", subtitle: "Personal agent on WhatsApp, Telegram, iMessage, Discord and more") {
                AgentGlyph(kind: AgentKind(id: "openclaw"), size: 14).frame(width: 22)
            } trailing: {
                HStack(spacing: 12) {
                    if openClawInstalled == false {
                        LinkButton(title: copied ? "Copied ✓" : "Copy install") {
                            copy("npm install -g openclaw@latest")
                            copied = true
                        }
                    }
                    LinkButton(title: "Docs ↗") { NSWorkspace.shared.open(URL(string: "https://docs.openclaw.ai")!) }
                    if let openClawInstalled {
                        Status(state: openClawInstalled ? .good : .off, text: openClawInstalled ? "On this Mac" : "Not on this Mac")
                    }
                }
            }
        }
        SettingsSection(title: "Open WebUI", footer: "Showing Open WebUI chats in the notch is coming.") {
            SettingsRow(title: "Open WebUI", subtitle: "Self-hosted ChatGPT-style app with agents and chat bots") {
                Image(systemName: "globe").foregroundStyle(Theme.secondary).frame(width: 22)
            } trailing: {
                LinkButton(title: "Website ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/open-webui/open-webui")!) }
            }
        }
        .task { openClawInstalled = await Task.detached { AskModel.installedPath(of: "openclaw") != nil }.value }
    }
}

// MARK: - Music

/// macOS's Automation permission: may this app control (send Apple
/// Events to) another app. The notch reads and controls the players that way.
enum AutomationPermission: Sendable {
    case allowed, denied, notAsked, notRunning, unknown

    /// `ask` shows macOS's prompt when it hasn't been answered yet; it
    /// blocks until the user answers, so call it off the main thread.
    static func check(_ bundleID: String, ask: Bool) -> AutomationPermission {
        var target = AEAddressDesc()
        let id = Data(bundleID.utf8)
        let created = id.withUnsafeBytes { AECreateDesc(typeApplicationBundleID, $0.baseAddress, id.count, &target) }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// Where one Automation permission stands, and the button that moves it
/// on: Allow… (macOS's prompt), Open the app (macOS only asks while it
/// runs), or Privacy Settings once it's been turned off. Music settings
/// and the setup window both use it.
struct AutomationControl: View {
    let bundleID: String
    let app: String
    let state: AutomationPermission?
    /// Re-checks every permission on the page; `ask` names the one to prompt for.
    let refresh: (_ ask: String?) async -> Void

    var body: some View {
        switch state {
        case .allowed:
            Status(state: .good, text: "Allowed")
        case .denied:
            HStack(spacing: 10) {
                Status(state: .warning, text: "Turned off")
                Button("Privacy Settings") { NSWorkspace.shared.open(AutomationPermission.settingsURL) }
                    .buttonStyle(PillButtonStyleSettings())
            }
        case .notAsked:
            Button("Allow…") { Task { await refresh(bundleID) } }
                .buttonStyle(PillButtonStyleSettings(prominent: true))
        case .notRunning:
            Button("Open \(app)") {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        await refresh(nil)
                    }
                }
            }
            .buttonStyle(PillButtonStyleSettings())
            .help("macOS asks for this permission only while \(app) is open")
        case .unknown:
            Status(state: .off, text: "Unknown")
        case nil:
            ProgressView().controlSize(.small)
        }
    }
}

private struct MusicSettingsPage: View {
    @ObservedObject var music: MusicStore
    @State private var clientID = UserDefaults.standard.string(forKey: SpotifyAPI.clientIDKey) ?? ""
    @State private var copied = false
    @State private var permissions: [String: AutomationPermission] = [:]

    private static let spotify = NowPlaying.Player.spotify.bundleID
    private static let appleMusic = NowPlaying.Player.music.bundleID

    private var spotifyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotify) != nil
    }

    var body: some View {
        PageHeader(title: "Music", subtitle: "What's playing, lyrics and controls in the notch.")
        SettingsSection(title: "Spotify", logo: BrandImage.app(Self.spotify),
                        footer: "Steps 1–2 give you what's playing, controls and lyrics. Step 3 needs your own free Spotify developer app (its owner needs Premium); Spotify only shares the queue and library with those.") {
            SettingsRow(title: "Spotify app") {
                StepNumber(number: 1, done: spotifyInstalled)
            } trailing: {
                if spotifyInstalled {
                    Status(state: .good, text: "Installed")
                } else {
                    LinkButton(title: "Get Spotify ↗") { NSWorkspace.shared.open(URL(string: "https://www.spotify.com/download/mac/")!) }
                }
            }
            SettingsRow(title: "Let Notch Agent control it") {
                StepNumber(number: 2, done: permissions[Self.spotify] == .allowed)
            } trailing: {
                AutomationControl(bundleID: Self.spotify, app: "Spotify", state: permissions[Self.spotify], refresh: refreshPermissions)
            }
            SettingsRow(title: "Up Next, ♥, search and playlists", subtitle: spotifySubtitle) {
                StepNumber(number: 3, done: music.spotify == .on)
            } trailing: {
                if music.spotify == .on {
                    Button("Disconnect") { music.disconnectSpotify() }.buttonStyle(PillButtonStyleSettings())
                } else {
                    Status(state: .off, text: music.spotify == .checking ? "Checking…" : "Not connected")
                }
            }
            if music.spotify != .on {
                SettingsRow(title: "a. Create an app, tick Web API") {
                    LinkButton(title: "Open dashboard ↗") { NSWorkspace.shared.open(SpotifyAPI.dashboardURL) }
                }
                SettingsRow(title: "b. Add this redirect URI", subtitle: SpotifyAPI.redirectURI) {
                    LinkButton(title: copied ? "Copied ✓" : "Copy") {
                        copy(SpotifyAPI.redirectURI)
                        copied = true
                    }
                }
                SettingsRow(title: "c. Paste its Client ID") {
                    HStack(spacing: 8) {
                        TextField("", text: $clientID, prompt: Text("Client ID"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(width: 210)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Button("Connect") { music.connectSpotify(clientID: clientID) }
                            .buttonStyle(PillButtonStyleSettings(prominent: true))
                            .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || music.spotify == .checking)
                    }
                }
            }
        }
        SettingsSection(title: "Apple Music", logo: BrandImage.app(Self.appleMusic),
                        footer: "No account needed. Lyrics come from LRCLIB, a free lyrics library; only the song's title, artist and length are sent.") {
            SettingsRow(title: "Let Notch Agent control Music") {
                StepNumber(number: 1, done: permissions[Self.appleMusic] == .allowed)
            } trailing: {
                AutomationControl(bundleID: Self.appleMusic, app: "Music", state: permissions[Self.appleMusic], refresh: refreshPermissions)
            }
            SettingsRow(title: "Play something", subtitle: "It shows in the notch, with lyrics") {
                StepNumber(number: 2, done: music.nowPlaying?.player == .music)
            } trailing: {
                EmptyView()
            }
        }
        .task { await refreshPermissions(ask: nil) }
    }

    private var spotifySubtitle: String? {
        switch music.spotify {
        case .failed(let message): message
        case .connecting: "Finish signing in in your browser"
        default: nil
        }
    }

    /// Checks both players; `ask` names the one to show macOS's prompt for.
    private func refreshPermissions(ask: String?) async {
        let ids = [Self.spotify, Self.appleMusic]
        let found = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, AutomationPermission.check($0, ask: $0 == ask)) })
        }.value
        permissions = found
    }
}

// MARK: - About

/// Update checks against the app's GitHub releases. No repository yet, so
/// the button says so; set `repository` ("owner/name") when there is one.
enum Updates {
    static let repository: String? = nil

    enum Result {
        case notSetUp, upToDate(String), available(version: String, page: URL), failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func check() async -> Result {
        guard let repository, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return .notSetUp }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String,
              let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else {
            return .failed("Couldn't reach GitHub. Try again later.")
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
            ? .available(version: latest, page: page) : .upToDate(currentVersion)
    }
}

private struct AboutSettingsPage: View {
    private static let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchAgent.log")
    @State private var update: Updates.Result?
    @State private var checking = false

    var body: some View {
        HStack(spacing: 16) {
            SettingsLogo(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Notch Agent").font(.system(size: 22, weight: .bold))
                Text("Version \(Updates.currentVersion)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Text("Your coding agents, music and Hermes, in the notch.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
        SettingsSection(title: "Updates") {
            SettingsRow(title: "Check for updates", subtitle: updateText) {
                Button(checking ? "Checking…" : "Check now") {
                    checking = true
                    Task {
                        update = await Updates.check()
                        checking = false
                    }
                }
                .buttonStyle(PillButtonStyleSettings(prominent: true))
                .disabled(checking)
            }
            if case .available(_, let page) = update {
                SettingsRow(title: "Download the new version") {
                    LinkButton(title: "Open ↗") { NSWorkspace.shared.open(page) }
                }
            }
        }
        SettingsSection(title: "Troubleshooting") {
            SettingsRow(title: "Setup", subtitle: "The first-run walkthrough: agents, permissions, shortcut") {
                Button("Run setup again") { SetupWindow.shared.show() }
                    .buttonStyle(PillButtonStyleSettings())
            }
            SettingsRow(title: "Log file", subtitle: "What the app did, for when something looks wrong") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Self.log]) }
                    .buttonStyle(PillButtonStyleSettings())
            }
            SettingsRow(title: "Quit Notch Agent") {
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PillButtonStyleSettings())
            }
        }
    }

    private var updateText: String? {
        switch update {
        case nil: nil
        case .notSetUp?: "Updates aren't set up yet. They'll come from GitHub once Notch Agent has a page there."
        case .upToDate(let version)?: "You're up to date (\(version))."
        case .available(let version, _)?: "Version \(version) is available."
        case .failed(let message)?: message
        }
    }
}
