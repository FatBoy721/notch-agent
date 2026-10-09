import Foundation
import SwiftUI

// MARK: - Model

struct TokenTotals {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var cost = 0.0

    var tokens: Int { input + output + cacheWrite + cacheRead }

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cost: lhs.cost + rhs.cost)
    }
}

struct UsageBucket: Hashable {
    let day: String      // yyyy-MM-dd, local time
    let model: String
    let project: String
}

/// API list prices in dollars per million tokens. What Claude Code logs is
/// the same usage the API would bill, so on a subscription this is the
/// "API-equivalent" cost rather than what you actually paid.
enum Pricing {
    private struct Rate {
        let input: Double, output: Double, cacheRead: Double
    }

    // First prefix match wins, so longer ids come before their shorter stems.
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rate(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Rate(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-8", Rate(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, cacheRead: 0.5)),
        ("claude-opus-4", Rate(input: 15, output: 75, cacheRead: 1.5)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-3-7-sonnet", Rate(input: 3, output: 15, cacheRead: 0.3)),
        ("claude-haiku-4-5", Rate(input: 1, output: 5, cacheRead: 0.1)),
        ("claude-3-5-haiku", Rate(input: 0.8, output: 4, cacheRead: 0.08)),
    ]

    static func totals(model: String, usage: [String: Any]) -> TokenTotals {
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let cacheWrite = int(usage["cache_creation_input_tokens"])
        // Writes cost 1.25x input for 5-minute entries and 2x for 1-hour ones.
        let split = usage["cache_creation"] as? [String: Any]
        let write1h = int(split?["ephemeral_1h_input_tokens"])
        let write5m = split == nil ? cacheWrite : int(split?["ephemeral_5m_input_tokens"])

        var totals = TokenTotals(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
        guard let rate = rates.first(where: { model.hasPrefix($0.prefix) })?.rate else { return totals }
        let perToken = 1.0 / 1_000_000
        var cost = Double(input) * rate.input + Double(output) * rate.output + Double(cacheRead) * rate.cacheRead
        cost += Double(write5m) * rate.input * 1.25 + Double(write1h) * rate.input * 2
        // Fast mode is billed at twice the standard rates.
        if usage["speed"] as? String == "fast" { cost *= 2 }
        totals.cost = cost * perToken
        return totals
    }
}

// MARK: - Scanner

/// Reads Claude Code's transcripts (~/.claude/projects/**/*.jsonl) and adds up
/// token usage. Files are read incrementally: each pass only parses the bytes
/// appended since the last one.
final class UsageScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notch-agent.usage", qos: .utility)
    private let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private let usageMarker = Data(#""usage""#.utf8)
    private var offsets: [String: UInt64] = [:]
    /// Claude Code writes one line per content block, each repeating the
    /// message's usage, so messages are counted once by id.
    private var seenMessages: Set<String> = []
    private var buckets: [UsageBucket: TokenTotals] = [:]

    private let timestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    func scan(completion: @escaping @Sendable ([UsageBucket: TokenTotals]) -> Void) {
        queue.async {
            self.scanFiles()
            completion(self.buckets)
        }
    }

    private func scanFiles() {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for case let url as URL in files where url.pathExtension == "jsonl" {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var offset = offsets[url.path] ?? 0
            if size < offset { offset = 0 } // rewritten; the id set prevents double counting
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(),
                  let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            // Stop at the last complete line; a half-written one is read next time.
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) where line.range(of: usageMarker) != nil {
                ingest(line)
            }
            offsets[url.path] = offset + UInt64(complete.count)
        }
    }

    private func ingest(_ line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              model.hasPrefix("claude") else { return }
        if let id = message["id"] as? String {
            guard seenMessages.insert(id + ":" + (entry["requestId"] as? String ?? "")).inserted else { return }
        }
        let date = (entry["timestamp"] as? String).flatMap(timestampParser.date(from:)) ?? Date()
        let project = (entry["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        let bucket = UsageBucket(day: UsageReport.dayKey(date), model: model, project: project)
        buckets[bucket] = (buckets[bucket] ?? TokenTotals()) + Pricing.totals(model: model, usage: usage)
    }
}

// MARK: - Codex

enum UsageProvider: String, CaseIterable {
    case claude, codex
}

/// Codex's model catalog (~/.codex/models_cache.json): the models its picker
/// lists, with their display names and reasoning levels.
enum CodexModels {
    struct Model: Hashable {
        let slug: String
        let name: String
        let efforts: [String]
        var listed = true
    }

    /// The models Codex's picker lists.
    static func load() -> [Model] { all().filter(\.listed) }

    /// Every model in the catalog, hidden ones included (for naming).
    static func all() -> [Model] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String else { return nil }
            let efforts = (model["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
            return Model(slug: slug, name: model["display_name"] as? String ?? slug, efforts: efforts,
                         listed: model["visibility"] as? String == "list")
        }
    }

    static var names: [String: String] { Dictionary(all().map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    static func displayName(_ slug: String) -> String {
        // Models dropped from the catalog keep a readable name: "gpt-6-sol" → "GPT-6-Sol".
        names[slug] ?? slug.split(separator: "-").map { part in
            part == "gpt" ? "GPT" : part.first?.isNumber == true ? String(part) : part.capitalized
        }.joined(separator: "-")
    }
}

/// Reads Codex's session logs (~/.codex/sessions/**/rollout-*.jsonl).
/// Every `token_count` event carries the session's running totals; usage is
/// counted as each total's growth, so repeated events never double-count.
/// Files are read incrementally, like Claude Code's.
final class CodexUsageScanner: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64 = 0
        var input = 0, cached = 0, output = 0
        var model = "codex"
        var project = "Unknown"
    }

    private let queue = DispatchQueue(label: "notch-agent.codex-usage", qos: .utility)
    private let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    private var files: [String: FileState] = [:]
    private var buckets: [UsageBucket: TokenTotals] = [:]
    private let markers = [#""token_count""#, #""turn_context""#, #""session_meta""#].map { Data($0.utf8) }
    private let timestampParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    func scan(completion: @escaping @Sendable ([UsageBucket: TokenTotals]) -> Void) {
        queue.async {
            self.scanFiles()
            completion(self.buckets)
        }
    }

    private func scanFiles() {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var state = files[url.path] ?? FileState()
            guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: state.offset)) != nil,
                  let data = try? handle.readToEnd(),
                  let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) where markers.contains(where: { line.range(of: $0) != nil }) {
                ingest(line, into: &state)
            }
            state.offset += UInt64(complete.count)
            files[url.path] = state
        }
    }

    private func ingest(_ line: Data, into state: inout FileState) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = entry["payload"] as? [String: Any] else { return }
        switch entry["type"] as? String {
        case "session_meta":
            if let cwd = payload["cwd"] as? String { state.project = URL(fileURLWithPath: cwd).lastPathComponent }
        case "turn_context":
            if let model = payload["model"] as? String { state.model = model }
            if let cwd = payload["cwd"] as? String { state.project = URL(fileURLWithPath: cwd).lastPathComponent }
        case "event_msg" where payload["type"] as? String == "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            func int(_ key: String) -> Int { (total[key] as? NSNumber)?.intValue ?? 0 }
            let input = int("input_tokens"), cached = int("cached_input_tokens"), output = int("output_tokens")
            // A smaller total means a new session in the same file; start over.
            if input < state.input || output < state.output { state.input = 0; state.cached = 0; state.output = 0 }
            let delta = TokenTotals(input: max(0, (input - cached) - (state.input - state.cached)),
                                    output: max(0, output - state.output),
                                    cacheRead: max(0, cached - state.cached))
            state.input = input; state.cached = cached; state.output = output
            guard delta.tokens > 0 else { return }
            let date = (entry["timestamp"] as? String).flatMap(timestampParser.date(from:)) ?? Date()
            let bucket = UsageBucket(day: UsageReport.dayKey(date), model: state.model, project: state.project)
            buckets[bucket] = (buckets[bucket] ?? TokenTotals()) + delta
        default:
            break
        }
    }
}

// MARK: - Report

struct UsageReport {
    enum Grouping: String, CaseIterable, Identifiable {
        case day = "Day", model = "Model", project = "Project"
        var id: Self { self }
    }

    struct Row: Identifiable {
        let id: String
        let label: String
        let totals: TokenTotals
    }

    var buckets: [UsageBucket: TokenTotals] = [:]

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Usage over the last `days` days, today included.
    /// Tokens per day (yyyy-MM-dd), all models and projects together.
    var dailyTokens: [String: Int] {
        buckets.reduce(into: [:]) { days, entry in days[entry.key.day, default: 0] += entry.value.tokens }
    }

    func total(days: Int) -> TokenTotals {
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        let cutoff = Self.dayKey(start)
        return buckets.filter { $0.key.day >= cutoff }.values.reduce(TokenTotals(), +)
    }

    /// The last 30 days grouped one way, biggest cost first (days newest first).
    func rows(by grouping: Grouping) -> [Row] {
        let start = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
        let cutoff = Self.dayKey(start)
        let grouped = Dictionary(grouping: buckets.filter { $0.key.day >= cutoff }) { entry -> String in
            switch grouping {
            case .day: entry.key.day
            case .model: entry.key.model
            case .project: entry.key.project
            }
        }
        let rows = grouped.map { key, entries in
            Row(id: key, label: label(for: key, grouping),
                totals: entries.map(\.value).reduce(TokenTotals(), +))
        }
        return grouping == .day
            ? rows.sorted { $0.id > $1.id }
            : rows.sorted { ($0.totals.cost, $0.totals.tokens) > ($1.totals.cost, $1.totals.tokens) }
    }

    private func label(for key: String, _ grouping: Grouping) -> String {
        switch grouping {
        case .model: return key.hasPrefix("claude") ? Self.modelName(key) : CodexModels.displayName(key)
        case .project: return key
        case .day:
            let calendar = Calendar.current
            if key == Self.dayKey(Date()) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()), key == Self.dayKey(yesterday) {
                return "Yesterday"
            }
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5"
    static func modelName(_ id: String) -> String {
        // Drop the "claude" prefix and any date suffix.
        let parts: [String] = id.components(separatedBy: "-").dropFirst().filter { $0.count < 8 }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var report = UsageReport()
    @Published private(set) var codexReport = UsageReport()
    @Published private(set) var loaded = false
    @Published private(set) var codexLoaded = false
    /// Whose usage the Usage page shows; picked by tapping a plan card.
    @Published var provider: UsageProvider = .claude
    private let scanner = UsageScanner()
    private let codexScanner = CodexUsageScanner()
    private var refreshing = false
    private var refreshingCodex = false

    func refresh() {
        if !refreshing {
            refreshing = true
            scanner.scan { buckets in
                Task { @MainActor in
                    self.report = UsageReport(buckets: buckets)
                    self.loaded = true
                    self.refreshing = false
                }
            }
        }
        if !refreshingCodex {
            refreshingCodex = true
            codexScanner.scan { buckets in
                Task { @MainActor in
                    self.codexReport = UsageReport(buckets: buckets)
                    self.codexLoaded = true
                    self.refreshingCodex = false
                }
            }
        }
    }
}

// MARK: - View

struct UsageView: View {
    @ObservedObject var usage: UsageStore
    @State private var grouping: UsageReport.Grouping = .day

    private var isCodex: Bool { usage.provider == .codex }
    private var report: UsageReport { isCodex ? usage.codexReport : usage.report }
    private var loaded: Bool { isCodex ? usage.codexLoaded : usage.loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatTile(title: "Today", totals: report.total(days: 1), tokensOnly: isCodex)
                StatTile(title: "7 days", totals: report.total(days: 7), tokensOnly: isCodex)
                StatTile(title: "30 days", totals: report.total(days: 30), tokensOnly: isCodex)
            }
            if loaded {
                ActivityHeatmap(daily: report.dailyTokens, color: isCodex ? Palette.codex : Palette.claude)
            }
            HStack {
                Picker("Group by", selection: $grouping) {
                    ForEach(UsageReport.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(isCodex ? "Codex tokens, last 30 days" : "Claude Code API-equivalent cost, last 30 days")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if loaded {
                BarList(rows: report.rows(by: grouping), tokensOnly: isCodex, agent: isCodex ? "Codex" : "Claude Code")
            } else {
                ProgressView(isCodex ? "Reading Codex logs…" : "Reading Claude Code logs…")
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
        }
        .id(usage.provider)
        .transition(.opacity)
        // Re-read the logs while the tab is open; only new bytes are parsed.
        .task {
            while !Task.isCancelled {
                usage.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let totals: TokenTotals
    var tokensOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(tokensOnly ? UsageFormat.tokens(totals.tokens) : UsageFormat.dollars(totals.cost))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(tokensOnly ? "\(UsageFormat.tokens(totals.output)) out · \(UsageFormat.tokens(totals.cacheRead)) cached"
                            : "\(UsageFormat.tokens(totals.tokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Ranked horizontal bars: one hue, magnitude only, value in text beside it.
private struct BarList: View {
    let rows: [UsageReport.Row]
    var tokensOnly = false
    var agent = "Claude Code"

    private func value(_ totals: TokenTotals) -> Double { tokensOnly ? Double(totals.tokens) : totals.cost }

    var body: some View {
        let maxCost = rows.map { value($0.totals) }.max() ?? 0
        if rows.isEmpty {
            Text("No \(agent) usage in the last 30 days.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else {
            CappedScroll(maxHeight: 190) {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .frame(width: 130, alignment: .leading)
                            GeometryReader { proxy in
                                UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                                    .fill(Color.blue)
                                    .frame(width: max(2, proxy.size.width * (maxCost > 0 ? value(row.totals) / maxCost : 0)))
                            }
                            .frame(height: 10)
                            Text(tokensOnly ? UsageFormat.tokens(row.totals.tokens) : UsageFormat.dollars(row.totals.cost))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .help(UsageFormat.breakdown(row.totals))
                    }
                }
            }
        }
    }
}

enum UsageFormat {
    static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func breakdown(_ totals: TokenTotals) -> String {
        "Input \(tokens(totals.input)) · Output \(tokens(totals.output)) · "
            + "Cache write \(tokens(totals.cacheWrite)) · Cache read \(tokens(totals.cacheRead))"
    }
}

/// GlassCode's activity grid: one square per day, a column per week
/// (oldest left), brighter for more tokens, plus streaks. Covers what the
/// logs still hold (Claude Code keeps about a month by default), up to a year.
private struct ActivityHeatmap: View {
    let daily: [String: Int]
    let color: Color
    private static let weeks = 52
    private static let cell: CGFloat = 7.5
    private static let gap: CGFloat = 2

    var body: some View {
        let days = Self.days()
        let top = max(1, daily.values.max() ?? 1)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("Activity").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                let (current, longest) = streaks(days)
                Label("\(current) day\(current == 1 ? "" : "s")", systemImage: "flame.fill")
                    .foregroundStyle(current > 0 ? color : Palette.mute)
                    .help("Current streak: days in a row with any usage")
                Text("Longest \(longest)").foregroundStyle(Palette.mute)
            }
            .font(.system(size: 11, weight: .medium))
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(0..<Self.weeks, id: \.self) { week in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let day = days[week * 7 + weekday]
                            RoundedRectangle(cornerRadius: 1.8)
                                .fill(fill(day.map { daily[$0] ?? 0 }, top: top))
                                .frame(width: Self.cell, height: Self.cell)
                                .help(day.map { "\($0): \(UsageFormat.tokens(daily[$0] ?? 0)) tokens" } ?? "")
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 52 × 7 day keys, Sunday-first columns ending with this week; days
    /// after today are nil.
    private static func days() -> [String?] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1   // 0 = Sunday
        let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 1 - (6 - weekday)), to: today) ?? today
        return (0..<(weeks * 7)).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start), date <= today else { return nil }
            return UsageReport.dayKey(date)
        }
    }

    /// Log scale, so one huge day doesn't flatten the rest.
    private func fill(_ tokens: Int?, top: Int) -> Color {
        guard let tokens else { return .clear }
        guard tokens > 0 else { return .white.opacity(0.06) }
        let level = log(Double(tokens) + 1) / log(Double(top) + 1)
        return color.opacity(0.25 + 0.75 * level)
    }

    private func streaks(_ days: [String?]) -> (current: Int, longest: Int) {
        var longest = 0, run = 0
        for day in days.compactMap({ $0 }) {
            run = (daily[day] ?? 0) > 0 ? run + 1 : 0
            longest = max(longest, run)
        }
        // A day without usage yet today doesn't break the streak.
        let past = days.compactMap { $0 }
        var current = 0
        for (index, day) in past.reversed().enumerated() {
            if (daily[day] ?? 0) > 0 { current += 1 } else if index > 0 { break }
        }
        return (current, longest)
    }
}
