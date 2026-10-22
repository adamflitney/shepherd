import Foundation
import ShepherdTasks

// crook: task CLI for agents. See docs/task-board.md.

let usage = """
crook task <command>

  new <title> [--objective <text>] [--project <path>] [--branch <name>]
  list [--status <status>] [--json]
  show <id> [--json]
  link <id> [--session <id>]     (defaults to $CLAUDE_CODE_SESSION_ID)
  status <id> <\(TaskStatus.allCases.map(\.rawValue).joined(separator: "|"))>
  title <id> <text>
  result <id> <text>             (what the task came to, written when it is wrapped up)
  objective <id> <text>
  log <id> <text>
  plan <id> add <text> | check <n> | uncheck <n> | set   (set reads one step per line from stdin)
  find --session <id>            (prints the linked task id, exit 1 if none)
  context <id>                   (the text a SessionStart hook injects)
crook hook session-start         (reads the hook JSON on stdin)

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("crook: \(message)\n".utf8))
    exit(1)
}

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

func taskID(_ s: String?) -> Int {
    guard let s, let n = Int(s), n >= 1 else { fail("expected a task number, got \"\(s ?? "")\"") }
    return n
}

func summary(_ t: TaskFile) -> String {
    let p = t.progress
    let progress = p.total > 0 ? " (\(p.done)/\(p.total))" : ""
    return "\(String(t.id).leftPad(4))  \(t.status.rawValue.rightPad(7)) \(t.title)\(progress)"
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
    func rightPad(_ n: Int) -> String { self + String(repeating: " ", count: max(0, n - count)) }
}

func json(_ t: TaskFile) -> [String: Any] {
    var d: [String: Any] = ["id": t.id, "title": t.title, "status": t.status.rawValue, "sessions": t.sessions,
                            "progress": ["done": t.progress.done, "total": t.progress.total]]
    if let v = t.objective { d["objective"] = v }
    if let v = t.projectPath { d["projectPath"] = v }
    if let v = t.branch { d["branch"] = v }
    if let v = t.pr { d["pr"] = v }
    return d
}

func printJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
    out(String(decoding: data, as: UTF8.self) + "\n")
}

struct Options {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    let valued: Set<String> = ["objective", "project", "branch", "session", "status"]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let name = String(a.dropFirst(2))
            if valued.contains(name) {
                i += 1
                guard i < args.count else { fail("--\(name) needs a value") }
                o.values[name] = args[i]
            } else {
                o.flags.insert(name)
            }
        } else if a == "-h" {
            o.flags.insert("help")
        } else {
            o.positionals.append(a)
        }
        i += 1
    }
    return o
}

func runHook(_ name: String?, store: TaskStore) {
    guard name == "session-start" else { fail("unknown hook \"\(name ?? "")\"") }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    // a hook must never break the session
    guard let input = try? JSONDecoder().decode(SessionStartInput.self, from: data),
          let output = sessionStartHookOutput(input, env: ProcessInfo.processInfo.environment, store: store) else { return }
    out(output + "\n")
}

func main() {
    let store = TaskStore()
    var opts = parse(Array(CommandLine.arguments.dropFirst()))
    if opts.positionals.first == "hook" { return runHook(opts.positionals.dropFirst().first, store: store) }
    if opts.positionals.first == "task" { opts.positionals.removeFirst() }
    guard let cmd = opts.positionals.first, !opts.flags.contains("help") else { return out(usage) }
    let rest = Array(opts.positionals.dropFirst())

    do {
        switch cmd {
        case "new":
            let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if title.isEmpty { fail("new needs a title") }
            let t = try store.create(NewTask(title: title, objective: opts.values["objective"],
                                             projectPath: opts.values["project"] ?? FileManager.default.currentDirectoryPath,
                                             branch: opts.values["branch"]))
            out("\(t.id)\n")
        case "list":
            var tasks = store.list()
            if let s = opts.values["status"] { tasks = tasks.filter { $0.status.rawValue == s } }
            if opts.flags.contains("json") { printJSON(tasks.map(json)) } else { out(tasks.map { summary($0) + "\n" }.joined()) }
        case "show":
            guard let t = store.get(taskID(rest.first)) else { fail("no task \(rest.first ?? "")") }
            if opts.flags.contains("json") { printJSON(json(t)) } else { out(t.serialize()) }
        case "link":
            let id = taskID(rest.first)
            guard let session = opts.values["session"] ?? ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] else {
                fail("no session id: pass --session or run inside Claude Code")
            }
            try store.update(id) { $0.linkSession(session) }
        case "status":
            let id = taskID(rest.first)
            guard rest.count > 1, let status = TaskStatus(rawValue: rest[1]) else {
                fail("status must be one of \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            if status == .done, ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] != nil {
                fail("marking a task done is the user's call; use \"review\" when the work is ready for them")
            }
            try store.update(id) { $0.setStatus(status) }
        case "objective":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("objective needs text") }
            try store.update(taskID(rest.first)) { $0.setObjective(text) }
        case "title":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("title needs text") }
            try store.update(taskID(rest.first)) { $0.setTitle(text) }
        case "result":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("result needs text") }
            try store.update(taskID(rest.first)) { $0.setResult(text) }
        case "log":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("log needs text") }
            try store.update(taskID(rest.first)) { $0.appendLog(text) }
        case "plan":
            let id = taskID(rest.first)
            let sub = rest.dropFirst().first
            let args = Array(rest.dropFirst(2))
            if sub == "add", !args.isEmpty {
                try store.update(id) { $0.addPlanItem(args.joined(separator: " ")) }
            } else if sub == "check" || sub == "uncheck", let n = args.first {
                try store.update(id) { try $0.setPlanItem(taskID(n), done: sub == "check") }
            } else if sub == "set" {
                let steps = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: #"^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression) }
                try store.update(id) { $0.setPlan(steps) }
            } else {
                fail("plan <id> add <text> | check <n> | uncheck <n> | set")
            }
        case "find":
            guard let session = opts.values["session"] else { fail("find needs --session") }
            guard let t = store.findBySession(session) else { exit(1) }
            out("\(t.id)\n")
        case "context":
            guard let t = store.get(taskID(rest.first)) else { fail("no task \(rest.first ?? "")") }
            out(taskContext(t) + "\n")
        default:
            fail("unknown command \"\(cmd)\"\n\n\(usage)")
        }
    } catch {
        fail("\(error)")
    }
}

main()
