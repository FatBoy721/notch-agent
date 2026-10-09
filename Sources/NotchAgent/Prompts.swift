import SwiftUI

/// What a waiting agent is asking for, read from its PermissionRequest:
/// file changes (shown as diffs: Claude's Edit/MultiEdit/Write, Codex's
/// apply_patch), multiple-choice questions
/// (AskUserQuestion, answered from the notch), a finished plan
/// (ExitPlanMode), or any other tool call (summary and detail).
enum PromptKind {
    case tool
    case diff([FileDiff])
    case questions([PromptQuestion])
    case plan(String)
    /// Hermes wants to run a command; `choices` are its allowed answers.
    case command(String, description: String?, choices: [String])

    static func from(tool: String, input: [String: JSONValue], cwd: String?) -> PromptKind {
        func value(_ key: String) -> String? { input[key]?.string }
        switch tool {
        case "apply_patch":
            // Codex: the patch text is the command, either as a string or
            // as the last element of an argv array.
            var command = value("command")
            if command == nil, case .array(let parts)? = input["command"] { command = parts.last?.string }
            guard let command, command.contains("*** Begin Patch") else { return .tool }
            let diffs = FileDiff.patch(command, cwd: cwd)
            return diffs.isEmpty ? .tool : .diff(diffs)
        case "Edit":
            guard let path = value("file_path") else { return .tool }
            return .diff([FileDiff.edit(path: path, pairs: [(value("old_string") ?? "", value("new_string") ?? "")])])
        case "MultiEdit":
            guard let path = value("file_path"), case .array(let edits)? = input["edits"] else { return .tool }
            let pairs = edits.compactMap { edit -> (String, String)? in
                guard case .object(let fields) = edit else { return nil }
                return (fields["old_string"]?.string ?? "", fields["new_string"]?.string ?? "")
            }
            return .diff([FileDiff.edit(path: path, pairs: pairs)])
        case "Write":
            guard let path = value("file_path"), let content = value("content") else { return .tool }
            return .diff([FileDiff.write(path: path, content: content)])
        case "AskUserQuestion":
            let questions = PromptQuestion.parse(input["questions"])
            return questions.isEmpty ? .tool : .questions(questions)
        case "ExitPlanMode":
            if let plan = value("plan"), !plan.isEmpty { return .plan(plan) }
            if let file = value("planFilePath"), let plan = try? String(contentsOfFile: file, encoding: .utf8) { return .plan(plan) }
            return .tool
        default:
            return .tool
        }
    }
}

// MARK: - Diff

struct DiffLine: Identifiable, Equatable {
    enum Kind { case same, added, removed, gap }
    let id: Int
    let kind: Kind
    let text: String
}

/// A proposed file change as lines to show: changed lines with a little
/// context, long unchanged runs folded to "⋯".
struct FileDiff {
    let path: String
    let lines: [DiffLine]
    let added: Int
    let removed: Int
    /// Where the edit starts in the file today, when it could be found.
    let startLine: Int?
    let isNewFile: Bool

    static func edit(path: String, pairs: [(old: String, new: String)]) -> FileDiff {
        var entries: [(DiffLine.Kind, String)] = []
        for (index, pair) in pairs.enumerated() {
            if index > 0 { entries.append((.gap, "")) }
            entries += lineDiff(old: pair.old, new: pair.new)
        }
        // The line number comes from the file as it is now; the first edit's
        // old text is still in it.
        var startLine: Int?
        if let first = pairs.first, !first.old.isEmpty,
           let file = read(path), let range = file.range(of: first.old) {
            startLine = file[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        return make(path: path, entries: entries, startLine: startLine, isNewFile: false)
    }

    /// A whole-file write: against what's on disk now, or all new.
    static func write(path: String, content: String) -> FileDiff {
        guard let current = read(path) else {
            return make(path: path, entries: content.components(separatedBy: "\n").map { (.added, $0) }, startLine: nil, isNewFile: true)
        }
        return make(path: path, entries: lineDiff(old: current, new: content), startLine: nil, isNewFile: false)
    }

    /// Codex's apply_patch format, one diff per file:
    ///
    ///     *** Begin Patch
    ///     *** Update File: src/app.py      (or Add File / Delete File)
    ///     @@ def main():
    ///      context
    ///     -old
    ///     +new
    ///     *** End Patch
    static func patch(_ text: String, cwd: String?) -> [FileDiff] {
        var diffs: [FileDiff] = []
        var path: String?
        var entries: [(DiffLine.Kind, String)] = []
        var isNew = false
        func flush() {
            guard let path else { return }
            let full = path.hasPrefix("/") || cwd == nil ? path : (cwd! as NSString).appendingPathComponent(path)
            diffs.append(make(path: full, entries: entries, startLine: nil, isNewFile: isNew))
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("*** ") {
                let header = line.dropFirst(4)
                for (prefix, new) in [("Update File: ", false), ("Add File: ", true), ("Delete File: ", false)] where header.hasPrefix(prefix) {
                    flush()
                    path = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    entries = []
                    isNew = new
                    if prefix == "Delete File: " { entries = [(.removed, "(file deleted)")] }
                }
                continue
            }
            guard path != nil else { continue }
            if line.hasPrefix("@@") { if !entries.isEmpty { entries.append((.gap, "")) } }
            else if line.hasPrefix("+") { entries.append((.added, String(line.dropFirst()))) }
            else if line.hasPrefix("-") { entries.append((.removed, String(line.dropFirst()))) }
            else if line.hasPrefix(" ") { entries.append((.same, String(line.dropFirst()))) }
        }
        flush()
        return diffs
    }

    private static func read(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size < 512 * 1024 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Line-level diff via the standard library's Myers difference.
    private static func lineDiff(old: String, new: String) -> [(DiffLine.Kind, String)] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [(DiffLine.Kind, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append((.removed, a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append((.added, b[j])); j += 1
            } else if i < a.count, j < b.count {
                out.append((.same, a[i])); i += 1; j += 1
            } else if i < a.count {
                out.append((.removed, a[i])); i += 1
            } else {
                out.append((.added, b[j])); j += 1
            }
        }
        return out
    }

    /// Keeps 2 lines of context around changes and caps the total, so a
    /// large write can't make the card unbearably long.
    private static func make(path: String, entries: [(DiffLine.Kind, String)], startLine: Int?, isNewFile: Bool) -> FileDiff {
        let context = 2, cap = 400
        let changed = entries.indices.filter { entries[$0].0 == .added || entries[$0].0 == .removed }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(entries.count - 1, index + context)) }
        var lines: [DiffLine] = []
        var folded = false
        for (index, entry) in entries.enumerated() {
            if entry.0 == .gap || (entry.0 == .same && !keep.contains(index)) {
                if !folded, !lines.isEmpty { lines.append(DiffLine(id: lines.count, kind: .gap, text: "⋯")) }
                folded = true
                continue
            }
            folded = false
            lines.append(DiffLine(id: lines.count, kind: entry.0, text: entry.1))
            if lines.count >= cap {
                lines.append(DiffLine(id: lines.count, kind: .gap, text: "⋯ \(entries.count - index - 1) more lines"))
                break
            }
        }
        if lines.last?.kind == .gap, lines.last?.text == "⋯" { lines.removeLast() }
        return FileDiff(path: path, lines: lines,
                        added: entries.filter { $0.0 == .added }.count, removed: entries.filter { $0.0 == .removed }.count,
                        startLine: startLine, isNewFile: isNewFile)
    }
}

// MARK: - Questions

struct PromptQuestion: Identifiable, Sendable {
    struct Option: Identifiable, Sendable {
        let label: String
        let description: String?
        var id: String { label }
    }

    let id: Int
    let question: String
    let header: String?
    let options: [Option]
    let multiSelect: Bool

    static func parse(_ value: JSONValue?) -> [PromptQuestion] {
        guard case .array(let items)? = value else { return [] }
        return items.enumerated().compactMap { index, item in
            guard case .object(let fields) = item, let question = fields["question"]?.string else { return nil }
            var options: [Option] = []
            if case .array(let list)? = fields["options"] {
                options = list.compactMap { option in
                    guard case .object(let o) = option, let label = o["label"]?.string else { return nil }
                    return Option(label: label, description: o["description"]?.string)
                }
            }
            var multi = false
            if case .bool(let flag)? = fields["multiSelect"] { multi = flag }
            return PromptQuestion(id: index, question: question, header: fields["header"]?.string, options: options, multiSelect: multi)
        }
    }
}

// MARK: - Views

/// The card under a waiting thread: the right body for what's asked, and
/// the matching answers.
struct PromptCard: View {
    @ObservedObject var store: Store
    let approval: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            switch approval.prompt {
            case .diff(let diffs):
                CappedScroll(maxHeight: 260) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(diffs.enumerated()), id: \.offset) { _, diff in DiffBody(diff: diff) }
                    }
                }
                allowDeny
            case .questions(let questions):
                QuestionsBody(questions: questions) { store.decide(approval, .answer($0)) }
                if !approval.isHermes { terminalOnly }
            case .command(let command, let description, let choices):
                CommandBody(command: command, description: description)
                commandButtons(choices)
            case .plan(let plan):
                PlanBody(plan: plan) { feedback in
                    store.decide(approval, feedback.map { .keepPlanning($0) } ?? .allow)
                }
                terminalOnly
            case .tool:
                CappedScroll(maxHeight: 130) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(approval.summary).fontWeight(.semibold)
                        if let detail = approval.detail {
                            Text(detail).foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                allowDeny
            }
        }
        .padding(12)
        .background(Palette.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.warn.opacity(0.28), lineWidth: 1))
    }

    private var title: LocalizedStringKey {
        switch approval.prompt {
        case .diff(let diffs):
            if diffs.count > 1 { "Change **\(diffs.count) files**?" }
            else if let diff = diffs.first, diff.isNewFile { "Create **\((diff.path as NSString).lastPathComponent)**?" }
            else { "Change **\(((diffs.first?.path ?? "") as NSString).lastPathComponent)**?" }
        case .questions(let questions): questions.count == 1 ? "Claude has a question" : "Claude has \(questions.count) questions"
        case .plan: "Claude's plan is ready"
        case .command: "Hermes wants to run a command"
        case .tool: "Allow **\(approval.tool)**?"
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(Palette.warn)
            Text(title).font(.system(size: 13.5))
            Spacer()
            let queued = store.approvals.count - 1
            if queued > 0 { Text("+\(queued) more").font(.system(size: 11.5)).foregroundStyle(Palette.mute) }
        }
    }

    private var icon: String {
        switch approval.prompt {
        case .diff: ToolIcon.name("Edit")
        case .questions: "questionmark.bubble.fill"
        case .command: "terminal.fill"
        case .plan: "list.bullet.clipboard.fill"
        default: ToolIcon.name(approval.tool)
        }
    }

    private var allowDeny: some View {
        HStack(spacing: 8) {
            Button("Answer in terminal") { store.decide(approval, .terminal) }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.mute)
            Spacer()
            Button("Deny") { store.decide(approval, .deny) }
                .buttonStyle(PillButtonStyle(color: .white.opacity(0.14)))
            Button("Allow") { store.decide(approval, .allow) }
                .buttonStyle(PillButtonStyle(color: .blue))
        }
        .font(.system(size: 12.5, weight: .semibold))
    }

    /// Hermes' own answers, the ones it offers: deny, once, for this chat,
    /// always.
    private func commandButtons(_ choices: [String]) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if choices.contains("deny") {
                Button("Deny") { store.decide(approval, .deny) }
                    .buttonStyle(PillButtonStyle(color: .white.opacity(0.14)))
            }
            if choices.contains("always") {
                Button("Always") { store.decide(approval, .allowAlways) }
                    .buttonStyle(PillButtonStyle(color: .white.opacity(0.14)))
                    .help("Allow this kind of command from now on")
            }
            if choices.contains("session") {
                Button("This chat") { store.decide(approval, .allowForChat) }
                    .buttonStyle(PillButtonStyle(color: .white.opacity(0.14)))
                    .help("Allow it for the rest of this chat")
            }
            Button("Allow once") { store.decide(approval, .allow) }
                .buttonStyle(PillButtonStyle(color: .blue))
        }
        .font(.system(size: 12.5, weight: .semibold))
    }

    private var terminalOnly: some View {
        Button("Answer in terminal instead") { store.decide(approval, .terminal) }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Palette.mute)
    }
}

private struct DiffBody: View {
    let diff: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text((diff.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(Palette.mute)
                if let line = diff.startLine { Text("line \(line)").foregroundStyle(Palette.mute) }
                Spacer()
                Text("+\(diff.added)").foregroundStyle(Palette.ok)
                Text("−\(diff.removed)").foregroundStyle(Color(red: 0.97, green: 0.44, blue: 0.44))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            // No scroll of its own: the card scrolls all files together.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker(line.kind)).foregroundStyle(color(line.kind)).frame(width: 9)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .same || line.kind == .gap ? .white.opacity(0.55) : .white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 0.5)
                    .background(background(line.kind))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .same, .gap: " "
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? Palette.ok : kind == .removed ? Color(red: 0.97, green: 0.44, blue: 0.44) : .clear
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Palette.ok.opacity(0.13)
        case .removed: Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.13)
        case .same, .gap: .white.opacity(0.03)
        }
    }
}

/// The command, as it would run, and Hermes' reason for flagging it.
private struct CommandBody: View {
    let command: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let description, !description.isEmpty {
                Text(description).font(.system(size: 12)).foregroundStyle(Palette.mute)
            }
            CappedScroll(maxHeight: 150) {
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Options as buttons. One single-choice question answers on click; with
/// several questions, multi-select or typed answers, a Send button collects
/// them. Answers go back as `answers: {question: label}` (labels joined with
/// ", " for multi-select), the form Claude Code reads.
private struct QuestionsBody: View {
    let questions: [PromptQuestion]
    let send: ([String: String]) -> Void
    @State private var picked: [Int: Set<String>] = [:]
    @State private var typed: [Int: String] = [:]

    private var answersAtOnce: Bool { questions.count == 1 && !questions[0].multiSelect }

    var body: some View {
        CappedScroll(maxHeight: 260) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        if let header = question.header, !header.isEmpty {
                            Text(header.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.mute)
                        }
                        Text(question.question).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        ForEach(question.options) { option in
                            optionButton(option, in: question)
                        }
                        TextField("Or type an answer", text: Binding(get: { typed[question.id] ?? "" }, set: { typed[question.id] = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit { if answersAtOnce { submit() } }
                    }
                }
            }
        }
        if !answersAtOnce || !(typed[0] ?? "").isEmpty {
            HStack {
                Spacer()
                Button("Send answer") { submit() }
                    .buttonStyle(PillButtonStyle(color: .blue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .disabled(!complete)
                    .opacity(complete ? 1 : 0.5)
            }
        }
    }

    private func optionButton(_ option: PromptQuestion.Option, in question: PromptQuestion) -> some View {
        let on = picked[question.id]?.contains(option.label) == true
        return Button {
            if question.multiSelect {
                picked[question.id, default: []].formSymmetricDifference([option.label])
            } else {
                picked[question.id] = [option.label]
                if answersAtOnce { submit() }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: question.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Color.blue : Palette.mute)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12.5, weight: .semibold))
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 11.5)).foregroundStyle(Palette.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(.white.opacity(on ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Every question has an option picked or text typed.
    private var complete: Bool {
        questions.allSatisfy { answer(for: $0) != nil }
    }

    private func answer(for question: PromptQuestion) -> String? {
        let text = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let labels = question.options.map(\.label).filter { picked[question.id]?.contains($0) == true }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private func submit() {
        var answers: [String: String] = [:]
        for question in questions {
            guard let answer = answer(for: question) else { return }
            answers[question.question] = answer
        }
        send(answers)
    }
}

/// The plan as light markdown, with Approve, or Keep planning plus an
/// optional note on what to change (sent back to Claude as the reason).
private struct PlanBody: View {
    let plan: String
    /// nil approves; a string keeps planning with that feedback.
    let decide: (String?) -> Void
    @State private var feedback = ""

    var body: some View {
        CappedScroll(maxHeight: 260) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    planLine(line)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        HStack(spacing: 8) {
            TextField("What should change? (optional)", text: $feedback)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { keepPlanning() }
            Button("Keep planning") { keepPlanning() }
                .buttonStyle(PillButtonStyle(color: .white.opacity(0.14)))
            Button("Approve") { decide(nil) }
                .buttonStyle(PillButtonStyle(color: .blue))
        }
        .font(.system(size: 12.5, weight: .semibold))
    }

    private func keepPlanning() {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        decide(note.isEmpty ? "Keep planning; the user hasn't approved this plan yet." : note)
    }

    @ViewBuilder private func planLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(.system(size: level <= 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .bold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Palette.mute)
                inline(String(trimmed.dropFirst(2)))
            }
            .font(.system(size: 12.5))
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count) * 4)
        } else if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else {
            inline(line).font(.system(size: 12.5))
        }
    }

    /// Bold, italics, `code` and links; anything else stays as written.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}
