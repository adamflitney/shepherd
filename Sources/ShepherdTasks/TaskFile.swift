import Foundation

public enum TaskStatus: String, CaseIterable, Sendable {
    case inbox, ready, active, review, done
}

public struct PlanStep: Equatable, Sendable {
    public var text: String
    public var done: Bool
}

public struct PlanProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
}

public struct TaskError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public func formatStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: date)
}

private func logStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

/// One task: a markdown file with frontmatter, a `## Plan` checklist and a `## Log`.
public struct TaskFile: Sendable {
    private var doc: Frontmatter

    private init(_ doc: Frontmatter) { self.doc = doc }

    public static func parse(_ text: String) -> TaskFile { TaskFile(Frontmatter.parse(text)) }

    public func serialize() -> String { doc.serialize() }

    public var body: String { doc.body }

    public static func create(id: Int, title: String, objective: String? = nil, projectPath: String? = nil, branch: String? = nil, now: Date = Date()) -> TaskFile {
        var doc = Frontmatter.parse("---\nid: \(id)\n---\n## Plan\n\n## Log\n")
        let stamp = formatStamp(now)
        doc.set("title", .string(title))
        doc.set("objective", objective.map { .string($0) })
        doc.set("project_path", projectPath.map { .string($0) })
        doc.set("status", .string(TaskStatus.inbox.rawValue))
        doc.set("sessions", .list([]))
        doc.set("branch", branch.map { .string($0) })
        doc.set("created", .string(stamp))
        doc.set("updated", .string(stamp))
        return TaskFile(doc)
    }

    private func str(_ key: String) -> String? {
        switch doc.get(key) {
        case .string(let s)?: return s
        case .int(let n)?: return String(n)
        default: return nil
        }
    }

    public var id: Int {
        if case .int(let n)? = doc.get("id") { return n }
        return 0
    }
    public var title: String { str("title") ?? "" }
    public var objective: String? { str("objective") }
    public var projectPath: String? { str("project_path") }
    public var branch: String? { str("branch") }
    public var pr: String? { str("pr") }
    public var status: TaskStatus { str("status").flatMap(TaskStatus.init(rawValue:)) ?? .inbox }
    public var sessions: [String] {
        if case .list(let l)? = doc.get("sessions") { return l }
        return []
    }

    public mutating func setStatus(_ status: TaskStatus, now: Date = Date()) {
        doc.set("status", .string(status.rawValue))
        touch(now: now)
    }

    public mutating func linkSession(_ sessionID: String, now: Date = Date()) {
        guard !sessions.contains(sessionID) else { return }
        doc.set("sessions", .list(sessions + [sessionID]))
        touch(now: now)
    }

    public mutating func unlinkSession(_ sessionID: String, now: Date = Date()) {
        doc.set("sessions", .list(sessions.filter { $0 != sessionID }))
        touch(now: now)
    }

    public mutating func setObjective(_ text: String, now: Date = Date()) {
        doc.set("objective", .string(text))
        touch(now: now)
    }

    public mutating func setBranch(_ name: String, now: Date = Date()) {
        doc.set("branch", .string(name))
        touch(now: now)
    }

    public mutating func setPR(_ url: String, now: Date = Date()) {
        doc.set("pr", .string(url))
        touch(now: now)
    }

    public mutating func setTitle(_ text: String, now: Date = Date()) {
        doc.set("title", .string(text))
        touch(now: now)
    }

    public mutating func touch(now: Date = Date()) {
        doc.set("updated", .string(formatStamp(now)))
    }

    /// Appends "- YYYY-MM-DD HH:MM: text" at the end of the `## Log` section, creating it if needed.
    public mutating func appendLog(_ text: String, now: Date = Date()) {
        appendToSection("Log", "- \(logStamp(now)): \(text)")
        touch(now: now)
    }

    public mutating func addPlanItem(_ text: String, now: Date = Date()) {
        appendToSection("Plan", "- [ ] \(text)")
        touch(now: now)
    }

    /// Replaces the Plan section's checklist with `steps`. A step that matches an existing one keeps its
    /// checked state, so rewording or reordering a plan doesn't un-tick finished work. Other text in the
    /// section is dropped, as the section is rewritten.
    public mutating func setPlan(_ steps: [String], now: Date = Date()) {
        let previous = section("Plan").filter(Self.isPlanItem)
        var checked = Set<String>()
        for line in previous where line.dropFirst(3).first != " " { checked.insert(String(line.dropFirst(6))) }
        let items = steps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { "- [\(checked.contains($0) ? "x" : " ")] \($0)" }
        var lines = doc.body.components(separatedBy: "\n")
        if let range = Self.findSection(lines, "Plan") {
            let tail = range.end < lines.count ? [""] : []
            lines.replaceSubrange((range.start + 1)..<range.end, with: items + tail)
            doc.body = lines.joined(separator: "\n")
        } else {
            for item in items { appendToSection("Plan", item) }
        }
        touch(now: now)
    }

    /// Sets plan item `n` (1-based) done or not done.
    public mutating func setPlanItem(_ n: Int, done: Bool, now: Date = Date()) throws {
        var lines = doc.body.components(separatedBy: "\n")
        guard let range = Self.findSection(lines, "Plan") else { throw TaskError("no plan item \(n)") }
        var seen = 0
        for i in (range.start + 1)..<range.end where Self.isPlanItem(lines[i]) {
            seen += 1
            if seen == n {
                lines[i] = (done ? "- [x]" : "- [ ]") + lines[i].dropFirst(5)
                doc.body = lines.joined(separator: "\n")
                touch(now: now)
                return
            }
        }
        throw TaskError("no plan item \(n)")
    }

    /// The Plan checklist, in order.
    public var plan: [PlanStep] {
        let lines = doc.body.components(separatedBy: "\n")
        guard let range = Self.findSection(lines, "Plan") else { return [] }
        return ((range.start + 1)..<range.end).compactMap { i in
            guard Self.isPlanItem(lines[i]) else { return nil }
            return PlanStep(text: String(lines[i].dropFirst(6)), done: lines[i].dropFirst(3).first != " ")
        }
    }

    /// The Log lines (oldest first), without their leading "- ".
    public var logEntries: [String] {
        section("Log").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    /// When the file was last changed, as written in its frontmatter.
    public var updated: String? { str("updated") }
    public var created: String? { str("created") }

    public var progress: PlanProgress {
        let lines = doc.body.components(separatedBy: "\n")
        guard let range = Self.findSection(lines, "Plan") else { return PlanProgress(done: 0, total: 0) }
        var done = 0, total = 0
        for i in (range.start + 1)..<range.end where Self.isPlanItem(lines[i]) {
            total += 1
            if lines[i].dropFirst(3).first != " " { done += 1 }
        }
        return PlanProgress(done: done, total: total)
    }

    /// The Plan lines (without blanks) and Log lines, for context rendering.
    func section(_ name: String) -> [String] {
        let lines = doc.body.components(separatedBy: "\n")
        guard let r = Self.findSection(lines, name) else { return [] }
        return lines[(r.start + 1)..<r.end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func isPlanItem(_ line: String) -> Bool {
        let chars = Array(line)
        return chars.count >= 6 && chars[0] == "-" && chars[1] == " " && chars[2] == "[" && " xX".contains(chars[3]) && chars[4] == "]" && chars[5] == " "
    }

    private mutating func appendToSection(_ name: String, _ line: String) {
        var lines = doc.body.components(separatedBy: "\n")
        guard let range = Self.findSection(lines, name) else {
            var body = doc.body
            if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
            if !body.isEmpty { body += "\n" }
            doc.body = "\(body)## \(name)\n\(line)\n"
            return
        }
        var at = range.end
        while at > range.start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }  // before trailing blank lines
        lines.insert(line, at: at)
        doc.body = lines.joined(separator: "\n")
    }

    /// Line range of "## name" through the line before the next "## " heading (or the end).
    private static func findSection(_ lines: [String], _ name: String) -> (start: Int, end: Int)? {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(name)" }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## ") {
            end = i
            break
        }
        return (start, end)
    }
}

/// Text injected into a session that works on this task: header, the whole Plan, and as much of the
/// most recent Log as fits in `max` characters.
/// Sessions started without a task get one titled "New task in <folder>" until there is more to go on.
public let placeholderTitlePrefix = "New task in "

public func taskContext(_ t: TaskFile, max: Int = 9000, crook: String = "crook") -> String {
    var head: [String] = ["You are working on shepherd task #\(t.id): \(t.title)"]
    if let o = t.objective { head.append("Objective: \(o)") }
    var status = "Status: \(t.status.rawValue)"
    if let p = t.projectPath { status += " | Project: \(p)" }
    if let b = t.branch { status += " | Branch: \(b)" }
    if let pr = t.pr { status += " | PR: \(pr)" }
    head.append(status)
    head.append("Keep the task current with the crook CLI: `\(crook) task objective <id> <text>`, `\(crook) task plan <id> add|check|uncheck`, or rewrite the whole plan by piping one step per line into `\(crook) task plan <id> set` (checked steps keep their ticks), `\(crook) task log <id> <text>`, `\(crook) task status <id> review` when the work is ready for the user to look at. Never mark a task done yourself: that is the user's call. When you move a task to review, or hit a decision you cannot make without the user, call the PushNotification tool with a one-line message that leads with what they would act on; skip it for routine progress.")

    let plan = t.section("Plan")
    let log = t.section("Log")
    if t.title.hasPrefix(placeholderTitlePrefix) {
        head.append("The title is a placeholder because the session started without a prompt. Once you know what the user wants, give the task a real title with `\(crook) task title \(t.id) <text>`.")
    }
    var missing: [String] = []
    if t.objective == nil { missing.append("an objective") }
    if plan.isEmpty { missing.append("a plan") }
    if !missing.isEmpty {
        head.append("This task is still missing \(missing.joined(separator: " and ")). It was probably captured as just a title, so treat the title as the start of the conversation, not the whole brief. As the goal becomes clear, record it with `\(crook) task objective \(t.id) <text>`, and as the approach takes shape add steps with `\(crook) task plan \(t.id) add <step>`, so a fresh session could pick the work up from the task alone.")
    }
    var out = head.joined(separator: "\n")
    if !plan.isEmpty { out += "\n\n## Plan\n" + plan.joined(separator: "\n") }
    let room = max - out.count - 20
    var kept: [String] = []
    var used = 0
    for line in log.reversed() {
        if used + line.count + 1 > room { break }
        kept.insert(line, at: 0)
        used += line.count + 1
    }
    if !kept.isEmpty {
        out += "\n\n## Log" + (kept.count < log.count ? " (most recent)" : "") + "\n" + kept.joined(separator: "\n")
    }
    return out.count > max ? String(out.prefix(max - 1)) + "…" : out
}
