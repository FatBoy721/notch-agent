import Foundation
import SwiftUI

/// Claude plan limits (the 5-hour session window and the weekly caps), the
/// same numbers Claude Code's /usage shows. They come from Anthropic's
/// usage endpoint, authorised with the sign-in Claude Code keeps in the
/// Keychain. The token is only ever sent to api.anthropic.com, and it is
/// never refreshed or written back here: Claude Code owns it.
struct PlanLimits {
    struct Window {
        let utilization: Double   // 0...100
        let resetsAt: Date?
    }

    var session: Window?
    var week: Window?
    var weekOpus: Window?
    var weekSonnet: Window?
    /// Usage credits ("extra usage") switched on for the account.
    var creditsEnabled: Bool?
    var checkedAt = Date()
}

/// The Claude subscription, as Claude Code's sign-in records it.
struct ClaudePlan: Equatable {
    let subscription: String   // "pro", "max", "team", "enterprise", "free"
    let tier: String?          // e.g. "default_claude_max_5x"

    var name: String {
        switch subscription {
        case "max":
            if tier?.contains("20x") == true { return "Max 20x" }
            if tier?.contains("5x") == true { return "Max 5x" }
            return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return subscription.capitalized
        }
    }
}

/// How Fable is billed for this account. Claude Code decides it from a
/// server setting it caches in ~/.claude.json: plans include Fable until
/// `planLimitsEndDate` (or until `overageConsentRequired` is switched on),
/// after which it runs on usage credits; some tiers (Enterprise) are
/// credits-only throughout. Mirrors Claude Code's own check.
enum FableAccess: Equatable {
    case included(plan: String, until: Date?)
    case credits(plan: String, creditsOn: Bool?)
    case unavailable
    case unknown

    static func evaluate(plan: ClaudePlan?, creditsEnabled: Bool?, now: Date = Date()) -> FableAccess {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = json["cachedGrowthBookFeatures"] as? [String: Any] else { return .unknown }
        if (flags["tengu-fable-off-switch"] as? [String: Any])?["activated"] as? Bool == true { return .unavailable }
        let planName = plan?.name ?? "your plan"
        let creditsOnlyTiers = flags["tengu_saffron_credits_only_tiers"] as? [String] ?? ["enterprise"]
        if let plan, creditsOnlyTiers.contains(plan.subscription) { return .credits(plan: planName, creditsOn: creditsEnabled) }
        guard let launch = flags["tengu_saffron_lattice"] as? [String: Any], launch["enabled"] as? Bool != false else {
            return .included(plan: planName, until: nil)
        }
        if launch["overageConsentRequired"] as? Bool == true { return .credits(plan: planName, creditsOn: creditsEnabled) }
        let parser = ISO8601DateFormatter()
        if let end = (launch["planLimitsEndDate"] as? String).flatMap(parser.date(from:)) {
            return now >= end ? .credits(plan: planName, creditsOn: creditsEnabled) : .included(plan: planName, until: end)
        }
        return .included(plan: planName, until: nil)
    }

    /// Beside Fable in the model menu.
    var badge: String? {
        switch self {
        case .included: "Included"
        case .credits(_, let on): on == false ? "Credits off" : "Uses usage credits"
        case .unavailable: "Unavailable"
        case .unknown: nil
        }
    }

    /// Under the pickers once Fable is chosen.
    var detail: String? {
        switch self {
        case .included(let plan, let until):
            until.map { "Included in \(plan) until \($0.formatted(date: .abbreviated, time: .omitted)), then it uses usage credits" }
                ?? "Included in \(plan)"
        case .credits(let plan, let on):
            switch on {
            case false?: "On \(plan), Fable uses usage credits, and yours are off. Turn them on at claude.ai › Settings › Usage."
            case true?: "On \(plan), Fable uses usage credits (billed beyond your plan)"
            case nil: "On \(plan), Fable uses usage credits"
            }
        case .unavailable: "Fable is switched off right now"
        case .unknown: nil
        }
    }
}

@MainActor
final class LimitsStore: ObservableObject {
    @Published private(set) var limits: PlanLimits?
    /// Codex's own limits, as its latest session log recorded them.
    @Published private(set) var codex: PlanLimits?
    @Published private(set) var problem: String?
    @Published private(set) var plan: ClaudePlan?
    @Published private(set) var fable: FableAccess = .unknown
    @Published private(set) var loading = false

    private var lastAttempt: Date?

    /// At most every five minutes (the endpoint rate-limits, and the
    /// numbers move slowly). On failure the last good numbers stay up.
    func refresh() {
        if loading { return }
        if let attempt = lastAttempt, Date().timeIntervalSince(attempt) < 300 { return }
        lastAttempt = Date()
        loading = true
        Task {
            defer { loading = false }
            codex = await Task.detached(priority: .utility) { CodexLimits.latest() }.value
            plan = await Task.detached(priority: .utility) { ClaudeAccount.plan() }.value
            do {
                limits = try await ClaudeAccount.fetchLimits()
                problem = nil
            } catch {
                if limits == nil { problem = error.localizedDescription }
            }
            let plan = plan, credits = limits?.creditsEnabled
            fable = await Task.detached(priority: .utility) { FableAccess.evaluate(plan: plan, creditsEnabled: credits) }.value
        }
    }
}

/// Codex writes its rate limits into every session log
/// (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl): `primary` is the 5-hour
/// window, `secondary` the week. Nothing is fetched.
enum CodexLimits {
    static func latest() -> PlanLimits? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let logs = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (url, modified) in logs.prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 0x0A).reversed() where line.range(of: Data(#""rate_limits""#.utf8)) != nil {
                guard let json = try? JSONSerialization.jsonObject(with: line),
                      let limits = find("rate_limits", in: json) as? [String: Any] else { continue }
                func window(_ key: String) -> PlanLimits.Window? {
                    guard let entry = limits[key] as? [String: Any], let used = entry["used_percent"] as? NSNumber else { return nil }
                    let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return PlanLimits.Window(utilization: used.doubleValue, resetsAt: resets)
                }
                return PlanLimits(session: window("primary"), week: window("secondary"), checkedAt: modified)
            }
        }
        return nil
    }

    private static func find(_ key: String, in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let found = dictionary[key] { return found }
            for child in dictionary.values { if let found = find(key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = find(key, in: child) { return found } }
        }
        return nil
    }
}

enum ClaudeAccount {
    enum Failure: LocalizedError {
        case notSignedIn, expired, http(Int)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Sign in to Claude Code (run `claude`, then /login) to see plan limits."
            case .expired: "Claude Code's sign-in has expired. Run `claude` once to refresh it."
            case .http(let status): "Anthropic's usage service answered \(status)."
            }
        }
    }

    static func fetchLimits() async throws -> PlanLimits {
        let credential = try await Task.detached { try accessToken() }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? Failure.expired : Failure.http(status) }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ key: String) -> PlanLimits.Window? {
            guard let entry = json[key] as? [String: Any], let used = entry["utilization"] as? NSNumber else { return nil }
            let resets = (entry["resets_at"] as? String).flatMap { parser.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return PlanLimits.Window(utilization: used.doubleValue, resetsAt: resets)
        }
        let credits = (json["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool
        return PlanLimits(session: window("five_hour"), week: window("seven_day"),
                          weekOpus: window("seven_day_opus"), weekSonnet: window("seven_day_sonnet"),
                          creditsEnabled: credits)
    }

    /// Claude Code's OAuth access token from the login Keychain.
    private static func accessToken() throws -> String {
        let oauth = try credentials()
        guard let token = oauth["accessToken"] as? String else { throw Failure.notSignedIn }
        if let expires = oauth["expiresAt"] as? NSNumber, expires.doubleValue / 1000 < Date().timeIntervalSince1970 {
            throw Failure.expired
        }
        return token
    }

    /// The plan from the same sign-in record (no network).
    static func plan() -> ClaudePlan? {
        guard let oauth = try? credentials(), let subscription = oauth["subscriptionType"] as? String else { return nil }
        return ClaudePlan(subscription: subscription, tier: oauth["rateLimitTier"] as? String)
    }

    private static func credentials() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notSignedIn }
        return json["claudeAiOauth"] as? [String: Any] ?? json
    }
}

/// The Claude plan card, and the Codex one beside it when Codex has run.
struct LimitsCards: View {
    @ObservedObject var limits: LimitsStore
    @ObservedObject var usage: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            card(.claude, provider: .claude) {
                LimitsCard(kind: .claude, plan: limits.limits, problem: limits.problem, planName: limits.plan?.name)
            }
            if let codex = limits.codex {
                card(.codex, provider: .codex) { LimitsCard(kind: .codex, plan: codex, problem: nil) }
            }
        }
        .onAppear { limits.refresh() }
    }

    /// Tapping a card shows that agent's usage below it.
    private func card<Content: View>(_ kind: AgentKind, provider: UsageProvider, @ViewBuilder content: () -> Content) -> some View {
        let selected = usage.provider == provider
        return Button {
            withAnimation(Motion.calm) { usage.provider = provider }
        } label: {
            content()
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(kind.color.opacity(selected ? 0.75 : 0), lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("Show \(kind.name) usage")
    }
}

/// A small ring of the 5-hour session used, for page headers.
struct PlanRing: View {
    @ObservedObject var limits: LimitsStore

    var body: some View {
        let used = (limits.limits?.session?.utilization ?? 0) / 100
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, used)))
                .stroke(used < 0.5 ? Palette.ok : used < 0.8 ? Palette.warn : .red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .help(limits.limits?.session.map { "Claude session: \(Int($0.utilization))% used" } ?? "Plan usage")
        .onAppear { limits.refresh() }
    }
}

struct LimitsCard: View {
    let kind: AgentKind
    let plan: PlanLimits?
    let problem: String?
    var planName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                AgentGlyph(kind: kind, size: 13)
                Text("\(kind == .claude ? "Claude" : kind.name) \(planName ?? "plan")").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if let checked = plan?.checkedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let minutes = Int(context.date.timeIntervalSince(checked) / 60)
                        Text(minutes < 1 ? "checked just now" : "checked \(minutes)m ago")
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.mute)
                }
            }
            if let plan {
                if let session = plan.session { LimitRow(label: "Session · 5h", window: session) }
                if let week = plan.week { LimitRow(label: "This week", window: week) }
                if let opus = plan.weekOpus { LimitRow(label: "Opus this week", window: opus) }
                if let sonnet = plan.weekSonnet { LimitRow(label: "Sonnet this week", window: sonnet) }
            } else if let problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking…").font(.system(size: 11.5)).foregroundStyle(Palette.mute)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.faint, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

private struct LimitRow: View {
    let label: String
    let window: PlanLimits.Window

    private var color: Color {
        window.utilization < 50 ? Palette.ok : window.utilization < 80 ? Palette.warn : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(Int(window.utilization.rounded()))% used")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * min(1, window.utilization / 100)))
                }
            }
            .frame(height: 5)
            if let resets = window.resetsAt {
                Text("resets in " + Self.remaining(until: resets))
                    .font(.system(size: 11)).foregroundStyle(Palette.mute)
            }
        }
    }

    static func remaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
