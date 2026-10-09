import AppKit
import SwiftUI

/// The first-run setup: a short walk through what the notch does and the
/// few things it needs, in the Settings window's look. It opens once, on a
/// new user's first launch; Settings › About can run it again.
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?
    private var store: Store?
    /// The notch's state, so the last step can see it being tried.
    private var ui: NotchUI?

    /// Finished or skipped: it doesn't open by itself again.
    static let doneKey = "setupDone"

    func configure(store: Store, ui: NotchUI?) {
        self.store = store
        self.ui = ui
    }

    /// On first launch only. Someone updating from a version without setup
    /// already has things working, so it's marked done for them instead.
    func showIfNeeded(returningUser: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        if returningUser || HookInstaller.isInstalled {
            defaults.set(true, forKey: Self.doneKey)
            return
        }
        show()
    }

    func show() {
        guard let store else { return }
        let root = SetupView(store: store, ui: ui) { [weak self] in self?.finish() }
        if let hosting: NSHostingView<SetupView> = SettingsWindow.hosting(in: window) {
            hosting.rootView = root
        } else {
            window = SettingsWindow.glassWindow(title: "Set up Notch Agent", size: NSSize(width: 640, height: 540), root: root)
        }
        focus()
    }

    /// Forward and with the keyboard (for recording a shortcut).
    func focus() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }
}

/// One page per step, with Back / Continue along the bottom and the steps
/// as dots along the top.
struct SetupView: View {
    @ObservedObject var store: Store
    let ui: NotchUI?
    let finish: () -> Void
    @State private var step = Step.welcome
    /// Which way the pages slide.
    @State private var forward = true

    enum Step: Int, CaseIterable {
        case welcome, agents, permissions, personalize, tryIt
    }

    var body: some View {
        GlassPanel {
            VStack(spacing: 0) {
                progress
                    .padding(.top, 38)
                ZStack {
                    page
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .padding(8)
        .frame(width: 640, height: 540)
        .foregroundStyle(Theme.text)
        .tint(Theme.control)
        .environment(\.colorScheme, .dark)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(.white.opacity(item == step ? 0.85 : item.rawValue < step.rawValue ? 0.4 : 0.14))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .animation(Motion.glide, value: step)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .agents: AgentsStep(store: store)
        case .permissions: PermissionsStep()
        case .personalize: PersonalizeStep(store: store)
        case .tryIt:
            if let ui { TryItStep(ui: ui) } else { TryItStep.Offline() }
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip setup", action: finish)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Spacer()
            if step != Step.allCases.first {
                Button("Back") { go(-1) }.buttonStyle(PillButtonStyleSettings())
            }
            Button(step == Step.allCases.last ? "Finish" : "Continue") {
                step == Step.allCases.last ? finish() : go(1)
            }
            .buttonStyle(PillButtonStyleSettings(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(Motion.calm) { step = next }
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                SettingsLogo(size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Notch Agent").font(.system(size: 22, weight: .bold))
                    Text("Your coding agents, live in the notch.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            NotchPreview()
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "rectangle.stack", title: "Every agent at a glance",
                        detail: "Claude Code, Codex, herdr panes and more, with what each is doing right now.")
                Feature(symbol: "checkmark.bubble", title: "Approve and reply from the notch",
                        detail: "Answer an agent's question or okay its change without finding its terminal.")
                Feature(symbol: "music.note", title: "Music, usage and stats",
                        detail: "Your plan limits and what's playing, one hover away.")
            }
            .frame(maxWidth: 440)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .glassRim(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A little screen whose notch acts out a run: idle, an agent thinking,
/// then done.
private struct NotchPreview: View {
    private enum Phase: CaseIterable { case idle, working, done }
    @State private var phase = Phase.idle

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.24, blue: 0.36), Color(red: 0.36, green: 0.22, blue: 0.3)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            notch
        }
        .frame(width: 380, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                let all = Phase.allCases
                let next = all[((all.firstIndex(of: phase) ?? 0) + 1) % all.count]
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { phase = next }
            }
        }
    }

    private var notch: some View {
        let open = phase != .idle
        return HStack(spacing: 8) {
            if open {
                AgentGlyph(kind: .claude, busy: phase == .working, size: 13)
                Text(phase == .working ? "Claude Code · Thinking…" : "Claude Code · Done")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                if phase == .done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: open ? 250 : 110, height: open ? 32 : 22)
        .background(NotchShape(radius: open ? 12 : 8, ear: 6).fill(.black))
        .foregroundStyle(.white)
        .transition(.opacity)
    }
}

private struct AgentsStep: View {
    @ObservedObject var store: Store
    @State private var states: [String: AgentState]?

    private var found: [AgentEntry] {
        guard let states else { return [] }
        return (AgentEntry.main + AgentEntry.more).filter { states[$0.id]?.installed == true }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(title: "Connect your agents",
                           subtitle: "The notch finds agents running in your terminals by itself. Claude Code and Codex can also report live: what they're doing, questions and approvals.")
                    .frame(maxWidth: .infinity)
                SettingsSection(title: "Live status",
                                footer: "Adds a small hook to Claude Code's and Codex's settings (a backup is kept). Codex asks once, inside Codex, to trust it. Remove it any time in Settings › Agents.") {
                    SettingsRow(title: "Claude Code and Codex", subtitle: "Live status, approvals and replies") {
                        HStack(spacing: 10) {
                            Status(state: store.hooksInstalled ? .good : .off, text: store.hooksInstalled ? "Connected" : "Not connected")
                            if !store.hooksInstalled {
                                Button("Connect") { store.setHooksInstalled(true) }
                                    .buttonStyle(PillButtonStyleSettings(prominent: true))
                            }
                        }
                    }
                    SettingsRow(title: "herdr", subtitle: "If you run agents in herdr panes, they show up with no setup") {
                        Status(state: Herdr.binary != nil ? .good : .off, text: Herdr.binary != nil ? "Found" : "Not installed")
                    }
                }
                SettingsSection(title: "Found on this Mac") {
                    if states == nil {
                        SettingsRow(title: "Looking for agents…") { ProgressView().controlSize(.small) }
                    } else if found.isEmpty {
                        SettingsRow(title: "No coding agents yet",
                                    subtitle: "Install one (Claude Code or Codex works best), then it shows up here and in the notch.") {
                            LinkButton(title: "Copy Claude Code install") { copy(AgentEntry.main[0].install ?? "") }
                        }
                    } else {
                        ForEach(found) { agent in
                            let state = states?[agent.id]
                            SettingsRow(title: agent.kind.name, subtitle: state?.signedIn == false ? agent.signIn : nil) {
                                AgentGlyph(kind: agent.kind, size: 14).frame(width: 22)
                            } trailing: {
                                switch state?.signedIn {
                                case true?: Status(state: .good, text: "Signed in")
                                case false?: Status(state: .warning, text: "Not signed in")
                                case nil: Status(state: .good, text: "Installed")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .task { states = await AgentState.scan() }
    }
}

/// Only the permissions that apply on this Mac, each with what it's for.
/// All optional: the notch works without them, just with less.
private struct PermissionsStep: View {
    private struct App: Identifiable {
        let bundleID: String
        let name: String
        let purpose: String
        var id: String { bundleID }
    }

    @State private var automation: [String: AutomationPermission] = [:]
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    /// Terminals the notch types replies into, when they're installed.
    /// herdr, tmux and WezTerm need no permission.
    private static let terminals: [App] = [
        App(bundleID: "com.apple.Terminal", name: "Terminal", purpose: "Type your replies into agents running in Terminal"),
        App(bundleID: "com.googlecode.iterm2", name: "iTerm2", purpose: "Type your replies into agents running in iTerm2"),
        App(bundleID: "com.mitchellh.ghostty", name: "Ghostty", purpose: "Type your replies into agents running in Ghostty"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        .filter { $0.bundleID != "com.mitchellh.ghostty" || TerminalBridge.ghosttyIsScriptable }

    private static let players: [App] = [
        App(bundleID: "com.spotify.client", name: "Spotify", purpose: "Show and control what's playing, with lyrics"),
        App(bundleID: "com.apple.Music", name: "Music", purpose: "Show and control what's playing, with lyrics"),
    ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }

    private static let screenRecordingURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(title: "A few permissions",
                           subtitle: "Each one is optional. macOS asks you once for each; you can change them later in System Settings › Privacy & Security.")
                    .frame(maxWidth: .infinity)
                if !Self.terminals.isEmpty {
                    SettingsSection(title: "Replies from the notch",
                                    footer: "Agents in herdr, tmux or WezTerm need nothing here.") {
                        ForEach(Self.terminals) { row($0) }
                    }
                }
                if !Self.players.isEmpty {
                    SettingsSection(title: "Music") {
                        ForEach(Self.players) { row($0) }
                    }
                }
                SettingsSection(title: "Screenshots",
                                footer: "If you allow it after the first ask, macOS may want Notch Agent restarted before it takes effect.") {
                    SettingsRow(title: "Screen Recording", subtitle: "Attach a screenshot to a prompt or reply with one click") {
                        if screenRecording {
                            Status(state: .good, text: "Allowed")
                        } else {
                            HStack(spacing: 10) {
                                Button("Allow…") {
                                    // The first time this shows macOS's prompt; after
                                    // that only System Settings can change it.
                                    if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(Self.screenRecordingURL) }
                                    screenRecording = CGPreflightScreenCaptureAccess()
                                }
                                .buttonStyle(PillButtonStyleSettings(prominent: true))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .task { await refresh(nil) }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenRecording = CGPreflightScreenCaptureAccess()
            Task { await refresh(nil) }
        }
    }

    private func row(_ app: App) -> some View {
        SettingsRow(title: app.name, subtitle: app.purpose) {
            BrandImage.app(app.bundleID).map { Image(nsImage: $0).resizable().frame(width: 22, height: 22) }
        } trailing: {
            AutomationControl(bundleID: app.bundleID, app: app.name, state: automation[app.bundleID], refresh: refresh)
        }
    }

    private func refresh(_ ask: String?) async {
        let ids = (Self.terminals + Self.players).map(\.bundleID)
        automation = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, AutomationPermission.check($0, ask: $0 == ask)) })
        }.value
    }
}

private struct PersonalizeStep: View {
    @ObservedObject var store: Store
    @State private var opensAtLogin = LoginItem.isEnabled
    @AppStorage(Store.dropOnFinishKey) private var dropOnFinish = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(title: "Make it yours", subtitle: "All of these live in Settings too, if you change your mind.")
                    .frame(maxWidth: .infinity)
                SettingsSection(title: "Shortcut", footer: "Works from any app. Use ⌘, ⌥ or ⌃ with a key (or an F-key).") {
                    SettingsRow(title: "Ask an agent", subtitle: "Opens the notch ready to type a prompt") {
                        ShortcutRecorder(focus: { SetupWindow.shared.focus() })
                    }
                }
                SettingsSection(title: "Behavior") {
                    SettingsRow(title: "Open at login", subtitle: LoginItem.isAvailable ? "Start Notch Agent when you log in" : "Only for the installed app in Applications") {
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
                    SettingsRow(title: "Drop down when an agent finishes", subtitle: "Shows its reply for a few seconds; hover to keep it") {
                        Toggle("", isOn: $dropOnFinish).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
                SettingsSection(title: "Spotify",
                                footer: "Playing music shows up without this; connecting adds your queue, liked songs and search.") {
                    SettingsRow(title: "Up Next, ♥ and search", subtitle: "Takes a free Spotify developer key, about two minutes") {
                        Button("Set up in Settings") { SettingsWindow.shared.show(.music) }
                            .buttonStyle(PillButtonStyleSettings())
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
    }
}

/// The notch itself, tried for real: each line ticks once it happens.
private struct TryItStep: View {
    @ObservedObject var ui: NotchUI
    @AppStorage(Shortcut.defaultsKey) private var shortcutData: Data?
    @State private var hovered = false
    @State private var asked = false

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: hovered && asked ? "You're all set" : "Try it",
                       subtitle: hovered && asked ? "Your agents will show up in the notch as they work." : "Do these now; each ticks off when it works.")
            VStack(spacing: 0) {
                SettingsRow(title: ui.hasNotch ? "Move your pointer onto the notch" : "Move your pointer to the top of the screen",
                            subtitle: "It opens to show your agents; click it to keep it open") {
                    StepNumber(number: 1, done: hovered)
                } trailing: { EmptyView() }
                SettingsRow(title: "Press \(Shortcut.current.display)", subtitle: "Ask any installed agent something, from any app") {
                    StepNumber(number: 2, done: asked)
                } trailing: { EmptyView() }
            }
            .padding(.bottom, -1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .glassRim(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 460)
            .animation(Motion.glide, value: hovered)
            .animation(Motion.glide, value: asked)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .onChange(of: ui.mode) { _, mode in
            if mode == .peek || mode == .open { hovered = true }
            if mode == .open, ui.page == .ask { asked = true }
        }
        .onChange(of: ui.page) { _, page in
            if page == .ask, ui.mode == .open { asked = true }
        }
    }

    /// Without the notch's state (it failed to start), just the hints.
    struct Offline: View {
        var body: some View {
            StepHeader(title: "Try it", subtitle: "Move your pointer onto the notch, or press \(Shortcut.current.display) to ask an agent.")
                .padding(36)
        }
    }
}
