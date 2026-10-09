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
    /// The shorter window's length, for its label ("Session · 5h").
    var sessionLabel = "Session · 5h"
    /// The plan as the service names it ("Plus", "Pro"), when it says.
    var planName: String?
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
    /// Kimi Code's, when it's signed in on this Mac.
    @Published private(set) var kimi: PlanLimits?
    @Published private(set) var kimiProblem: String?
    var hasKimi: Bool { KimiLimits.isInstalled }
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
            if KimiLimits.isInstalled {
                do {
                    kimi = try await KimiLimits.fetch()
                    kimiProblem = nil
                } catch {
                    if kimi == nil { kimiProblem = error.localizedDescription }
                }
            }
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
                // Codex logs a second pool ("premium") with no windows in
                // between the real ones; it says nothing, so look further back.
                let session = window("primary"), week = window("secondary")
                guard session != nil || week != nil else { continue }
                return PlanLimits(session: session, week: week,
                                  planName: (limits["plan_type"] as? String)?.capitalized, checkedAt: modified)
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

/// Kimi Code's plan use, the numbers its `/usage` shows: GET
/// api.kimi.com/coding/v1/usages with the sign-in Kimi Code keeps in
/// ~/.kimi-code/credentials. Like Claude's, the token is only sent to Kimi
/// and never refreshed here; Kimi Code refreshes it while it runs.
enum KimiLimits {
    enum Failure: LocalizedError {
        case signedOut, http(Int)

        var errorDescription: String? {
            switch self {
            case .signedOut: "Kimi Code's sign-in has expired. Run `kimi` once (or /login in it) to refresh it."
            case .http(let status): "Kimi's usage service answered \(status)."
            }
        }
    }

    private static let credentials = NSHomeDirectory() + "/.kimi-code/credentials/kimi-code.json"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: credentials) }

    static func fetch() async throws -> PlanLimits {
        guard let data = FileManager.default.contents(atPath: credentials),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else { throw Failure.signedOut }
        var request = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? Failure.signedOut : Failure.http(status) }
        return parse((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
    }

    /// `usage` is the plan's main (weekly) allowance; `limits` the shorter
    /// rate windows, each with its length.
    static func parse(_ payload: [String: Any]) -> PlanLimits {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ raw: Any?) -> PlanLimits.Window? {
            guard let raw = raw as? [String: Any] else { return nil }
            let used = number(raw["used"]), limit = number(raw["limit"])
            guard let limit, limit > 0 else { return nil }
            let resets = (raw["resetTime"] as? String).flatMap { parser.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return PlanLimits.Window(utilization: min(100, 100 * (used ?? 0) / limit), resetsAt: resets)
        }
        var limits = PlanLimits(week: window(payload["usage"]))
        if let first = (payload["limits"] as? [[String: Any]])?.first, let session = window(first["detail"]) {
            limits.session = session
            limits.sessionLabel = "Session · " + length(first["window"])
        }
        return limits
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    /// {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"} → "5h".
    private static func length(_ raw: Any?) -> String {
        guard let raw = raw as? [String: Any], var duration = number(raw["duration"]).map(Int.init) else { return "limit" }
        var unit = ["TIME_UNIT_MINUTE": "m", "TIME_UNIT_HOUR": "h", "TIME_UNIT_DAY": "d", "TIME_UNIT_WEEK": "w"][raw["timeUnit"] as? String ?? ""] ?? ""
        if unit == "m", duration >= 60, duration % 60 == 0 { duration /= 60; unit = "h" }
        return "\(duration)\(unit)"
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

/// A card per plan: Claude's, then Codex's once it has run and Kimi
/// Code's when it's signed in. Two fit side by side; with more, the row
/// slides on a page every few seconds (not while the pointer is on it), and
/// dots show where it is.
struct LimitsCards: View {
    @ObservedObject var limits: LimitsStore
    @ObservedObject var usage: UsageStore
    @State private var shown: Int? = 0
    @State private var hovering = false

    private struct Plan: Identifiable {
        let kind: AgentKind
        /// Tapping shows its token use below; Kimi keeps no logs to count.
        let provider: UsageProvider?
        let limits: PlanLimits?
        let problem: String?
        let name: String?
        var id: String { kind.id }
    }

    private var plans: [Plan] {
        var plans = [Plan(kind: .claude, provider: .claude, limits: limits.limits, problem: limits.problem, name: limits.plan?.name)]
        if let codex = limits.codex {
            plans.append(Plan(kind: .codex, provider: .codex, limits: codex, problem: nil, name: codex.planName))
        }
        if limits.hasKimi {
            plans.append(Plan(kind: AgentKind(id: "kimi"), provider: nil, limits: limits.kimi, problem: limits.kimiProblem, name: "Code"))
        }
        return plans
    }

    var body: some View {
        let plans = plans
        Group {
            if plans.count <= 2 {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(plans) { card($0) }
                }
            } else {
                carousel(plans)
            }
        }
        .onAppear { limits.refresh() }
    }

    private func carousel(_ plans: [Plan]) -> some View {
        // Pages of two, so each plan shows once; an odd one out sits beside
        // an empty slot at the same width.
        let pages = stride(from: 0, to: plans.count, by: 2).map { Array(plans[$0..<min($0 + 2, plans.count)]) }
        return VStack(spacing: 7) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(page) { card($0).frame(maxWidth: .infinity) }
                            if page.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $shown, anchor: .leading)
            .onHover { hovering = $0 }
            .task(id: pages.count) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !hovering, !Task.isCancelled else { continue }
                    withAnimation(.easeInOut(duration: 0.9)) { shown = ((shown ?? 0) + 1) % pages.count }
                }
            }
            HStack(spacing: 5) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == (shown ?? 0) ? 0.7 : 0.2))
                        .frame(width: index == (shown ?? 0) ? 14 : 5, height: 5)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.6)) { shown = index } }
                }
            }
            .animation(Motion.calm, value: shown)
        }
    }

    /// Tapping a card shows that agent's usage below it.
    @ViewBuilder
    private func card(_ plan: Plan) -> some View {
        let content = LimitsCard(kind: plan.kind, plan: plan.limits, problem: plan.problem, planName: plan.name)
        if let provider = plan.provider {
            let selected = usage.provider == provider
            Button {
                withAnimation(Motion.calm) { usage.provider = provider }
            } label: {
                content
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(plan.kind.color.opacity(selected ? 0.75 : 0), lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .help("Show \(plan.kind.name) usage")
        } else {
            content
        }
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
                if let session = plan.session { LimitRow(label: plan.sessionLabel, window: session) }
                if let week = plan.week { LimitRow(label: "This week", window: week) }
                if let opus = plan.weekOpus { LimitRow(label: "Opus this week", window: opus) }
                if let sonnet = plan.weekSonnet { LimitRow(label: "Sonnet this week", window: sonnet) }
            } else if let problem {
                Text(LocalizedStringKey(problem)).font(.system(size: 11.5)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
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

    /// A window whose reset time has passed has reset, whatever the last
    /// reading said (Codex's numbers only update when Codex runs).
    private var hasReset: Bool { window.resetsAt.map { $0 < Date() } ?? false }
    private var used: Double { hasReset ? 0 : window.utilization }

    private var color: Color {
        used < 50 ? Palette.ok : used < 80 ? Palette.warn : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(Int(used.rounded()))% used")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * min(1, used / 100)))
                }
            }
            .frame(height: 5)
            if hasReset {
                Text("reset since last check")
                    .font(.system(size: 11)).foregroundStyle(Palette.mute)
            } else if let resets = window.resetsAt {
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
