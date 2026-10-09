import AppKit
import SwiftUI

/// Timing and the small animated pieces the notch is built from. The
/// spring and the focus-in follow the motion spec (docs/MOTION_SPEC.md);
/// Reduce Motion gets its calmer spring and no blur.
enum Motion {
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opening and closing: the spec's landing spring
    /// `{ damping: 15, stiffness: 120, mass: 1.05 }`, a little overshoot so the
    /// notch stretches out of the bezel; `{ 30, 160, 1 }` under Reduce Motion.
    static var morph: Animation {
        reduceMotion ? .interpolatingSpring(mass: 1, stiffness: 160, damping: 30)
                     : .interpolatingSpring(mass: 1.05, stiffness: 120, damping: 15)
    }

    /// Resizes while already open (page changes, rows arriving): no overshoot.
    static let calm = Animation.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.45)

    /// Headlines in: 520 ms on `bezier(0.23, 1, 0.32, 1)`; out: 240 ms ease-out.
    static let focusIn = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.52)
    static let focusOut = Animation.easeOut(duration: 0.24)

    /// Page content comes into focus (defocus 14 → 0) as it fades in,
    /// settling from slightly smaller; it leaves quickly.
    static var content: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.2)) }
        return .asymmetric(
            insertion: .modifier(active: Defocus(radius: 14, opacity: 0), identity: Defocus(radius: 0, opacity: 1))
                .animation(focusIn.delay(0.08))
                .combined(with: .scale(scale: 0.96, anchor: .top).animation(calm)),
            removal: .modifier(active: Defocus(radius: 8, opacity: 0), identity: Defocus(radius: 0, opacity: 1))
                .animation(focusOut)
        )
    }

    /// Switching pages while open: the same focus-in, quicker.
    static var page: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: Defocus(radius: 10, opacity: 0), identity: Defocus(radius: 0, opacity: 1))
                .animation(Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.4)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }

    /// New rows rise into place and come into focus, GlassCode's entrance:
    /// up 18 pt, blur 10 → 0, fading in, 0.55 s on (0.16, 1, 0.3, 1).
    static var row: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.2)) }
        let entrance = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)
        return .asymmetric(
            insertion: .modifier(active: Defocus(radius: 10, opacity: 0), identity: Defocus(radius: 0, opacity: 1))
                .combined(with: .offset(y: 18)).animation(entrance),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }

    /// A row leaving dissolves into drifting dust (GlassCode's "Thanos" exit).
    static var dust: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .modifier(active: DustEffect(progress: 1), identity: DustEffect(progress: 0))
            .animation(.easeOut(duration: 0.85))
    }

    /// The selection highlight gliding between dock or sidebar items.
    static let glide = Animation.spring(response: 0.35, dampingFraction: 0.86)
}

/// The view fades and softens while specks lift off it and drift away.
private struct DustEffect: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .blur(radius: progress * 3)
            .overlay {
                if progress > 0 && progress < 1 {
                    Canvas { context, size in
                        for index in 0..<70 {
                            // Fixed per-speck randomness, so it drifts rather than flickers.
                            let a = Double((index &* 7919) % 997) / 997, b = Double((index &* 104_729) % 991) / 991
                            let start = CGPoint(x: a * size.width, y: b * size.height)
                            // Specks further right go first, as if blown off.
                            let local = min(1, max(0, progress * 1.6 - (1 - a) * 0.6))
                            let point = CGPoint(x: start.x + local * (30 + 50 * b), y: start.y - local * (14 + 30 * a))
                            context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1.8, height: 1.8)),
                                         with: .color(.white.opacity(0.7 * (1 - local) * min(1, local * 6))))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

private struct Defocus: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

enum Palette {
    static let accent = Color(red: 0.91, green: 0.51, blue: 0.37)   // #e8825e
    static let ok = Color(red: 0.29, green: 0.87, blue: 0.5)        // #4ade80
    static let warn = Color(red: 0.98, green: 0.75, blue: 0.14)     // #fbbf24
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)   // #d97757
    static let codex = Color(red: 0.55, green: 0.66, blue: 1)       // #8ca8ff
    static let mute = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.07)
}

// MARK: - Shape

/// The notch: square top, rounded bottom, and concave "ears" at the top
/// corners so it reads as part of the bezel. The ears sit outside the
/// content width, so the shape is `2 * ear` wider than what it holds.
struct NotchShape: Shape {
    var radius: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, ear) }
        set { radius = newValue.first; ear = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, (rect.width - 2 * ear) / 2)
        let left = rect.minX + ear, right = rect.maxX - ear
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + ear), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - r), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Indicators

// The looping marks below run as repeating SwiftUI animations rather than
// per-frame TimelineViews: an animated scale, offset or opacity is drawn by
// the render server, while a TimelineView re-runs the view and lays out the
// whole notch every frame (≈12% CPU for one spinner, and dropped frames in
// whatever transition runs beside it). Each loop is scoped with
// `.animation(_:body:)` to just its own scale, opacity, offset or rotation:
// a plain `.animation(_:value:)` also caught the view's position while a
// page slid in, and the mark then wandered back and forth forever.

/// A status dot with a soft ring that breathes out from it.
struct PulseDot: View {
    var color: Color = Palette.accent
    var animated = true
    @State private var swelling = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 14, height: 14)
                .animation(animated ? .easeOut(duration: 1.4).repeatForever(autoreverses: false) : .default) {
                    $0.scaleEffect(swelling ? 18.0 / 14 : 1).opacity(swelling ? 0 : 1)
                }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .onAppear { swelling = animated }
        .onChange(of: animated) { _, on in swelling = on }
    }
}

/// A faint track with an arc that draws itself around it while spinning.
struct ArcSpinner: View {
    var size: CGFloat = 12
    var color: Color = .white
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    $0.rotationEffect(.degrees(turning ? 270 : -90))
                }
        }
        .frame(width: size, height: size)
        .onAppear { turning = true }
        // Reset, so a view SwiftUI hides and shows again (same identity,
        // state kept) starts turning again instead of freezing.
        .onDisappear { turning = false }
    }
}

/// Four bars bouncing out of phase: the "now playing" waves.
struct LevelBars: View {
    var color: Color = .white
    var playing = true
    var height: CGFloat = 14
    /// Each bar's head start, so they bounce out of step.
    private static let offsets: [Double] = [0, 0.45, 0.2, 0.65]
    @State private var bouncing = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: height)
                    .animation(bouncing ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Self.offsets[index])
                                        : .easeOut(duration: 0.3)) {
                        $0.scaleEffect(y: bouncing ? 1 : 0.3, anchor: .center)
                    }
            }
        }
        .frame(height: height)
        .onAppear { bouncing = playing }
        .onChange(of: playing) { _, on in bouncing = on }
    }
}

/// An agent CLI: its name, color and glyph. Claude and Codex use the
/// characters their own terminals animate; the rest get a mark in their
/// brand color. `id` is herdr's agent kind name.
struct AgentKind: Hashable, Sendable {
    let id: String

    static let claude = AgentKind(id: "claude")
    static let codex = AgentKind(id: "codex")
    static let gemini = AgentKind(id: "gemini")
    static let hermes = AgentKind(id: "hermes")

    private struct Style {
        let name: String
        let red: Double, green: Double, blue: Double
        let idle: String
        let frames: [String]
    }

    private static let styles: [String: Style] = [
        "claude": Style(name: "Claude Code", red: 0.85, green: 0.47, blue: 0.34, idle: "✳",
                        frames: ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]),
        "codex": Style(name: "Codex", red: 0.55, green: 0.66, blue: 1, idle: "❯",
                       frames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]),
        "gemini": Style(name: "Gemini", red: 0.55, green: 0.55, blue: 1, idle: "✦", frames: ["✦", "✧", "✦", "⋆"]),
        "cursor": Style(name: "Cursor", red: 0.85, green: 0.85, blue: 0.85, idle: "⬢", frames: ["⬢", "⬡"]),
        "opencode": Style(name: "OpenCode", red: 0.75, green: 0.78, blue: 0.82, idle: "▣", frames: ["▣", "▢"]),
        "copilot": Style(name: "Copilot", red: 0.62, green: 0.55, blue: 0.95, idle: "◉", frames: ["◉", "◎"]),
        "amp": Style(name: "Amp", red: 0.95, green: 0.42, blue: 0.32, idle: "ϟ", frames: ["ϟ", "⚡︎"]),
        "aider": Style(name: "Aider", red: 0.35, green: 0.85, blue: 0.5, idle: "◆", frames: ["◆", "◇"]),
        "grok": Style(name: "Grok Build", red: 0.9, green: 0.9, blue: 0.9, idle: "⊘", frames: ["⊘", "○"]),
        "muse": Style(name: "Muse Code", red: 0.3, green: 0.55, blue: 1, idle: "✺", frames: ["✺", "✹", "✸", "✹"]),
        "zcode": Style(name: "ZCode (GLM)", red: 0.4, green: 0.62, blue: 1, idle: "◇", frames: ["◇", "◈"]),
        "openclaw": Style(name: "OpenClaw", red: 1, green: 0.38, blue: 0.3, idle: "⟡", frames: ["⟡", "✦"]),
        "cline": Style(name: "Cline", red: 0.95, green: 0.95, blue: 0.95, idle: "◈", frames: ["◈", "◇"]),
        "kimi": Style(name: "Kimi", red: 0.45, green: 0.7, blue: 1, idle: "◐", frames: ["◐", "◓", "◑", "◒"]),
        "droid": Style(name: "Droid", red: 0.95, green: 0.6, blue: 0.25, idle: "⬣", frames: ["⬣", "⬡"]),
        "devin": Style(name: "Devin", red: 0.4, green: 0.8, blue: 0.75, idle: "◍", frames: ["◍", "○"]),
        "kiro": Style(name: "Kiro", red: 0.6, green: 0.45, blue: 0.95, idle: "◭", frames: ["◭", "◮"]),
        "hermes": Style(name: "Hermes", red: 0.96, green: 0.78, blue: 0.36, idle: "☤", frames: ["☤", "✧", "☤", "✦"]),
    ]

    private var style: Style {
        Self.styles[id] ?? Style(name: id.prefix(1).uppercased() + id.dropFirst(), red: 0.8, green: 0.8, blue: 0.8,
                                 idle: "●", frames: ["●", "○"])
    }

    var name: String { style.name }
    var color: Color { Color(red: style.red, green: style.green, blue: style.blue) }
    var highlight: Color { Color(red: min(1, style.red + 0.3), green: min(1, style.green + 0.3), blue: min(1, style.blue + 0.3)) }
    var idleGlyph: String { style.idle }
    var frames: [String] { style.frames }
}

/// An agent's live mark: its glyph cycling while it works, resting when idle.
struct AgentGlyph: View {
    var kind: AgentKind = .claude
    var busy = false
    var size: CGFloat = 15

    var body: some View {
        if kind == .codex {
            CodexMark(busy: busy, size: size * 1.2)
                .frame(width: size * 1.25, height: size * 1.25)
        } else if let logo = BrandImage.logo(for: kind) {
            // Services with a picture for a logo: the picture, breathing
            // gently while it works.
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.2, height: size * 1.2)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3))
                .frame(width: size * 1.25, height: size * 1.25)
                .animation(busy ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default) {
                    $0.opacity(busy ? 0.55 : 1)
                }
        } else if busy {
            BusyGlyph(kind: kind, size: size)
        } else {
            Text(kind.idleGlyph)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(kind.color)
                .frame(width: size * 1.25, height: size * 1.25)
        }
    }
}

/// A working agent's glyph, stepping through its frames on the shared clock.
private struct BusyGlyph: View {
    let kind: AgentKind
    let size: CGFloat
    @ObservedObject private var clock = GlyphClock.shared
    @State private var token = UUID()

    var body: some View {
        Text(kind.frames[clock.tick % kind.frames.count])
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(kind.color)
            .frame(width: size * 1.25, height: size * 1.25)
            .onAppear { clock.retain(token) }
            .onDisappear { clock.release(token) }
    }
}

/// One 8 Hz tick shared by every busy glyph, so they all step in the same
/// frame. Each glyph with its own timer forced its own layout pass of the
/// notch: dozens a second with a few agents working, and Threads lagged.
@MainActor
final class GlyphClock: ObservableObject {
    static let shared = GlyphClock()
    @Published private(set) var tick = 0
    /// The glyphs on screen. A set, not a count: SwiftUI can call onAppear
    /// twice without onDisappear between during transitions, and a count
    /// would then never get back to zero and the timer would never stop.
    private var users = Set<UUID>()
    private var timer: Timer?

    func retain(_ user: UUID) {
        users.insert(user)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick &+= 1 }
        }
        // .common keeps it ticking while a list is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func release(_ user: UUID) {
        users.remove(user)
        guard users.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// Codex's mark, drawn: a scalloped cloud shading lavender to deep blue
/// with a `>_` prompt on it. While Codex works the cloud turns slowly and
/// the cursor blinks.
struct CodexMark: View {
    var busy = false
    var size: CGFloat = 18
    @State private var working = false

    var body: some View {
        ZStack {
            CodexCloud()
                .fill(LinearGradient(colors: [Color(red: 0.73, green: 0.66, blue: 0.98),
                                              Color(red: 0.42, green: 0.53, blue: 0.97),
                                              Color(red: 0.2, green: 0.17, blue: 0.95)],
                                     startPoint: .top, endPoint: .bottom))
                .animation(working ? .linear(duration: 9).repeatForever(autoreverses: false) : .easeOut(duration: 0.4)) {
                    $0.rotationEffect(.degrees(working ? 360 : 0))
                }
            let stroke = StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round, lineJoin: .round)
            ZStack {
                CodexPrompt(chevron: true, cursor: false).stroke(.white.opacity(0.92), style: stroke)
                CodexPrompt(chevron: false, cursor: true).stroke(.white.opacity(0.92), style: stroke)
                    .animation(working ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .default) {
                        $0.opacity(working ? 0 : 1)
                    }
            }
            .frame(width: size * 0.5, height: size * 0.32)
        }
        .frame(width: size, height: size)
        .onAppear { working = busy }
        .onChange(of: busy) { _, on in working = on }
    }
}

/// Eight round lobes around a round middle.
private struct CodexCloud: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - radius * 0.72, y: center.y - radius * 0.72, width: radius * 1.44, height: radius * 1.44))
        for lobe in 0..<8 {
            let angle = Double(lobe) / 8 * 2 * .pi
            let lobeCenter = CGPoint(x: center.x + cos(angle) * radius * 0.66, y: center.y + sin(angle) * radius * 0.66)
            let lobeRadius = radius * 0.34
            path.addEllipse(in: CGRect(x: lobeCenter.x - lobeRadius, y: lobeCenter.y - lobeRadius, width: lobeRadius * 2, height: lobeRadius * 2))
        }
        return path
    }
}

/// `>_`: the chevron always, the underscore while the cursor is on.
private struct CodexPrompt: Shape {
    var chevron = true
    var cursor = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if chevron {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if cursor {
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

/// Text with a bright band sweeping across it, like Claude Code's
/// "Combobulating…" line.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 12.5
    var weight: Font.Weight = .semibold
    var color: Color = Palette.claude
    var highlight = Color(red: 1, green: 0.82, blue: 0.7)
    @State private var sweeping = false

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: weight))
        label
            .foregroundStyle(color)
            .overlay(
                // A bright band slides from before the text to past it, then
                // starts over; only the slide is animated, never the layout.
                GeometryReader { proxy in
                    let band = proxy.size.width * 0.36
                    LinearGradient(colors: [highlight.opacity(0), highlight, highlight.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                            $0.offset(x: sweeping ? proxy.size.width * 1.5 : -band * 1.5)
                        }
                }
                .mask(label)
            )
            .onAppear { sweeping = true }
            .onDisappear { sweeping = false }
    }
}

/// A key cap, as in the ⌥ Space shortcut.
struct Kbd: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .semibold))
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 19)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// What a working agent is doing right now: the tool it's running, or
/// Claude's thinking verb (read off its terminal when possible).
struct ActivityLabel: View {
    let activity: Activity
    var size: CGFloat = 12.5
    var showsDetail = false
    /// Off where the agent's glyph is already shown beside it.
    var showsGlyph = true

    var body: some View {
        HStack(spacing: 6) {
            switch activity {
            case .tool(let name):
                ArcSpinner(size: size - 0.5)
                Text(name).font(.system(size: size, weight: .semibold))
            case .thinking(let kind, let verb, let detail):
                if showsGlyph { AgentGlyph(kind: kind, busy: true, size: size + 1) }
                ShimmerText(text: verb + "…", size: size,
                            color: kind.color, highlight: kind.highlight)
                if showsDetail, let detail {
                    Text(detail).font(.system(size: size - 1, weight: .medium)).foregroundStyle(Palette.mute)
                }
            }
        }
        .lineLimit(1)
    }
}

enum Activity: Hashable {
    case tool(String)
    case thinking(AgentKind, verb: String, detail: String?)

    var width: CGFloat {
        switch self {
        case .tool(let name): 12 + 6 + textWidth(name, size: 12.5)
        case .thinking(_, let verb, _): textWidth(verb + "…", size: 12.5)
        }
    }
}

// MARK: - Layout helpers

/// A scroll view that is only as tall as its content, up to `maxHeight`,
/// so the notch can hug short pages and still scroll long ones.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    var anchorBottom = false
    /// Fades the bottom edge while there's more below, so a long list
    /// doesn't look like it ends at the cut.
    var fadesOverflow = false
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    private var overflows: Bool { fadesOverflow && contentHeight > maxHeight }

    var body: some View {
        // Measured with onGeometryChange: a preference callback doesn't fire
        // again when a page comes back with the same content height, which
        // left this at 0 while the list still drew past the notch's edge.
        ScrollView(showsIndicators: overflows) {
            content
                .padding(.bottom, overflows ? 28 : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 - (overflows ? 28 : 0) }
        }
        .defaultScrollAnchor(anchorBottom ? .bottom : .top)
        .softTopEdge()
        .frame(height: min(contentHeight, maxHeight))
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: overflows ? 0.86 : 1),
                                     .init(color: overflows ? .clear : .black, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}


/// Width of a single line of text, for sizing the closed notch's wings.
func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width.rounded(.up)
}

// MARK: - Activity grid

/// A 3×3 grid of dots twinkling out of step: the "working" mark in lists.
struct ActivityGrid: View {
    var color: Color = Palette.accent
    var animating = true
    private static let phases: [Double] = [0.1, 0.55, 0.3, 0.8, 0.0, 0.65, 0.4, 0.95, 0.2]
    @State private var twinkling = false

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { column in
                        let phase = Self.phases[row * 3 + column]
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(color)
                            .frame(width: 3.2, height: 3.2)
                            .animation(twinkling ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(phase * 1.1)
                                                 : .easeOut(duration: 0.3)) {
                                $0.opacity(twinkling ? 1 : 0.2 + 0.8 * 0.35)
                            }
                    }
                }
            }
        }
        .onAppear { twinkling = animating }
        .onChange(of: animating) { _, on in twinkling = on }
    }
}

// MARK: - Brand images and glass

/// Logos that are pictures: Hermes (Nous Research) and OpenClaw ship in
/// the app's Resources; Spotify and Music come from the installed apps.
@MainActor
enum BrandImage {
    private static var cache: [String: NSImage] = [:]

    static func logo(for kind: AgentKind) -> NSImage? {
        ["hermes", "openclaw"].contains(kind.id) ? bundled(kind.id) : nil
    }

    /// From the app bundle; in a dev build (no bundle) from the repo.
    static func bundled(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../packaging/brand/\(name).png").standardized
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    /// An installed app's icon, e.g. Spotify or Music.
    static func app(_ bundleID: String) -> NSImage? {
        if let image = cache[bundleID] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

extension View {
    /// GlassCode's surface: Apple's Liquid Glass tinted dark (macOS 26 and
    /// later), or frosted glass before that.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tint: Double = 0.4, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(.black.opacity(tint)).interactive(interactive), in: shape)
        } else {
            background(GlassBackground(shape: shape))
        }
    }

    /// GlassCode's rim: a bright hairline along the top inner edge that
    /// fades down the sides, the cue that reads as glass.
    func glassRim<S: Shape>(_ shape: S, from start: CGFloat = 0) -> some View {
        overlay(shape.stroke(LinearGradient(stops: [
            .init(color: .white.opacity(start > 0 ? 0 : 0.32), location: 0),
            .init(color: .white.opacity(start > 0 ? 0 : 0.32), location: start),
            .init(color: .white.opacity(0.22), location: min(1, start + 0.02)),
            .init(color: .white.opacity(0.07), location: min(1, start + 0.4)),
            .init(color: .white.opacity(0.05), location: 1),
        ], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }

    /// Liquid Glass draws differently in a focused window (near-solid dark)
    /// than in an unfocused one (clear). The notch takes focus when clicked,
    /// for typing, so it flipped between the two; it always draws as
    /// unfocused, the clear glass.
    @ViewBuilder
    func steadyGlass() -> some View {
        if #available(macOS 15.0, *) {
            environment(\.appearsActive, false)
        } else {
            self
        }
    }

    /// Content scrolling under the top edge blurs away softly (macOS 26).
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// GlassCode's glass: what's behind the window, blurred, under a dark
/// translucent fill (so text stays legible over anything), with a hairline
/// edge.
struct GlassBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        ZStack {
            BehindWindowBlur().clipShape(shape)
            shape.fill(Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.82))
        }
        .overlay(shape.stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// The desktop and windows behind, blurred by the window server.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassThroughEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Never takes clicks; it's only a backdrop.
    private final class PassThroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Frame probes

/// An invisible AppKit view laid out exactly where the SwiftUI view it sits
/// behind is. Hit testing asks it for its frame on demand, instead of
/// trusting SwiftUI's geometry callbacks, which can report stale sizes after
/// animated layout changes.
final class FrameProbe {
    fileprivate weak var view: NSView?

    /// Where the view is on screen right now; nil while it isn't shown.
    var screenFrame: NSRect? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
}

struct ProbeView: NSViewRepresentable {
    let probe: FrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { probe.view = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
