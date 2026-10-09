import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Combine
import SwiftUI

@main
enum NotchAgentApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let services = Services()
    private var server: HookServer?
    private var notch: NotchController?
    private let herdr = HerdrMonitor()
    private let processes = ProcessMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController(store: store, services: services)
        SettingsWindow.shared.configure(store: store, services: services)
        SetupWindow.shared.configure(store: store, ui: notch?.ui)
        // Read before the login item marks this launch as seen.
        let returningUser = UserDefaults.standard.bool(forKey: LoginItem.firstLaunchKey)
        services.music.start()
        // Ready for the usage peek on the first hover.
        services.limits.refresh()
        herdr.start { [store] snapshot in
            Task { @MainActor in store.applyHerdr(snapshot) }
        }
        processes.start { [store] readings in
            Task { @MainActor in store.applyProcesses(readings) }
        }
        store.watchTerminals()
        store.watchHermes()
        let server = HookServer { [store] payload, reply in
            Task { @MainActor in store.handle(payload, reply: reply) }
        }
        #if DEBUG
        // The snapshot is refreshed on the main thread and read from a cache,
        // so the debug page can't block on (or be blocked by) the UI.
        let cache = DebugCache()
        server.debugSnapshot = { cache.data }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [store, notch, services] _ in
            MainActor.assumeIsolated { cache.data = Self.debugJSON(store: store, ui: notch?.ui, services: services) }
        }
        StallWatch.start()
        // Testing aid: open Settings at launch while this file exists; it
        // may name the tab ("agents", "music"…).
        if let tab = try? String(contentsOfFile: "/tmp/notch-agent-open-settings", encoding: .utf8) {
            SettingsWindow.shared.show(SettingsWindow.Tab(rawValue: tab.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .general)
        }
        // And the setup window, as a new user would see it.
        if FileManager.default.fileExists(atPath: "/tmp/notch-agent-open-setup") { SetupWindow.shared.show() }
        #endif
        server.spotifyCallback = { [services] query in
            Task { @MainActor in services.music.finishSpotifyLogin(query) }
            return SpotifyAPI.callbackPage(for: query)
        }
        LoginItem.enableOnFirstLaunch()
        SetupWindow.shared.showIfNeeded(returningUser: returningUser)
        Updater.shared.onFound = { [store] release in
            store.announce("Notch Agent \(release.version) is out. Install it from the ⚙ menu.")
        }
        Updater.shared.startAutomaticChecks()
        do {
            try server.start()
            self.server = server
        } catch {
            store.problem = "Port \(HookBridge.port) is busy, so agents can't reach the notch. Is another copy running?"
        }
    }
}

extension AppDelegate {
    static func debugJSON(store: Store, ui: NotchUI?, services: Services) -> Data {
        let sessions = store.orderedSessions.map { session -> [String: Any] in
            ["id": session.id, "title": session.title, "status": "\(session.status)", "kind": session.kind.name,
             "model": session.model ?? "", "context": session.contextTokens ?? -1, "runningTool": session.runningTool?.tool ?? "", "herdr": session.herdr?.paneID ?? "", "reply": String((session.lastReply ?? "").prefix(80)),
             "fromHooks": session.fromHooks, "where": session.terminalName,
             "waitedMinutes": session.waitingSince.map { Int(Date().timeIntervalSince($0) / 60) } as Any]
        }
        var snapshot: [String: Any] = ["tab": "\(store.tabStatus)", "approvals": store.approvals.count, "sessions": sessions,
                                       "askAttachments": services.ask.attachments.map(\.url.lastPathComponent),
                                       "replyAttachments": store.replyAttachments.mapValues { $0.map(\.url.lastPathComponent) }]
        if let ui {
            snapshot["mode"] = "\(ui.mode)"
            snapshot["idle"] = Int(NotchController.idleSeconds)
            snapshot["drop"] = store.drop.map { ["session": $0.sessionID, "others": $0.others.count] } as Any
            snapshot["page"] = "\(ui.page)"
            snapshot["shape"] = ["width": ui.shapeSize.width, "height": ui.shapeSize.height]
            snapshot["dock"] = ["width": ui.dockSize.width, "height": ui.dockSize.height]
            snapshot["frames"] = ["shape": "\(ui.shapeProbe.screenFrame ?? .zero)", "dock": "\(ui.dockProbe.screenFrame ?? .zero)"]
            snapshot["notch"] = ["width": ui.notchSize.width, "height": ui.notchSize.height]
        }
        let music = services.music
        snapshot["music"] = ["player": music.nowPlaying?.player.rawValue ?? "", "panel": music.panel.map { "\($0)" } ?? "",
                             "spotify": "\(music.spotify)", "upNext": music.upNext?.map(\.title) as Any,
                             "liked": music.nowPlaying?.favorite as Any, "likeNeedsPermission": music.likeNeedsPermission,
                             "browse": ["query": music.browser.query, "results": music.browser.results?.map(\.title) as Any,
                                        "playlists": music.browser.playlists?.count as Any, "liked": music.browser.likedSongs?.count as Any,
                                        "playlistsNeedPermission": music.browser.playlistsNeedPermission,
                                        "problem": music.browser.problem as Any]]
        return (try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])) ?? Data()
    }
}

/// Opening at login, through the system's login items. Only possible when
/// running as an .app bundle; it's switched on once, at first launch, and
/// after that follows the menu toggle (or System Settings › Login Items).
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Set at the end of the first launch; setup also reads it.
    static let firstLaunchKey = "didEnableLoginItemOnFirstLaunch"

    static func enableOnFirstLaunch() {
        let key = firstLaunchKey
        guard isAvailable, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? set(true)
    }
}

#if DEBUG
final class DebugCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data("{}".utf8)
    var data: Data {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Development aid: if the main thread stops answering for two seconds,
/// profile the app with `sample` so the stall's cause is on disk
/// (/tmp/notch-agent-stall-*.txt) instead of a mystery.
enum StallWatch {
    private nonisolated(unsafe) static var lastPong = Date()
    private nonisolated(unsafe) static var sampling = false

    static func start() {
        let queue = DispatchQueue(label: "notch-agent.stallwatch")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler {
            DispatchQueue.main.async { lastPong = Date() }
            let silent = Date().timeIntervalSince(lastPong)
            guard silent > 2, !sampling else { return }
            sampling = true
            let file = "/tmp/notch-agent-stall-\(Int(Date().timeIntervalSince1970)).txt"
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", file]
            try? sample.run()
            sample.waitUntilExit()
            print("main thread stalled \(Int(silent))s; sampled to \(file)")
            sampling = false
        }
        timer.resume()
        retained = timer
    }

    private nonisolated(unsafe) static var retained: DispatchSourceTimer?
}
#endif

/// A short record of what the notch did and why, for figuring out reports
/// like "it never showed": ~/Library/Logs/NotchAgent.log, kept under 512 KB.
enum EventLog {
    private static let queue = DispatchQueue(label: "notch-agent.log")
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchAgent.log")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                try? manager.removeItem(at: url)
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

/// The notch's feature models, owned once by the app.
@MainActor
final class Services {
    let usage = UsageStore()
    let music = MusicStore()
    let stats = SystemStats()
    let limits = LimitsStore()
    let ask = AskModel()
}

/// Shared between the window controller and the SwiftUI view.
@MainActor
final class NotchUI: ObservableObject {
    /// `drop`: dropped down on its own to show an agent's finished turn.
    enum Mode { case closed, peek, drop, open }
    enum Page: Equatable { case ask, threads, thread(String), usage, stats, music }

    @Published var mode: Mode = .closed
    @Published var page: Page = .threads
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasNotch = true
    /// What the closed notch shows while music plays (the peek switch).
    @Published var tabSide: TabSide = .auto
    var switchSize: CGSize = .zero

    enum TabSide { case auto, agents, music }
    /// What the view is currently drawing, reported back for hit testing.
    var shapeSize: CGSize = .zero
    var dockSize: CGSize = .zero
    /// Where the notch, the dock and the peek switch are laid out, in the
    /// panel's coordinates (origin top-left); `.zero` when not shown.
    /// Ask AppKit where the notch and its dock are drawn (see FrameProbe).
    let shapeProbe = FrameProbe()
    let dockProbe = FrameProbe()

    var isOpen: Bool { mode == .open }

    static let panelWidth: CGFloat = 560
    static let ear: CGFloat = 8
    static let dockGap: CGFloat = 8
    /// Room for the widest page (the player with lyrics, 660pt).
    static let windowSize = CGSize(width: 660 + 2 * ear + 40, height: 720)
}

/// Owns the borderless panel over the notch (a tab at the top of the menu
/// bar on Macs without one). Hover peeks, click or the Ask shortcut opens, and an
/// agent asking for permission opens it by itself.
@MainActor
final class NotchController {
    private let store: Store
    let ui = NotchUI()
    private let panel: NotchPanel
    private var screen: NSScreen?
    /// Why the notch was opened without the pointer: it then stays open
    /// (until Esc, or the approval is answered) instead of closing as soon
    /// as the pointer isn't over it. A visit by the pointer clears it.
    private enum Pin { case none, approval, hotKey }
    private var pin: Pin = .none
    private var outsideSince: Date?
    private var currentBounds: NSRect?
    private var menuSeenAt: Date?
    private var menuOpen = false
    private var dropShownAt = Date.distantPast
    private var dropHoveredAt = Date.distantPast
    /// 6 s normally; 15 s once you're back from being away, so it's still
    /// there when you look.
    private var dropDuration: TimeInterval = 6
    private var dropWaitedForUser = false
    private var lastMode: NotchUI.Mode = .closed

    /// Seconds since the last keyboard, mouse or trackpad input anywhere.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Seconds since the pointer last moved. Unlocking the Mac is typing,
    /// so "back" means the pointer moved.
    static var pointerIdleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    }

    private nonisolated(unsafe) static var displaysAsleep = false
    private nonisolated(unsafe) static var screenLocked = false
    static var userAway: Bool {
        #if DEBUG
        // Testing aid: pretend nobody is at the Mac while this file exists.
        if FileManager.default.fileExists(atPath: "/tmp/notch-agent-force-away") { return true }
        #endif
        // Only truly away: sitting still to read or watch isn't. Counting
        // 20 s without input as "away" held finished-turn cards down for
        // people who were right there.
        return displaysAsleep || screenLocked
    }
    private var previousBounds: (rect: NSRect, until: Date)?
    private var hotKey: HotKey?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []

    init(store: Store, services: Services) {
        self.store = store
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Only the reply field takes the keyboard; clicking a button leaves
        // focus with whatever app the user was in.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(store: store, ui: ui, services: services).steadyGlass())
        panel.onCancel = { [weak self] in self?.ui.mode = .closed }

        layout()
        panel.orderFrontRegardless()

        // Menus (pickers, ⚙) are tracked by the system; their windows aren't
        // ours to hit-test, so follow tracking begin and end instead.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuOpen = true }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                self?.menuOpen = false
                self?.menuSeenAt = Date()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &subscriptions)

        // @Published emits before the property changes, so work from the
        // emitted value rather than reading store.approvals here.
        store.$approvals
            .scan(([Approval](), [Approval]())) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                guard let self, current.count > previous.count, let approval = current.last else { return }
                self.ui.page = .thread(approval.sessionID)
                if !self.ui.isOpen { self.open(pin: .approval) }
            }
            .store(in: &subscriptions)

        ui.$mode
            .removeDuplicates()
            .sink { [weak self] mode in self?.modeChanged(to: mode) }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { _ in Self.displaysAsleep = true }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { _ in Self.displaysAsleep = false }
            .store(in: &subscriptions)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { _ in Self.screenLocked = true }
            .store(in: &subscriptions)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { _ in Self.screenLocked = false }
            .store(in: &subscriptions)

        // A finished turn drops the notch down to show the reply, unless
        // it's already open (then the thread updates in place).
        store.$drop
            .compactMap { $0 }
            .sink { [weak self] drop in
                guard let self else { return }
                guard self.ui.mode == .closed || self.ui.mode == .peek || self.ui.mode == .drop else {
                    EventLog.write("drop skipped for \(drop.sessionID.prefix(8)): notch is \(self.ui.mode)")
                    return
                }
                EventLog.write("drop shown for \(drop.sessionID.prefix(8)) (+\(drop.others.count) others), away=\(Self.userAway)")
                self.dropShownAt = Date()
                self.dropHoveredAt = .distantPast
                self.dropDuration = 6
                self.dropWaitedForUser = false
                self.ui.mode = .drop
            }
            .store(in: &subscriptions)

        hotKey = HotKey { [weak self] in
            guard let self else { return }
            if self.ui.isOpen {
                self.ui.mode = .closed
            } else {
                // The Ask shortcut: open on Ask with the keyboard ready.
                self.ui.page = .ask
                self.open(pin: .hotKey)
                self.panel.makeKey()
            }
        }

        // Closed, the notch only cares when the pointer moves, so it listens
        // for mouse moves instead of a 30 Hz timer that woke the app all day.
        // Open, peeking or dropped down it also runs on a timer (timeouts,
        // the panel moving under a still pointer).
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }) { monitors.append(local) }
        updateTimer(for: ui.mode)
    }

    private func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        var insetTop = screen.safeAreaInsets.top
        #if DEBUG
        // Testing aid: lay out as on a Mac without a notch.
        if FileManager.default.fileExists(atPath: "/tmp/notch-agent-no-notch") { insetTop = 0 }
        #endif
        if insetTop > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            ui.hasNotch = true
            ui.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: insetTop)
        } else {
            ui.hasNotch = false
            ui.notchSize = CGSize(width: 196, height: NSStatusBar.system.thickness)
        }
        let size = NotchUI.windowSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func open(pin: Pin) {
        self.pin = pin
        outsideSince = nil
        ui.mode = .open
    }

    private func modeChanged(to mode: NotchUI.Mode) {
        updateTimer(for: mode)
        if lastMode == .drop && mode != .drop { EventLog.write("drop ended: notch now \(mode)") }
        lastMode = mode
        if mode != .drop { store.dismissDrop() }
        if mode != .open {
            pin = .none
            currentBounds = nil
            previousBounds = nil
        }
        if mode == .closed && panel.isKeyWindow {
            // Hand the keyboard back to the app the user came from.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func updateTimer(for mode: NotchUI.Mode) {
        if mode == .closed {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Only when it changes: mouse moves now call in at up to 120 Hz.
    private func setTakesMouse(_ takes: Bool) {
        if panel.ignoresMouseEvents == takes { panel.ignoresMouseEvents = !takes }
    }

    /// Hit testing by hand: the window is much bigger than what it draws,
    /// so it only takes the mouse while the pointer is over the notch or its
    /// dock, and clicks everywhere else reach the apps underneath.
    private func trackMouse() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        let top = screen.frame.maxY, mid = screen.frame.midX
        let shape = NSRect(x: mid - ui.shapeSize.width / 2, y: top - ui.shapeSize.height,
                           width: ui.shapeSize.width, height: ui.shapeSize.height + 1)
        // When closed and quiet the shape is just the hardware notch; give
        // the pointer a little extra room to find it.
        let hotZone = shape.insetBy(dx: -6, dy: 0).union(
            NSRect(x: mid - ui.notchSize.width / 2, y: top - ui.notchSize.height, width: ui.notchSize.width, height: ui.notchSize.height + 1))

        switch ui.mode {
        case .closed:
            setTakesMouse(false)
            if hotZone.contains(mouse) {
                // Dragging something over the notch opens it to drop into.
                ui.mode = NSEvent.pressedMouseButtons & 1 != 0 ? .open : .peek
            }
        case .peek:
            let switchArea = NSRect(x: mid - ui.switchSize.width / 2, y: shape.minY - NotchUI.dockGap - ui.switchSize.height,
                                    width: ui.switchSize.width, height: ui.switchSize.height + NotchUI.dockGap)
            let inside = hotZone.insetBy(dx: -4, dy: -6).contains(mouse) || switchArea.insetBy(dx: -8, dy: -4).contains(mouse)
            setTakesMouse(inside)
            if !inside { ui.mode = .closed }
        case .drop:
            // Up after 6 s on its own. Hovering holds it; once the pointer
            // has been on it and left, it goes up a second later (it's been
            // seen), whatever is left of the 6 s.
            let bounds = ui.shapeProbe.screenFrame?.insetBy(dx: -14, dy: -14) ?? hotZone
            let inside = bounds.contains(mouse)
            setTakesMouse(inside)
            let now = Date()
            if inside { dropHoveredAt = now }
            // Nobody at the Mac (display off or locked): keep the card down.
            // Its 8 s start once the pointer moves again.
            if Self.userAway {
                if !dropWaitedForUser { EventLog.write("drop waiting: user away") }
                dropWaitedForUser = true
                dropShownAt = now
            } else if dropWaitedForUser {
                if Self.pointerIdleSeconds > 1.5 {
                    dropShownAt = now
                } else {
                    EventLog.write("drop: user back (pointer moved), showing 8 s more")
                    dropWaitedForUser = false
                    dropDuration = 8
                    dropShownAt = now
                }
            }
            let shownLongEnough = now.timeIntervalSince(dropShownAt) > dropDuration
            let hovered = dropHoveredAt > dropShownAt
            let leftFor = now.timeIntervalSince(dropHoveredAt)
            if !dropWaitedForUser, hovered ? leftFor > 1 : shownLongEnough {
                EventLog.write("drop dismissed: \(hovered ? "pointer left" : "timed out")")
                ui.mode = .closed
            }
        case .open:
            // The border is what's actually drawn: the panel, the dock under
            // it and the gap between, with a margin so a slight overshoot
            // doesn't count.
            guard let shapeFrame = ui.shapeProbe.screenFrame else { break }
            // The gap between panel and dock counts too (the union covers it).
            let bounds = shapeFrame.union(ui.dockProbe.screenFrame ?? shapeFrame).insetBy(dx: -14, dy: -14)
            // When a page change shrinks the panel, the dock slides up from
            // under the pointer; the old outline counts for a second.
            let now = Date()
            if let current = currentBounds, current != bounds {
                previousBounds = (current, now.addingTimeInterval(1))
            }
            currentBounds = bounds
            let lingering = previousBounds.map { now < $0.until && $0.rect.contains(mouse) } ?? false
            // The notch's own menus (pickers, ⚙) can stick out past its
            // edge: pointing at one counts as inside, and so does the moment
            // after picking from it.
            if menuOpen { menuSeenAt = now }
            let justUsedMenu = menuSeenAt.map { now.timeIntervalSince($0) < 1 } ?? false
            let inside = bounds.contains(mouse) || lingering || menuOpen || justUsedMenu
            let dragging = NSEvent.pressedMouseButtons != 0
            setTakesMouse(inside || dragging)
            let held = pin == .hotKey || (pin == .approval && !store.approvals.isEmpty)
            if inside {
                pin = .none
                outsideSince = nil
            } else if dragging || isEditingText || held {
                // Mid-drag, typing a reply, or opened on purpose: stay.
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) > 0.4 { ui.mode = .closed }
            } else {
                outsideSince = Date()
            }
        }
    }

    /// Something is typed in the reply or Ask field. An empty field with
    /// the cursor in it doesn't hold the notch open.
    private var isEditingText: Bool {
        guard panel.isKeyWindow, let editor = panel.firstResponder as? NSTextView else { return false }
        return !editor.string.isEmpty
    }
}

/// A panel that can take keyboard focus for the reply field without
/// activating the app, and closes on Esc.
final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The Ask shortcut (⌥ Space unless changed in Settings), system-wide,
/// through Carbon's hot key API (no Accessibility permission needed). It
/// re-registers when the shortcut changes. If another app already owns the
/// combination, registration fails, which is logged, and the notch still
/// opens by pointer.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var observer: Any?
    private nonisolated(unsafe) static var action: (() -> Void)?
    /// Set while Settings records a new shortcut, so pressing the old one
    /// doesn't open the notch.
    nonisolated(unsafe) static var paused = false

    init(action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { if !HotKey.paused { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
        register(Shortcut.current)
        observer = NotificationCenter.default.addObserver(forName: Shortcut.changed, object: nil, queue: .main) { [weak self] _ in
            self?.register(Shortcut.current)
        }
    }

    private func register(_ shortcut: Shortcut) {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let id = EventHotKeyID(signature: OSType(0x4E54_4348), id: 1) // "NTCH"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status != noErr { EventLog.write("shortcut \(shortcut.display) is taken by another app (\(status))") }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
