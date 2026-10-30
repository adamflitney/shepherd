import Foundation
import ShepherdTasks

// crook: task CLI for agents. See docs/task-board.md.

let usage = """
crook task <command>

  new <title> [--objective <text>] [--project <path>] [--branch <name>] [--parent <id>]
  list [--status <status>] [--json]
  show <id> [--json]
  link <id> [--session <id>]     (defaults to $CLAUDE_CODE_SESSION_ID)
  status <id> <\(TaskStatus.allCases.map(\.rawValue).joined(separator: "|"))>
  title <id> <text>
  result <id> <text>             (what the task came to, written when it is wrapped up)
  objective <id> <text>
  note <id> <text>               (a finding or decision worth keeping; appended with the time)
  handoff <id> <text>            (where the work stands, for a fresh session; replaces the last)
  workspace <id>                 (prints the task's folder for scripts and files, creating it)
  log <id> <text>
  plan <id> add <text> | check <n> | uncheck <n> | set   (set reads one step per line from stdin)
  find --session <id>            (prints the linked task id, exit 1 if none)
  context <id>                   (the text a SessionStart hook injects)
crook hook session-start         (reads the hook JSON on stdin)

Other sessions (needs Shepherd running; see `crook --skill`):
  sessions [--task <id>] [--state <state>] [--json]
  session read <#task|id>
  session prompt <#task|id> <text> [--wait] [--timeout <seconds>]
  session wait <#task|id> [--until idle|done|blocked] [--timeout <seconds>]
  tasks search <words> [--json]
  --skill                        (prints the skill agents read)

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
    let valued: Set<String> = ["objective", "project", "branch", "session", "status", "parent", "task", "state", "until", "timeout"]
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

// MARK: other sessions, through the local server

let environment = ProcessInfo.processInfo.environment

func serverPort() -> Int {
    let config = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/shepherd/config.json"))
    return AgentCLI.port(env: environment, configJSON: config)
}

func call(_ method: String, _ path: String, body: [String: Any]? = nil) -> Data {
    let port = serverPort()
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 20
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    URLSession.shared.dataTask(with: request) { result = ($0, $1, $2); done.signal() }.resume()
    done.wait()
    guard let data = result.0, let http = result.1 as? HTTPURLResponse else {
        fail("can't reach Shepherd on port \(port) (is the app running?). Task commands such as `crook task show` still work without it.")
    }
    guard (200..<300).contains(http.statusCode) else {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        fail(message ?? "Shepherd answered \(http.statusCode)")
    }
    return data
}

func liveSessions() -> [AgentSession] {
    (try? JSONDecoder().decode([AgentSession].self, from: call("GET", "/api/sessions"))) ?? []
}

func target(_ reference: String?, _ sessions: [AgentSession]) -> AgentSession {
    guard let reference else { fail("which session? give an id prefix or #<task>") }
    switch AgentCLI.resolve(reference, in: sessions) {
    case .success(let s): return s
    case .failure(let e): fail(e.description)
    }
}

/// Polls until `done` holds for the session, or the timeout passes (exit 2).
func waitFor(_ id: String, timeout: Double, _ done: (AgentSession) -> Bool) -> AgentSession {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let s = liveSessions().first(where: { $0.id == id }) {
            if done(s) { return s }
        } else { fail("that session has ended") }
        if Date() >= deadline { FileHandle.standardError.write(Data("crook: timed out\n".utf8)); exit(2) }
        Thread.sleep(forTimeInterval: 1)
    }
}

func report(_ s: AgentSession) { out(AgentCLI.describe(s) + "\n") }

func runSessions(_ positionals: [String], _ opts: Options, store: TaskStore) {
    let timeout = opts.values["timeout"].flatMap(Double.init) ?? 120
    switch positionals.first {
    case "sessions":
        var list = liveSessions()
        if let t = opts.values["task"].flatMap(Int.init) { list = list.filter { $0.taskID == t } }
        if let st = opts.values["state"] { list = list.filter { $0.state == st } }
        if opts.flags.contains("json") {
            printJSON(list.map { ["id": $0.id, "title": $0.title, "state": $0.state, "task": $0.taskID as Any, "folder": $0.folder as Any, "summary": $0.summary as Any] })
        } else { out(list.isEmpty ? "No live sessions.\n" : list.map { AgentCLI.describe($0) + "\n" }.joined()) }
    case "tasks":
        guard positionals.dropFirst().first == "search" else { fail("tasks search <words>") }
        let query = positionals.dropFirst(2).joined(separator: " ")
        if query.isEmpty { fail("search needs words") }
        let hits = store.list().compactMap { t in t.search(query).map { (t, $0) } }
            .sorted { ($0.1.titleMatch ? 1 : 0, $0.0.updated ?? "") > ($1.1.titleMatch ? 1 : 0, $1.0.updated ?? "") }.prefix(30)
        if opts.flags.contains("json") {
            printJSON(hits.map { ["id": $0.0.id, "title": $0.0.title, "status": $0.0.status.rawValue, "found": $0.1.field] as [String: Any] })
        } else { out(hits.isEmpty ? "No tasks match.\n" : hits.map { "\(summary($0.0))  [in \($0.1.field)]\n" }.joined()) }
    case "session":
        let sub = positionals.dropFirst().first
        let all = liveSessions()
        let me = environment["SHEPHERD_SESSION_ID"]
        switch sub {
        case "read":
            let s = target(positionals.dropFirst(2).first, all)
            let text = (try? JSONSerialization.jsonObject(with: call("GET", "/api/sessions/\(s.id)/peek")) as? [String: Any])?["text"] as? String
            out((text ?? "") + "\n")
        case "prompt":
            let s = target(positionals.dropFirst(2).first, all)
            let text = positionals.dropFirst(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { fail("prompt needs text") }
            if let why = AgentCLI.promptRefusal(target: s, callerSessionID: me) { fail(why) }
            let crook = environment["SHEPHERD_CROOK"] ?? "crook"
            let myTask = environment["SHEPHERD_TASK_ID"].flatMap(Int.init)
            _ = call("POST", "/api/sessions/\(s.id)/prompt", body: ["text": AgentCLI.framedPrompt(text, fromSession: me, fromTask: myTask, crook: crook)])
            if let task = s.taskID {
                _ = try? store.update(task) { $0.appendLog("Message from \(myTask.map { "task #\($0)" } ?? "another session") via crook: " + String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))) }
            }
            if opts.flags.contains("wait") {
                _ = waitFor(s.id, timeout: 8) { $0.state == "working" || ($0.state == "blocked") }
                report(waitFor(s.id, timeout: timeout) { $0.isSettled })
            } else { out("sent to \(s.id.prefix(8))\n") }
        case "wait":
            let s = target(positionals.dropFirst(2).first, all)
            let until = opts.values["until"] ?? "settled"
            report(waitFor(s.id, timeout: timeout) {
                switch until {
                case "blocked": return $0.state == "blocked"
                case "done": return $0.state == "done"
                case "idle": return $0.state == "idle" || $0.state == "done"
                default: return $0.isSettled
                }
            })
        default: fail("session read|prompt|wait <#task|id>")
        }
    default: break
    }
}

func main() {
    let store = TaskStore()
    var opts = parse(Array(CommandLine.arguments.dropFirst()))
    if opts.flags.contains("skill") { return out(AgentCLI.skill(crook: environment["SHEPHERD_CROOK"].map { $0.contains(" ") ? "'\($0)'" : $0 } ?? "crook") + "\n") }
    if let first = opts.positionals.first, ["sessions", "session", "tasks"].contains(first) { return runSessions(opts.positionals, opts, store: store) }
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
                                             branch: opts.values["branch"], parent: opts.values["parent"].flatMap { Int($0) }))
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
        case "note":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("note needs text") }
            try store.update(taskID(rest.first)) { $0.appendNote(text) }
        case "handoff":
            let text = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { fail("handoff needs text") }
            try store.update(taskID(rest.first)) { $0.setHandoff(text) }
        case "workspace":
            let id = taskID(rest.first)
            guard store.get(id) != nil else { fail("no task \(id)") }
            out(try store.ensureWorkspace(for: id).path + "\n")
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
            out(taskContext(t, workspace: store.workspaceDirectory(for: t.id).path) + "\n")
        default:
            fail("unknown command \"\(cmd)\"\n\n\(usage)")
        }
    } catch {
        fail("\(error)")
    }
}

main()
