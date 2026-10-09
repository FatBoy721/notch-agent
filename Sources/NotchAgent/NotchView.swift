import SwiftUI

struct NotchView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    let services: Services
    @ObservedObject var music: MusicStore
    /// The tab's width depends on the shortcut's key caps.
    @AppStorage(Shortcut.defaultsKey) private var shortcutData: Data?
    @State private var pageHeight: CGFloat = 0
    @State private var dropHeight: CGFloat = 0
    @State private var dropTargeted = false

    /// Files dropped on the notch go with the open thread's next reply, or
    /// otherwise with a new prompt on Ask.
    private func accept(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let items = urls.map { Attachment(url: $0, isScreenshot: false) }
        if case .thread(let id) = ui.page, store.session(id)?.canReply == true {
            store.replyAttachments[id, default: []] += items
        } else {
            services.ask.attachments += items
            ui.page = .ask
        }
        ui.mode = .open
        return true
    }

    init(store: Store, ui: NotchUI, services: Services) {
        self.store = store
        self.ui = ui
        self.services = services
        self.music = services.music
    }

    /// What the closed notch shows: a playing song when no agent is busy,
    /// unless the peek switch says otherwise.
    private var showsMusic: Bool {
        guard music.nowPlaying != nil else { return false }
        switch ui.tabSide {
        case .music: return true
        case .agents: return false
        case .auto: return store.tabStatus == .quiet && music.isPlaying
        }
    }

    /// Closed, solid black like the hardware it extends. Open, GlassCode's
    /// frosted glass, kept black where it meets the bezel so it still grows
    /// out of the notch, and on the Music page faintly tinted with the
    /// album's color toward the bottom.
    @ViewBuilder private var background: some View {
        let shape = NotchShape(radius: radius, ear: ear)
        if isPanel {
            let bezel = min(0.9, ui.notchSize.height / max(1, shapeSize.height))
            Color.clear
                .liquidGlass(shape, tint: 0.45)
                .overlay(shape.fill(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: bezel),
                    .init(color: .black.opacity(0), location: min(1, bezel + 0.22)),
                ], startPoint: .top, endPoint: .bottom)))
                .overlay(shape.fill(LinearGradient(
                    colors: [.clear, ui.page == .music && music.nowPlaying != nil ? music.accent.opacity(0.22) : .clear],
                    startPoint: .top, endPoint: .bottom)))
                // The rim starts below the black, where the glass shows.
                .glassRim(shape, from: bezel)
        } else {
            shape.fill(.black)
        }
    }

    private var ear: CGFloat {
        switch ui.mode {
        case .open, .drop: 0
        case .peek: 9
        case .closed: NotchUI.ear
        }
    }

    private var radius: CGFloat {
        switch ui.mode {
        case .open: 24
        case .drop: 22
        case .peek: 14
        case .closed: 12
        }
    }

    /// Pages are 560pt wide; the music player is narrower, or wider with lyrics.
    private var panelWidth: CGFloat {
        ui.page == .music ? MusicPage.panelWidth(music) : NotchUI.panelWidth
    }

    /// The drawn size, ears excluded.
    /// The "<shortcut> · Ask an agent" hint: while peeking, and always on a
    /// display without a notch, where an idle tab would otherwise be an
    /// empty black bar.
    private var showsHint: Bool { ui.mode == .peek || !ui.hasNotch }

    /// Open, or dropped down with a finished turn: drawn as a panel.
    private var isPanel: Bool { ui.isOpen || ui.mode == .drop }

    private var dropSession: AgentSession? {
        store.drop.flatMap { store.session($0.sessionID) }
    }

    private var shapeSize: CGSize {
        if ui.mode == .drop {
            return CGSize(width: DropCard.width, height: max(dropHeight, ui.notchSize.height + 50))
        }
        if ui.isOpen {
            // The measured page already includes the notch's height as top padding.
            return CGSize(width: panelWidth, height: max(pageHeight, ui.notchSize.height + 60))
        }
        let tab = TabLayout(status: store.tabStatus, peeking: showsHint,
                            musicWing: showsMusic ? MusicTab.wing(music) : nil)
        let peekGrow: CGFloat = ui.mode == .peek ? 4 : 0
        if ui.hasNotch {
            let width = tab.isEmpty ? ui.notchSize.width : ui.notchSize.width + 2 * (tab.wing + 16)
            return CGSize(width: width, height: ui.notchSize.height + peekGrow)
        }
        let width = max(196, tab.isEmpty ? 0 : 2 * (tab.wing + 16) + 96)
        return CGSize(width: width, height: ui.notchSize.height + peekGrow)
    }

    var body: some View {
        VStack(spacing: NotchUI.dockGap) {
            ZStack(alignment: .top) {
                background
                    .shadow(color: .black.opacity(isPanel ? 0.45 : 0), radius: 24, y: 12)
                if ui.mode == .drop, let session = dropSession {
                    DropCard(session: session, othersCount: store.drop?.others.count ?? 0)
                        .frame(width: DropCard.width - 32)
                        .padding(.top, ui.notchSize.height + 6)
                        .padding(.bottom, 14)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dropHeight = $0 }
                        .transition(Motion.content)
                } else if ui.isOpen {
                    PageView(store: store, ui: ui, services: services)
                        .frame(width: panelWidth - 32)
                        .padding(.top, ui.notchSize.height + 6)
                        .padding(.bottom, 16)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
                        .transition(Motion.content)
                } else {
                    TabContent(status: store.tabStatus, peeking: showsHint, notchWidth: ui.hasNotch ? ui.notchSize.width : 96,
                               music: showsMusic ? music : nil)
                        .padding(.horizontal, ear) // measure insets from the body, not the ears' tips
                        .frame(height: shapeSize.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.16)))
                }
            }
            .frame(width: shapeSize.width + 2 * ear, height: shapeSize.height, alignment: .top)
            // Hit testing uses the size actually laid out, not the computed
            // target: SwiftUI doesn't reliably re-report a computed value
            // that changes inside an animation, which left the bottom of
            // tall pages counting as "outside" and closing the notch.
            .background(ProbeView(probe: ui.shapeProbe))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                ui.shapeSize = CGSize(width: size.width - 2 * ear, height: size.height)
            }
            .clipped(antialiased: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !ui.isOpen else { return }
                // Clicking the dropped-down card opens its thread, or the
                // list when several finished.
                if ui.mode == .drop, let drop = store.drop {
                    ui.page = drop.others.isEmpty ? .thread(drop.sessionID) : .threads
                }
                ui.mode = .open
            }
            .overlay(
                NotchShape(radius: radius, ear: ear)
                    .stroke(Palette.accent.opacity(dropTargeted ? 0.9 : 0), lineWidth: 2)
                    .animation(.easeOut(duration: 0.15), value: dropTargeted)
            )
            .overlay(DonePulse(shape: NotchShape(radius: radius, ear: ear), trigger: store.justFinished))
            .dropDestination(for: URL.self) { urls, _ in
                accept(urls.filter(\.isFileURL))
            } isTargeted: { dropTargeted = $0 }

            if ui.mode == .peek {
                // Under the peeking notch: the music switch while something
                // plays, and a glance at the plan limits (GlassCode's usage
                // peek) without opening anything.
                VStack(spacing: 6) {
                    if music.nowPlaying != nil { TabSwitch(ui: ui, musicShown: showsMusic) }
                    UsagePeek(limits: services.limits)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { ui.switchSize = $0 }
                .transition(.opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if ui.isOpen {
                Dock(store: store, ui: ui)
                    .background(ProbeView(probe: ui.dockProbe))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { ui.dockSize = $0 }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.15))
                            .combined(with: .offset(y: -6).animation(Motion.morph.delay(0.1))),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .animation(Motion.morph, value: ui.mode)
        .animation(Motion.calm, value: pageHeight)
        .animation(Motion.calm, value: store.tabStatus)
        // The closed tab's lyric and its width move together.
        .animation(Motion.calm, value: music.lyricLine?.id)
        .animation(Motion.calm, value: music.nowPlaying?.trackKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Drop-down card

/// What the notch drops down to show when an agent finishes: who, where,
/// and the reply, typing itself out.
struct DropCard: View {
    static let width: CGFloat = 460
    let session: AgentSession
    var othersCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                AgentGlyph(kind: session.kind, size: 16)
                Text(session.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text("✓ Done").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Palette.ok)
            }
            Text([session.project, session.modelName ?? session.agent, session.terminalName].joined(separator: " · "))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.mute)
                .lineLimit(1)
            if let reply = session.lastReply {
                TypedReply(text: reply)
                    .padding(.top, 2)
            }
            if othersCount > 0 {
                Label("+\(othersCount) more finished · click to see all", systemImage: "checkmark.circle")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.mute)
                    .padding(.top, 2)
            }
        }
    }
}

/// The reply revealed word by word (like the site's response line), with
/// inline Markdown rendered and long replies cut to a few lines.
struct TypedReply: View {
    let text: String
    var lines = 5
    @State private var shown = 0

    private var words: [Substring] {
        String(text.prefix(600)).split(separator: " ", omittingEmptySubsequences: false)
    }

    var body: some View {
        let visible = words.prefix(shown).joined(separator: " ")
        Text(Self.render(visible))
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text) {
                shown = 0
                for count in 1...max(1, words.count) {
                    shown = count
                    try? await Task.sleep(for: .milliseconds(28))
                }
            }
    }

    static func render(_ text: String) -> AttributedString {
        let flattened = text.replacingOccurrences(of: "\n\n", with: "\n")
        return (try? AttributedString(markdown: flattened,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(flattened)
    }
}

// MARK: - Closed tab

/// Under the peeking notch while music plays: choose what the closed notch
/// shows.
private struct TabSwitch: View {
    @ObservedObject var ui: NotchUI
    let musicShown: Bool

    var body: some View {
        HStack(spacing: 2) {
            option("sparkle", "Agents", on: !musicShown) { ui.tabSide = .agents }
            option("music.note", "Music", on: musicShown) { ui.tabSide = .music }
        }
        .padding(3)
        .liquidGlass(RoundedRectangle(cornerRadius: 12), tint: 0.4, interactive: true)
        .glassRim(RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }

    private func option(_ icon: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? .white : .white.opacity(0.6))
                .padding(.horizontal, 12).frame(height: 30)
                .background(.white.opacity(on ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// How wide each side of the closed notch needs to be for what it says.
private struct TabLayout {
    let wing: CGFloat
    let isEmpty: Bool

    init(status: TabStatus, peeking: Bool, musicWing: CGFloat?) {
        if let musicWing {
            wing = max(44, musicWing)
            isEmpty = false
            return
        }
        let (left, right): (CGFloat, CGFloat)
        switch status {
        case .quiet:
            // The shortcut's key caps (each at least 20 wide), gaps, a little air.
            let caps = Shortcut.current.symbols.map { max(20, textWidth($0, size: 11.5) + 14) }
            let keys = caps.reduce(0, +) + CGFloat(caps.count - 1) * 4 + 6
            (left, right) = peeking ? (keys, textWidth("Ask an agent", size: 12.5)) : (0, 0)
        case .running(_, let project, let activity):
            (left, right) = (19 + 6 + min(110, textWidth(project, size: 12.5)), activity.width)
        case .needsYou(_, let project):
            (left, right) = (19 + 6 + min(110, textWidth(project, size: 12.5)), textWidth("Needs you", size: 12.5, weight: .bold))
        case .done:
            (left, right) = (19, textWidth("✓ Done", size: 12.5, weight: .bold))
        case .many(let kinds):
            (left, right) = (CGFloat(min(kinds.count, 3)) * 21, textWidth("\(kinds.count) running", size: 12.5))
        }
        wing = max(left, right)
        isEmpty = wing == 0
    }
}

private struct TabContent: View {
    /// Redraws the key caps when the shortcut changes in Settings.
    @AppStorage(Shortcut.defaultsKey) private var shortcutData: Data?
    let status: TabStatus
    let peeking: Bool
    let notchWidth: CGFloat
    var music: MusicStore?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let music { MusicTabLeft(music: music) } else { left }
            }
            .padding(.leading, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 6) {
                if let music { MusicTabRight(music: music) } else { right }
            }
            .padding(.trailing, 13)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .lineLimit(1)
        // Content waits for the notch to finish widening, so nothing is
        // drawn past its edge mid-animation.
        .id(music == nil ? AnyHashable([AnyHashable(status), AnyHashable(peeking)]) : AnyHashable("music"))
        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.24)),
                                removal: .opacity.animation(.easeOut(duration: 0.1))))
    }

    @ViewBuilder private var left: some View {
        switch status {
        case .quiet where peeking:
            HStack(spacing: 4) {
                ForEach(Shortcut.current.symbols, id: \.self) { Kbd($0) }
            }
        case .running(let kind, let project, _):
            AgentGlyph(kind: kind, busy: true)
            Text(project).foregroundStyle(Palette.mute).frame(maxWidth: 110, alignment: .leading)
        case .needsYou(let kind, let project):
            AgentGlyph(kind: kind)
            Text(project).foregroundStyle(Palette.mute).frame(maxWidth: 110, alignment: .leading)
        case .done:
            AgentGlyph()
        case .many(let kinds):
            HStack(spacing: 2) {
                ForEach(Array(kinds.prefix(3).enumerated()), id: \.offset) { _, kind in
                    AgentGlyph(kind: kind, busy: true)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var right: some View {
        switch status {
        case .quiet where peeking:
            Text("Ask an agent").foregroundStyle(Palette.mute)
        case .running(_, _, let activity):
            ActivityLabel(activity: activity, showsGlyph: false)
        case .needsYou:
            Text("Needs you").fontWeight(.bold).foregroundStyle(Palette.warn)
        case .done:
            Text("✓ Done").fontWeight(.bold).foregroundStyle(Palette.ok)
        case .many(let kinds):
            Text("\(kinds.count) running").foregroundStyle(Palette.mute)
        default:
            EmptyView()
        }
    }
}

// MARK: - Pages

private struct PageView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    let services: Services
    private var usage: UsageStore { services.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = store.notice {
                Label(notice, systemImage: "doc.on.clipboard")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ok)
            }
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch ui.page {
            case .threads:
                ThreadsPage(store: store, ui: ui, usage: usage, limits: services.limits)
            case .thread(let id):
                if let session = store.session(id) {
                    ThreadPage(store: store, ui: ui, session: session)
                } else {
                    ThreadsPage(store: store, ui: ui, usage: usage, limits: services.limits)
                }
            case .usage:
                PageHeader(title: "Usage") { HeaderIcons(store: store, ui: ui, limits: services.limits) }
                LimitsCards(limits: services.limits, usage: services.usage)
                UsageView(usage: usage)
            case .ask:
                AskPage(ask: services.ask, store: store, ui: ui, limits: services.limits) { ui.page = .threads }
            case .stats:
                PageHeader(title: "Stats") { SettingsMenu(store: store) }
                StatsView(stats: services.stats)
            case .music:
                MusicPage(music: services.music, ui: ui)
            }
        }
        .id(pageKey)
        .transition(Motion.page)
    }

    private var pageKey: String {
        switch ui.page {
        case .threads: "threads"
        case .thread(let id): "thread-" + id
        case .usage: "usage"
        case .ask: "ask"
        case .stats: "stats"
        case .music: "music"
        }
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var back: (() -> Void)? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            Text(title).font(.system(size: 15, weight: .bold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            Spacer()
            trailing
        }
    }
}

/// The usage chart and settings, at the right of page headers.
struct HeaderIcons: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    let limits: LimitsStore

    var body: some View {
        HStack(spacing: 12) {
            if ui.page != .usage {
                Button { ui.page = .usage } label: {
                    Image(systemName: "chart.bar.fill").font(.system(size: 11.5)).foregroundStyle(Palette.mute)
                }
                .buttonStyle(.plain)
                .help("Usage")
            }
            SettingsMenu(store: store)
        }
    }
}

/// The gear: Settings, the one toggle people flip often, and Quit.
struct SettingsMenu: View {
    @ObservedObject var store: Store
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Store.dropOnFinishKey) private var dropOnFinish = true

    var body: some View {
        Menu {
            if let release = updater.available {
                Button("Install Notch Agent \(release.version)…") { updater.install() }
                Divider()
            }
            Button("Settings…") { SettingsWindow.shared.show() }
            Divider()
            Toggle("Drop down when agents finish", isOn: $dropOnFinish)
            Divider()
            Button("Quit Notch Agent") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(Palette.mute)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A dot while an update waits. On the menu, not in its label: the
        // label is drawn as a plain image, without overlays.
        .overlay(alignment: .topTrailing) {
            if updater.available != nil {
                Circle().fill(Palette.ok).frame(width: 6, height: 6).offset(x: 3, y: -2).allowsHitTesting(false)
            }
        }
        .help(updater.available.map { "Notch Agent \($0.version) is ready to install" } ?? "")
    }
}

// MARK: Threads

private struct ThreadsPage: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    @ObservedObject var usage: UsageStore
    let limits: LimitsStore

    var body: some View {
        let sessions = store.listedSessions
        let old = groups(sessions).filter { $0.title == "Earlier" || $0.title == "Waiting a while" }.flatMap(\.sessions)
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "Threads", count: sessions.isEmpty ? nil : sessions.count) {
                if usage.loaded {
                    Text(UsageFormat.dollars(usage.report.total(days: 1).cost))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.mute)
                        .help("API-equivalent spend today")
                }
                if !old.isEmpty || store.hiddenCount > 0 {
                    Menu {
                        if !old.isEmpty {
                            Button("Hide \(old.count) old thread\(old.count == 1 ? "" : "s")") {
                                withAnimation { store.hide(old.map(\.id)) }
                            }
                        }
                        if store.hiddenCount > 0 {
                            Button("Show \(store.hiddenCount) hidden") { withAnimation { store.showHidden() } }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 12.5)).foregroundStyle(Palette.mute)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Clean up the list")
                }
                HeaderIcons(store: store, ui: ui, limits: limits)
            }
            if sessions.isEmpty {
                EmptyState(store: store)
            } else {
                CappedScroll(maxHeight: 440, fadesOverflow: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups(sessions), id: \.title) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                ThreadGroupLabel(title: group.title)
                                ForEach(group.sessions) { session in
                                    ThreadRow(store: store, ui: ui, session: session,
                                              needsYou: store.approvals.contains { $0.sessionID == session.id }) {
                                        ui.page = .thread(session.id)
                                    }
                                    .transition(.asymmetric(insertion: Motion.row, removal: Motion.dust))
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { usage.refresh() }
    }

    /// Hermes' sidebar grouping: what needs attention now, then by age,
    /// with long-unanswered waits last. Empty groups are left out.
    private func groups(_ sessions: [AgentSession]) -> [(title: String, sessions: [AgentSession])] {
        let dayAgo = Date().addingTimeInterval(-86_400)
        var now: [AgentSession] = [], today: [AgentSession] = [], earlier: [AgentSession] = [], stale: [AgentSession] = []
        for session in sessions {
            let needsYou = store.approvals.contains { $0.sessionID == session.id }
            if session.status == .working || needsYou || (session.status == .waiting && !session.isStaleWait) {
                now.append(session)
            } else if session.isStaleWait {
                stale.append(session)
            } else if (session.finishedAt ?? session.updatedAt) > dayAgo {
                today.append(session)
            } else {
                earlier.append(session)
            }
        }
        return [("Now", now), ("Today", today), ("Earlier", earlier), ("Waiting a while", stale)].filter { !$0.1.isEmpty }
    }
}

/// A subagent's identity, as in GlassCode: a scientist's name and a color,
/// picked from its tool call id so it stays the same while it runs.
enum Subagent {
    private static let names = ["Lovelace", "Turing", "Curie", "Hopper", "Noether", "Feynman", "Dirac", "Heisenberg",
                                "Ramanujan", "Tesla", "Meitner", "Shannon", "Hamilton", "Franklin", "Euler", "Darwin"]
    private static let colors: [Color] = [
        Color(red: 0.98, green: 0.55, blue: 0.4), Color(red: 0.45, green: 0.7, blue: 1), Color(red: 0.55, green: 0.85, blue: 0.5),
        Color(red: 0.85, green: 0.6, blue: 1), Color(red: 1, green: 0.8, blue: 0.35), Color(red: 0.4, green: 0.85, blue: 0.85),
    ]

    /// Stable across runs (unlike `hashValue`).
    private static func seed(_ item: FeedItem) -> Int {
        (item.toolUseID ?? item.id.uuidString).unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fff_ffff }
    }

    static func name(_ item: FeedItem) -> String { names[seed(item) % names.count] }
    /// Follows the name, so different names mostly get different colors.
    static func color(_ item: FeedItem) -> Color { colors[seed(item) % names.count % colors.count] }
}

/// The turn's subagents: who, what they're on, running or done.
private struct SubagentList: View {
    let subagents: [FeedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subagents · \(subagents.filter { !$0.isDone }.count) running")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.mute)
            ForEach(subagents) { item in
                HStack(spacing: 8) {
                    if item.isDone {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.ok).frame(width: 10)
                    } else {
                        ArcSpinner(size: 10, color: Subagent.color(item))
                    }
                    Text(Subagent.name(item)).font(.system(size: 12, weight: .bold)).foregroundStyle(Subagent.color(item))
                    Text(item.title).font(.system(size: 12)).foregroundStyle(.white.opacity(item.isDone ? 0.45 : 0.8)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// How full Claude's context window is, as a ring that turns amber, then
/// red, as Claude Code nears compacting the conversation.
struct ContextRing: View {
    let fraction: Double
    let limit: Int
    /// Rows show the % only once it's worth reading; the thread header
    /// always does, so a nearly empty ring isn't mistaken for a spinner.
    var showsPercent = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            if showsPercent || fraction >= 0.6 {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
        }
        .help("Context \(Int(fraction * 100))% of \(limit >= 1_000_000 ? "1M" : "\(limit / 1000)k") tokens. The agent compacts the conversation near the limit.")
    }

    private var color: Color {
        fraction < 0.6 ? .white.opacity(0.45) : fraction < 0.8 ? Palette.warn : .red
    }
}

/// A green ring that flashes out from the notch when an agent finishes.
private struct DonePulse<S: Shape>: View {
    let shape: S
    let trigger: String?
    @State private var progress: CGFloat = 1

    var body: some View {
        shape
            .stroke(Palette.ok.opacity(0.85 * (1 - progress)), lineWidth: 2 + 3 * progress)
            .scaleEffect(1 + 0.05 * progress, anchor: .top)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, finished in
                guard finished != nil else { return }
                progress = 0
                withAnimation(.easeOut(duration: 1.1)) { progress = 1 }
            }
    }
}

/// The plan's 5-hour and weekly use, shown under the notch while the
/// pointer rests on it.
private struct UsagePeek: View {
    @ObservedObject var limits: LimitsStore

    var body: some View {
        Group {
            if let plan = limits.limits, plan.session != nil || plan.week != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let session = plan.session { row("5-hour", session) }
                    if let week = plan.week { row("Week", week) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 270)
                .liquidGlass(RoundedRectangle(cornerRadius: 12), tint: 0.4)
                .glassRim(RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { limits.refresh() }
    }

    private func row(_ label: String, _ window: PlanLimits.Window) -> some View {
        let used = min(1, window.utilization / 100)
        return HStack(spacing: 8) {
            Text(label).foregroundStyle(Palette.mute).frame(width: 44, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(used < 0.5 ? Palette.ok : used < 0.8 ? Palette.warn : .red)
                    .frame(width: max(3, 96 * used))
            }
            .frame(width: 96, height: 4)
            Text("\(Int(window.utilization))%").monospacedDigit().frame(width: 32, alignment: .trailing)
            Spacer(minLength: 0)
            if let resets = window.resetsAt {
                Text(Self.until(resets)).foregroundStyle(Palette.mute).lineLimit(1).fixedSize()
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }

    /// "2h 10m", "3d 4h": until the window resets.
    private static func until(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
}

/// "■ TODAY": a small square and letter-spaced caps over a group of rows.
private struct ThreadGroupLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Palette.mute).frame(width: 5, height: 5)
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(Palette.mute)
        }
        .padding(.leading, 10)
        .padding(.bottom, 2)
    }
}

/// A thread's actions, in its row's right-click menu and behind ⋯ on its
/// page: rename it, take its run with you (summary, diff, log), and the
/// housekeeping (compact, hide, close).
private struct ThreadMenu: View {
    let store: Store
    let ui: NotchUI
    let session: AgentSession
    /// Hiding only makes sense from the list.
    let inList: Bool

    var body: some View {
        Button("Rename…") { rename() }
        Divider()
        Button("Copy run summary") { store.copySummary(session.id) }
        if session.kind == .claude || session.kind == .codex || !session.changedFiles.isEmpty {
            Button(session.changedFiles.isEmpty ? "Copy diff of uncommitted changes" : "Copy diff of files it changed") {
                store.copyDiff(session.id)
            }
        }
        if session.kind == .claude || session.kind == .codex {
            Button("Show transcript in Finder") { store.revealTranscript(session.id) }
        }
        Divider()
        if session.canCompact { Button("Compact context") { store.compactContext(session.id) } }
        if inList { Button("Hide from list") { withAnimation { store.hide([session.id]) } } }
        if session.herdr != nil { Button("Close agent (ends its herdr pane)…") { confirmClose() } }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename thread"
        alert.informativeText = "Leave it empty to go back to its latest prompt."
        let field = NSTextField(string: session.customTitle ?? session.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runAboveNotch(below: notchFrame) == .alertFirstButtonReturn else { return }
        store.rename(session.id, to: field.stringValue)
    }

    private func confirmClose() {
        let alert = NSAlert()
        alert.messageText = "Close \(session.agent) in \(session.herdrTab ?? session.project)?"
        alert.informativeText = "This closes its herdr pane and ends the agent. Anything it's doing stops."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runAboveNotch(below: notchFrame) == .alertFirstButtonReturn { withAnimation { store.closeAgent(session.id) } }
    }

    /// The open notch with its dock, on screen; dialogs open just below it.
    private var notchFrame: NSRect? {
        [ui.shapeProbe.screenFrame, ui.dockProbe.screenFrame].compactMap { $0 }.reduce(nil) { $0?.union($1) ?? $1 }
    }
}

extension NSAlert {
    /// The notch floats above the menu bar, so an alert at its normal level
    /// opened behind it, out of sight, and blocked the app until dismissed.
    /// Given the notch's frame, the alert opens centered just below it
    /// rather than over it, where it would hide what it's about.
    func runAboveNotch(below notch: NSRect? = nil) -> NSApplication.ModalResponse {
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        NSApp.activate()
        if let notch {
            layout()
            let window = window
            let place = {
                let size = window.frame.size
                let visible = (NSScreen.screens.first { $0.frame.intersects(notch) } ?? NSScreen.main)?.visibleFrame ?? .zero
                let x = min(max(notch.midX - size.width / 2, visible.minX), visible.maxX - size.width)
                let top = max(notch.minY - 12, visible.minY + size.height)
                window.setFrameTopLeftPoint(NSPoint(x: x, y: top))
            }
            place()
            // runModal centers the window as it opens; move it back once shown.
            DispatchQueue.main.async(execute: place)
        }
        return runModal()
    }
}

private struct ThreadRow: View {
    let store: Store
    let ui: NotchUI
    let session: AgentSession
    let needsYou: Bool
    let open: () -> Void
    @State private var hovering = false

    /// Near the end of its window: offer to compact right in the row.
    private var nearlyFull: Bool { (session.contextFraction ?? 0) >= 0.75 && session.canCompact }

    var body: some View {
        // The Compact pill sits beside the row's button, not inside it, so
        // each takes its own clicks.
        HStack(spacing: 6) {
            rowButton
            if nearlyFull {
                Button("Compact") { store.compactContext(session.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
                    .help("Ask \(session.agent) to compact its context now")
            }
        }
        .padding(.trailing, nearlyFull ? 6 : 0)
        .background(.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu { ThreadMenu(store: store, ui: ui, session: session, inList: true) }
    }

    private var rowButton: some View {
        Button(action: open) {
            // Slim, like Hermes' sidebar: no card per row, a highlight on hover.
            HStack(spacing: 10) {
                AgentGlyph(kind: session.kind, busy: session.status == .working, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                }
                Spacer(minLength: 8)
                let running = session.subagents.filter { !$0.isDone }
                if !running.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(running.prefix(5)) { Circle().fill(Subagent.color($0)).frame(width: 6, height: 6) }
                    }
                    .help("\(running.count) subagent\(running.count == 1 ? "" : "s") running")
                }
                if let fraction = session.contextFraction {
                    ContextRing(fraction: fraction, limit: session.contextLimit)
                }
                ThreadStatus(session: session, needsYou: needsYou)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if let tool = session.lastTool { return "\(tool.tool ?? "Tool") \(tool.title)" }
        return "\(session.herdrTab ?? session.project) · \(session.modelName ?? session.agent)"
    }
}

private struct ThreadStatus: View {
    let session: AgentSession
    let needsYou: Bool

    var body: some View {
        Group {
            if needsYou {
                Text("Needs you").fontWeight(.bold).foregroundStyle(Palette.warn)
            } else if session.status == .working {
                HStack(spacing: 8) {
                    ActivityLabel(activity: session.activity, size: 12, showsGlyph: false)
                    ActivityGrid(color: session.kind.color)
                    if let start = session.turnStartedAt { Elapsed(since: start) }
                }
            } else if session.status == .waiting {
                // How long it's waited; long waits fade so fresh ones stand out.
                HStack(spacing: 4) {
                    Text("Needs you").fontWeight(.bold)
                    if let since = session.waitingSince { Waited(since: since) }
                }
                .foregroundStyle(Palette.warn.opacity(session.isStaleWait ? 0.5 : 1))
            } else if session.status == .ended {
                Text("Ended").foregroundStyle(Palette.mute)
            } else if let finished = session.finishedAt {
                HStack(spacing: 4) {
                    Text("✓ Done").fontWeight(.bold).foregroundStyle(Palette.ok)
                    Ago(date: finished)
                }
            } else {
                Text("Idle").foregroundStyle(Palette.mute)
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
    }
}

/// "just now", "4m ago": how long since something happened.
private struct Ago: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let seconds = Int(max(0, context.date.timeIntervalSince(date)))
            Text(seconds < 15 ? "just now" : seconds < 3600 ? "\(max(1, seconds / 60))m ago"
                 : seconds < 86_400 ? "\(seconds / 3600)h ago" : "\(seconds / 86_400)d ago")
                .foregroundStyle(Palette.mute)
        }
    }
}

/// "· 12m", "· 3h", "· 2d": how long a thread has waited on the user.
private struct Waited: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minutes = Int(max(0, context.date.timeIntervalSince(since)) / 60)
            Text("· " + (minutes < 1 ? "now" : minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"))
                .fontWeight(.semibold)
        }
    }
}

/// "9s", "2m 05s": ticking time since the turn started. Whole seconds, on
/// the wall clock's second, so every counter on screen updates in the same
/// frame (tenths at 10 Hz per row made long thread lists lag).
struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down)), by: 1)) { context in
            let seconds = Int(max(0, context.date.timeIntervalSince(since)))
            Text(seconds < 60 ? "\(seconds)s" : String(format: "%dm %02ds", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: Thread

private struct ThreadPage: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    let session: AgentSession

    /// "notch-agent · Opus 5.5 · Metalterm · following", each part once
    /// (a herdr tab is often named after its folder).
    private var subtitle: String {
        let parts = [session.project, session.modelName ?? session.agent]
            + session.terminalName.components(separatedBy: " · ") + ["following"]
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " · ")
    }

    var body: some View {
        let approval = store.approvals.first { $0.sessionID == session.id }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { ui.page = .threads } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                AgentGlyph(kind: session.kind, busy: session.status == .working, size: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 14.5, weight: .bold)).lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.mute)
                }
                Spacer()
                if let fraction = session.contextFraction {
                    ContextRing(fraction: fraction, limit: session.contextLimit, showsPercent: true)
                    if session.canCompact {
                        Button("Compact") { store.compactContext(session.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.white.opacity(0.1), in: Capsule())
                            .help("Ask \(session.agent) to compact its context now")
                    }
                }
                Menu {
                    ThreadMenu(store: store, ui: ui, session: session, inList: false)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.mute)
                        .frame(width: 26, height: 26)
                        .background(Palette.faint, in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rename, copy its summary or diff, show its log")
                if session.herdr != nil || session.terminal != nil {
                    Button {
                        TerminalBridge.focus(session.terminal, herdr: session.herdr)
                        ui.mode = .closed
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.mute)
                            .frame(width: 26, height: 26)
                            .background(Palette.faint, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Show in \(session.terminalName)")
                }
            }

            if let prompt = session.prompt {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("↳").foregroundStyle(session.kind.color)
                    Text(prompt).lineLimit(3)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.faint, in: RoundedRectangle(cornerRadius: 11))
            }

            if !session.turnTools.isEmpty {
                ToolList(tools: session.turnTools, running: session.status == .working, tint: session.kind.color)
            }

            if !session.subagents.isEmpty {
                SubagentList(subagents: session.subagents)
                    .transition(Motion.row)
            }

            if session.status != .working, let reply = session.lastReply {
                TypedReply(text: reply, lines: 8)
                    .transition(Motion.row)
            }

            if let approval {
                PromptCard(store: store, approval: approval)
                    .transition(Motion.row)
            }

            StatusLine(session: session, needsYou: approval != nil || session.status == .waiting)
            ReplyBar(store: store, ui: ui, session: session)
        }
    }
}

private struct ToolList: View {
    let tools: [FeedItem]
    let running: Bool
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if running {
                    ArcSpinner(size: 10, color: .white.opacity(0.6))
                } else {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ok)
                }
                Text(running ? "Running tools" : "Ran \(tools.count) tool\(tools.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.mute)
            }
            CappedScroll(maxHeight: 170, anchorBottom: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tools) { tool in
                        ToolRow(item: tool).transition(Motion.row)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(tint.opacity(0.55)).frame(width: 1.5)
                }
                .padding(.leading, 5)
            }
        }
    }
}

private struct ToolRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ToolIcon.name(item.tool ?? ""))
                .font(.system(size: 11))
                .frame(width: 14)
                .opacity(0.6)
            Text(item.tool ?? "Tool").font(.system(size: 12.5, weight: .bold))
            Text(item.title)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 6)
            if !item.isDone {
                ArcSpinner(size: 11, color: .white.opacity(0.7))
            } else if item.failed {
                Label("failed", systemImage: "xmark").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.red)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ok)
                    if let result = item.result { Text(result) }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(minHeight: 26)
    }
}

private struct StatusLine: View {
    let session: AgentSession
    let needsYou: Bool
    private var terminalName: String { session.terminalName }

    var body: some View {
        HStack(spacing: 6) {
            if needsYou {
                PulseDot(color: Palette.warn)
                Text("Waiting for you · \(terminalName)")
            } else if session.status == .working {
                ActivityLabel(activity: session.activity, size: 12, showsDetail: true)
                Text("· \(terminalName)")
            } else if session.status == .ended {
                Text("Session ended")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                Text("Done · waiting for your next prompt")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.mute)
    }
}

private struct ReplyBar: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    let session: AgentSession

    private var canReply: Bool { session.canReply }
    private var attachments: [Attachment] { store.replyAttachments[session.id] ?? [] }
    private var hasContent: Bool { !draft.wrappedValue.isEmpty || !attachments.isEmpty }

    private var draft: Binding<String> {
        Binding { store.drafts[session.id] ?? "" } set: { store.drafts[session.id] = $0 }
    }

    private var placeholder: String {
        if session.status == .ended { return "Session ended" }
        // Mid-turn, the agent queues what you send until it can read it.
        if session.status == .working, session.replyRoute != .none { return "Queue a follow-up for \(session.agent)…" }
        switch session.replyRoute {
        case .herdr: return "Reply into its herdr pane"
        case .terminal: return "Reply into its terminal"
        case .clipboard: return "Reply (copied for you to paste into \(session.terminalName))"
        // A reply runs in Hermes itself; a Telegram chat won't see it there.
        case .hermes: return session.origin == "Telegram" ? "Reply in Hermes (it won't show in Telegram)" : "Reply to Hermes"
        case .none: return "Send a prompt from the terminal once to enable replies"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachmentChips(attachments: attachments) { item in
                store.replyAttachments[session.id]?.removeAll { $0.id == item.id }
            }
            HStack(spacing: 8) {
                Text("↳").foregroundStyle(Palette.mute)
                TextField(placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .disabled(!canReply)
                    .onSubmit { store.sendReply(to: session.id, ui: ui) }
                if canReply {
                    AttachButtons(screenshot: takeScreenshot) {
                        store.replyAttachments[session.id, default: []] += ScreenCapture.chooseFiles()
                    }
                }
                if store.sendingReply {
                    ArcSpinner(size: 14)
                } else {
                    Button { store.sendReply(to: session.id, ui: ui) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 19))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canReply && hasContent ? session.kind.color : .white.opacity(0.25))
                    .disabled(!canReply || !hasContent)
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 7)
            .background(Palette.faint, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }

    private func takeScreenshot() {
        Task {
            do {
                let shot = try await ScreenCapture.capture(hiding: ui, reopen: true)
                store.replyAttachments[session.id, default: []].append(shot)
            } catch {
                store.problem = error.localizedDescription
            }
        }
    }
}

private struct EmptyState: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 24)).foregroundStyle(Palette.mute)
            if store.hooksInstalled {
                Text("No agents running").font(.system(size: 13.5, weight: .semibold))
                Text("Start `claude` in any terminal and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.mute)
            } else {
                Text("Connect Claude Code").font(.system(size: 13.5, weight: .semibold))
                Text("Adds hooks to ~/.claude/settings.json (a backup is saved next to it).")
                    .font(.system(size: 12)).foregroundStyle(Palette.mute)
                Button("Install hooks") { store.setHooksInstalled(true) }
                    .buttonStyle(PillButtonStyle(color: .blue))
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - Dock

/// The page switcher that floats under the open notch.
private struct Dock: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: NotchUI
    @Namespace private var selection

    private var isThreads: Bool {
        if case .thread = ui.page { return true }
        return ui.page == .threads
    }

    var body: some View {
        HStack(spacing: 2) {
            DockButton(icon: "pencil", label: "Ask", badge: 0, on: ui.page == .ask, selection: selection) { ui.page = .ask }
            DockButton(icon: "list.bullet", label: "Threads", badge: store.sessions.filter { $0.status == .working }.count,
                       on: isThreads, selection: selection) { ui.page = .threads }
            DockButton(icon: "chart.bar.fill", label: "Usage", badge: 0, on: ui.page == .usage, selection: selection) { ui.page = .usage }
            DockButton(icon: "gauge.with.dots.needle.33percent", label: "Stats", badge: 0, on: ui.page == .stats, selection: selection) { ui.page = .stats }
            DockButton(icon: "music.note", label: "Music", badge: 0, on: ui.page == .music, selection: selection) { ui.page = .music }
        }
        .padding(3)
        .animation(Motion.glide, value: ui.page)
        .liquidGlass(RoundedRectangle(cornerRadius: 12), tint: 0.4, interactive: true)
        .glassRim(RoundedRectangle(cornerRadius: 12))
        .fixedSize()
    }
}

private struct DockButton: View {
    let icon: String
    let label: String
    let badge: Int
    let on: Bool
    /// The highlight is one view gliding between buttons (GlassCode's
    /// sliding selection), not one per button.
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(minWidth: 17, minHeight: 17)
                        .padding(.horizontal, 2)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(on || hovering ? .white : .white.opacity(0.6))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.15))
                        .matchedGeometryEffect(id: "dock-selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared

struct PillButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.calm, value: configuration.isPressed)
    }
}

enum ToolIcon {
    static func name(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}
