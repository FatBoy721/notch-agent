import AppKit
import SwiftUI

/// Timing and the small animated pieces the notch is built from. The
/// spring, the focus-in and the rim light follow the liquid-glass-screens
/// motion spec (docs/MOTION_SPEC.md); Reduce Motion gets its calmer spring
/// and no blur.
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

    /// New rows drop in from just above.
    static let row = AnyTransition.opacity.combined(with: .offset(y: -4)).animation(.easeOut(duration: 0.3))
}

private struct Defocus: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

/// The glass's single hairline of rim light: brightest toward one o'clock,
/// fading round toward ten and to almost nothing underneath.
struct RimLight<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.stroke(
            AngularGradient(stops: [
                .init(color: .white.opacity(0.05), location: 0.0),    // 3 o'clock
                .init(color: .white.opacity(0.03), location: 0.25),   // 6
                .init(color: .white.opacity(0.06), location: 0.5),    // 9
                .init(color: .white.opacity(0.14), location: 0.66),   // 10
                .init(color: .white.opacity(0.30), location: 0.80),   // 12–1
                .init(color: .white.opacity(0.12), location: 0.92),   // 2
                .init(color: .white.opacity(0.05), location: 1.0),
            ], center: .center),
            lineWidth: 1
        )
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

/// A status dot with a soft ring that breathes out from it.
struct PulseDot: View {
    var color: Color = Palette.accent
    var animated = true

    var body: some View {
        TimelineView(.animation(paused: !animated)) { timeline in
            let phase = animated ? (timeline.date.timeIntervalSinceReferenceDate / 1.4).truncatingRemainder(dividingBy: 1) : 0
            let swell = sin(phase * .pi) // 0 → 1 → 0 over one beat
            ZStack {
                Circle()
                    .fill(color.opacity(0.22 * (1 - swell)))
                    .frame(width: 8 + 6 + 4 * swell, height: 8 + 6 + 4 * swell)
                Circle().fill(color).frame(width: 8, height: 8)
            }
            .frame(width: 18, height: 18)
        }
    }
}

/// A faint track with an arc that draws itself around it while spinning.
struct ArcSpinner: View {
    var size: CGFloat = 12
    var color: Color = .white

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = (t / 1.6).truncatingRemainder(dividingBy: 1)
            // First half the arc grows, second half its tail chases the head.
            let head = min(1, cycle * 2) * 0.99
            let tail = max(0, cycle * 2 - 1) * 0.99
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 2.2)
                Circle()
                    .trim(from: tail, to: max(tail + 0.02, head))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(t / 1.6 * 360 - 90))
            }
            .frame(width: size, height: size)
        }
    }
}

/// Four bars bouncing out of phase: the "now playing" waves.
struct LevelBars: View {
    var color: Color = .white
    var playing = true
    var height: CGFloat = 14
    private static let offsets: [Double] = [0, 0.5, 0.22, 0.72]

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate / 0.9
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = 0.5 - 0.5 * cos(2 * .pi * (t + Self.offsets[index]))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: 3, height: height)
                        .scaleEffect(y: playing ? 0.3 + 0.7 * wave : 0.3, anchor: .center)
                }
            }
            .frame(height: height)
        }
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
        "grok": Style(name: "Grok", red: 0.9, green: 0.9, blue: 0.9, idle: "⊘", frames: ["⊘", "○"]),
        "cline": Style(name: "Cline", red: 0.95, green: 0.95, blue: 0.95, idle: "◈", frames: ["◈", "◇"]),
        "kimi": Style(name: "Kimi", red: 0.45, green: 0.7, blue: 1, idle: "◐", frames: ["◐", "◓", "◑", "◒"]),
        "droid": Style(name: "Droid", red: 0.95, green: 0.6, blue: 0.25, idle: "⬣", frames: ["⬣", "⬡"]),
        "devin": Style(name: "Devin", red: 0.4, green: 0.8, blue: 0.75, idle: "◍", frames: ["◍", "○"]),
        "kiro": Style(name: "Kiro", red: 0.6, green: 0.45, blue: 0.95, idle: "◭", frames: ["◭", "◮"]),
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
        } else {
            TimelineView(.animation(minimumInterval: 0.12, paused: !busy)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
                Text(busy ? kind.frames[tick % kind.frames.count] : kind.idleGlyph)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(kind.color)
                    .frame(width: size * 1.25, height: size * 1.25)
            }
        }
    }
}

/// Codex's mark, drawn: a scalloped cloud shading lavender to deep blue
/// with a `>_` prompt on it. While Codex works the cloud turns slowly and
/// the cursor blinks.
struct CodexMark: View {
    var busy = false
    var size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !busy)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                CodexCloud()
                    .fill(LinearGradient(colors: [Color(red: 0.73, green: 0.66, blue: 0.98),
                                                  Color(red: 0.42, green: 0.53, blue: 0.97),
                                                  Color(red: 0.2, green: 0.17, blue: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
                    .rotationEffect(.degrees(busy ? (t * 40).truncatingRemainder(dividingBy: 360) : 0))
                CodexPrompt(cursorOn: !busy || Int(t * 2.2) % 2 == 0)
                    .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.5, height: size * 0.32)
            }
            .frame(width: size, height: size)
        }
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
    var cursorOn = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        if cursorOn {
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

    var body: some View {
        TimelineView(.animation) { context in
            // Sweep from just before the text to just past it, then rest.
            let cycle = (context.date.timeIntervalSinceReferenceDate / 2.0).truncatingRemainder(dividingBy: 1)
            let center = -0.3 + cycle * 1.8
            let label = Text(text).font(.system(size: size, weight: weight))
            label
                .foregroundStyle(color)
                .overlay(
                    LinearGradient(stops: [
                        .init(color: highlight.opacity(0), location: max(0, center - 0.18)),
                        .init(color: highlight, location: min(1, max(0, center))),
                        .init(color: highlight.opacity(0), location: min(1, center + 0.18)),
                    ], startPoint: .leading, endPoint: .trailing)
                    .mask(label)
                )
        }
    }
}

/// A key cap, as in ⌥ Space.
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
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Measured with onGeometryChange: a preference callback doesn't fire
        // again when a page comes back with the same content height, which
        // left this at 0 while the list still drew past the notch's edge.
        ScrollView(showsIndicators: false) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .defaultScrollAnchor(anchorBottom ? .bottom : .top)
        .frame(height: min(contentHeight, maxHeight))
        .clipped()
    }
}


/// Width of a single line of text, for sizing the closed notch's wings.
func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width.rounded(.up)
}

// MARK: - Activity grid and glass

/// A 3×3 grid of dots twinkling out of step: the "working" mark in lists.
struct ActivityGrid: View {
    var color: Color = Palette.accent
    var animating = true
    private static let phases: [Double] = [0.1, 0.55, 0.3, 0.8, 0.0, 0.65, 0.4, 0.95, 0.2]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 1.1
            VStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { column in
                            let phase = Self.phases[row * 3 + column]
                            let level = animating ? 0.5 + 0.5 * sin(2 * .pi * (t + phase)) : 0.35
                            RoundedRectangle(cornerRadius: 0.8)
                                .fill(color.opacity(0.2 + 0.8 * level))
                                .frame(width: 3.2, height: 3.2)
                        }
                    }
                }
            }
        }
    }
}

/// The notch's look, chosen in ⚙ › Appearance.
enum NotchAppearance: String, CaseIterable {
    case glass, black

    static let key = "notchAppearance"

    var title: String { self == .glass ? "Glass" : "Full black" }
}

extension View {
    /// Liquid Glass on macOS 26 and later (darkened so text stays legible
    /// over anything) when the Glass look is on; a solid fill otherwise.
    @ViewBuilder
    func notchGlass<S: Shape>(in shape: S, tint: Color = .black.opacity(0.5), fallback: Color = .black.opacity(0.86),
                              interactive: Bool = false, appearance: NotchAppearance = .glass) -> some View {
        if appearance == .glass, #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(shape.fill(appearance == .black ? .black : fallback))
        }
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
